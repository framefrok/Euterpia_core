# cli/cmd_history.nim
#
# Команды истории CLI: `undo`, `redo`, `history` (issue #331).
#
# Идея: CLI — процесс на одну команду, поэтому «отменить последнее действие»
# возможно только если история ПЕРЕЖИВАЕТ перезапуск. Она и переживает: стек
# записей лежит сайдкаром рядом с проектом (`cli/history_file`), а сами
# команды применяет control-слой — клиент лишь двигает записи между стеками.
#
# Границы (§20, §65):
#   - отмену/повтор исполняет ЯДРО (`Document.applyTransaction`), а не CLI:
#     обратные команды построены `planTransaction`, и откат идёт тем же путём,
#     что и обычная правка;
#   - запись новой операции в историю делает изменяющая команда (см.
#     `cmd_graph.commitEditWithHistory`), а `undo`/`redo` историю только
#     двигают — иначе отмена сама стала бы «действием, которое можно отменить»
#     и стек зациклился бы.

import std/[json, strutils]

import context
import cmd_project
import control_bridge
import history_file
import control/document
import control/error_frame
import cli_spec

const
  HistoryOptions* = @[
    opt("--file", "проект: " & projectSuffixesHint() & "; по умолчанию " &
        DefaultProjectFile, value = "проект.eproj"),
  ]
    ## Ключ общий у `undo`, `redo` и `history`: все три работают с проектом и
    ## его сайдкаром истории, поэтому «какой файл правится» описывается один
    ## раз (как у команд графа).

# =============================================================================
# Спецификации команд (#330)
# =============================================================================

const
  UndoSpec* = CommandSpec(
    name: "undo",
    summary: "отменить последнюю правку проекта",
    synopsis: "undo [файл] [--file проект.eproj]",
    options: HistoryOptions,
    args: @[
      arg("файл", "проект: " & projectSuffixesHint() &
        "; по умолчанию " & DefaultProjectFile),
    ],
    example: "euterpia undo project.eproj",
    fields: @[
      field("path", "проект, к которому применена отмена"),
      field("action", "`undo` — что сделала команда"),
      field("description", "что именно было отменено (описание записи истории)"),
      field("commands", "сколько обратных команд применено"),
      field("undoDepth", "сколько операций ещё можно отменить"),
      field("redoDepth", "сколько операций можно повторить"),
    ],
    notes: @[
      "история хранится рядом с проектом (`<проект>.history`) и переживает перезапуск CLI",
      "отмена применяется транзакцией: отказ не оставляет половины изменений",
      "отменять нечего — код 1 с причиной `invalid_argument`, а не тихий успех",
      "`--dry-run` показывает отменяемое действие, но не пишет ни проект, ни историю",
    ])

  RedoSpec* = CommandSpec(
    name: "redo",
    summary: "повторить отменённую правку проекта",
    synopsis: "redo [файл] [--file проект.eproj]",
    options: HistoryOptions,
    args: @[
      arg("файл", "проект: " & projectSuffixesHint() &
        "; по умолчанию " & DefaultProjectFile),
    ],
    example: "euterpia redo project.eproj",
    fields: @[
      field("path", "проект, к которому применён повтор"),
      field("action", "`redo` — что сделала команда"),
      field("description", "что именно повторено (описание записи истории)"),
      field("commands", "сколько команд записи повторно применено"),
      field("undoDepth", "сколько операций ещё можно отменить"),
      field("redoDepth", "сколько операций можно повторить"),
    ],
    notes: @[
      "новая правка сбрасывает повтор: после неё повторять нечего",
      "повторять нечего — код 1 с причиной `invalid_argument`",
    ])

  HistorySpec* = CommandSpec(
    name: "history",
    summary: "показать историю правок проекта",
    synopsis: "history [сколько] [файл] [--file проект.eproj]",
    options: HistoryOptions,
    args: @[
      arg("сколько", "сколько последних операций показать; без числа — все"),
      arg("файл", "проект: " & projectSuffixesHint() &
        "; по умолчанию " & DefaultProjectFile),
    ],
    example: "euterpia history 10 project.eproj",
    fields: @[
      field("path", "проект, чью историю показали"),
      field("undoDepth", "сколько операций можно отменить"),
      field("redoDepth", "сколько операций можно повторить"),
      field("undo", "стек отмены: описания записей и число команд"),
      field("redo", "стек повтора: описания записей и число команд"),
    ],
    notes: @[
      "не меняет ни проект, ни историю: это чтение",
      "битый или чужой файл истории — код 1 с причиной `check_failed`, а не «пустая история»",
    ])

# =============================================================================
# Разбор аргументов
# =============================================================================

type
  HistoryScan = object
    ok: bool
    rep: Report
    path: string
    count: int
      ## `history <сколько>`: сколько последних записей показать.
    haveCount: bool

proc scanHistory(args: seq[string]; what: string; allowCount: bool): HistoryScan =
  ## Разбор общий для `undo`, `redo`, `history`: необязательный файл проекта
  ## (позиционно или `--file`) и — только у `history` — число записей. Правило
  ## файла то же, что у команд графа (`isProjectPath`): «какой аргумент файл»
  ## решается одним списком расширений, а не догадкой (§82).
  result.path = DefaultProjectFile
  var haveFile = false
  var positionals: seq[string] = @[]
  var i = 0
  while i < args.len:
    let token = args[i]
    var key = token
    var value = ""
    var haveInline = false
    let eq = token.find('=')
    if token.startsWith("--") and eq > 0:
      key = token[0 ..< eq]
      value = token[eq + 1 .. ^1]
      haveInline = true

    if key == "--file":
      if not haveInline:
        if i + 1 >= args.len:
          result.rep = usageError("--file требует значение",
                                  "например: euterpia " & what & " --file " &
                                  DefaultProjectFile)
          return
        inc i
        value = args[i]
      result.path = value
      haveFile = true
    elif token.startsWith("--"):
      result.rep = usageError("неизвестный ключ: " & token, "ключ: --file")
      return
    else:
      positionals.add token
    inc i

  # Позиционные аргументы: число (`history`) и/или файл проекта. Файл — по
  # расширению, число — только у `history`; всё остальное — ошибка данных.
  var filePosition = -1
  for idx in 0 ..< positionals.len:
    let token = positionals[idx]
    if isProjectPath(token):
      if filePosition >= 0:
        result.rep = usageError(
          "указано несколько файлов проекта: " &
            positionals[filePosition] & ", " & token,
          "оставьте один файл или задайте --file")
        return
      filePosition = idx
    elif allowCount and token.len > 0 and token.allCharsInSet({'0'..'9'}):
      if result.haveCount:
        result.rep = usageError(what & ": число указано дважды: " & token,
                                "например: euterpia history 10 " &
                                DefaultProjectFile)
        return
      result.count = parseInt(token)
      result.haveCount = true
    else:
      result.rep = usageError(what & ": лишний аргумент: " & token,
                              (if allowCount:
                                 "например: euterpia history 10 " & DefaultProjectFile
                               else:
                                 "например: euterpia " & what & " " &
                                 DefaultProjectFile))
      return

  if filePosition >= 0:
    if haveFile:
      result.rep = usageError(
        "файл указан дважды: --file и " & positionals[filePosition],
        "оставьте что-то одно")
      return
    result.path = positionals[filePosition]
  result.ok = true


# =============================================================================
# Представление истории
# =============================================================================

proc stackJson(entries: seq[HistoryEntry]): JsonNode =
  ## Стек записей машинно: описание и число команд. Порядок — как в файле
  ## (новые в конце), поэтому агент видит и «что отменять следующим».
  result = newJArray()
  for entry in entries:
    result.add %*{"description": entry.description, "commands": entry.redo.len}

proc historyBody(hist: CliHistory; path: string): JsonNode =
  ## Машинный вид истории: глубины стеков и их содержимое.
  %*{
    "path": path,
    "undoDepth": hist.undoStack.len,
    "redoDepth": hist.redoStack.len,
    "undo": stackJson(hist.undoStack),
    "redo": stackJson(hist.redoStack),
  }

# =============================================================================
# history
# =============================================================================

proc runHistory*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia history [сколько] [файл]`. Чтение истории: проект и сайдкар не
  ## меняются. Битый файл истории — отказ с кодом, а не «пустая история».
  discard ctx
  let scan = scanHistory(args, "history", allowCount = true)
  if not scan.ok:
    return scan.rep

  var hist: CliHistory
  let read = readHistory(scan.path, hist)
  if not read.isOk():
    return frameReport(read)

  var lines: seq[string] = @[
    "файл: " & scan.path,
    "история: отменить " & $hist.undoStack.len &
      ", повторить " & $hist.redoStack.len,
  ]
  if hist.undoStack.len == 0:
    lines.add "  (история пуста)"
  else:
    let limit =
      if scan.haveCount: min(scan.count, hist.undoStack.len)
      else: hist.undoStack.len
    var shown = 0
    var i = hist.undoStack.high
    while i >= 0 and shown < limit:
      let entry = hist.undoStack[i]
      lines.add "  " & entry.description & " (команд: " & $entry.redo.len & ")"
      inc shown
      dec i
  okReport(body = historyBody(hist, scan.path), lines = lines)

# =============================================================================
# undo
# =============================================================================

proc runUndo*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia undo [файл]`. Отмена последней записи: применяются её ОБРАТНЫЕ
  ## команды (транзакцией), запись переезжает из стека отмены в стек повтора.
  let scan = scanHistory(args, "undo", allowCount = false)
  if not scan.ok:
    return scan.rep

  var hist: CliHistory
  let read = readHistory(scan.path, hist)
  if not read.isOk():
    return frameReport(read)
  if hist.undoStack.len == 0:
    return usageError("отменять нечего: история пуста",
                      "файл истории: " & historyPath(scan.path),
                      code = ecInvalidArgument)
  let entry = hist.undoStack[^1]

  if ctx.dryRun:
    return okReport(
      body = %*{"path": scan.path, "action": "undo",
                "description": entry.description,
                "commands": entry.undo.len,
                "undoDepth": hist.undoStack.len - 1,
                "redoDepth": hist.redoStack.len + 1},
      lines = @[
        "файл: " & scan.path,
        "будет отменено: " & entry.description &
          " (команд: " & $entry.undo.len & ")",
        "не записан: " & scan.path & " (--dry-run)",
      ])

  let loaded = loadAt(scan.path)
  if not loaded.ok:
    return loaded.rep
  var doc = openDocument(scan.path, loaded.proj)
  let applied = doc.applyTransaction(entry.undo, "отмена: " & entry.description)
  if not applied.frame.isOk():
    return frameReport(applied.frame)

  let saved = writeAtomic(scan.path, doc.proj)
  if not saved.success:
    return saveError(saved, scan.path)

  discard hist.popUndo()
  hist.pushRedo(entry)
  let written = writeHistory(scan.path, hist)
  if not written.isOk():
    return frameReport(written)

  okReport(
    body = %*{"path": scan.path, "action": "undo",
              "description": entry.description,
              "commands": entry.undo.len,
              "undoDepth": hist.undoStack.len,
              "redoDepth": hist.redoStack.len},
    lines = @[
      "файл: " & scan.path,
      "отменено: " & entry.description,
      "осталось: отменить " & $hist.undoStack.len &
        ", повторить " & $hist.redoStack.len,
      "записан: " & scan.path,
    ])


# =============================================================================
# redo
# =============================================================================

proc runRedo*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia redo [файл]`. Повтор последней отменённой записи: применяются её
  ## ИСХОДНЫЕ команды, запись возвращается из стека повтора в стек отмены.
  let scan = scanHistory(args, "redo", allowCount = false)
  if not scan.ok:
    return scan.rep

  var hist: CliHistory
  let read = readHistory(scan.path, hist)
  if not read.isOk():
    return frameReport(read)
  if hist.redoStack.len == 0:
    return usageError("повторять нечего: история повтора пуста",
                      "файл истории: " & historyPath(scan.path),
                      code = ecInvalidArgument)
  let entry = hist.redoStack[^1]

  if ctx.dryRun:
    return okReport(
      body = %*{"path": scan.path, "action": "redo",
                "description": entry.description,
                "commands": entry.redo.len,
                "undoDepth": hist.undoStack.len + 1,
                "redoDepth": hist.redoStack.len - 1},
      lines = @[
        "файл: " & scan.path,
        "будет повторено: " & entry.description &
          " (команд: " & $entry.redo.len & ")",
        "не записан: " & scan.path & " (--dry-run)",
      ])

  let loaded = loadAt(scan.path)
  if not loaded.ok:
    return loaded.rep
  var doc = openDocument(scan.path, loaded.proj)
  let applied = doc.applyTransaction(entry.redo, "повтор: " & entry.description)
  if not applied.frame.isOk():
    return frameReport(applied.frame)

  let saved = writeAtomic(scan.path, doc.proj)
  if not saved.success:
    return saveError(saved, scan.path)

  discard hist.popRedo()
  hist.pushUndo(entry)
  let written = writeHistory(scan.path, hist)
  if not written.isOk():
    return frameReport(written)

  okReport(
    body = %*{"path": scan.path, "action": "redo",
              "description": entry.description,
              "commands": entry.redo.len,
              "undoDepth": hist.undoStack.len,
              "redoDepth": hist.redoStack.len},
    lines = @[
      "файл: " & scan.path,
      "повторено: " & entry.description,
      "осталось: отменить " & $hist.undoStack.len &
        ", повторить " & $hist.redoStack.len,
      "записан: " & scan.path,
    ])

