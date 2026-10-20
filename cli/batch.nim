# cli/batch.nim
#
# Пакетный режим (`--script`), перенаправленный stdin и REPL (#97, #334).
#
# Почему это НЕ «запустить euterpia ещё раз на каждую строку»:
#   * сессия одна: `open demo.eproj` загружает проект один раз, дальше команды
#     правят его, а не перечитывают файл с диска;
#   * разбор argv один (`cli/dispatch.executeArgv`), поэтому строка сценария и
#     обычный вызов понимают ключи одинаково;
#   * в `--json` каждая строка даёт РОВНО один JSON-объект, а итог — последнюю
#     строку: поток читается построчно (NDJSON), «человеческих» вставок нет.
#
# Чего здесь нет и не будет: вызова оболочки. Строка разбирается на слова
# собственным токенизатором с кавычками и `#`-комментариями; `$(…)`, `|`, `;`
# остаются частью аргумента. CLI исполняет только СВОИ команды (MANIFEST §21).
#
# Коды возврата: ошибка в середине останавливает сценарий (код первой ошибки)
# или, с `--keep-going`, копится в отчёте. Код 0 — всё выполнено.

import std/[json, strutils]

import context
import dispatch
import cmd_project
import cmd_session

type
  BatchState* = object
    ## Состояние сессии: счётчики и первая ошибка. Живёт столько же, сколько
    ## REPL/сценарий, — поэтому `status` видит настоящую картину, а не
    ## «одну команду».
    executed*: int
    failed*: int
    lastCode*: ExitCode
    haveFirstError*: bool
    firstCode*: ExitCode
    errors*: seq[JsonNode]
      ## По строке на ошибку: `line`, `exitCode`, `message`. Машинный список
      ## для CI и агента; текст в human-выводе собирается из него же.

  LineOutcome = object
    rep: Report
    stop: bool

# =============================================================================
# Токенизатор строки
# =============================================================================

proc tokenizeLine*(line: string; tokens: var seq[string];
                   problem: var string): bool =
  ## Строка → слова. Поддерживаются одиночные и двойные кавычки, экранирование
  ## `\"` внутри двойных и `\\` вне кавычек, `#` — комментарий до конца строки
  ## (только в начале слова: `gain#1` остаётся именем).
  ##
  ## Никакой оболочки: `$`, `|`, `;` — обычные символы аргумента.
  var current = ""
  var haveToken = false
  var quote = '\0'
  var i = 0
  while i < line.len:
    let ch = line[i]
    if quote == '\0':
      case ch
      of ' ', '\t':
        if haveToken:
          tokens.add current
          current = ""
          haveToken = false
      of '#':
        if haveToken:
          current.add ch
        else:
          break
      of '\'', '"':
        quote = ch
        haveToken = true
      of '\\':
        if i + 1 >= line.len:
          problem = "строка заканчивается обратной косой чертой"
          return false
        inc i
        current.add line[i]
        haveToken = true
      else:
        current.add ch
        haveToken = true
    else:
      if ch == quote:
        quote = '\0'
      elif ch == '\\' and quote == '"':
        if i + 1 >= line.len:
          problem = "строка заканчивается обратной косой чертой в кавычках"
          return false
        inc i
        current.add line[i]
      else:
        current.add ch
    inc i
  if quote != '\0':
    problem = "незакрытая кавычка"
    return false
  if haveToken:
    tokens.add current
  true

# =============================================================================
# Команды сессии (`open`, `save`, `save-as`, `status`, `exit`)
# =============================================================================

proc cmdOpen(ctx: var Ctx; args: seq[string]): Report =
  ## Загрузить проект один раз. Проверка — тем же `loadAt`, что у остальных
  ## команд: «открыть» не значит «поверить, что это проект».
  if args.len != 1:
    return usageError("open: нужен один файл проекта",
      "например: open demo" & ProjectExt)
  if not isProjectPath(args[0]):
    return usageError("open: это не файл проекта: " & args[0],
      "проект — " & projectSuffixesHint())
  let loaded = loadAt(args[0])
  if not loaded.ok:
    return loaded.rep
  ctx.sessionProject = args[0]
  okReport(body = %*{"project": ctx.sessionProject},
           lines = @["открыт проект: " & ctx.sessionProject])

proc cmdSave(ctx: var Ctx; args: seq[string]; saveAs: bool): Report =
  ## Сохранить проект сессии. Изменяющие команды пишут файл сразу (атомарно),
  ## поэтому `save` без аргумента — подтверждение, а `save-as` — копия в новый
  ## файл и переключение сессии на него.
  if ctx.sessionProject.len == 0:
    return usageError("save: проект не открыт",
      "сначала: open demo" & ProjectExt)
  if args.len == 0:
    if saveAs:
      return usageError("save-as: нужен новый путь",
        "например: save-as copy" & ProjectExt)
    return okReport(
      body = %*{"project": ctx.sessionProject, "written": false},
      lines = @["проект уже записан: " & ctx.sessionProject,
                "каждая изменяющая команда пишет файл сразу"])
  if args.len > 1:
    return usageError("save: лишние аргументы: " & args[1 .. ^1].join(" "))
  let target = args[0]
  if not isProjectPath(target):
    return usageError("save: целевой файл не похож на проект: " & target,
      "проект — " & projectSuffixesHint())
  let loaded = loadAt(ctx.sessionProject)
  if not loaded.ok:
    return loaded.rep
  let saved = writeAtomic(target, loaded.proj)
  if not saved.success:
    return saveError(saved, target)
  ctx.sessionProject = target
  okReport(body = %*{"project": target, "written": true},
           lines = @["записан: " & target])


proc cmdStatus(ctx: var Ctx; state: BatchState): Report =
  ## Состояние сессии: какой проект открыт, режим вывода, счётчики и —
  ## отдельным блоком — состояние runtime-сессии транспорта (#407). Без
  ## запущенного демона блок честно говорит `running: false`.
  var body = %*{
    "project": ctx.sessionProject,
    "mode": (if ctx.mode == omJson: "json" else: "human"),
    "dryRun": ctx.dryRun,
    "executed": state.executed,
    "failed": state.failed,
    "lastExitCode": int(ord(state.lastCode)),
  }
  var lines = @[
    "проект: " & (if ctx.sessionProject.len > 0: ctx.sessionProject
                  else: "(не открыт; команда open <файл>)"),
    "режим вывода: " & (if ctx.mode == omJson: "json" else: "human") &
      (if ctx.dryRun: ", --dry-run" else: ""),
    "команд выполнено: " & $state.executed & ", ошибок: " & $state.failed,
  ]
  let statusArgs =
    if ctx.sessionProject.len > 0: @["status", ctx.sessionProject]
    else: @["status"]
  let runtime = runSession(ctx, statusArgs)
  if runtime.ok:
    body["session"] = runtime.body
    for line in runtime.lines:
      lines.add "runtime: " & line
  okReport(body = body, lines = lines)

# =============================================================================
# Одна строка сценария
# =============================================================================

proc sessionCommand(ctx: var Ctx; tokens: seq[string];
                    state: BatchState): LineOutcome =
  ## Команды сессии распознаются ДО реестра: у них нет CLI-команды, потому что
  ## они существуют только внутри сессии (`open`, `save`, `status`, `exit`).
  let head = tokens[0]
  ctx.command = head
  case head
  of "open":
    result.rep = cmdOpen(ctx, tokens[1 .. ^1])
  of "save":
    result.rep = cmdSave(ctx, tokens[1 .. ^1], saveAs = false)
  of "save-as":
    result.rep = cmdSave(ctx, tokens[1 .. ^1], saveAs = true)
  of "status":
    result.rep = cmdStatus(ctx, state)
  of "exit", "quit":
    result.stop = true
    result.rep = okReport(lines = @["выход из сессии"])
  else:
    result.rep = usageError("неизвестная команда сессии: " & head)

proc runLine(ctx: var Ctx; line: string; lineNo: int;
             state: BatchState): LineOutcome =
  ## Одна строка: разбор, команда сессии или обычная команда CLI.
  var tokens: seq[string] = @[]
  var problem = ""
  if not tokenizeLine(line, tokens, problem):
    ctx.command = "script"
    result.rep = usageError("строка " & $lineNo & ": " & problem,
      "кавычки закрываются в той же строке; `#` начинает комментарий")
    return
  if tokens.len == 0:
    result.rep = okReport()
    return
  if tokens[0] in ["open", "save", "save-as", "status", "exit", "quit"]:
    result = sessionCommand(ctx, tokens, state)
    return
  result.rep = executeArgv(ctx, tokens)


# =============================================================================
# Пакетный прогон
# =============================================================================

proc summaryReport(source: string; state: BatchState): Report =
  ## Итог сценария. `--json` получает его отдельной NDJSON-строкой, human —
  ## строками; в обоих случаях видно, сколько выполнено и что упало.
  var body = %*{
    "source": source,
    "executed": state.executed,
    "failed": state.failed,
    "errors": state.errors,
  }
  var lines = @["сценарий: " & source,
                "команд: " & $state.executed & ", ошибок: " & $state.failed]
  for item in state.errors:
    lines.add "  строка " & $item["line"].getInt &
      " (код " & $item["exitCode"].getInt & "): " & $item["message"].getStr
  if state.failed == 0:
    return okReport(body = body, lines = lines)
  result = Report(ok: false, code: state.firstCode, errorKind: "usage",
                  error: "сценарий: команд упало " & $state.failed,
                  hint: "", lines: lines, body: body,
                  errorCode: state.errors[0]["errorCode"].getInt(0))

proc noteFailure(state: var BatchState; lineNo: int; rep: Report) =
  ## Учесть отказ: счётчик, первая причина и машинная строка ошибки.
  inc state.failed
  if not state.haveFirstError:
    state.haveFirstError = true
    state.firstCode = rep.code
  state.errors.add %*{
    "line": lineNo,
    "exitCode": int(ord(rep.code)),
    "errorCode": rep.errorCode,
    "message": (if rep.error.len > 0: rep.error else: rep.lines.join(" ")),
  }

proc runBatchLines*(ctx: var Ctx; lines: seq[string]; keepGoing: bool;
                    source: string): int =
  ## Выполнить строки сценария. `keepGoing` — не останавливаться на первой
  ## ошибке; код возврата всё равно по ПЕРВОЙ ошибке (так сценарий остаётся
  ## детерминированным ответом, а не «где-то упало»).
  var state = BatchState(lastCode: exOk)
  var lineNo = 0
  for line in lines:
    inc lineNo
    # Пустые строки и комментарии не считаются командами: сценарий читается
    # человеком, и «выполнено 0, ошибок 0» на комментарий было бы ложью.
    var probe: seq[string] = @[]
    var probeProblem = ""
    if tokenizeLine(line, probe, probeProblem) and probe.len == 0:
      continue
    let outcome = runLine(ctx, line, lineNo, state)
    emit(ctx, outcome.rep)
    inc state.executed
    state.lastCode = outcome.rep.code
    if not outcome.rep.ok:
      noteFailure(state, lineNo, outcome.rep)
      if not keepGoing:
        break
    if outcome.stop:
      break
  let summary = summaryReport(source, state)
  emit(ctx, summary)
  ord(summary.code)

# =============================================================================
# REPL
# =============================================================================

proc writePrompt(ctx: Ctx) =
  ## Приглашение — ТОЛЬКО в stderr: stdout принадлежит результату команд, и
  ## `euterpia --json` в REPL обязан оставаться потоком JSON (#21, #97).
  if ctx.mode != omHuman or ctx.quiet:
    return
  try:
    stderr.write(CliName & "> ")
    stderr.flushFile()
  except CatchableError:
    discard

proc runRepl*(ctx: var Ctx): int =
  ## Интерактивный режим: та же строка, что в сценарии, но вводится руками.
  ## Выход — `exit`/`quit` или Ctrl-D (EOF). Внешних readline-библиотек нет:
  ## REPL обязан работать в pipe и на машине без зависимостей (#97).
  var state = BatchState(lastCode: exOk)
  var lineNo = 0
  if ctx.mode == omHuman and not ctx.quiet:
    cliWarn(CliName & " " & EuterpiaVersion &
            " — REPL; `help`, `status`, `open <проект>`, `exit` или Ctrl-D")
  while true:
    writePrompt(ctx)
    var line = ""
    if not stdin.readLine(line):
      break
    inc lineNo
    var probe: seq[string] = @[]
    var probeProblem = ""
    if tokenizeLine(line, probe, probeProblem) and probe.len == 0:
      continue
    let outcome = runLine(ctx, line, lineNo, state)
    emit(ctx, outcome.rep)
    inc state.executed
    state.lastCode = outcome.rep.code
    if not outcome.rep.ok:
      noteFailure(state, lineNo, outcome.rep)
    if outcome.stop:
      break
  if state.failed > 0: ord(state.firstCode) else: 0

