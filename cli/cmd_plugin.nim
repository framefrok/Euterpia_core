# cli/cmd_plugin.nim
#
# `euterpia plugin` — пользовательский путь к внешним плагинам (issue #95) и
# обёртка официального `clap-validator` (issue #260).
#
# Границы (§20, §40-§42):
#   * CLI не трогает CLAP-ABI — только `core/plugin_api` (через адаптер);
#   * состояние плагина — непрозрачный блоб в проекте; его пишет и читает
#     хост, а не Core;
#   * `plugin validate` ничего не «проверяет сам»: он запускает внешний
#     валидатор и разбирает его вывод. Нет валидатора — код 2 и подсказка,
#     а не имитация проверки.
#
# Подкоманды:
#   scan    <файл.clap|каталог>   перечислить плагины библиотеки;
#   info    <файл.clap> [--index N] подробности и параметры;
#   params  <проект> <нода>       значения параметров инстанса;
#   save    <проект> <нода>       снимок состояния в проект;
#   validate <файл.clap> [--validator путь]  прогон официального валидатора.

import std/[algorithm, json, os, osproc, strutils, sha1, tables]

import context
import cli_spec
import cmd_project
import plugin_api
import plugin_host
import clap_plugin_backend
import control/query
import control/document
import control_bridge
import control/error_frame
import project

const
  PluginSubcommands* = @["scan", "info", "params", "save", "validate"]

  PluginSpec* = CommandSpec(
    name: "plugin",
    summary: "внешние плагины: scan/info/params/save/validate",
    synopsis: "plugin <scan|info|params|save|validate> [аргументы] [ключи]",
    subcommands: PluginSubcommands,
    commandArgs: true,
    args: @[
      arg("подкоманда", "scan | info | params | save | validate"),
      arg("аргументы", "путь к .clap/каталогу или проект и id ноды"),
    ],
    options: @[
      opt("--index", "индекс плагина в библиотеке (по умолчанию 0)", value = "N"),
      opt("--validator", "путь к clap-validator (иначе поиск в PATH)", value = "путь"),
    ],
    example: "euterpia plugin scan /usr/lib/clap --json",
    fields: @[
      field("subcommand", "выполненная подкоманда"),
      field("files", "библиотеки/бандлы, которые просмотрены"),
      field("plugins", "найденные плагины: id, name, vendor, порты, параметры"),
      field("plugin", "подробности одного плагина (`info`)"),
      field("node", "нода проекта (`params`/`save`)"),
      field("params", "параметры инстанса: id, имя, значение"),
      field("state", "сохранённое состояние: bytes, sha1 (`save`)"),
      field("validator", "путь и код возврата внешнего валидатора"),
      field("checks", "проверки валидатора: id, status, message"),
      field("passed", "валидатор: все проверки пройдены"),
      field("failed", "валидатор: сколько проверок упало"),
    ],
    notes: @[
      "нет CLAP-адаптера — код 2, а не паника: `plugin scan` честно говорит, чего нет",
      "`save` пишет непрозрачный блоб состояния в проект; байты в `project show` не печатаются — только размер и хеш",
      "`validate` не подменяет валидатор своим кодом: нет инструмента — код 2 с подсказкой установки (#260)",
      "валидатор запускается на control-path; аудиоустройство не открывается, плагин в процесс CLI не грузится (#260)",
    ])

type
  PluginArgs = object
    ok: bool
    rep: Report
    sub: string
    positional: seq[string]
    index: int32
    validator: string

proc toInt32(text, key: string; low, high: int32):
    tuple[ok: bool; value: int32; message: string] =
  try:
    let v = parseInt(text.strip())
    if v < int(low) or v > int(high):
      return (false, 0'i32, key & ": диапазон " & $low & ".." & $high)
    (true, int32(v), "")
  except ValueError:
    (false, 0'i32, key & ": ожидается целое, получено «" & text & "»")

proc parseArgs(args: seq[string]): PluginArgs =
  if args.len == 0:
    return PluginArgs(rep: usageError("plugin: нужна подкоманда",
      "подкоманды: " & PluginSubcommands.join(", ")))
  result.sub = args[0]
  if result.sub notin PluginSubcommands:
    return PluginArgs(rep: usageError("неизвестная подкоманда plugin: " &
                                      result.sub,
      "подкоманды: " & PluginSubcommands.join(", ")))
  var i = 1
  while i < args.len:
    let a = args[i]
    if a == "--index":
      if i + 1 >= args.len:
        return PluginArgs(rep: usageError("--index: нужно число"))
      let parsed = toInt32(args[i + 1], "--index", 0, int32(high(int32)))
      if not parsed.ok:
        return PluginArgs(rep: usageError(parsed.message))
      result.index = parsed.value
      inc i, 2
      continue
    if a == "--validator":
      if i + 1 >= args.len:
        return PluginArgs(rep: usageError("--validator: нужен путь"))
      result.validator = args[i + 1]
      inc i, 2
      continue
    if a.len > 1 and a[0] == '-':
      return PluginArgs(rep: usageError("неизвестный ключ: " & a,
        "ключи plugin: --index, --validator"))
    result.positional.add a
    inc i
  result.ok = true

# ==============================================================================
# Общее: адаптер и представление плагина
# ==============================================================================

proc categoryName(c: PluginCategory): string =
  case c
  of pcEffect: "effect"
  of pcInstrument: "instrument"
  of pcNoteEffect: "note-effect"
  of pcAnalyzer: "analyzer"
  else: "unknown"

proc pluginJson(file: string; index: int32; info: PluginInfo): JsonNode =
  %*{
    "file": file,
    "index": index,
    "id": info.id,
    "name": info.name,
    "vendor": info.vendor,
    "version": info.version,
    "category": categoryName(info.category),
    "audioIn": info.audioInCount,
    "audioOut": info.audioOutCount,
    "noteIn": info.noteInCount,
    "noteOut": info.noteOutCount,
    "params": info.paramCount,
    "hasState": info.hasState,
    "latency": info.reportedLatency,
  }

proc collectClapFiles(path: string): seq[string] =
  ## Файл `.clap` либо каталог с библиотеками. Каталоги обходятся
  ## рекурсивно: плагины часто лежат в подкаталогах (`/usr/lib/clap/Foo.clap`).
  if fileExists(path):
    return @[path]
  if dirExists(path):
    for item in walkDirRec(path, yieldFilter = {pcFile}):
      if item.toLowerAscii().endsWith(".clap"):
        result.add item
    result.sort()

proc requireApi(): tuple[api: ptr PluginApi; rep: Report] =
  let api = pluginHostApi()
  if api.isNil:
    return (nil, envError("CLAP-адаптер недоступен: плагины не читаются",
      "проверьте сборку CLI и права на чтение библиотеки; `euterpia doctor`"))
  (api, okReport())

proc scanLibraries(api: ptr PluginApi; path: string):
    tuple[plugins: seq[JsonNode], files: int, error: string] =
  let files = collectClapFiles(path)
  result.files = files.len
  for file in files:
    let count = pluginCount(api, cstring(file))
    if count < 0:
      result.error = "не удалось прочитать библиотеку: " & file
      return
    var i = 0'i32
    while i < count:
      var info: PluginInfo
      if pluginInfo(api, cstring(file), i, info):
        result.plugins.add pluginJson(file, i, info)
      inc i

# ==============================================================================
# scan / info
# ==============================================================================

proc runScan(ctx: var Ctx; args: PluginArgs): Report =
  if args.positional.len != 1:
    return usageError("plugin scan: нужен файл .clap или каталог",
      "например: euterpia plugin scan /usr/lib/clap --json")
  let (api, apiRep) = requireApi()
  if api.isNil:
    return apiRep
  let found = scanLibraries(api, args.positional[0])
  if found.error.len > 0:
    return envError(found.error, "проверьте путь и формат библиотеки")

  var plugins = newJArray()
  for p in found.plugins:
    plugins.add p
  var lines: seq[string] = @[]
  lines.add "библиотек: " & $found.files & "; плагинов: " & $found.plugins.len
  for p in found.plugins:
    lines.add "  " & p["id"].getStr & " — " & p["name"].getStr &
      " (" & $p["vendor"].getStr & ", " & p["category"].getStr & ")" &
      ": in " & $p["audioIn"].getInt & "/out " & $p["audioOut"].getInt &
      ", параметров " & $p["params"].getInt
  okReport(body = %*{
    "subcommand": "scan",
    "path": args.positional[0],
    "files": found.files,
    "plugins": plugins,
  }, lines = lines)

proc paramsJson(api: ptr PluginApi; handle: PluginHandle): seq[JsonNode] =
  let count = pluginParamCount(api, handle)
  var i = 0'i32
  while i < count:
    var pi: PluginParamInfo
    if pluginParamInfo(api, handle, i, pi):
      result.add %*{
        "id": pi.id,
        "name": pi.name,
        "value": pluginParamGet(api, handle, pi.id),
        "min": pi.minValue,
        "max": pi.maxValue,
        "default": pi.defaultValue,
        "step": pi.step,
        "automatable": ppfAutomatable in pi.flags,
        "integer": ppfInteger in pi.flags,
        "choice": ppfChoice in pi.flags,
        "hidden": ppfHidden in pi.flags,
      }
    inc i

proc runInfo(ctx: var Ctx; args: PluginArgs): Report =
  if args.positional.len != 1 or not fileExists(args.positional[0]):
    return usageError("plugin info: нужен существующий файл .clap",
      "например: euterpia plugin info build/libmockclap.so --index 0 --json")
  let (api, apiRep) = requireApi()
  if api.isNil:
    return apiRep
  let path = args.positional[0]
  let count = pluginCount(api, cstring(path))
  if count <= 0:
    return usageError("в библиотеке нет плагинов: " & path,
      "проверьте файл: euterpia plugin scan " & path)
  if args.index >= count:
    return usageError("--index вне диапазона: в библиотеке " & $count & " плагин(ов)",
      "индексы: 0.." & $(count - 1))

  var info: PluginInfo
  if not pluginInfo(api, cstring(path), args.index, info):
    return envError("не удалось прочитать описание плагина", path)
  let handle = pluginInstantiate(api, cstring(path), args.index)
  var params: seq[JsonNode] = @[]
  if not handle.isNil:
    params = paramsJson(api, handle)
    pluginDestroy(api, handle)
  else:
    return envError("плагин не инстанцируется: " & info.id,
      "проверьте зависимости плагина и `plugin validate`")

  var pj = pluginJson(path, args.index, info)
  var pjParams = newJArray()
  for p in params: pjParams.add p
  pj["paramList"] = pjParams
  var lines = @[
    "плагин: " & info.name & " (" & info.id & ")",
    "вендор: " & info.vendor & "; категория: " & categoryName(info.category),
    "порты: audio in " & $info.audioInCount & "/out " & $info.audioOutCount &
      ", note in " & $info.noteInCount,
    "параметров: " & $params.len,
  ]
  for p in params:
    lines.add "  #" & $p["id"].getInt & " " & p["name"].getStr & " = " &
      $p["value"].getFloat
  okReport(body = %*{"subcommand": "info", "plugin": pj}, lines = lines)

# ==============================================================================
# params / save: инстанс ноды проекта
# ==============================================================================

type
  PluginNodeRig = object
    ok: bool
    rep: Report
    doc: Document
    node: NodeInfo
    api: ptr PluginApi
    handle: PluginHandle
    clapId: string
    index: int32

proc closeRig(rig: var PluginNodeRig) =
  if not rig.api.isNil and not rig.handle.isNil:
    pluginDeactivate(rig.api, rig.handle)
    pluginDestroy(rig.api, rig.handle)
    rig.handle = nil

proc applyNodeParams(rig: var PluginNodeRig) =
  ## Значения из проекта → инстанс. Сопоставление по ИМЕНИ параметра:
  ## id плагина меняются между версиями, имя — часть пользовательского
  ## контракта (так же их хранит проект).
  let count = pluginParamCount(rig.api, rig.handle)
  var i = 0'i32
  while i < count:
    var pi: PluginParamInfo
    if pluginParamInfo(rig.api, rig.handle, i, pi):
      for p in rig.node.params:
        if p.name == pi.name:
          discard pluginParamSet(rig.api, rig.handle, pi.id,
                                 float64(p.value), false)
          break
    inc i

proc openPluginNode(projectPath, refText: string): PluginNodeRig =
  let loaded = loadAt(projectPath)
  if not loaded.ok:
    return PluginNodeRig(rep: loaded.rep)
  result.doc = openDocument(projectPath, loaded.proj)
  let found = queryNode(result.doc, refText)
  if not found.ok:
    return PluginNodeRig(rep: frameReport(found.frame))
  result.node = found.node
  if not result.node.nodeType.startsWith("plugin:"):
    return PluginNodeRig(rep: usageError(
      "нода #" & $result.node.id & " — не плагин: " & result.node.nodeType,
      "ноды-плагины имеют тип `plugin:<id>`; список: euterpia node list --json"))
  if result.node.pluginPath.len == 0:
    return PluginNodeRig(rep: usageError(
      "у ноды #" & $result.node.id & " не записан путь к плагину",
      "пересоздайте ноду: node add \"" & result.node.nodeType &
      "\" --path <файл.clap>"))
  let api = pluginHostApi()
  if api.isNil:
    return PluginNodeRig(rep: envError(
      "CLAP-адаптер недоступен: плагин не загрузить",
      "проверьте сборку CLI; `euterpia doctor`"))
  result.api = api
  result.clapId = result.node.nodeType["plugin:".len .. ^1]
  result.index = findPluginIndex(api, result.node.pluginPath, result.clapId)
  if result.index < 0:
    return PluginNodeRig(rep: envError(
      "плагин " & result.clapId & " не найден в " & result.node.pluginPath,
      "проверьте путь и `euterpia plugin scan`"))
  result.handle = pluginInstantiate(api, cstring(result.node.pluginPath),
                                    result.index)
  if result.handle.isNil:
    return PluginNodeRig(rep: envError(
      "плагин не инстанцируется: " & result.clapId,
      "проверьте зависимости плагина и `euterpia plugin validate`"))
  result.applyNodeParams()
  result.ok = true

proc runParams(ctx: var Ctx; args: PluginArgs): Report =
  if args.positional.len != 2:
    return usageError("plugin params: нужен проект и нода",
      "например: euterpia plugin params p.eproj 3 --json")
  var rig = openPluginNode(args.positional[0], args.positional[1])
  if not rig.ok:
    return rig.rep
  defer: rig.closeRig()

  let params = paramsJson(rig.api, rig.handle)
  var arr = newJArray()
  for p in params: arr.add p
  var lines = @[
    "плагин: " & rig.node.nodeType & " (нода #" & $rig.node.id & ")",
    "путь: " & rig.node.pluginPath,
    "параметров: " & $params.len,
  ]
  for p in params:
    lines.add "  #" & $p["id"].getInt & " " & p["name"].getStr & " = " &
      $p["value"].getFloat
  okReport(body = %*{
    "subcommand": "params",
    "node": %*{"id": rig.node.id, "type": rig.node.nodeType,
                "pluginPath": rig.node.pluginPath},
    "params": arr,
  }, lines = lines)

proc runSave(ctx: var Ctx; args: PluginArgs): Report =
  if args.positional.len != 2:
    return usageError("plugin save: нужен проект и нода",
      "например: euterpia plugin save p.eproj 3 --json")
  var rig = openPluginNode(args.positional[0], args.positional[1])
  if not rig.ok:
    return rig.rep
  defer: rig.closeRig()

  # Прежнее состояние — ДО параметров: снимок должен содержать и внутренние
  # данные плагина, которых в файле проекта нет.
  let prior = pluginStateBytesOf(rig.doc, rig.node.id)
  if prior.len > 0:
    discard pluginStateLoad(rig.api, rig.handle, unsafeAddr prior[0], prior.len)
    rig.applyNodeParams()

  let rate = float64(queryMetadata(rig.doc).sampleRate)
  let sr = if rate > 0.0: rate else: 48000.0
  discard pluginActivate(rig.api, rig.handle, sr, 4096,
                         int32(rig.node.audioIn), int32(rig.node.audioOut))

  var buffer = newSeq[byte](1_048_576)
  let n = pluginStateSave(rig.api, rig.handle, addr buffer[0], buffer.len)
  if n <= 0:
    return envError("плагин не отдаёт состояние: " & rig.node.nodeType,
      "не все плагины умеют сохранять состояние; `plugin params` работает")
  buffer.setLen(n)

  # Запись непрозрачного блоба в проект. Это единственный путь записи в
  # `pluginStates` из CLI (исключение guard'а §63 объявлено поимённо в
  # tools/check_architecture.py).
  var replaced = false
  for i in 0 ..< rig.doc.proj.pluginStates.len:
    if rig.doc.proj.pluginStates[i].nodeId == rig.node.id:
      rig.doc.proj.pluginStates[i] = PluginStateFormat(
        nodeId: rig.node.id, pluginId: rig.clapId, state: buffer)
      replaced = true
      break
  if not replaced:
    rig.doc.proj.pluginStates.add PluginStateFormat(
      nodeId: rig.node.id, pluginId: rig.clapId, state: buffer)

  let saved = saveProject(rig.doc.proj, args.positional[0])
  if not saved.success:
    return envError("не удалось записать проект: " & saved.error.message,
      "проверьте права на файл: " & args.positional[0])

  var text = newString(buffer.len)
  if buffer.len > 0:
    copyMem(addr text[0], addr buffer[0], buffer.len)
  let digest = $secureHash(text)
  okReport(body = %*{
    "subcommand": "save",
    "node": %*{"id": rig.node.id, "type": rig.node.nodeType},
    "pluginId": rig.clapId,
    "state": %*{"bytes": buffer.len, "sha1": digest},
    "project": args.positional[0],
  }, lines = @[
    "состояние плагина сохранено: " & $buffer.len & " байт (sha1 " & digest & ")",
    "нода #" & $rig.node.id & " " & rig.node.nodeType,
    "проект: " & args.positional[0],
  ])

# ==============================================================================
# validate: обёртка официального clap-validator (issue #260)
# ==============================================================================

type
  CheckStatus = enum
    csPass = "pass"
    csFail = "fail"
    csWarn = "warn"
    csInfo = "info"

proc statusOf(line: string): CheckStatus =
  let l = line.toLowerAscii()
  if l.contains("[fail]") or l.contains("[error]") or l.contains("❌") or
     l.contains("✗") or l.contains("✖"):
    return csFail
  if l.contains("[warn]") or l.contains("⚠"):
    return csWarn
  if l.contains("[pass]") or l.contains("[ok]") or l.contains("✅") or
     l.contains("✓") or l.contains("✔"):
    return csPass
  csInfo

proc parseCheck(line: string; number: int): tuple[status: CheckStatus;
                                                 id, message: string] =
  ## Разбор строки валидатора. Формат чужого инструмента не наш контракт,
  ## поэтому разбор ТОЛЕРАНТНЫЙ: маркер статуса — если он есть, остальное —
  ## `id: сообщение` либо просто сообщение с синтетическим id.
  result.status = statusOf(line)
  var rest = line.strip()
  const markers = ["[FAIL]", "[fail]", "[FAILED]", "[failed]", "[ERROR]",
                   "[error]", "[PASS]", "[pass]", "[OK]", "[ok]",
                   "[WARN]", "[warn]", "✅", "❌", "⚠", "✗", "✖", "✓",
                   "✔"]
  for marker in markers:
    if rest.startsWith(marker):
      rest = rest[marker.len .. ^1].strip()
      break
  let colon = rest.find(':')
  if colon > 0:
    result.id = rest[0 ..< colon].strip()
    result.message = rest[colon + 1 .. ^1].strip()
  else:
    result.message = rest
  if result.id.len == 0:
    result.id = "check-" & $number
  if result.id.len > 80:
    result.id.setLen(80)

proc validateJson(
  validator: string;
  exitCode: int;
  checks: seq[tuple[status: CheckStatus; id, message: string]]
): tuple[body: JsonNode; failed, warnings: int] =
  var arr = newJArray()
  for c in checks:
    arr.add %*{"id": c.id, "status": $c.status, "message": c.message}
    if c.status == csFail: inc result.failed
    elif c.status == csWarn: inc result.warnings
  result.body = %*{
    "subcommand": "validate",
    "validator": %*{"path": validator, "exitCode": exitCode},
    "checks": arr,
    "passed": result.failed == 0 and exitCode == 0,
    "failed": result.failed,
    "warnings": result.warnings,
  }

proc runValidate(ctx: var Ctx; args: PluginArgs): Report =
  if args.positional.len != 1:
    return usageError("plugin validate: нужен путь к .clap",
      "например: euterpia plugin validate Foo.clap --json")
  let path = args.positional[0]
  if not fileExists(path):
    return usageError("файл плагина не найден: " & path,
      "проверьте путь; список библиотек: euterpia plugin scan <каталог>")

  var validator = args.validator
  if validator.len == 0:
    validator = findExe("clap-validator")
  elif not fileExists(validator):
    validator = ""
  if validator.len == 0:
    return envError("валидатор clap-validator не найден",
      "установите официальный валидатор (cargo install clap-validator) " &
      "или укажите путь: --validator <файл>")

  let (output, code) = execCmdEx(
    quoteShell(validator) & " " & quoteShell(path),
    options = {poStdErrToStdOut})
  if code == 126 or code == 127:
    return envError("валидатор не запускается: " & validator,
      "проверьте права на файл и формат (--validator <файл>)")

  var checks: seq[tuple[status: CheckStatus; id, message: string]] = @[]
  var n = 0
  for line in output.splitLines():
    if line.strip().len == 0:
      continue
    inc n
    checks.add parseCheck(line, n)
  let report = validateJson(validator, code, checks)

  var lines: seq[string] = @[]
  lines.add "валидатор: " & validator & " (код " & $code & ")"
  for c in checks:
    lines.add "  [" & $c.status & "] " & c.id & ": " & c.message
  lines.add "итого: " & $report.failed & " ошибок, " & $report.warnings &
    " предупреждений"
  if code != 0 and report.failed == 0:
    lines.add "валидатор вернул код " & $code & " без распознанных ошибок: " &
      "смотрите его вывод"

  if report.failed > 0 or code != 0:
    return checkFailedError(
      "плагин не прошёл валидатор: " & $report.failed & " ошибок",
      hint = "исправьте плагин; список проверок — в `checks` (--json)",
      body = report.body)
  okReport(body = report.body, lines = lines)

# ==============================================================================
# Точка входа
# ==============================================================================

proc runPlugin*(ctx: var Ctx; args: seq[string]): Report =
  let parsed = parseArgs(args)
  if not parsed.ok:
    return parsed.rep
  case parsed.sub
  of "scan": runScan(ctx, parsed)
  of "info": runInfo(ctx, parsed)
  of "params": runParams(ctx, parsed)
  of "save": runSave(ctx, parsed)
  of "validate": runValidate(ctx, parsed)
  else: usageError("неизвестная подкоманда plugin: " & parsed.sub)
