# cli/cmd_script.nim
#
# `euterpia script <run|plan|show|record|render>` — сценарии CLI (#333, #335).
#
# Границы (§20, §65):
#   * форма сценария, подстановка переменных, план и транзакция — `libs/script`;
#     CLI не разбирает команды control-слоя сам;
#   * проект читается и пишется теми же путями, что у остальных команд
#     (`cmd_project.loadAt`/`writeAtomic`), история — тем же сайдкаром (#331);
#   * рендер по сценарию идёт тем же путём, что `render`
#     (`cmd_render.renderPreparedProject`), поэтому эталон (#335) проверяет
#     настоящий звук, а не отдельную «похожую» ветку.
#
# Почему `plan` ничего не пишет:
#   `previewScript` принимает документ по значению и гоняет команды на копии.
#   Это не соглашение «не забудь не сохранить», а тип: у процедуры нет
#   `var Document`, поэтому «план изменил файл» невозможен (#333).
#
# Детерминизм:
#   Часы документа для сценария возвращают отметку из сценария (`stamp`) или
#   прежнюю отметку проекта. Один и тот же сценарий на одном проекте даёт
#   побайтово тот же документ — критерий приёмки #333.

import std/[algorithm, json, math, os, strutils, tables]

import context
import cli_spec
import cmd_project
import cmd_render
import control_bridge
import history_file
import script
import stamp
import control/commands
import control/document
import control/query
import audio_file_io
import project
import codec_api

const
  ScriptSubcommands* = @["run", "plan", "show", "record", "render", "build"]
    ## Подкоманды `script` — они же кандидаты автодополнения второго уровня.

  DefaultBaselineSuffix = ".baseline.json"
    ## Эталон по умолчанию лежит рядом со сценарием:
    ## `demo.eus` → `demo.baseline.json`. Рядом, а не в общем каталоге:
    ## эталон живёт и умирает вместе со своим сценарием.

  ScriptSpec* = CommandSpec(
    name: "script",
    summary: "сценарии: план, повтор, сборка с нуля и рендер",
    synopsis: "script <run|plan|show|record|render|build> <сценарий.eus> " &
      "[--file проект] [ключи]",
    subcommands: ScriptSubcommands,
    args: @[
      arg("<подкоманда>", "run|plan|show|record|render|build"),
      arg("сценарий.eus", "файл сценария (*" & ScriptSuffix & ")"),
      arg("проект.eproj", "проект, если он не задан ключом --file"),
    ],
    options: @[
      opt("--file", "проект: " & projectSuffixesHint() &
        "; по умолчанию — из сценария или " & DefaultProjectFile,
        value = "проект.eproj"),
      opt("--base", "build: проект, из которого взять ТОЛЬКО метаданные",
        value = "проект.eproj"),
      opt("--var", "значение переменной сценария; можно повторять",
        value = "имя=значение"),
      opt("--last", "record: сколько последних операций истории записать",
        value = "число"),
      opt("--description", "record: описание сценария", value = "текст"),
      opt("--out", "render: файл WAV; по умолчанию рядом со сценарием",
        value = "файл.wav"),
      opt("--seconds", "render: длительность; без ключа — конец партитуры плюс --tail",
        value = "секунды"),
      opt("--tail", "render: добавка после последней ноты, секунды",
        value = "секунды", default = $int(DefaultTailSeconds)),
      opt("--sample-rate", "render: частота дискретизации", value = "Гц"),
      opt("--bits", "render: биты WAV (16, 24, 32)", value = "бит",
        default = "16"),
      opt("--baseline", "render: файл эталона; по умолчанию рядом со сценарием",
        value = "файл.json"),
      switch("--update-baseline",
             "render: пересоздать эталон явно и показать, что изменилось"),
      switch("--samples", "render: сверять с эталоном сэмплы, а не только метрики"),
      switch("--force", "record: перезаписать сценарий; build: перезаписать проект"),
      switch("--allow-loss",
             "build: разрешить потерю ресурсов, состояний плагинов и автоматизации"),
      switch("--build",
             "plan: показать сборку с нуля, а не правку текущего проекта"),
    ],
    example: "euterpia script run demo.eus --file demo.eproj",
    fields: @[
      field("scenario", "файл сценария"),
      field("path", "проект, к которому применён сценарий"),
      field("action", "что сделала подкоманда: `run`|`plan`|`show`|`record`|`render`|`build`"),
      field("base", "build: проект, из которого взяты метаданные"),
      field("commands", "команды сценария: вид и (у `show`) данные"),
      field("commandCount", "сколько команд в сценарии"),
      field("changed", "меняет ли сценарий документ (у `plan` — до применения)"),
      field("counts", "счётчики сущностей `before`/`after`/`delta`"),
      field("lost", "build: что будет потеряно — `kind`, `count`, `reason`"),
      field("backup", "build: путь к `.bak` прежней версии проекта"),
      field("archivedHistory", "build: путь к архиву истории (`.history.bak`)"),
      field("dryRun", "диск не тронут"),
      field("rendered", "render: файл записан"),
      field("frames", "render: кадров в результате"),
      field("baseline", "render: эталон, с которым сверялись или который записан"),
      field("differences", "render: различия с эталоном — пусто при совпадении"),
    ],
    notes: @[
      "сценарий — команды control-слоя в JSON (`euterpia.script`), а не строки shell: ничего не исполняется через оболочку",
      "`script run` применяет сценарий ОДНОЙ транзакцией: отказ не оставляет половины изменений",
      "`script plan` не меняет ни файл, ни документ: команды гоняются на копии",
      "`script build` собирает проект С НУЛЯ: содержимое заменяется, метаданные берутся из `--base`/текущего файла",
      "существующий проект перезаписывается только с `--force`; прежняя версия остаётся в `.bak`, история — в `.history.bak`",
      "если в проекте есть ресурсы, состояния плагинов или автоматизация, которых нет в сценарии, сборка отказывает: `--allow-loss` — явное согласие",
      "переменные `" & "${имя}" & "` подставляются из `variables` сценария и из `--var имя=значение`",
      "`script record` берёт операции из истории проекта (`<проект>.history`), а не из вывода терминала",
      "`script render` — тот же офлайн-рендер, что `render`; эталон сверяется по метрикам, а `--samples` добавляет сэмплы",
      "эталон обновляется только явно (`--update-baseline`) и печатает, что изменилось",
      "часы документа для сценария — из поля `stamp` или прежняя отметка проекта: повтор даёт побайтово тот же документ",
    ])

  ScriptKeys* = ScriptSpec.optionKeys
    ## Ключи `script` — из спецификации: справка, автодополнение и текст
    ## ошибки читают одно описание (#259, #330).

type
  ScriptScan = object
    ok: bool
    rep: Report
    subcommand: string
    scenarioPath: string
    projectPath: string
    haveProject: bool
    overrides: seq[(string, string)]
    last: int
    haveLast: bool
    description: string
    outPath: string
    seconds: float64
    haveSeconds: bool
    tail: float64
    sampleRate: int
    bits: int
    baselinePath: string
    updateBaseline: bool
    samples: bool
    force: bool
    basePath: string
    allowLoss: bool
    buildPlan: bool

# =============================================================================
# Разбор аргументов
# =============================================================================

type
  NumberArg = object
    ok: bool
    value: float64
    message: string

  IntArg = object
    ok: bool
    value: int
    message: string

proc numberArg(text, key: string; lowInclusive, highInclusive: float64): NumberArg =
  ## Число в диапазоне. `NaN`/`inf` отсекаются сравнениями: иначе `--seconds
  ## inf` дал бы рендер, который никто не согласится ждать.
  var number: float
  try:
    number = parseFloat(text.strip())
  except ValueError:
    return NumberArg(ok: false,
      message: key & ": ожидается число, получено «" & text & "»")
  if not (float64(number) >= lowInclusive) or
     not (float64(number) <= highInclusive):
    return NumberArg(ok: false,
      message: key & ": ожидается число от " & $lowInclusive & " до " &
        $highInclusive & ", получено «" & text & "»")
  NumberArg(ok: true, value: float64(number))

proc intArg(text, key: string; lowInclusive, highInclusive: int): IntArg =
  var number: int
  try:
    number = parseInt(text.strip())
  except ValueError:
    return IntArg(ok: false,
      message: key & ": ожидается целое число, получено «" & text & "»")
  if number < lowInclusive or number > highInclusive:
    return IntArg(ok: false,
      message: key & ": ожидается целое от " & $lowInclusive & " до " &
        $highInclusive & ", получено «" & text & "»")
  IntArg(ok: true, value: number)

proc isScenarioPath(path: string): bool =
  ## «Этот аргумент — сценарий» решается расширением из одного места
  ## (`ScriptSuffix`), а не догадкой.
  path.toLowerAscii().endsWith(ScriptSuffix)


proc scanArgs(args: seq[string]): ScriptScan =
  ## Разбор общий для всех подкоманд: так ключ, принятый одной, не становится
  ## «неизвестным» в другой, а подсказка об ошибке перечисляет настоящий
  ## список ключей (`ScriptKeys`).
  result.bits = 16
  result.tail = DefaultTailSeconds
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

    if key in ["--update-baseline", "--samples", "--force", "--allow-loss",
               "--build"]:
      if haveInline:
        result.rep = usageError(key & " — флаг и не принимает значение",
          "например: euterpia script render " & key)
        return
      case key
      of "--update-baseline": result.updateBaseline = true
      of "--samples": result.samples = true
      of "--force": result.force = true
      of "--allow-loss": result.allowLoss = true
      of "--build": result.buildPlan = true
      else: discard
    elif key in ScriptKeys:
      if not haveInline:
        if i + 1 >= args.len:
          result.rep = usageError(key & " требует значение",
            "ключи: " & ScriptKeys.join(", "))
          return
        inc i
        value = args[i]
      case key
      of "--file":
        result.projectPath = value
        result.haveProject = true
      of "--base":
        result.basePath = value
      of "--var":
        let sep = value.find('=')
        if sep <= 0:
          result.rep = usageError("--var: ожидается имя=значение, получено «" &
                                  value & "»",
            "например: euterpia script run demo.eus --var freq=220")
          return
        result.overrides.add (value[0 ..< sep], value[sep + 1 .. ^1])
      of "--last":
        let parsed = intArg(value, key, 1, 10_000)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "record пишет последние операции истории; без ключа — все")
          return
        result.last = parsed.value
        result.haveLast = true
      of "--description":
        result.description = value
      of "--out":
        result.outPath = value
      of "--seconds":
        let parsed = numberArg(value, key, 0.001, 36_000.0)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "например: euterpia script render demo.eus --seconds 5")
          return
        result.seconds = parsed.value
        result.haveSeconds = true
      of "--tail":
        let parsed = numberArg(value, key, 0.0, 36_000.0)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "хвост — добавка к длине партитуры")
          return
        result.tail = parsed.value
      of "--sample-rate":
        let parsed = intArg(value, key, 1, 1_000_000)
        if not parsed.ok:
          result.rep = usageError(parsed.message, "частота в герцах")
          return
        result.sampleRate = parsed.value
      of "--bits":
        let parsed = intArg(value, key, 8, 32)
        if not parsed.ok or parsed.value notin [16, 24, 32]:
          result.rep = usageError(
            "--bits: поддерживаются 16, 24 и 32 бита, получено «" & value & "»",
            "ядро пишет WAV PCM 16/24/32 бита")
          return
        result.bits = parsed.value
      of "--baseline":
        result.baselinePath = value
      else:
        discard
    elif token.startsWith("--"):
      result.rep = usageError("неизвестный ключ: " & token,
                              "ключи: " & ScriptKeys.join(", "))
      return
    else:
      positionals.add token
    inc i


  if positionals.len == 0:
    result.rep = usageError("script: не указана подкоманда",
      "подкоманды: " & ScriptSubcommands.join(", "))
    return
  result.subcommand = positionals[0]
  if result.subcommand notin ScriptSubcommands:
    result.rep = usageError("script: неизвестная подкоманда «" &
                            result.subcommand & "»",
      "подкоманды: " & ScriptSubcommands.join(", "))
    return

  for index in 1 ..< positionals.len:
    let token = positionals[index]
    if isScenarioPath(token):
      if result.scenarioPath.len > 0:
        result.rep = usageError("сценарий указан дважды: " &
          result.scenarioPath & ", " & token,
          "оставьте один файл сценария (*" & ScriptSuffix & ")")
        return
      result.scenarioPath = token
    elif isProjectPath(token):
      if result.haveProject:
        result.rep = usageError("проект указан дважды: " & result.projectPath &
          ", " & token, "оставьте один проект или задайте --file")
        return
      result.projectPath = token
      result.haveProject = true
    else:
      result.rep = usageError("непонятный аргумент: " & token,
        "сценарий — *" & ScriptSuffix & ", проект — " & projectSuffixesHint())
      return

  if result.scenarioPath.len == 0:
    result.rep = usageError("script " & result.subcommand & ": нужен файл сценария",
      "например: euterpia script " & result.subcommand & " demo" & ScriptSuffix)
    return
  result.ok = true

# =============================================================================
# Общие шаги: сценарий, проект, часы
# =============================================================================

proc resolveProjectPath(scan: ScriptScan; script: Script): string =
  ## Проект команды: `--file` сильнее позиционного аргумента, позиционный —
  ## сильнее поля `project` сценария, поле — сильнее умолчания. Правило
  ## записано здесь, а не «по месту»: иначе `run` и `render` разошлись бы в
  ## том, какой проект они правят.
  if scan.haveProject and scan.projectPath.len > 0:
    return scan.projectPath
  if script.project.len > 0:
    # Относительный путь в сценарии — сначала от текущего каталога, затем от
    # каталога сценария: сценарий и проект обычно лежат рядом, а запускать
    # CLI можно откуда угодно.
    if not fileExists(script.project):
      let near = parentDir(scan.scenarioPath) / script.project
      if fileExists(near):
        return near
    return script.project
  DefaultProjectFile

proc stampFor(script: Script; path: string; proj: ProjectFormat): string =
  ## Отметка изменения для часов документа. Сценарий может назвать её явно
  ## (`stamp`), иначе остаётся прежняя отметка проекта: повтор сценария не
  ## зависит от времени запуска (критерий #333).
  ##
  ## Отметка читается через Query API (#336): CLI не заглядывает в
  ## `proj.metadata` сам — это правило проверяет `nimble archGuard`.
  if script.stamp.len > 0:
    return script.stamp
  queryMetadata(openDocument(path, proj)).modified

proc clockFor(stamp: string): Clock =
  ## Часы с фиксированной отметкой. Замыкание захватывает строку по значению,
  ## поэтому документ не зависит от того, когда его создали.
  proc(): string = stamp


proc readScript(scan: ScriptScan; text: var string; parsed: var Script): Report =
  ## Прочитать и разобрать сценарий. Текст возвращается вызывающему: из него
  ## считается sha1 для эталона (#335), и второй раз файл не читается.
  if not fileExists(scan.scenarioPath):
    return envError("нет такого сценария: " & scan.scenarioPath,
      "сценарий создаётся командой `script record` или руками")
  try:
    text = readFile(scan.scenarioPath)
  except CatchableError as e:
    return envError("не удалось прочитать сценарий: " & e.msg,
      "проверьте права: " & scan.scenarioPath)
  let frame = parseScript(text, parsed, scan.overrides)
  if not frame.isOk():
    return frameReport(frame)
  okReport()

proc loadProject(path: string; proj: var ProjectFormat): Report =
  ## Проект — тем же путём, что у остальных команд: формат, версия и границы
  ## проверяются ядром, CLI не пересказывает причины.
  let loaded = loadAt(path)
  if not loaded.ok:
    return loaded.rep
  proj = loaded.proj
  okReport()

proc saveProject(ctx: Ctx; path: string; proj: ProjectFormat;
                 run: ScriptRun; description: string): Report =
  ## Хвост изменяющих подкоманд: проект и история пишутся вместе. Обратные
  ## команды уже построены ядром (`planTransaction`), поэтому откат сценария
  ## — обычная запись истории, а не отдельный механизм (#331).
  let saved = writeAtomic(path, proj)
  if not saved.success:
    return saveError(saved, path)
  let entry = HistoryEntry(redo: run.plan.redo, undo: run.plan.undo,
                           description: description)
  let recorded = recordEntry(path, entry)
  if not recorded.isOk():
    return frameReport(recorded)
  okReport()



# =============================================================================
# Сборка «с нуля»: метаданные и потери (#416)
# =============================================================================

type
  BuildTemplate = object
    ## Откуда взять метаданные для сборки и какая отметка времени станет
    ## `metadata.modified`. Содержимое проекта сюда не входит: сборка его
    ## заменяет.
    ok: bool
    rep: Report
    proj: ProjectFormat
    basePath: string
      ## Пусто — метаданные по умолчанию (как у `init`).
    modified: string

proc metadataOf(info: MetadataInfo; format: string; version: int): ProjectFormat =
  ## Метаданные из Query API в формате проекта. Читать `proj.metadata` в CLI
  ## нельзя (§63, `nimble archGuard`), поэтому единственный вход — DTO.
  ProjectFormat(
    format: (if format.len > 0: format else: ProjectFormatName),
    version: (if version > 0: version else: ProjectFormatVersion),
    metadata: ProjectMetadata(
      name: info.name, author: info.author,
      sampleRate: info.sampleRate, tempo: info.tempo,
      timeSignature: TimeSignatureFormat(
        numerator: info.tsNumerator, denominator: info.tsDenominator),
      created: info.created, modified: info.modified))

proc buildTemplate(scan: ScriptScan; projectPath: string;
                   sc: Script): BuildTemplate =
  ## Метаданные сборки: `--base` > существующий выходной проект > умолчания
  ## `init`. Само содержимое не читается в документ — только метаданные.
  let base =
    if scan.basePath.len > 0: scan.basePath
    elif fileExists(projectPath): projectPath
    else: ""
  if base.len > 0:
    var proj: ProjectFormat
    let loaded = loadProject(base, proj)
    if not loaded.ok:
      result.rep = loaded
      return
    let info = queryMetadata(openDocument(base, proj))
    result.proj = metadataOf(info, proj.format, proj.version)
    result.basePath = base
    result.modified = info.modified
  else:
    let created = if sc.stamp.len > 0: sc.stamp else: nowStamp()
    result.proj = ProjectFormat(
      format: ProjectFormatName, version: ProjectFormatVersion,
      metadata: ProjectMetadata(
        name: defaultName(projectPath),
        sampleRate: DefaultSampleRate, tempo: DefaultTempo,
        timeSignature: TimeSignatureFormat(
          numerator: DefaultTimeSigNumerator,
          denominator: DefaultTimeSigDenominator),
        created: created, modified: created))
    result.modified = created
  result.ok = true

proc buildStamp(sc: Script; tpl: BuildTemplate): string =
  ## Отметка для часов документа при сборке: сценарий сильнее метаданных,
  ## метаданные сильнее системных часов. Поэтому повторная сборка поверх
  ## своего же результата даёт тот же документ.
  if sc.stamp.len > 0:
    return sc.stamp
  if tpl.modified.len > 0:
    return tpl.modified
  nowStamp()

proc lossesJson(items: seq[LossItem]): JsonNode =
  result = newJArray()
  for item in items:
    result.add %*{"kind": item.kind, "count": item.count,
                  "reason": item.reason}

proc lossLines(items: seq[LossItem]): seq[string] =
  for item in items:
    result.add "  " & item.kind & ": " & $item.count & " — " & item.reason

# =============================================================================
# Представление
# =============================================================================

const CountedEntities = ["nodes", "connections", "tracks", "clips",
                         "automationLanes", "pluginStates", "resources"]
  ## Порядок строк сводки фиксирован: вывод CLI сравним между запусками (#88).

proc counterLine(name: string; item: JsonNode): string =
  ## `ноды: 1 → 2 (+1)`. Печатаются только изменившиеся счётчики: «0 → 0»
  ## в отчёте о правке — шум, из-за которого изменение не видно.
  let before = item{"before"}.getInt(0)
  let after = item{"after"}.getInt(0)
  let delta = item{"delta"}.getInt(0)
  result = "  " & name & ": " & $before & " → " & $after &
    " (" & (if delta > 0: "+" else: "") & $delta & ")"

proc changedLines(summary: JsonNode): seq[string] =
  ## Изменившиеся счётчики сводки. Пусто — сценарий ничего не меняет.
  for name in CountedEntities:
    if summary.hasKey(name) and summary[name]{"delta"}.getInt(0) != 0:
      result.add counterLine(name, summary[name])

proc commandLines(script: Script): seq[string] =
  ## Команды сценария по порядку: вид и, у `show`, данные.
  var index = 0
  for cmd in script.commands:
    result.add "  " & $index & ". " & commandName(cmd.kind)
    inc index

proc scenarioHeader(scan: ScriptScan; script: Script): seq[string] =
  result = @["сценарий: " & scan.scenarioPath,
             "формат: " & ScriptFormatName & " v" & $script.version,
             "команд: " & $script.commands.len]
  if script.description.len > 0:
    result.add "описание: " & script.description
  if script.variables.len > 0:
    result.add "переменных: " & $script.variables.len

proc runBody(scan: ScriptScan; path: string; action: string;
             script: Script; run: ScriptRun; dryRun: bool): JsonNode =
  ## Машинный ответ `run`/`plan`: сводка — та же, что в human-выводе.
  ## Команды печатаются видом, без данных: агенту нужно «что будет сделано»,
  ## а полное содержимое отдаёт `show`.
  var commands = newJArray()
  for cmd in script.commands:
    commands.add %*{"kind": commandName(cmd.kind)}
  result = %*{
    "scenario": scan.scenarioPath,
    "path": path,
    "action": action,
    "commands": commands,
    "commandCount": script.commands.len,
    "changed": run.changed,
    "dryRun": dryRun,
    "counts": run.summary,
  }

# =============================================================================
# run / plan
# =============================================================================

proc runScriptRun(ctx: var Ctx; scan: ScriptScan): Report =
  ## `script run`: применить сценарий одной транзакцией и записать проект.
  ## `--dry-run` идёт путём плана: ни проект, ни история не меняются.
  var text = ""
  var sc: Script
  let read = readScript(scan, text, sc)
  if not read.ok:
    return read

  let projectPath = resolveProjectPath(scan, sc)
  var proj: ProjectFormat
  let loaded = loadProject(projectPath, proj)
  if not loaded.ok:
    return loaded

  let stamp = stampFor(sc, projectPath, proj)
  var doc = openDocumentAt(projectPath, proj, clockFor(stamp))
  let description = "сценарий: " & scan.scenarioPath &
    " (команд: " & $sc.commands.len & ")"

  let run =
    if ctx.dryRun: previewScript(doc, sc, description)
    else: applyScript(doc, sc, description)
  if not run.frame.isOk():
    # Отказ «уже есть» — не тупик: у пользователя есть сборка с нуля. Без
    # этой подсказки единственным выходом остаётся удалить проект руками.
    var rep = frameReport(run.frame)
    if run.frame.code in {ecAlreadyExists, ecDuplicateConnection}:
      rep.hint = "проект уже содержит эти объекты; пересобрать с нуля: " &
        "euterpia script build " & scan.scenarioPath & " --force"
    return rep

  var body = runBody(scan, projectPath, "run", sc, run, ctx.dryRun)
  var lines = @[CliName & " script run — сценарий", ""]
  lines.add scenarioHeader(scan, sc)
  lines.add "проект: " & projectPath
  let changes = changedLines(run.summary)
  if changes.len == 0:
    lines.add "изменения: документ не меняется"
  else:
    lines.add "изменения:"
    lines.add changes
  lines.add "команд применено: " & $run.plan.redo.len

  if ctx.dryRun:
    lines.add "не записан: " & projectPath & " (--dry-run)"
    return okReport(body = body, lines = lines)

  let saved = saveProject(ctx, projectPath, doc.proj, run, description)
  if not saved.ok:
    return saved
  lines.add "записан: " & projectPath
  lines.add "история: " & historyPath(projectPath)
  okReport(body = body, lines = lines)

proc runBuildPlan(scan: ScriptScan; sc: Script; projectPath: string): Report =
  ## План сборки (`plan --build`): вопрос «что будет собрано с нуля».
  ## Считается на пустом документе с метаданными, поэтому показывает ровно
  ## то, что сделает `script build`.
  let tpl = buildTemplate(scan, projectPath, sc)
  if not tpl.ok:
    return tpl.rep
  var losses: seq[LossItem] = @[]
  if fileExists(projectPath):
    var current: ProjectFormat
    let loaded = loadProject(projectPath, current)
    if not loaded.ok:
      return loaded
    losses = lossReport(current, sc)
  let baseProj = baseDocument(tpl.proj)
  let doc = openDocumentAt(projectPath, baseProj,
                           clockFor(buildStamp(sc, tpl)))
  let run = previewScript(doc, sc, "план сборки: " & scan.scenarioPath)
  if not run.frame.isOk():
    return frameReport(run.frame)

  var lines = @[CliName & " script plan --build — что будет собрано", ""]
  lines.add scenarioHeader(scan, sc)
  lines.add "проект: " & projectPath & " (будет собран с нуля)"
  lines.add "база метаданных: " &
    (if tpl.basePath.len > 0: tpl.basePath else: "(умолчания init)")
  lines.add "команды:"
  lines.add commandLines(sc)
  let changes = changedLines(run.summary)
  if changes.len == 0:
    lines.add "изменения: документ не меняется"
  else:
    lines.add "изменения:"
    lines.add changes
  if losses.len > 0:
    lines.add "потери при сборке (нужен --allow-loss):"
    lines.add lossLines(losses)
  lines.add "ничего не записано: план не меняет ни проект, ни историю"

  var body = runBody(scan, projectPath, "plan", sc, run, true)
  body["build"] = %true
  body["base"] = %tpl.basePath
  body["lost"] = lossesJson(losses)
  okReport(body = body, lines = lines)


proc runScriptPlan(ctx: var Ctx; scan: ScriptScan): Report =
  ## `script plan`: показать, что изменится, НЕ применяя. Диск не трогается
  ## даже без `--dry-run`: у `previewScript` нет `var Document`.
  ##
  ## `--build` меняет вопрос: план показывает, что даст `script build`.
  discard ctx
  var text = ""
  var sc: Script
  let read = readScript(scan, text, sc)
  if not read.ok:
    return read

  let projectPath = resolveProjectPath(scan, sc)
  if scan.buildPlan:
    return runBuildPlan(scan, sc, projectPath)

  var proj: ProjectFormat
  let loaded = loadProject(projectPath, proj)
  if not loaded.ok:
    return loaded

  let stamp = stampFor(sc, projectPath, proj)
  let doc = openDocumentAt(projectPath, proj, clockFor(stamp))
  let run = previewScript(doc, sc, "план: " & scan.scenarioPath)
  if not run.frame.isOk():
    return frameReport(run.frame)

  var lines = @[CliName & " script plan — что изменится", ""]
  lines.add scenarioHeader(scan, sc)
  lines.add "проект: " & projectPath
  lines.add "команды:"
  lines.add commandLines(sc)
  let changes = changedLines(run.summary)
  if changes.len == 0:
    lines.add "изменения: документ не меняется"
  else:
    lines.add "изменения:"
    lines.add changes
  lines.add "ничего не записано: план не меняет ни проект, ни историю"

  okReport(body = runBody(scan, projectPath, "plan", sc, run, true),
           lines = lines)


# =============================================================================
# build (#416)
# =============================================================================

proc runScriptBuild(ctx: var Ctx; scan: ScriptScan): Report =
  ## `script build`: собрать проект С НУЛЯ и записать его.
  ##
  ## Отличия от `run` зафиксированы контрактом, а не привычкой:
  ##   * содержимое заменяется (метаданные — из `--base`/текущего файла);
  ##   * существующий файл требует `--force` (защита от опечатки в пути);
  ##   * история архивируется: документ заменён, прежний стек к нему не
  ##     относится;
  ##   * то, что сценарий не умеет выражать, не теряется молча — отказ или
  ##     `--allow-loss`.
  var text = ""
  var sc: Script
  let read = readScript(scan, text, sc)
  if not read.ok:
    return read

  let projectPath = resolveProjectPath(scan, sc)
  let exists = fileExists(projectPath)
  if exists and not scan.force:
    return usageError("проект уже есть: " & projectPath,
      "перезапись: euterpia script build " & scan.scenarioPath & " --force",
      code = ecAlreadyExists)

  let tpl = buildTemplate(scan, projectPath, sc)
  if not tpl.ok:
    return tpl.rep

  var losses: seq[LossItem] = @[]
  if exists:
    var current: ProjectFormat
    let loaded = loadProject(projectPath, current)
    if not loaded.ok:
      return loaded
    losses = lossReport(current, sc)
    if losses.len > 0 and not scan.allowLoss:
      var details = @[
        "пересборка заменит проект целиком, а сценарий не создаёт:"]
      details.add lossLines(losses)
      return usageError(
        "сборка потеряет данные проекта: " & $losses.len & " вид(ов)",
        "если потеря ожидаема — добавьте --allow-loss",
        code = ecCheckFailed, lines = details,
        body = %*{"lost": lossesJson(losses)})

  let description = "сборка: " & scan.scenarioPath &
    " (команд: " & $sc.commands.len & ")"
  let baseProj = baseDocument(tpl.proj)
  var doc = openDocumentAt(projectPath, baseProj,
                           clockFor(buildStamp(sc, tpl)))
  let run =
    if ctx.dryRun: previewScript(doc, sc, description)
    else: applyScript(doc, sc, description)
  if not run.frame.isOk():
    return frameReport(run.frame)

  var body = runBody(scan, projectPath, "build", sc, run, ctx.dryRun)
  body["base"] = %tpl.basePath
  body["force"] = %scan.force
  body["lost"] = lossesJson(losses)

  var lines = @[CliName & " script build — сборка проекта из сценария", ""]
  lines.add scenarioHeader(scan, sc)
  lines.add "проект: " & projectPath &
    (if exists: " (перезаписан)" else: " (создан)")
  lines.add "база метаданных: " &
    (if tpl.basePath.len > 0: tpl.basePath else: "(умолчания init)")
  let changes = changedLines(run.summary)
  if changes.len > 0:
    lines.add "изменения:"
    lines.add changes
  if losses.len > 0:
    lines.add "потеряно осознанно (--allow-loss):"
    lines.add lossLines(losses)

  if ctx.dryRun:
    lines.add "не записан: " & projectPath & " (--dry-run)"
    lines.add "история: не тронута (--dry-run)"
    return okReport(body = body, lines = lines)

  # Сначала архив истории, потом запись: если архив не удался, проект цел и
  # причина видна. Обратный порядок оставил бы новый проект с чужим стеком.
  let hadHistory = fileExists(historyPath(projectPath))
  let archived = archiveHistory(projectPath)
  if not archived.isOk():
    return frameReport(archived)

  let saved = writeAtomic(projectPath, doc.proj)
  if not saved.success:
    return saveError(saved, projectPath)

  if exists:
    body["backup"] = %(projectPath & ".bak")
    lines.add "прежняя версия: " & projectPath & ".bak"
  if hadHistory:
    body["archivedHistory"] = %historyArchivePath(projectPath)
    lines.add "история: архивирована в " & historyArchivePath(projectPath)
  else:
    body["archivedHistory"] = %""
  lines.add "записан: " & projectPath
  okReport(body = body, lines = lines)


# =============================================================================
# show
# =============================================================================

proc runScriptShow(ctx: var Ctx; scan: ScriptScan): Report =
  ## `script show`: показать сценарий, ничего не выполняя. Проект не нужен:
  ## сценарий — данные, и его видно до всякого применения.
  discard ctx
  var text = ""
  var sc: Script
  let read = readScript(scan, text, sc)
  if not read.ok:
    return read

  var lines = @[CliName & " script show — сценарий", ""]
  lines.add scenarioHeader(scan, sc)
  if sc.project.len > 0:
    lines.add "базовый проект: " & sc.project
  if sc.stamp.len > 0:
    lines.add "отметка изменения: " & sc.stamp
  if sc.variables.len > 0:
    var names: seq[string] = @[]
    for name in sc.variables.keys:
      names.add name
    names.sort()
    for name in names:
      lines.add "  переменная " & name & " = " & scalarText(sc.variables[name])
  lines.add "команды:"
  var index = 0
  for cmd in sc.commands:
    lines.add "  " & $index & ". " & commandName(cmd.kind) & "  " &
      $cmd.toJson
    inc index

  var body = scriptJson(sc)
  body["scenario"] = %scan.scenarioPath
  body["action"] = %"show"
  okReport(body = body, lines = lines)

# =============================================================================
# record
# =============================================================================

proc runScriptRecord(ctx: var Ctx; scan: ScriptScan): Report =
  ## `script record`: записать то, что уже сделано с проектом.
  ##
  ## Источник — история проекта (`<проект>.history`), а не вывод терминала:
  ## она хранит ИСХОДНЫЕ команды каждой операции (обратные нужны откату), а
  ## значит сценарий получается из того же контракта, что и обычная правка.
  var hist: CliHistory
  # Сценарий на входе НЕ читается: `record` его создаёт из истории.
  let projectPath =
    if scan.haveProject and scan.projectPath.len > 0: scan.projectPath
    else: DefaultProjectFile
  let read = readHistory(projectPath, hist)
  if not read.isOk():
    return frameReport(read)
  if hist.undoStack.len == 0:
    return usageError("нечего записывать: история проекта пуста",
      "сначала измените проект (например, `node add osc`) — правки попадают в " &
        historyPath(projectPath), code = ecInvalidArgument)

  let take =
    if scan.haveLast: min(scan.last, hist.undoStack.len)
    else: hist.undoStack.len
  let first = hist.undoStack.len - take

  var commands: seq[ControlCommand] = @[]
  var descriptions: seq[string] = @[]
  for index in first ..< hist.undoStack.len:
    let entry = hist.undoStack[index]
    descriptions.add entry.description
    for cmd in entry.redo:
      commands.add cmd

  if commands.len == 0:
    return usageError("в выбранных операциях нет команд",
      "история пуста или записи не содержат исходных команд",
      code = ecInvalidArgument)

  let description =
    if scan.description.len > 0: scan.description
    else: "запись истории: " & $take & " операций"
  let recorded = Script(version: ScriptFormatVersion,
                        description: description,
                        project: projectPath,
                        commands: commands)

  var lines = @[CliName & " script record — сценарий из истории", ""]
  lines.add "проект: " & projectPath
  lines.add "операций записано: " & $take & " (команд: " & $commands.len & ")"
  for item in descriptions:
    lines.add "  " & item
  if description.len > 0:
    lines.add "описание: " & description

  if ctx.dryRun:
    lines.add "не записан: " & scan.scenarioPath & " (--dry-run)"
    return okReport(body = %*{
      "scenario": scan.scenarioPath, "path": projectPath, "action": "record",
      "entries": take, "commandCount": commands.len, "dryRun": true,
      "description": description}, lines = lines)

  if fileExists(scan.scenarioPath) and not scan.force:
    return usageError("сценарий уже есть: " & scan.scenarioPath,
      "перезапись затрёт его содержимое; добавьте --force или укажите другой файл",
      code = ecAlreadyExists)

  let saved = saveScript(scan.scenarioPath, recorded)
  if not saved.isOk():
    return frameReport(saved)
  lines.add "записан: " & scan.scenarioPath
  okReport(body = %*{
    "scenario": scan.scenarioPath, "path": projectPath, "action": "record",
    "entries": take, "commandCount": commands.len, "dryRun": false,
    "description": description}, lines = lines)

proc updateBaselineFile(ctx: Ctx; scan: ScriptScan; actual: Baseline;
                        path: string; lines: var seq[string];
                        body: JsonNode): Report =
  ## Явное обновление эталона: сначала показать, что изменилось относительно
  ## прежнего, потом записать. Молчаливой перезаписи нет — иначе «эталон»
  ## превратился бы в снимок последнего прогона и перестал что-то ловить.
  var old: Baseline
  var previousFound = false
  var differences: seq[string] = @[]
  if fileExists(path):
    let readOld = readBaseline(path, old)
    if readOld.isOk():
      previousFound = true
      differences = compareBaseline(old, actual, false)
    else:
      lines.add "прежний эталон не прочитан (" & readOld.message &
        "): он будет заменён"

  var diffsJson = newJArray()
  for item in differences:
    diffsJson.add %item
  body["differences"] = diffsJson
  body["baseline"] = %*{"path": path, "checked": false, "written": false,
                        "previousFound": previousFound}

  if ctx.dryRun:
    lines.add "эталон не записан: " & path & " (--dry-run)"
    return okReport(body = body, lines = lines)

  let written = writeBaseline(path, actual)
  if not written.isOk():
    return frameReport(written)
  body["baseline"]["written"] = %true
  lines.add "эталон записан: " & path
  if differences.len == 0:
    lines.add "изменений относительно прежнего эталона нет"
  else:
    lines.add "изменилось относительно прежнего эталона (" &
      $differences.len & "):"
    for item in differences:
      lines.add "  " & item
  okReport(body = body, lines = lines)

proc checkAgainstBaseline(scan: ScriptScan; actual: Baseline; path: string;
                          lines: var seq[string]; body: JsonNode): Report =
  ## Сверка с эталоном: метрики всегда, сэмплы — по `--samples`. Несовпадение
  ## — вердикт CI (`check_failed`, код 1), а не ошибка окружения: рендер
  ## состоялся, звук другой.
  var expected: Baseline
  let readExpected = readBaseline(path, expected)
  if not readExpected.isOk():
    return frameReport(readExpected)
  let differences = compareBaseline(expected, actual, scan.samples)
  var diffsJson = newJArray()
  for item in differences:
    diffsJson.add %item
  body["differences"] = diffsJson
  body["baseline"] = %*{"path": path, "checked": true, "written": false,
                        "samples": scan.samples}
  if differences.len > 0:
    var details = @["эталон: " & path, "различий: " & $differences.len]
    details.add differences
    return checkFailedError(
      "рендер по сценарию не совпал с эталоном: " & $differences.len &
        " различий",
      hint = "если изменение ожидаемое — обновите эталон явно: " &
        "--update-baseline",
      lines = lines & details, body = body, errorKind = "baseline")
  lines.add "эталон: совпал (" & path & ")"
  okReport(body = body, lines = lines)




# =============================================================================
# render (#335)
# =============================================================================

proc measureWav(path: string; baseline: var Baseline): string =
  ## Метрики записанного файла: кадры, частота, пик, RMS, суммы байтов и
  ## сэмплов. Пустая строка — измерение удалось; иначе причина.
  var samples: seq[float32] = @[]
  var info: AudioFileInfo
  try:
    let loaded = readAllAudioFile(path)
    samples = loaded.samples
    info = loaded.info
  except CatchableError as e:
    return "не удалось прочитать результат рендера: " & e.msg

  baseline.frames = int(info.numFrames)
  baseline.sampleRate = int(info.sampleRate)
  baseline.bits = int(info.bitsPerSample)
  baseline.output = path
  baseline.fileSha1 = sha1OfFile(path)
  baseline.measured = true

  var peak = 0.0
  var sumSquares = 0.0
  var digest = ""
  # Сумма сэмплов — по десятичному тексту, а не по сырым байтам: так она не
  # зависит от порядка байтов платформы и от `float32`-представления.
  for sample in samples:
    let value = float64(sample)
    let magnitude = abs(value)
    if magnitude > peak:
      peak = magnitude
    sumSquares += value * value
    digest.add formatFloat(value, ffDecimal, 7)
    digest.add ','
  baseline.peak = peak
  baseline.rms = (if samples.len > 0: sqrt(sumSquares / float64(samples.len))
                  else: 0.0)
  baseline.silent = peak == 0.0
  baseline.samplesSha1 = sha1OfText(digest)
  ""

proc baselinePathFor(scan: ScriptScan): string =
  ## Эталон рядом со сценарием, если ключ `--baseline` не назвал другой файл.
  if scan.baselinePath.len > 0: scan.baselinePath
  else: scan.scenarioPath.changeFileExt(DefaultBaselineSuffix)

proc runScriptRender(ctx: var Ctx; scan: ScriptScan): Report =
  ## `script render`: детерминированный рендер по сценарию и сверка с эталоном.
  ##
  ## Сценарий применяется к документу В ПАМЯТИ и рендерится тем же путём, что
  ## `render` (#335). Промежуточный файл проекта не создаётся: иначе рендер
  ## проверял бы не то, что записано в сценарии, а то, что успело сохраниться.
  var text = ""
  var sc: Script
  let read = readScript(scan, text, sc)
  if not read.ok:
    return read

  let projectPath = resolveProjectPath(scan, sc)
  var proj: ProjectFormat
  let loaded = loadProject(projectPath, proj)
  if not loaded.ok:
    return loaded

  var doc = openDocumentAt(projectPath, proj,
                           clockFor(stampFor(sc, projectPath, proj)))
  let applied = applyScript(doc, sc, "рендер по сценарию: " & scan.scenarioPath)
  if not applied.frame.isOk():
    return frameReport(applied.frame)

  var outPath = scan.outPath
  if outPath.len == 0:
    outPath = scan.scenarioPath.changeFileExt(".wav")
  if not outPath.toLowerAscii().endsWith(".wav"):
    return usageError("формат вывода не поддержан: " & outPath,
      "рендер по сценарию пишет WAV — расширение .wav")

  let rendered = renderPreparedProject(
    ctx, projectPath, outPath, doc.proj,
    (if scan.haveSeconds: scan.seconds else: 0.0),
    scan.tail, -1, scan.sampleRate, 0, scan.bits)
  if not rendered.ok:
    return rendered

  var lines = @[CliName & " script render — рендер по сценарию", ""]
  lines.add scenarioHeader(scan, sc)
  lines.add "проект: " & projectPath
  lines.add "команд применено: " & $applied.plan.redo.len
  # Отчёт рендера (длительность, пик, RMS, предупреждения) — тот же, что у
  # `render`: второй формулировки не появляется.
  for line in rendered.lines:
    lines.add line

  var body = newJObject()
  if rendered.body != nil and rendered.body.kind == JObject:
    body = rendered.body
  body["scenario"] = %scan.scenarioPath
  body["path"] = %projectPath
  body["action"] = %"render"
  body["commandCount"] = %sc.commands.len

  if ctx.dryRun or not body{"rendered"}.getBool(false):
    lines.add "эталон не сверялся: файл не записан"
    body["baseline"] = %*{"checked": false}
    body["differences"] = newJArray()
    return okReport(body = body, lines = lines)

  var actual: Baseline
  let measured = measureWav(outPath, actual)
  if measured.len > 0:
    return envError(measured, "проверьте файл: " & outPath)
  actual.scenario = scan.scenarioPath
  actual.scenarioSha1 = sha1OfText(text)

  body["fileSha1"] = %actual.fileSha1
  body["samplesSha1"] = %actual.samplesSha1

  let baselinePath = baselinePathFor(scan)
  if scan.updateBaseline:
    return updateBaselineFile(ctx, scan, actual, baselinePath, lines, body)
  if scan.baselinePath.len > 0 or fileExists(baselinePath):
    return checkAgainstBaseline(scan, actual, baselinePath, lines, body)

  lines.add "эталон не сверялся: --baseline не задан"
  body["baseline"] = %*{"checked": false, "path": baselinePath}
  body["differences"] = newJArray()
  okReport(body = body, lines = lines)


# =============================================================================
# Точка входа
# =============================================================================

proc runScript*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia script <подкоманда> <сценарий.eus> [ключи]`.
  ##
  ## Подкоманды называют намеренно глаголами: `run` применяет, `plan` только
  ## показывает, `record` записывает сделанное, `render` закрепляет звук
  ## эталоном. Одна команда `script` с ключами заставляла бы угадывать режим.
  let scan = scanArgs(args)
  if not scan.ok:
    return scan.rep
  case scan.subcommand
  of "run": runScriptRun(ctx, scan)
  of "plan": runScriptPlan(ctx, scan)
  of "show": runScriptShow(ctx, scan)
  of "record": runScriptRecord(ctx, scan)
  of "render": runScriptRender(ctx, scan)
  of "build": runScriptBuild(ctx, scan)
  else:
    usageError("script: неизвестная подкоманда «" & scan.subcommand & "»",
      "подкоманды: " & ScriptSubcommands.join(", "))

