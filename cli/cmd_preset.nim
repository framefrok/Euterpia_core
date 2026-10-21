# cli/cmd_preset.nim
#
# `euterpia preset …` и `euterpia setlist …` — шаблоны, сет-листы и пресеты
# параметров (issues #341–#343).
#
# Границы (§20):
#   * форма файлов, проверка по реестру и превращение в команды — `libs/presets`;
#   * проект читается и пишется теми же путями, что у остальных команд
#     (`cmd_project.loadAt`/`writeAtomic`, сайдкар истории #331);
#   * применение — ОДНА транзакция control-слоя: отказ не оставляет следов
#     (критерий #341), а `undo` отменяет применение целиком;
#   * `init --preset` живёт в `cmd_project` и идёт тем же путём, что
#     `script build` (#416): второй сборки нет.
#
# Почему сет-лист обновляет клип, а не пересобирает пьесу:
#   «смена сет-листа не ломает уже собранную пьесу» (#342) — существующая
#   дорожка получает `clip.set`, отсутствующая — `track.add` + `clip.add`.
#   Сведение идёт параметрами ГОЛОСА: команды «микс дорожки» в control-слое
#   нет, и выдумывать её в клиенте значило бы завести второй источник правды.

import std/[json, os, strutils, tables]

import context
import cli_spec
import cmd_project
import control_bridge
import history_file
import presets
import script
import catalog
import project
import control/commands
import control/document
import control/query
import control/error_frame
import sdk/node_registry

const
  PresetSubcommands* = @["list", "show", "apply", "param"]
    ## Подкоманды `preset` — кандидаты автодополнения второго уровня.
  PresetParamSubcommands* = @["list", "show", "apply"]
  SetlistSubcommands* = @["list", "show", "apply"]

  DefaultPresetDirHint = DefaultPresetsDir & "/" & kindDir(pkTemplate)

  PresetSpec* = CommandSpec(
    name: "preset",
    summary: "шаблоны проектов и пресеты параметров: список, показ, применение",
    synopsis: "preset <list|show|apply|param> [шаблон|файл] [проект.eproj] [ключи]",
    subcommands: PresetSubcommands,
    args: @[
      arg("<list|show|apply|param>", "что делать; `param` — пресет параметров"),
      arg("шаблон|файл", "имя из `preset list` или путь *" & PresetSuffix),
      arg("проект.eproj", "к чему применить; без аргумента — " & DefaultProjectFile),
    ],
    options: @[
      opt("--file", "проект, если он не задан позиционно",
          value = projectSuffixesHint()),
      opt("--node", "`param apply`: к каким нодам (id через запятую)",
          value = "id[,id]"),
      opt("--role", "`param apply`: только голос этой роли (имя дорожки)",
          value = "роль"),
    ],
    example: "euterpia preset apply band demo.eproj",
    fields: @[
      field("kind", "вид заготовок в списке: templates | params"),
      field("items", "список: name, description, path, nodes/tracks/parts/params"),
      field("problems", "файлы, которые не разобрались (пусто — все читаются)"),
      field("preset", "имя шаблона/пресета"),
      field("presetPath", "откуда прочитан файл"),
      field("path", "проект, который изменён"),
      field("nodeType", "`param`: тип ноды пресета"),
      field("role", "`param`: роль, к которой применяли (пусто — все ноды типа)"),
      field("applied", "`param apply`: что изменилось: node, nodeId, param, from, to"),
      field("unchanged", "`param apply`: параметры уже имели нужное значение"),
      field("untouched", "`param apply`: ноды этого типа, не попавшие под роль"),
      field("changed", "документ изменился (false — применение ничего не меняло)"),
      field("dryRun", "план без записи"),
      field("counts", "счётчики изменений документа"),
      field("format", "формат файла заготовки"),
      field("version", "версия формата"),
      field("description", "описание заготовки"),
      field("tempo", "темп из шаблона"),
      field("sampleRate", "частота из шаблона"),
      field("nodes", "`show`: ноды шаблона"),
      field("connections", "`show`: связи шаблона"),
      field("tracks", "`show`: дорожки шаблона"),
      field("params", "`show`: параметры пресета"),
    ],
    notes: @[
      "шаблон проверяется реестром нод ДО применения: неизвестный тип — код `not_found`, а не «получилось не то»",
      "применение к проекту — одна транзакция: отказ не оставляет следов, `euterpia undo` отменяет его целиком",
      "файлы ищутся в `" & DefaultPresetsDir & "/" & kindDir(pkTemplate) & "`, рядом с бинарём, в `EUTERPIA_PRESETS` и `~/.config/euterpia/presets`",
      "`init --preset band` создаёт стартовый проект тем же путём, что `script build` (#341)",
      "`preset param apply cello-warm song.eproj --role lead` — только голос роли; без `--role` — все ноды типа",
    ])

  SetlistSpec* = CommandSpec(
    name: "setlist",
    summary: "сет-листы: состав пьесы и сведение как данные",
    synopsis: "setlist <list|show|apply> [сет-лист|файл] [проект.eproj] [ключи]",
    subcommands: SetlistSubcommands,
    args: @[
      arg("<list|show|apply>", "что делать"),
      arg("сет-лист|файл", "имя из `setlist list` или путь *" & SetlistSuffix),
      arg("проект.eproj", "куда собрать; без аргумента — " & DefaultProjectFile),
    ],
    options: @[
      opt("--file", "проект, если он не задан позиционно",
          value = projectSuffixesHint()),
      opt("--preset", "шаблон, поверх которого собрать (сильнее поля `preset`)",
          value = "имя|файл.preset.json"),
    ],
    example: "euterpia setlist apply punk-demo punk.eproj",
    fields: @[
      field("kind", "вид заготовок в списке: setlists"),
      field("items", "список: name, description, path, parts"),
      field("problems", "файлы, которые не разобрались"),
      field("setlist", "имя сет-листа"),
      field("setlistPath", "откуда прочитан файл"),
      field("preset", "шаблон, поверх которого собрана пьеса"),
      field("path", "проект"),
      field("created", "проект создан с нуля (иначе — обновлён транзакцией)"),
      field("written", "файл записан (false при --dry-run)"),
      field("dryRun", "план без записи"),
      field("parts", "состав пьесы: track, clip, notes, mix — и для агента"),
      field("counts", "счётчики изменений документа"),
    ],
    notes: @[
      "сет-лист — данные поверх шаблона: партии и типичное сведение, а не копия проекта",
      "нет проекта — пьеса собирается с нуля шаблоном + сет-листом; проект есть — обновление идёт транзакцией (`clip.set`)",
      "обновление не плодит клипы: существующая дорожка получает новый клип на месте первого",
      "сведение задаётся параметрами голоса (`level`, `pan`), а не отдельной командой микса",
      "файлы ищутся в `" & DefaultPresetsDir & "/" & kindDir(pkSetlist) & "` и каталогах `EUTERPIA_PRESETS`",
    ])

  PresetKeys* = PresetSpec.optionKeys
  SetlistKeys* = SetlistSpec.optionKeys

type
  PresetScan = object
    ok: bool
    rep: Report
    sub, paramSub, target, project: string
    haveProject: bool
    nodeIds: seq[int32]
    role: string

  SetlistScan = object
    ok: bool
    rep: Report
    sub, target, project: string
    haveProject: bool
    presetOverride: string

# =============================================================================
# Разбор аргументов
# =============================================================================

proc parseIntList(text, key: string; ids: var seq[int32]): string =
  ## `--node 1,3,7`: пустой список — ошибка, а не «применить ко всему».
  for part in text.split(','):
    let item = part.strip()
    if item.len == 0:
      continue
    try:
      let value = int32(parseInt(item))
      if value <= 0:
        return key & ": id ноды должен быть положительным, получено «" &
          item & "»"
      ids.add value
    except ValueError:
      return key & ": ожидаются целые id через запятую, получено «" & item & "»"
  if ids.len == 0:
    return key & ": нужен хотя бы один id"
  ""

proc scanPreset(args: seq[string]): PresetScan =
  result.project = DefaultProjectFile
  var positional: seq[string] = @[]
  let tokens = splitInline(args)
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token in ["--file", "--node", "--role"]:
      if i + 1 >= tokens.len:
        result.rep = usageError(token & " требует значение",
                                "ключи: " & PresetKeys.join(", "))
        return
      let value = tokens[i + 1]
      case token
      of "--file":
        result.project = value
        result.haveProject = true
      of "--node":
        let problem = parseIntList(value, "--node", result.nodeIds)
        if problem.len > 0:
          result.rep = usageError(problem)
          return
      of "--role":
        result.role = value
      else: discard
      inc i, 2
      continue
    if token.startsWith("--"):
      result.rep = usageError("неизвестный ключ preset: " & token,
                              "ключи: " & PresetKeys.join(", "))
      return
    positional.add token
    inc i

  if positional.len == 0:
    result.rep = usageError("preset: нужна подкоманда",
                            "например: euterpia preset list")
    return
  result.sub = positional[0]
  if result.sub notin PresetSubcommands:
    result.rep = usageError("неизвестная подкоманда preset: " & result.sub,
                            "подкоманды: " & PresetSubcommands.join(", "))
    return
  var rest = 1
  if result.sub == "param":
    if positional.len < 2:
      result.rep = usageError("preset param: нужна подкоманда",
                              "подкоманды: " & PresetParamSubcommands.join(", "))
      return
    result.paramSub = positional[1]
    if result.paramSub notin PresetParamSubcommands:
      result.rep = usageError("неизвестная подкоманда preset param: " &
                              result.paramSub,
                              "подкоманды: " & PresetParamSubcommands.join(", "))
      return
    rest = 2
  if result.sub in ["show", "apply"] or
     (result.sub == "param" and result.paramSub in ["show", "apply"]):
    if positional.len <= rest:
      result.rep = usageError("нужно имя " & kindName(
        if result.sub == "param": pkParams else: pkTemplate) & " или путь",
        "список: euterpia preset list")
      return
    result.target = positional[rest]
    inc rest
  if result.sub == "apply" or
     (result.sub == "param" and result.paramSub == "apply"):
    if positional.len > rest:
      result.project = positional[rest]
      result.haveProject = true
      inc rest
  if positional.len > rest:
    result.rep = usageError("лишние аргументы: " &
                            positional[rest .. ^1].join(" "))
    return
  result.ok = true


proc scanSetlist(args: seq[string]): SetlistScan =
  result.project = DefaultProjectFile
  var positional: seq[string] = @[]
  let tokens = splitInline(args)
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token in ["--file", "--preset"]:
      if i + 1 >= tokens.len:
        result.rep = usageError(token & " требует значение",
                                "ключи: " & SetlistKeys.join(", "))
        return
      let value = tokens[i + 1]
      if token == "--file":
        result.project = value
        result.haveProject = true
      else:
        result.presetOverride = value
      inc i, 2
      continue
    if token.startsWith("--"):
      result.rep = usageError("неизвестный ключ setlist: " & token,
                              "ключи: " & SetlistKeys.join(", "))
      return
    positional.add token
    inc i

  if positional.len == 0:
    result.rep = usageError("setlist: нужна подкоманда",
                            "например: euterpia setlist list")
    return
  result.sub = positional[0]
  if result.sub notin SetlistSubcommands:
    result.rep = usageError("неизвестная подкоманда setlist: " & result.sub,
                            "подкоманды: " & SetlistSubcommands.join(", "))
    return
  if result.sub in ["show", "apply"]:
    if positional.len < 2:
      result.rep = usageError("нужно имя сет-листа или путь",
                              "список: euterpia setlist list")
      return
    result.target = positional[1]
    if positional.len > 2:
      result.project = positional[2]
      result.haveProject = true
      if positional.len > 3:
        result.rep = usageError("лишние аргументы: " &
                                positional[3 .. ^1].join(" "))
        return
  elif positional.len > 1:
    result.rep = usageError("setlist list не принимает аргументов")
    return
  result.ok = true

# =============================================================================
# Общие шаги
# =============================================================================

proc registryHere(): NodeRegistry =
  ## Реестр официальных нод: та же сборка, что проверяется командой
  ## `node types`. Плагинные типы в шаблонах пока не участвуют — это
  ## ограничение названо в `docs/cli.md`, а не спрятано.
  builtinRegistry()

proc loadPresetTarget(target: string; preset: var ProjectPreset;
                      path: var string): Report =
  ## Шаблон по имени/пути + проверка реестром. Проверка ДО применения.
  let found = findPreset(pkTemplate, target, presetSearchDirs(pkTemplate))
  if not found.ok:
    let available =
      if found.available.len > 0: found.available.join(", ")
      else: "ни одного: каталог " & DefaultPresetsDir / kindDir(pkTemplate)
    return usageError("нет шаблона «" & target & "»",
                      "доступны: " & available, code = ecNotFound)
  path = found.path
  let loaded = loadPresetFile(path, preset)
  if not loaded.isOk():
    return frameReport(loaded)
  let validated = validatePreset(preset, registryHere())
  if not validated.isOk():
    return frameReport(validated)
  okReport()

proc loadSetlistTarget(target: string; setlist: var Setlist;
                       path: var string): Report =
  let found = findPreset(pkSetlist, target, presetSearchDirs(pkSetlist))
  if not found.ok:
    let available =
      if found.available.len > 0: found.available.join(", ")
      else: "ни одного: каталог " & DefaultPresetsDir / kindDir(pkSetlist)
    return usageError("нет сет-листа «" & target & "»",
                      "доступны: " & available, code = ecNotFound)
  path = found.path
  let loaded = loadSetlistFile(path, setlist)
  if not loaded.isOk():
    return frameReport(loaded)
  okReport()

proc loadParamTarget(target: string; preset: var ParamPreset;
                     path: var string): Report =
  let found = findPreset(pkParams, target, presetSearchDirs(pkParams))
  if not found.ok:
    let available =
      if found.available.len > 0: found.available.join(", ")
      else: "ни одного: каталог " & DefaultPresetsDir / kindDir(pkParams)
    return usageError("нет пресета параметров «" & target & "»",
                      "доступны: " & available, code = ecNotFound)
  path = found.path
  let loaded = loadParamPresetFile(path, preset)
  if not loaded.isOk():
    return frameReport(loaded)
  let validated = validateParamPreset(preset, registryHere())
  if not validated.isOk():
    return frameReport(validated)
  okReport()


proc saveApplied(ctx: Ctx; path: string; proj: ProjectFormat;
                 run: ScriptRun; description: string): Report =
  ## Хвост изменяющих подкоманд: проект и история пишутся вместе. Обратные
  ## команды уже построены ядром (`planTransaction`) — откат применения
  ## шаблона/пресета это обычная запись истории (#331).
  if ctx.dryRun:
    return okReport()
  let saved = writeAtomic(path, proj)
  if not saved.success:
    return saveError(saved, path)
  let recorded = recordEntry(path, HistoryEntry(
    redo: run.plan.redo, undo: run.plan.undo, description: description))
  if not recorded.isOk():
    return frameReport(recorded)
  okReport()

proc projectIndex(doc: Document): ProjectIndex =
  ## Срез проекта для сет-листа — через Query API, без внутренностей модели.
  for node in doc.queryNodes().nodes:
    var names: seq[string] = @[]
    for p in node.params:
      names.add p.name
    result.addNodeTo(int32(node.id), node.nodeType, node.name, names)
  for track in doc.queryTracks():
    result.addTrackTo(track.name, track.clips.len)

proc catalogBody(kind: PresetKind; dirs: seq[string]): JsonNode =
  ## Машинный список заготовок: то же, что печатает человек.
  let cat = catalogOf(kind, dirs)
  var items = newJArray()
  for item in cat.items:
    items.add %*{
      "name": item.name, "description": item.description, "path": item.path,
      "nodes": item.nodes, "tracks": item.tracks, "parts": item.parts,
      "params": item.params,
    }
  var problems = newJArray()
  for problem in cat.problems:
    problems.add %problem
  %*{"items": items, "problems": problems}

proc catalogLines(kind: PresetKind; dirs: seq[string]): seq[string] =
  ## Человеческий список: имя, описание, счётчики и путь. Пустой каталог —
  ## не «всё хорошо», а подсказка, где искать.
  let cat = catalogOf(kind, dirs)
  if cat.items.len == 0:
    result.add "заготовок нет: " & dirs.join(", ")
  for item in cat.items:
    var details: seq[string] = @[]
    case kind
    of pkTemplate:
      details.add "нод " & $item.nodes
      details.add "дорожек " & $item.tracks
    of pkSetlist:
      details.add "партий " & $item.parts
    of pkParams:
      details.add "параметров " & $item.params
    result.add "  " & item.name & " — " &
      (if item.description.len > 0: item.description else: "(без описания)") &
      " (" & details.join(", ") & ")"
    result.add "      " & item.path
  for problem in cat.problems:
    result.add "  сломан: " & problem

proc presetLines(preset: ProjectPreset; path: string): seq[string] =
  result.add "шаблон: " & preset.name
  result.add "файл: " & path
  if preset.description.len > 0:
    result.add "описание: " & preset.description
  result.add "формат: " & PresetFormatName & " v" & $PresetFormatVersion
  result.add "темп: " & $preset.tempo & " BPM, частота: " & $preset.sampleRate &
    " Гц, размер: " & $preset.tsNum & "/" & $preset.tsDen
  result.add "ноды:"
  var index = 1
  for node in preset.nodes:
    var params: seq[string] = @[]
    for param in node.params:
      params.add param.name & "=" & $param.value
    result.add "  #" & $index & " " & node.nodeType & " — " & node.name &
      (if params.len > 0: " (" & params.join(", ") & ")" else: "")
    inc index
  result.add "связи:"
  if preset.connections.len == 0:
    result.add "  нет"
  for conn in preset.connections:
    result.add "  " & conn.srcNode & ":" & SignalNames[conn.sigType] & ":" &
      $conn.srcPort & " → " & conn.dstNode & ":" &
      SignalNames[conn.sigType] & ":" & $conn.dstPort
  result.add "дорожки:"
  if preset.tracks.len == 0:
    result.add "  нет"
  for track in preset.tracks:
    result.add "  " & track.name & ": клип «" & track.clip.name & "», " &
      $track.clip.lengthTicks & " тиков, нот " & $track.clip.notes.len

proc setlistLines(setlist: Setlist; path, presetPath: string): seq[string] =
  result.add "сет-лист: " & setlist.name
  result.add "файл: " & path
  if setlist.description.len > 0:
    result.add "описание: " & setlist.description
  result.add "формат: " & SetlistFormatName & " v" & $SetlistFormatVersion
  result.add "шаблон: " & setlist.preset &
    (if presetPath.len > 0: " (" & presetPath & ")" else: "")
  for part in setlist.parts:
    var mix: seq[string] = @[]
    for param in part.mix:
      mix.add param.name & "=" & $param.value
    result.add "  " & part.track & ": клип «" & part.clipName & "», " &
      $part.lengthTicks & " тиков, нот " & $part.notes.len &
      (if mix.len > 0: ", сведение: " & mix.join(", ") else: "")


# =============================================================================
# preset: list / show
# =============================================================================

proc runPresetList(): Report =
  let dirs = presetSearchDirs(pkTemplate)
  var lines = @[CliName & " preset list — шаблоны проектов", ""]
  lines.add catalogLines(pkTemplate, dirs)
  lines.add ""
  lines.add "пресеты параметров: euterpia preset param list"
  var body = catalogBody(pkTemplate, dirs)
  body["kind"] = %"templates"
  okReport(body = body, lines = lines)

proc runPresetShow(scan: PresetScan): Report =
  var preset: ProjectPreset
  var path: string
  let loaded = loadPresetTarget(scan.target, preset, path)
  if not loaded.ok:
    return loaded
  var body = presetJson(preset)
  body["presetPath"] = %path
  okReport(body = body, lines = presetLines(preset, path))

proc runParamList(): Report =
  let dirs = presetSearchDirs(pkParams)
  var lines = @[CliName & " preset param list — пресеты параметров", ""]
  lines.add catalogLines(pkParams, dirs)
  var body = catalogBody(pkParams, dirs)
  body["kind"] = %"params"
  okReport(body = body, lines = lines)

proc runParamShow(scan: PresetScan): Report =
  var preset: ParamPreset
  var path: string
  let loaded = loadParamTarget(scan.target, preset, path)
  if not loaded.ok:
    return loaded
  var body = paramPresetJson(preset)
  body["presetPath"] = %path
  var lines = @[
    "пресет параметров: " & preset.name,
    "файл: " & path,
    "формат: " & ParamPresetFormatName & " v" & $ParamPresetFormatVersion,
    "тип ноды: " & preset.nodeType,
  ]
  if preset.role.len > 0:
    lines.add "роль: " & preset.role
  if preset.description.len > 0:
    lines.add "описание: " & preset.description
  lines.add "параметры:"
  for param in preset.params:
    lines.add "  " & param.name & " = " & $param.value
  okReport(body = body, lines = lines)

# =============================================================================
# preset apply: шаблон к существующему проекту
# =============================================================================

proc runPresetApply(ctx: var Ctx; scan: PresetScan): Report =
  ## Применение к существующему проекту — транзакция: id нод сдвигаются за
  ## последний занятый, дорожки добавляются после существующих. Отказ не
  ## оставляет следов, `undo` отменяет применение целиком.
  var preset: ProjectPreset
  var presetPath: string
  let loaded = loadPresetTarget(scan.target, preset, presetPath)
  if not loaded.ok:
    return loaded

  let loadedProject = loadAt(scan.project)
  if not loadedProject.ok:
    return loadedProject.rep
  var doc = openDocument(scan.project, loadedProject.proj)
  var maxId = 0'i32
  for node in doc.queryNodes().nodes:
    maxId = max(maxId, int32(node.id))
  let trackBase = doc.queryTracks().len
  let commands = presetCommands(preset, idBase = maxId, trackBase = trackBase)
  let description = "шаблон: " & preset.name
  let scenario = Script(version: ScriptFormatVersion, description: description,
                        variables: initTable[string, JsonNode](),
                        commands: commands)
  let run =
    if ctx.dryRun: previewScript(doc, scenario, description)
    else: applyScript(doc, scenario, description)
  if not run.frame.isOk():
    return frameReport(run.frame)

  if not ctx.dryRun:
    let saved = saveApplied(ctx, scan.project, doc.proj, run, description)
    if not saved.ok:
      return saved

  var body = %*{
    "path": scan.project,
    "preset": preset.name,
    "presetPath": presetPath,
    "changed": run.changed,
    "dryRun": ctx.dryRun,
    "commands": commands.len,
    "counts": run.summary,
  }
  var lines = @[CliName & " preset apply — шаблон в проект", ""]
  lines.add presetLines(preset, presetPath)
  lines.add "проект: " & scan.project
  if run.changed:
    lines.add "изменения:"
    for name in ["nodes", "connections", "tracks", "clips", "notes"]:
      if run.summary.hasKey(name) and run.summary[name].hasKey("delta") and
         run.summary[name]["delta"].getInt(0) != 0:
        lines.add "  " & name & ": " & $run.summary[name]["delta"].getInt
  else:
    lines.add "изменения: документ не меняется"
  if ctx.dryRun:
    lines.add "не записан: " & scan.project & " (--dry-run)"
  else:
    lines.add "записан: " & scan.project
    lines.add "история: " & historyPath(scan.project) &
      " (откат: euterpia undo)"
  okReport(body = body, lines = lines)


# =============================================================================
# preset param apply: параметры к нодам по типу и роли (#343)
# =============================================================================

proc runParamApply(ctx: var Ctx; scan: PresetScan): Report =
  var preset: ParamPreset
  var presetPath: string
  let loaded = loadParamTarget(scan.target, preset, presetPath)
  if not loaded.ok:
    return loaded

  let loadedProject = loadAt(scan.project)
  if not loadedProject.ok:
    return loadedProject.rep
  var doc = openDocument(scan.project, loadedProject.proj)
  let nodes = doc.queryNodes().nodes

  var selected: seq[NodeInfo] = @[]
  if scan.nodeIds.len > 0:
    for nodeId in scan.nodeIds:
      var found = false
      for node in nodes:
        if int32(node.id) == nodeId:
          found = true
          if node.nodeType != preset.nodeType:
            return usageError(
              "нода #" & $nodeId & " имеет тип " & node.nodeType &
                ", а пресет — " & preset.nodeType,
              "пресет применяется к совместимому типу целиком, а не наполовину",
              code = ecInvalidArgument)
          selected.add node
      if not found:
        return usageError("нет ноды #" & $nodeId, "список: euterpia node list",
                          code = ecNotFound)
  else:
    for node in nodes:
      if node.nodeType != preset.nodeType:
        continue
      if scan.role.len > 0 and cmpIgnoreCase(node.name, scan.role) != 0:
        continue
      selected.add node

  var untouched = newJArray()
  for node in nodes:
    if node.nodeType == preset.nodeType and scan.role.len > 0 and
       cmpIgnoreCase(node.name, scan.role) != 0:
      untouched.add %*{"node": node.name, "nodeId": node.id,
                       "reason": "role"}
  if selected.len == 0:
    return usageError(
      "в проекте нет нод типа " & preset.nodeType &
        (if scan.role.len > 0: " с ролью «" & scan.role & "»" else: ""),
      "сначала соберите проект шаблоном: euterpia init --preset …",
      code = ecNotFound, body = %*{"untouched": untouched})

  # Отчёт «что изменится» строится ДО применения: после транзакции старых
  # значений уже нет, а отчёт обязан называть обе стороны.
  var applied = newJArray()
  var unchanged = newJArray()
  var nodeIds: seq[int32] = @[]
  for node in selected:
    nodeIds.add int32(node.id)
    for param in preset.params:
      var current = 0.0f
      var found = false
      for p in node.params:
        if p.name == param.name:
          current = p.value
          found = true
      if found and abs(current - param.value) < 1e-6f:
        unchanged.add %*{"node": node.name, "nodeId": node.id,
                         "param": param.name, "value": current}
      else:
        applied.add %*{"node": node.name, "nodeId": node.id,
                       "param": param.name, "from": current,
                       "to": param.value}

  let commands = paramPresetCommands(preset, nodeIds)
  let description = "пресет параметров: " & preset.name
  let scenario = Script(version: ScriptFormatVersion, description: description,
                        variables: initTable[string, JsonNode](),
                        commands: commands)
  let run =
    if ctx.dryRun: previewScript(doc, scenario, description)
    else: applyScript(doc, scenario, description)
  if not run.frame.isOk():
    return frameReport(run.frame)

  if not ctx.dryRun:
    let saved = saveApplied(ctx, scan.project, doc.proj, run, description)
    if not saved.ok:
      return saved

  var body = %*{
    "path": scan.project,
    "preset": preset.name,
    "presetPath": presetPath,
    "nodeType": preset.nodeType,
    "role": scan.role,
    "nodes": selected.len,
    "applied": applied,
    "unchanged": unchanged,
    "untouched": untouched,
    "changed": run.changed,
    "dryRun": ctx.dryRun,
    "counts": run.summary,
  }
  var lines = @[CliName & " preset param apply — пресет параметров", ""]
  lines.add "пресет: " & preset.name & " (" & presetPath & ")"
  lines.add "тип ноды: " & preset.nodeType &
    (if scan.role.len > 0: ", роль: " & scan.role else: "")
  lines.add "проект: " & scan.project
  lines.add "нод выбрано: " & $selected.len
  lines.add "изменения:"
  if applied.len == 0:
    lines.add "  нет: значения уже такие"
  for item in applied:
    lines.add "  #" & $item["nodeId"].getInt & " " & item["node"].getStr &
      ": " & item["param"].getStr & " " & $item["from"].getFloat & " → " &
      $item["to"].getFloat
  if unchanged.len > 0:
    lines.add "не тронуто (значение совпало):"
    for item in unchanged:
      lines.add "  #" & $item["nodeId"].getInt & " " & item["node"].getStr &
        ": " & item["param"].getStr & " = " & $item["value"].getFloat
  if untouched.len > 0:
    lines.add "вне роли (не тронуто):"
    for item in untouched:
      lines.add "  #" & $item["nodeId"].getInt & " " & item["node"].getStr
  if ctx.dryRun:
    lines.add "не записан: " & scan.project & " (--dry-run)"
  else:
    lines.add "записан: " & scan.project
    lines.add "история: " & historyPath(scan.project) &
      " (откат: euterpia undo)"
  okReport(body = body, lines = lines)


# =============================================================================
# setlist: list / show / apply (#342)
# =============================================================================

proc runSetlistList(): Report =
  let dirs = presetSearchDirs(pkSetlist)
  var lines = @[CliName & " setlist list — сет-листы", ""]
  lines.add catalogLines(pkSetlist, dirs)
  var body = catalogBody(pkSetlist, dirs)
  body["kind"] = %"setlists"
  okReport(body = body, lines = lines)

proc runSetlistShow(scan: SetlistScan): Report =
  var setlist: Setlist
  var path: string
  let loaded = loadSetlistTarget(scan.target, setlist, path)
  if not loaded.ok:
    return loaded
  # Шаблон показывается путём, а не содержимым: сет-лист на него ссылается.
  let found = findPreset(pkTemplate, setlist.preset,
                         presetSearchDirs(pkTemplate))
  let presetPath = if found.ok: found.path else: ""
  var body = setlistJson(setlist)
  body["setlistPath"] = %path
  body["presetPath"] = %presetPath
  okReport(body = body, lines = setlistLines(setlist, path, presetPath))

proc setlistPartsBody(setlist: Setlist): JsonNode =
  ## Состав пьесы в машинном виде: «что играет и как сведено».
  result = newJArray()
  for part in setlist.parts:
    var mix = newJObject()
    for param in part.mix:
      mix[param.name] = %param.value
    result.add %*{
      "track": part.track, "clip": part.clipName,
      "lengthTicks": part.lengthTicks, "notes": part.notes.len,
      "mix": mix,
    }

proc setlistReportLines(setlist: Setlist; path, presetPath: string;
                        project: string; created: bool;
                        counts: JsonNode; dryRun: bool): seq[string] =
  result = @[CliName & " setlist apply — пьеса из сет-листа", ""]
  result.add setlistLines(setlist, path, presetPath)
  result.add "проект: " & project &
    (if created: " (создан)" else: " (обновлён)")
  result.add "состав:"
  for part in setlist.parts:
    var mix: seq[string] = @[]
    for param in part.mix:
      mix.add param.name & "=" & $param.value
    result.add "  " & part.track & ": " & $part.notes.len & " нот" &
      (if mix.len > 0: ", сведение: " & mix.join(", ") else: "")
  if counts != nil and counts.hasKey("notes") and
     counts["notes"].hasKey("delta"):
    result.add "нот добавлено: " & $counts["notes"]["delta"].getInt
  if dryRun:
    result.add "не записан: " & project & " (--dry-run)"
  else:
    result.add "записан: " & project
    result.add "история: " & historyPath(project) &
      " (откат: euterpia undo)"


proc runSetlistApply(ctx: var Ctx; scan: SetlistScan): Report =
  var setlist: Setlist
  var setlistPath: string
  let loaded = loadSetlistTarget(scan.target, setlist, setlistPath)
  if not loaded.ok:
    return loaded

  let presetName =
    if scan.presetOverride.len > 0: scan.presetOverride else: setlist.preset
  var preset: ProjectPreset
  var presetPath: string
  let loadedPreset = loadPresetTarget(presetName, preset, presetPath)
  if not loadedPreset.ok:
    return loadedPreset

  let exists = fileExists(scan.project)
  if not exists:
    # Пьеса с нуля: шаблон + сет-лист ОДНИМ сценарием, тем же путём, что
    # `script build`. Проверка идёт по индексу шаблона — до записи.
    var index = presetIndex(preset)
    let validation = validateSetlist(setlist, index, registryHere())
    if not validation.isOk():
      return frameReport(validation)
    var commands = presetCommands(preset)
    commands.add setlistCommands(setlist, index)
    let stamp = nowStamp()
    let meta = ProjectFormat(
      format: ProjectFormatName, version: ProjectFormatVersion,
      metadata: ProjectMetadata(
        name: defaultName(scan.project), author: "",
        sampleRate: (if preset.sampleRate > 0: preset.sampleRate
                     else: DefaultSampleRate),
        tempo: (if preset.tempo > 0: preset.tempo else: DefaultTempo),
        timeSignature: TimeSignatureFormat(
          numerator: (if preset.tsNum > 0: preset.tsNum
                      else: DefaultTimeSigNumerator),
          denominator: (if preset.tsDen > 0: preset.tsDen
                        else: DefaultTimeSigDenominator)),
        created: stamp, modified: stamp))
    var lines = setlistReportLines(setlist, setlistPath, presetPath,
                                   scan.project, true, nil, ctx.dryRun)
    var built = buildProjectFromCommands(ctx, scan.project, meta, commands,
                                         stamp, "сет-лист: " & setlist.name,
                                         lines)
    if not built.ok:
      return built
    var body = built.body
    body["created"] = %true
    body["setlist"] = %setlist.name
    body["setlistPath"] = %setlistPath
    body["preset"] = %preset.name
    body["presetPath"] = %presetPath
    body["written"] = %(not ctx.dryRun)
    body["dryRun"] = %ctx.dryRun
    body["parts"] = setlistPartsBody(setlist)
    return okReport(body = body, lines = built.lines)

  # Проект уже есть: обновление — транзакция. Дорожки и голоса ищутся по
  # индексу проекта, а не по шаблону: пьеса могла быть переименована/сведена.
  let loadedProject = loadAt(scan.project)
  if not loadedProject.ok:
    return loadedProject.rep
  var doc = openDocument(scan.project, loadedProject.proj)
  var index = projectIndex(doc)
  let validation = validateSetlist(setlist, index, registryHere())
  if not validation.isOk():
    return frameReport(validation)
  let commands = setlistCommands(setlist, index)
  let description = "сет-лист: " & setlist.name
  let scenario = Script(version: ScriptFormatVersion, description: description,
                        variables: initTable[string, JsonNode](),
                        commands: commands)
  let run =
    if ctx.dryRun: previewScript(doc, scenario, description)
    else: applyScript(doc, scenario, description)
  if not run.frame.isOk():
    return frameReport(run.frame)
  if not ctx.dryRun:
    let saved = saveApplied(ctx, scan.project, doc.proj, run, description)
    if not saved.ok:
      return saved
  let body = %*{
    "path": scan.project,
    "setlist": setlist.name,
    "setlistPath": setlistPath,
    "preset": preset.name,
    "presetPath": presetPath,
    "created": false,
    "written": not ctx.dryRun,
    "dryRun": ctx.dryRun,
    "changed": run.changed,
    "parts": setlistPartsBody(setlist),
    "counts": run.summary,
  }
  let lines = setlistReportLines(setlist, setlistPath, presetPath,
                                 scan.project, false, run.summary, ctx.dryRun)
  okReport(body = body, lines = lines)

# =============================================================================
# Точки входа
# =============================================================================

proc runPreset*(ctx: var Ctx; args: seq[string]): Report =
  let scan = scanPreset(args)
  if not scan.ok:
    return scan.rep
  case scan.sub
  of "list": runPresetList()
  of "show": runPresetShow(scan)
  of "apply": runPresetApply(ctx, scan)
  of "param":
    case scan.paramSub
    of "list": runParamList()
    of "show": runParamShow(scan)
    of "apply": runParamApply(ctx, scan)
    else: usageError("preset param: " & scan.paramSub)
  else:
    usageError("preset: " & scan.sub)

proc runSetlist*(ctx: var Ctx; args: seq[string]): Report =
  let scan = scanSetlist(args)
  if not scan.ok:
    return scan.rep
  case scan.sub
  of "list": runSetlistList()
  of "show": runSetlistShow(scan)
  of "apply": runSetlistApply(ctx, scan)
  else: usageError("setlist: " & scan.sub)

