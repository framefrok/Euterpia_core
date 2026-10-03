# cli/cmd_project.nim
#
# `euterpia init` и `euterpia project show|set|validate` (issue #89) —
# минимум, без которого CLI не может создать проект (MANIFEST §19).
#
# Границы (MANIFEST §20): формат проекта целиком живёт в `core/project.nim`.
# CLI вызывает `loadProject`/`saveProject`/`toJson` и НЕ разбирает JSON сам:
# иначе появился бы второй парсер формата, который разошёлся бы с первым
# (§58/§59 — версионирование формата). Команды — чистый I/O: движок не
# создаётся, аудиоустройство не открывается (критерий приёмки #89).
#
# Что такое «поле проекта» здесь: только метаданные (`ProjectFields`).
# Граф, секвенсор и состояния плагинов появляются в файле через команды
# графа (#90) и плагинов (#95) — правка JSON руками не является интерфейсом.
#
# Безопасность записи:
# - `set` пишет АТОМАРНО (tmp-файл рядом + rename): обрыв процесса между
#   записью и переименованием не оставляет полупроект, а цель до rename
#   не тронута;
# - повреждённый или чужой файл НЕ перезаписывается: сначала чтение и
#   проверка формата, запись — только после успешного разбора;
# - `init` отказывается затирать существующий файл без `--force`;
# - `--dry-run` показывает, что было бы сделано, и не касается диска.
#
# Коды возврата (#88, критерии #89): 0 — успех, 1 — данные (неверное поле,
# битый формат, отсутствующий файл), 2 — среда (файл/каталог не читается
# или не пишется), 3 — внутренняя ошибка. Версия и формат файла — это
# данные пользователя, а не среда: они и дают код 1.

import std/[algorithm, json, os, strutils, tables, times]

import project
import context
import checks

const
  DefaultProjectFile* = "project.eut"
    ## Проект по умолчанию: MANIFEST §19 показывает `euterpia init` и
    ## `euterpia project show` без аргументов, а расширение `.eut` — из
    ## `euterpia render project.eut` (там же). Один источник для всех
    ## четырёх команд: `show`/`set`/`validate` тоже работают без файла.

  ProjectFields* = @["name", "author", "tempo", "sample-rate", "time-signature"]
    ## Поля, которыми управляет `project set`. Один источник для разбора,
    ## текста ошибки и справки — подсказка не может разойтись с кодом.

  ProjectSubcommands* = @["show", "set", "validate"]
    ## Подкоманды `project`: кандидаты автодополнения второго уровня (#259).

  InitFlags* = @[
    "--name", "--author", "--sr", "--sample-rate",
    "--tempo", "--ts", "--time-signature", "--force",
  ]
    ## Ключи `init` — для справки и автодополнения.

  StampFormat* = "yyyy-MM-dd'T'HH:mm:ss"
    ## Формат `metadata.created`/`modified`: ISO 8601 без зоны (локальное
    ## время). Ядро хранит эти поля как непрозрачные строки, но формат
    ## лексикографически упорядочен, поэтому строки сравнимы между собой.

  DefaultTempo* = 120.0f
  DefaultSampleRate* = 48000.0f
  DefaultTimeSigNumerator* = 4'i32
  DefaultTimeSigDenominator* = 4'i32
    ## Умолчания `init` совпадают с `initTransport` ядра (120 BPM, 48 кГц,
    ## 4/4): проект, созданный CLI, ведёт себя как проект, который движок
    ## инициализирует по умолчанию.

  MaxTempo* = 1000.0
  MaxSampleRate* = 1_000_000.0
    ## Границы значений объявлены явно и попадают в текст ошибки: правило
    ## видно пользователю, а не выясняется на опыте.

type
  LoadedProject = object
    ok: bool
    proj: ProjectFormat
    rep: Report
      ## Готовый отчёт об ошибке чтения — печатается как есть, чтобы
      ## команда не переизобретала текст для каждого вида сбоя.
    code: ExitCode
      ## Код возврата для этого сбоя. Нужен `validate`: он печатает отчёт
      ## в общем виде, но статус процесса обязан остаться «данные» (1) или
      ## «среда» (2), а не превратиться в «провал проверок» (тоже 1) для
      ## недоступного файла.
    kind: ProjectErrorKind
      ## Вид ошибки ядра. По нему `validate` выбирает подсказку: советовать
      ## «запустите validate» внутри самого validate бессмысленно.

  NumberParse = object
    ok: bool
    number: float
    message: string

  TimeSigParse = object
    ok: bool
    numerator, denominator: int32
    message: string

# =============================================================================
# Отображение ошибок ядра на коды возврата CLI
# =============================================================================

proc codeFor*(kind: ProjectErrorKind): ExitCode =
  ## Формат, версия и битый JSON — это ДАННЫЕ (код 1): они пришли из файла,
  ## который указал пользователь. I/O — среда (код 2): файл верный, но
  ## недоступен. `pekNone` сюда не попадает, но случай покрыт, чтобы `case`
  ## остался исчерпывающим при добавлении новых видов ошибок в Core.
  case kind
  of pekNone: exOk
  of pekFileNotFound, pekJsonParseError, pekInvalidFormat,
     pekUnsupportedVersion, pekMissingField: exUsage
  of pekIOError: exEnv
  of pekUnknownError: exPanic

proc kindName*(code: ExitCode): string =
  ## Стабильные имена для агента (`context.Ctx` документирует их набор).
  case code
  of exOk, exUsage: "usage"
  of exEnv: "env"
  of exPanic: "panic"

proc loadHint(kind: ProjectErrorKind; path: string): string =
  ## Подсказка зависит от причины: советовать `validate` для отсутствующего
  ## файла бессмысленно — validate упадёт на том же месте.
  case kind
  of pekFileNotFound: "создать проект: euterpia init " & path
  of pekIOError: "проверьте права доступа к файлу и каталогу"
  of pekUnsupportedVersion:
    "версия формата новее этой сборки CLI: обновите euterpia"
  else: "структуру файла показывает: euterpia project validate " & path

proc validateHint(kind: ProjectErrorKind; path: string): string =
  ## Подсказка для отчёта `validate`: он сам объясняет структуру, поэтому
  ## набор советов другой — что делать с файлом, а не куда его нести.
  case kind
  of pekFileNotFound: "создать проект: euterpia init " & path
  of pekIOError: "проверьте права доступа к файлу и каталогу"
  of pekUnsupportedVersion:
    "версия формата новее этой сборки CLI: обновите euterpia"
  else: "исправьте файл или восстановите его из резервной копии"

proc projectError*(
  kind: ProjectErrorKind;
  message, path, hint: string
): Report =
  ## Сообщение ядра НЕ переводится и не пересказывается: пересказ разошёлся
  ## бы с настоящей причиной. CLI добавляет только подсказку и код возврата.
  let code = codeFor(kind)
  errReport(code, kindName(code), message, hint = hint)

proc loadAt(path: string): LoadedProject =
  let loaded = loadProject(path)
  if not loaded.success:
    let code = codeFor(loaded.error.kind)
    return LoadedProject(
      ok: false,
      code: code,
      kind: loaded.error.kind,
      rep: errReport(code, kindName(code), loaded.error.message,
                     hint = loadHint(loaded.error.kind, path)))
  LoadedProject(ok: true, proj: loaded.value)

proc saveError(saved: ProjectResult[void]; path: string): Report =
  ## Ошибку записи формирует ядро (`pekIOError`), CLI добавляет путь и код.
  projectError(saved.error.kind, saved.error.message, path,
               "проверьте каталог и права: " & path)

# =============================================================================
# Метаданные и машинный вид проекта
# =============================================================================

proc nowStamp*(): string =
  ## Отметка времени для `metadata.created`/`modified`.
  now().format(StampFormat)

proc defaultName*(path: string): string =
  ## Имя проекта по умолчанию — имя файла без расширения. Это правило
  ## документировано в справке `init`, а не угадывается: `init demo.eut`
  ## даёт проект «demo», и `project show` сразу показывает осмысленное имя.
  let stem = extractFilename(path).changeFileExt("")
  if stem.len > 0: stem else: "project"

proc display(value: string): string =
  ## Пустое поле печатается словами: «имя: » в выводе неотличимо от сбоя.
  if value.len > 0: value else: "(не задано)"

proc metadataLines*(proj: ProjectFormat): seq[string] =
  ## Метаданные в человекочитаемом виде. Порядок строк фиксирован: вывод
  ## CLI должен быть сравнимым между запусками (#88).
  result.add "имя: " & display(proj.metadata.name)
  result.add "автор: " & display(proj.metadata.author)
  result.add "частота дискретизации: " & $proj.metadata.sampleRate & " Гц"
  result.add "темп: " & $proj.metadata.tempo & " BPM"
  result.add "размер: " & $proj.metadata.timeSignature.numerator & "/" &
    $proj.metadata.timeSignature.denominator
  result.add "создан: " & display(proj.metadata.created)
  result.add "изменён: " & display(proj.metadata.modified)

proc summarize*(proj: ProjectFormat): JsonNode =
  ## Счётчики содержимого: агент читает их, не разворачивая граф и треки.
  var clips = 0
  var notes = 0
  for track in proj.sequencer.tracks:
    clips += track.clips.len
    for clip in track.clips:
      notes += clip.notes.len
  var points = 0
  for lane in proj.sequencer.automationLanes:
    points += lane.points.len
  var stateBytes = 0
  for state in proj.pluginStates:
    stateBytes += state.state.len
  %*{
    "nodes": proj.graph.nodes.len,
    "connections": proj.graph.connections.len,
    "tracks": proj.sequencer.tracks.len,
    "clips": clips,
    "notes": notes,
    "automationLanes": proj.sequencer.automationLanes.len,
    "automationPoints": points,
    "pluginStates": proj.pluginStates.len,
    "pluginStateBytes": stateBytes,
  }

proc projectBody*(proj: ProjectFormat; path: string): JsonNode =
  ## Машинный вид проекта: `toJson` из Core + путь и счётчики.
  ##
  ## Сериализация НЕ дублируется в CLI: если Core изменит схему файла
  ## (§58/§59), `project show --json` изменится вместе с ней — клиент узнает
  ## об этом по полю `version`, а не по тому, что «CLI забыл поле».
  result = toJson(proj)
  result["path"] = %path
  result["summary"] = summarize(proj)

proc writeAtomic*(path: string; proj: ProjectFormat): ProjectResult[void] =
  ## Атомарная запись: временный файл рядом с целью + переименование.
  ##
  ## `moveFile` перезаписывает цель на всех платформах (POSIX `rename`,
  ## Windows `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`), поэтому читатель
  ## видит либо старый файл целиком, либо новый целиком. Имя tmp-файла
  ## содержит PID: два параллельных `set` не подменят друг другу буфер.
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  let saved = saveProject(proj, tmp)
  if not saved.success:
    return saved
  try:
    moveFile(tmp, path)
  except CatchableError as e:
    # Мусорный tmp-файл не оставляем: иначе он переживёт процесс и будет
    # выглядеть как «второй проект».
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return err[void](pekIOError, "не удалось заменить файл проекта: " & e.msg)
  ok[void]()

proc splitInline*(args: seq[string]): seq[string] =
  ## `--tempo=140` → `--tempo`, `140`: ключи с инлайн-значением
  ## разворачиваются до разбора. Разворачивается только токен, начинающийся
  ## с `--`: позиционный аргумент со знаком равенства (имя файла) не трогается.
  for arg in args:
    if arg.len > 2 and arg.startsWith("--") and '=' in arg:
      let eq = arg.find('=')
      result.add arg[0 ..< eq]
      result.add arg[eq + 1 .. ^1]
    else:
      result.add arg

# =============================================================================
# Поля проекта
# =============================================================================

proc parseNumber(text, field: string; maxValue: float): NumberParse =
  ## Числовое поле метаданных. Верхняя граница — из одного места для всех
  ## полей, а текст ошибки называет правило целиком.
  var number: float
  try:
    number = parseFloat(text.strip())
  except ValueError:
    return NumberParse(ok: false,
      message: field & ": ожидается число, получено «" & text & "»")
  # NaN отсекается сравнением (`NaN > 0` — ложь), бесконечность — верхней
  # границей: без неё `--tempo inf` дал бы проект с бесконечным темпом.
  if not (number > 0.0) or number > maxValue:
    return NumberParse(ok: false,
      message: field & ": ожидается 0 < значение ≤ " & $maxValue &
        ", получено «" & text & "»")
  NumberParse(ok: true, number: number)

proc parseTimeSignature(text: string): TimeSigParse =
  ## «4/4», «3/4», «6/8». Знаменатель обязан быть степенью двойки: в ядре
  ## доля считается как `4/знаменатель` (`transport.beatsPerBar`), поэтому
  ## 4/6 дал бы не музыкальный размер, а мусор.
  let parts = text.split('/')
  if parts.len != 2:
    return TimeSigParse(ok: false,
      message: "time-signature: ожидается «числитель/знаменатель», " &
               "например 4/4, получено «" & text & "»")
  var numerator, denominator: int
  try:
    numerator = parseInt(parts[0].strip())
    denominator = parseInt(parts[1].strip())
  except ValueError:
    return TimeSigParse(ok: false,
      message: "time-signature: числитель и знаменатель должны быть целыми, " &
               "получено «" & text & "»")
  if numerator < 1 or denominator < 1:
    return TimeSigParse(ok: false,
      message: "time-signature: числитель и знаменатель должны быть больше " &
               "нуля, получено «" & text & "»")
  if (denominator and (denominator - 1)) != 0:
    return TimeSigParse(ok: false,
      message: "time-signature: знаменатель — степень двойки " &
               "(1, 2, 4, 8, 16, 32), получено «" & text & "»")
  TimeSigParse(ok: true, numerator: int32(numerator),
               denominator: int32(denominator))

proc readField*(proj: ProjectFormat; field: string): string =
  ## Текущее значение поля — для diff при `set`.
  case field
  of "name": proj.metadata.name
  of "author": proj.metadata.author
  of "tempo": $proj.metadata.tempo
  of "sample-rate": $proj.metadata.sampleRate
  of "time-signature": $proj.metadata.timeSignature.numerator & "/" &
    $proj.metadata.timeSignature.denominator
  else: ""

proc setField*(
  proj: var ProjectFormat;
  field, value: string
): tuple[ok: bool; message: string] =
  ## Записывает поле метаданных, проверяя значение. Проверка живёт ЗДЕСЬ, а
  ## не в разборе аргументов: одно правило обслуживает и `init --tempo`, и
  ## `project set tempo` — иначе ключ и поле разошлись бы в требованиях.
  case field
  of "name":
    proj.metadata.name = value
  of "author":
    proj.metadata.author = value
  of "tempo":
    let parsed = parseNumber(value, "tempo", MaxTempo)
    if not parsed.ok: return (false, parsed.message)
    proj.metadata.tempo = float32(parsed.number)
  of "sample-rate":
    let parsed = parseNumber(value, "sample-rate", MaxSampleRate)
    if not parsed.ok: return (false, parsed.message)
    proj.metadata.sampleRate = float32(parsed.number)
  of "time-signature":
    let parsed = parseTimeSignature(value)
    if not parsed.ok: return (false, parsed.message)
    proj.metadata.timeSignature = TimeSignatureFormat(
      numerator: parsed.numerator, denominator: parsed.denominator)
  else:
    return (false, "неизвестное поле проекта: " & field)
  (true, "")

# =============================================================================
# init
# =============================================================================

type
  InitOptions = object
    path, name, author: string
    nameGiven: bool
      ## Отличает «--name не передавали» от «--name ""»: в первом случае имя
      ## берётся из имени файла, во втором остаётся пустым по воле вызывающего.
    tempo, sampleRate: float32
    tsNumerator, tsDenominator: int32
    force: bool

  InitParse = object
    ok: bool
    options: InitOptions
    rep: Report
      ## Ошибка разбора аргументов — готовая к печати.

proc parseInit(args: seq[string]): InitParse =
  ## Разбор `init`. Умолчания выставляются ЗДЕСЬ и совпадают с ядром
  ## (`initTransport`): проект, созданный CLI, ведёт себя как проект,
  ## инициализированный движком.
  result.options.path = DefaultProjectFile
  result.options.tempo = DefaultTempo
  result.options.sampleRate = DefaultSampleRate
  result.options.tsNumerator = DefaultTimeSigNumerator
  result.options.tsDenominator = DefaultTimeSigDenominator

  let tokens = splitInline(args)
  var positional: seq[string] = @[]
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token in ["--name", "--author", "--sr", "--sample-rate", "--tempo",
                 "--ts", "--time-signature"]:
      if i + 1 >= tokens.len:
        result.rep = usageError("ключ " & token & " требует значение",
                                "например: euterpia init demo.eut --tempo 140")
        return
      let value = tokens[i + 1]
      case token
      of "--name":
        result.options.name = value
        result.options.nameGiven = true
      of "--author":
        result.options.author = value
      of "--sr", "--sample-rate":
        let parsed = parseNumber(value, "sample-rate", MaxSampleRate)
        if not parsed.ok:
          result.rep = usageError(parsed.message, "например: --sr 48000")
          return
        result.options.sampleRate = float32(parsed.number)
      of "--tempo":
        let parsed = parseNumber(value, "tempo", MaxTempo)
        if not parsed.ok:
          result.rep = usageError(parsed.message, "например: --tempo 140")
          return
        result.options.tempo = float32(parsed.number)
      else:
        let parsed = parseTimeSignature(value)
        if not parsed.ok:
          result.rep = usageError(parsed.message, "например: --ts 4/4")
          return
        result.options.tsNumerator = parsed.numerator
        result.options.tsDenominator = parsed.denominator
      inc i, 2
      continue
    if token == "--force":
      result.options.force = true
      inc i
      continue
    if token.startsWith("--"):
      result.rep = usageError("неизвестный ключ init: " & token,
                              "ключи: " & InitFlags.join(", "))
      return
    positional.add token
    inc i

  if positional.len > 1:
    result.rep = usageError(
      "init принимает один файл проекта, получено: " & positional.join(" "),
      "например: euterpia init demo.eut")
    return
  if positional.len == 1:
    result.options.path = positional[0]
  result.ok = true

proc runInit*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia init [файл] [--tempo BPM] [--sr Гц] [--ts 4/4] [--name И]
  ## [--author А] [--force]`. Создаёт проект с метаданными и ПУСТЫМ графом:
  ## ноды добавляет `node add` (#90), и CLI не выдумывает за пользователя
  ## содержимое проекта.
  let parsed = parseInit(args)
  if not parsed.ok:
    return parsed.rep
  let options = parsed.options

  if fileExists(options.path) and not options.force:
    # Существующий проект не затирается молча: потерять работу из-за
    # опечатки в имени файла — слишком дорогая ошибка.
    return usageError("файл уже существует: " & options.path,
                      "перезапись: euterpia init " & options.path & " --force")

  let stamp = nowStamp()
  var proj: ProjectFormat
  proj.format = ProjectFormatName
  proj.version = ProjectFormatVersion
  proj.metadata = ProjectMetadata(
    name: (if options.nameGiven: options.name else: defaultName(options.path)),
    author: options.author,
    sampleRate: options.sampleRate,
    tempo: options.tempo,
    timeSignature: TimeSignatureFormat(
      numerator: options.tsNumerator, denominator: options.tsDenominator),
    created: stamp,
    modified: stamp)

  let body = projectBody(proj, options.path)
  var lines: seq[string] = @[
    "проект: " & options.path,
    "формат: " & ProjectFormatName & " v" & $ProjectFormatVersion,
  ]
  lines.add metadataLines(proj)
  lines.add "граф: пустой (ноды добавляет `euterpia node add` — #90)"

  if ctx.dryRun:
    lines.add "не записан: " & options.path & " (--dry-run)"
    return okReport(body = body, lines = lines)

  let saved = writeAtomic(options.path, proj)
  if not saved.success:
    return saveError(saved, options.path)
  lines.add "записан: " & options.path
  okReport(body = body, lines = lines)

# =============================================================================
# Общие помощники команд project
# =============================================================================

proc singleFileArg(args: seq[string]; what: string):
    tuple[ok: bool; path: string; rep: Report] =
  ## `show` и `validate` принимают файл или ничего (тогда — умолчание).
  ## Больше одного файла — ошибка данных: молча взять первый значило бы
  ## угадывать за пользователя.
  if args.len > 1:
    return (false, "",
      usageError(what & " принимает не больше одного файла, получено: " &
                 args.join(" "),
                 "например: euterpia " & what & " " & DefaultProjectFile))
  (true, (if args.len == 1: args[0] else: DefaultProjectFile), okReport())

proc paramLines(parameters: Table[string, float32]): seq[string] =
  ## Параметры ноды печатаются по алфавиту: порядок `Table` — деталь
  ## реализации хеш-таблицы, а вывод CLI обязан быть детерминированным (#88).
  var pairs: seq[(string, float32)] = @[]
  for key, value in parameters:
    pairs.add (key, value)
  pairs.sort(proc(a, b: (string, float32)): int = cmp(a[0], b[0]))
  for pair in pairs:
    result.add "      " & pair[0] & " = " & $pair[1]

proc trackFlags(track: TrackFormat): string =
  var flags: seq[string] = @[]
  if track.mute: flags.add "mute"
  if track.solo: flags.add "solo"
  if track.armed: flags.add "armed"
  if flags.len == 0: "-" else: flags.join("+")

proc joinInts[T](values: seq[T]): string =
  ## «1, 2, 3» — для списков id в тексте проверок.
  for value in values:
    if result.len > 0: result.add ", "
    result.add $value

# =============================================================================
# project show
# =============================================================================

proc runProjectShow*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia project show [файл]`. Печатает метаданные, граф, секвенсор и
  ## состояния плагинов: ровно то, что лежит в формате (#57), и ничего из
  ## runtime-состояния — проект читается без движка.
  discard ctx
  let target = singleFileArg(args, "project show")
  if not target.ok: return target.rep
  let loaded = loadAt(target.path)
  if not loaded.ok: return loaded.rep
  let proj = loaded.proj

  var lines: seq[string] = @[
    "проект: " & target.path,
    "формат: " & proj.format & " v" & $proj.version,
    "",
    "Метаданные:",
  ]
  for line in metadataLines(proj):
    lines.add "  " & line

  lines.add ""
  lines.add "Граф: нод " & $proj.graph.nodes.len & ", связей " &
            $proj.graph.connections.len
  for node in proj.graph.nodes:
    lines.add "  [" & $node.id & "] " & node.nodeType & " «" &
              display(node.name) & "» — audio " & $node.audioInCount & "/" &
              $node.audioOutCount & ", ctrl " & $node.ctrlInCount & "/" &
              $node.ctrlOutCount &
              (if node.isSubgraph: ", субграф" else: "")
    lines.add paramLines(node.parameters)
  for conn in proj.graph.connections:
    lines.add "  " & $conn.srcNodeId & ":" & $conn.srcPortIdx & " → " &
              $conn.dstNodeId & ":" & $conn.dstPortIdx &
              " (sig " & $conn.sigType & ")"

  var clips = 0
  var notes = 0
  for track in proj.sequencer.tracks:
    clips += track.clips.len
    for clip in track.clips:
      notes += clip.notes.len

  lines.add ""
  lines.add "Секвенсор: треков " & $proj.sequencer.tracks.len & ", клипов " &
            $clips & ", нот " & $notes
  if proj.sequencer.tracks.len == 0:
    lines.add "  (пусто)"
  for track in proj.sequencer.tracks:
    lines.add "  [" & $track.id & "] «" & display(track.name) & "» — клипов " &
              $track.clips.len & ", vol " & $track.volume & ", pan " &
              $track.pan & ", " & trackFlags(track)
    for clip in track.clips:
      lines.add "      клип [" & $clip.id & "] «" & display(clip.name) &
                "»: тик " & $clip.startTick & ", длина " & $clip.lengthTicks &
                ", нот " & $clip.notes.len &
                (if clip.loopEnabled: ", loop" else: "")

  lines.add ""
  lines.add "Автоматизация: дорожек " &
            $proj.sequencer.automationLanes.len
  for lane in proj.sequencer.automationLanes:
    lines.add "  узел " & $lane.nodeId & ", параметр " & $lane.paramId &
              ", точек " & $lane.points.len

  lines.add ""
  lines.add "Состояния плагинов: " & $proj.pluginStates.len
  for state in proj.pluginStates:
    lines.add "  узел " & $state.nodeId & ": " & display(state.pluginId) &
              " (" & $state.state.len & " байт)"

  okReport(body = projectBody(proj, target.path), lines = lines)

# =============================================================================
# project set
# =============================================================================

proc runProjectSet*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia project set [файл] <поле> <значение>`.
  ##
  ## Файл можно не указывать (тогда `project.eut`) — так пример из MANIFEST
  ## §19 (`euterpia project set tempo 140`) работает как написан. Число
  ## аргументов различает формы однозначно: 2 — поле и значение, 3 — файл,
  ## поле и значение.
  ##
  ## Diff (`было → стало`) печатается и в человеческом выводе, и в `--json`:
  ## агенту он нужен, чтобы подтвердить, что изменилось ровно то, что просили.
  var path = DefaultProjectFile
  var field = ""
  var value = ""
  case args.len
  of 2:
    field = args[0]
    value = args[1]
  of 3:
    path = args[0]
    field = args[1]
    value = args[2]
  else:
    return usageError(
      "project set принимает [файл] <поле> <значение>, получено аргументов: " &
        $args.len,
      "например: euterpia project set " & DefaultProjectFile & " tempo 140")

  if field notin ProjectFields:
    return usageError("неизвестное поле проекта: " & field,
                      "поля: " & ProjectFields.join(", "))

  let loaded = loadAt(path)
  if not loaded.ok: return loaded.rep
  var proj = loaded.proj

  let before = readField(proj, field)
  let applied = setField(proj, field, value)
  if not applied.ok:
    return usageError(applied.message, "поля: " & ProjectFields.join(", "))
  let after = readField(proj, field)

  if before == after:
    # Значение уже такое: файл НЕ трогаем. Иначе идемпотентный `set`
    # переписывал бы проект и поднимал `metadata.modified` на ровном месте.
    var body = projectBody(proj, path)
    body["change"] = %*{"field": field, "before": before, "after": after,
                        "applied": false}
    return okReport(body = body,
                    lines = @[path & ": без изменений", field & ": " & after])

  # Отметка изменения ставится ДО сборки машинного ответа: `--json` обязан
  # показывать то состояние, которое записывается, а не прежнее.
  proj.metadata.modified = nowStamp()

  var body = projectBody(proj, path)
  body["change"] = %*{"field": field, "before": before, "after": after,
                      "applied": true}

  var lines: seq[string] = @[
    "изменено: " & path,
    field & ": " & before & " → " & after,
    "изменён: " & proj.metadata.modified,
  ]

  if ctx.dryRun:
    lines.add "не записан: " & path & " (--dry-run)"
    return okReport(body = body, lines = lines)

  let saved = writeAtomic(path, proj)
  if not saved.success:
    return saveError(saved, path)
  lines.add "записан: " & path
  okReport(body = body, lines = lines)

# =============================================================================
# project validate
# =============================================================================

proc validateFile(path: string): Section =
  ## Секция «file»: файл существует и разобран Core. Размер — факт, по
  ## которому видно, что читали именно тот файл.
  var lines: seq[string] = @["путь: " & path]
  var body = newJObject()
  body["path"] = %path
  if fileExists(path):
    let size = getFileSize(path)
    lines.add "размер: " & $size & " байт"
    body["bytes"] = %size
  result.id = "file"
  result.title = "file: файл проекта"
  result.checks.add mkCheck("read", "файл прочитан и разобран", csOk,
    lines = lines, body = body)

proc validateFormat(proj: ProjectFormat): Section =
  ## Секция «format»: формат и версию проверило ядро при чтении — здесь они
  ## только показываются. Дублировать проверку формата в CLI нечего (§20).
  result.id = "format"
  result.title = "format: формат и версия"
  result.checks.add mkCheck("format", "формат и версия поддерживаются", csOk,
    lines = @[
      "format = " & proj.format,
      "version = " & $proj.version & " (поддерживает эта сборка: " &
        $ProjectFormatVersion & ")",
      "проверено ядром при чтении (core/project.nim)",
    ],
    body = %*{"format": proj.format, "version": proj.version,
              "supported": ProjectFormatVersion})

proc validateMetadata(proj: ProjectFormat): Section =
  ## Секция «metadata». Две проверки с разной строгостью:
  ## - описательные поля (имя, автор, даты): пусто — предупреждение, потому
  ##   что проект без автора остаётся рабочим;
  ## - транспортные значения: темп 0 обнуляет `samplesPerQuarter` в ядре, а
  ##   размер с нулевым знаменателем — `beatsPerBar`, то есть это ПРОВАЛ.
  result.id = "metadata"
  result.title = "metadata: метаданные"
  let meta = proj.metadata

  var empty: seq[string] = @[]
  if meta.name.len == 0: empty.add "name"
  if meta.author.len == 0: empty.add "author"
  if meta.created.len == 0: empty.add "created"
  if meta.modified.len == 0: empty.add "modified"
  var emptyJson = newJArray()
  for name in empty:
    emptyJson.add %name

  result.checks.add mkCheck("fields", "описательные поля заполнены",
    (if empty.len == 0: csOk else: csWarn),
    lines = metadataLines(proj),
    advice = (if empty.len == 0: ""
              else: "не заполнено: " & empty.join(", ") &
                     " (`euterpia init` заполняет их при создании)"),
    body = %*{"empty": emptyJson})

  var problems: seq[string] = @[]
  if not (meta.tempo > 0.0): problems.add "tempo должен быть > 0"
  if not (meta.sampleRate > 0.0): problems.add "sampleRate должен быть > 0"
  if meta.timeSignature.numerator < 1:
    problems.add "числитель размера должен быть ≥ 1"
  let denominator = int(meta.timeSignature.denominator)
  if denominator < 1 or (denominator and (denominator - 1)) != 0:
    problems.add "знаменатель размера должен быть степенью двойки"
  var transportLines = @[
    "темп: " & $meta.tempo & " BPM",
    "частота дискретизации: " & $meta.sampleRate & " Гц",
    "размер: " & $meta.timeSignature.numerator & "/" &
      $meta.timeSignature.denominator,
  ]
  for problem in problems:
    transportLines.add "проблема: " & problem
  result.checks.add mkCheck("transport", "транспортные значения корректны",
    (if problems.len == 0: csOk else: csFail),
    lines = transportLines,
    advice = (if problems.len == 0: ""
              else: "исправьте значение: euterpia project set <файл> " &
                     "tempo|sample-rate|time-signature <значение>"),
    body = %*{"tempo": meta.tempo, "sampleRate": meta.sampleRate,
              "numerator": meta.timeSignature.numerator,
              "denominator": meta.timeSignature.denominator,
              "problems": %problems})

proc nodeIndex(nodes: seq[NodeFormat]; id: int): int =
  ## Индекс ноды по id или -1. Свой поиск, а не `Table`: формат хранит
  ## ноды списком, и порядок в файле — часть данных (граф компилируется
  ## в этом порядке), поэтому превращать список в таблицу здесь незачем.
  for i in 0 ..< nodes.len:
    if nodes[i].id == id:
      return i
  -1

proc validateGraph(proj: ProjectFormat): Section =
  ## Секция «graph». Провал — только однозначная несогласованность: повтор
  ## id или связь с несуществующей нодой. Диапазон портов и самосоединение —
  ## предупреждение: счётчики портов есть не во всех файлах (формат
  ## дополнялся), а обратная связь допустима для ноды с явной задержкой.
  result.id = "graph"
  result.title = "graph: ноды и связи"

  var seen: seq[int] = @[]
  var duplicates: seq[int] = @[]
  for node in proj.graph.nodes:
    if node.id in seen and node.id notin duplicates:
      duplicates.add node.id
    seen.add node.id
  var duplicateLines: seq[string] = @["нод: " & $proj.graph.nodes.len]
  if duplicates.len > 0:
    duplicateLines.add "повторяются id: " & joinInts(duplicates)
  result.checks.add mkCheck("node-ids", "идентификаторы нод уникальны",
    (if duplicates.len == 0: csOk else: csFail),
    lines = duplicateLines,
    advice = (if duplicates.len == 0: ""
              else: "повтор id делает выбор ноды неоднозначным"),
    body = %*{"nodes": proj.graph.nodes.len, "duplicates": %duplicates})

  var dangling: seq[string] = @[]
  var outOfRange: seq[string] = @[]
  var selfLoops: seq[string] = @[]
  for conn in proj.graph.connections:
    let src = nodeIndex(proj.graph.nodes, conn.srcNodeId)
    let dst = nodeIndex(proj.graph.nodes, conn.dstNodeId)
    if src < 0 or dst < 0:
      dangling.add $conn.srcNodeId & "→" & $conn.dstNodeId
      continue
    let srcNode = proj.graph.nodes[src]
    let dstNode = proj.graph.nodes[dst]
    if conn.srcPortIdx < 0 or
       conn.srcPortIdx >= srcNode.audioOutCount + srcNode.ctrlOutCount +
                          srcNode.eventOutCount:
      outOfRange.add $conn.srcNodeId & ":" & $conn.srcPortIdx
    if conn.dstPortIdx < 0 or
       conn.dstPortIdx >= dstNode.audioInCount + dstNode.ctrlInCount +
                          dstNode.eventInCount:
      outOfRange.add $conn.dstNodeId & ":" & $conn.dstPortIdx
    if src == dst and conn.srcPortIdx == conn.dstPortIdx:
      selfLoops.add $conn.srcNodeId & ":" & $conn.srcPortIdx

  var connLines: seq[string] = @["связей: " & $proj.graph.connections.len]
  for item in dangling:
    connLines.add "нет такой ноды: " & item
  for item in outOfRange:
    connLines.add "порт вне диапазона: " & item
  for item in selfLoops:
    connLines.add "самосоединение: " & item
  result.checks.add mkCheck("connections",
    "связи ссылаются на существующие ноды и порты",
    (if dangling.len > 0: csFail
     elif outOfRange.len > 0 or selfLoops.len > 0: csWarn
     else: csOk),
    lines = connLines,
    advice = (if dangling.len > 0:
                "связь с несуществующей нодой не скомпилируется: проверьте граф (#90)"
              elif outOfRange.len > 0 or selfLoops.len > 0:
                "проверьте порты: в старых файлах счётчиков портов могло не быть"
              else: ""),
    body = %*{"connections": proj.graph.connections.len,
              "dangling": %dangling, "outOfRange": %outOfRange,
              "selfLoops": %selfLoops})

proc validateSequencer(proj: ProjectFormat): Section =
  ## Секция «sequencer»: треки, клипы, ноты, автоматизация. Проверяются
  ## значения, которые ломают проигрывание: отрицательные тики, нулевая
  ## длина, pitch за пределами MIDI. Нота, вылезающая за клип, — только
  ## предупреждение: она прозвучит, но короче, чем записана.
  result.id = "sequencer"
  result.title = "sequencer: треки, клипы, автоматизация"

  var trackIds: seq[int32] = @[]
  var duplicateTracks: seq[int32] = @[]
  for track in proj.sequencer.tracks:
    if track.id in trackIds and track.id notin duplicateTracks:
      duplicateTracks.add track.id
    trackIds.add track.id
  var duplicateJson = newJArray()
  for id in duplicateTracks:
    duplicateJson.add %int(id)
  var trackLines: seq[string] = @["треков: " & $proj.sequencer.tracks.len]
  if duplicateTracks.len > 0:
    trackLines.add "повторяются id: " & joinInts(duplicateTracks)
  result.checks.add mkCheck("track-ids", "идентификаторы треков уникальны",
    (if duplicateTracks.len == 0: csOk else: csWarn),
    lines = trackLines,
    advice = (if duplicateTracks.len == 0: ""
              else: "повтор id делает выбор трека неоднозначным"),
    body = %*{"tracks": proj.sequencer.tracks.len,
              "duplicates": duplicateJson})

  var problems: seq[string] = @[]
  var clips = 0
  var notes = 0
  var outsideClip = 0
  for track in proj.sequencer.tracks:
    for clip in track.clips:
      inc clips
      if clip.startTick < 0:
        problems.add "клип " & $clip.id & " трека " & $track.id &
                     ": startTick < 0"
      if clip.lengthTicks <= 0:
        problems.add "клип " & $clip.id & " трека " & $track.id &
                     ": lengthTicks ≤ 0"
      for note in clip.notes:
        inc notes
        if int(note.pitch) > 127:
          problems.add "клип " & $clip.id & ": pitch " & $note.pitch & " > 127"
        if note.duration <= 0:
          problems.add "клип " & $clip.id & ": duration ≤ 0"
        if note.startTick < 0:
          problems.add "клип " & $clip.id & ": startTick < 0"
        if clip.lengthTicks > 0 and
           int(note.startTick) + int(note.duration) > int(clip.lengthTicks):
          inc outsideClip
  var clipLines: seq[string] = @["клипов: " & $clips, "нот: " & $notes]
  for problem in problems:
    clipLines.add "проблема: " & problem
  if outsideClip > 0:
    clipLines.add "нот за границей клипа: " & $outsideClip
  result.checks.add mkCheck("clips", "клипы и ноты корректны",
    (if problems.len == 0: csOk else: csFail),
    lines = clipLines,
    advice = (if problems.len == 0: ""
              else: "исправьте значения клипов: их задаёт импорт или редактор (#111)"),
    body = %*{"clips": clips, "notes": notes, "outsideClip": outsideClip,
              "problems": %problems})

  var points = 0
  var negativeTicks = 0
  var unknownLanes: seq[int32] = @[]
  for lane in proj.sequencer.automationLanes:
    for point in lane.points:
      inc points
      if point.tick < 0: inc negativeTicks
    if nodeIndex(proj.graph.nodes, int(lane.nodeId)) < 0 and
       lane.nodeId notin unknownLanes:
      unknownLanes.add lane.nodeId
  var unknownLanesJson = newJArray()
  for id in unknownLanes:
    unknownLanesJson.add %int(id)
  var autoLines: seq[string] = @[
    "дорожек: " & $proj.sequencer.automationLanes.len,
    "точек: " & $points,
  ]
  for id in unknownLanes:
    autoLines.add "параметры ноды " & $id & ", которой нет в графе"
  if negativeTicks > 0:
    autoLines.add "точек с отрицательным тиком: " & $negativeTicks
  result.checks.add mkCheck("automation", "дорожки автоматизации согласованы",
    (if unknownLanes.len > 0 or negativeTicks > 0: csWarn else: csOk),
    lines = autoLines,
    advice = (if unknownLanes.len > 0 or negativeTicks > 0:
                "такая дорожка не проиграется: ноды нет или тик вне таймлайна"
              else: ""),
    body = %*{"automationLanes": proj.sequencer.automationLanes.len,
              "points": points, "negativeTicks": negativeTicks,
              "unknownNodes": unknownLanesJson})

proc validatePlugins(proj: ProjectFormat): Section =
  ## Секция «plugins». Состояние — непрозрачные байты (Core не знает форматов
  ## плагинов, §29/§40), поэтому проверяется только связь с нодой и наличие
  ## данных. Два состояния одной ноды — провал: непонятно, какое
  ## восстанавливать.
  result.id = "plugins"
  result.title = "plugins: состояния плагинов"

  var seen: seq[int] = @[]
  var duplicates: seq[int] = @[]
  var unknown: seq[int] = @[]
  var empty = 0
  for state in proj.pluginStates:
    if state.nodeId in seen and state.nodeId notin duplicates:
      duplicates.add state.nodeId
    seen.add state.nodeId
    if nodeIndex(proj.graph.nodes, state.nodeId) < 0 and
       state.nodeId notin unknown:
      unknown.add state.nodeId
    if state.state.len == 0: inc empty

  var refLines: seq[string] = @["состояний: " & $proj.pluginStates.len]
  for id in duplicates:
    refLines.add "два состояния для ноды " & $id
  for id in unknown:
    refLines.add "нода " & $id & " не найдена в графе"
  result.checks.add mkCheck("node-refs", "состояния привязаны к нодам графа",
    (if duplicates.len > 0: csFail
     elif unknown.len > 0: csWarn else: csOk),
    lines = refLines,
    advice = (if duplicates.len > 0:
                "у ноды не может быть двух состояний: какое восстанавливать — неоднозначно"
              elif unknown.len > 0:
                "нода удалена или лежит в субграфе: состояние всё равно сохранится"
              else: ""),
    body = %*{"pluginStates": proj.pluginStates.len,
              "duplicates": %duplicates, "unknownNodes": %unknown})

  result.checks.add mkCheck("payload", "состояния не пусты",
    (if empty > 0: csWarn else: csOk),
    lines = @["пустых состояний: " & $empty],
    advice = (if empty > 0:
                "пустое состояние означает возврат плагина к умолчаниям (#95)"
              else: ""),
    body = %*{"empty": empty})

# =============================================================================
# project validate: команда
# =============================================================================

proc renderValidate(
  sections: seq[Section]; path: string; verbose: bool
): seq[string] =
  ## Заголовок принадлежит команде, вид секций — общий (`checks`): отчёт
  ## `project validate` и отчёт `doctor` читаются одинаково (#96).
  result.add CliName & " project validate — проверка проекта"
  result.add "файл: " & path
  result.add ""
  result.add renderHuman(sections, verbose)
  let total = counts(sections)
  result.add ""
  result.add "Итог: " & $total.ok & " ok, " & $total.warn & " warn, " &
             $total.fail & " fail"

proc validateBody(path: string; sections: seq[Section]): JsonNode =
  ## Машинный отчёт. Схема та же, что у `doctor` (#96): `sections` +
  ## `summary`, поэтому агент читает обе команды одним кодом.
  var sectionsJson = newJArray()
  for section in sections:
    sectionsJson.add sectionJson(section)
  result = newJObject()
  result["path"] = %path
  result["sections"] = sectionsJson
  result["summary"] = summaryJson(sections)

proc runProjectValidate*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia project validate [файл]`. Проверяет то, что видно из формата
  ## (§58): формат/версию, метаданные, ссылки в графе, тики и ноты, состояния
  ## плагинов. Аудиоустройство не открывается, плагин в процесс CLI не
  ## загружается (#89): это не `plugin validate` (#260) и не `doctor` (#105).
  ##
  ## Код возврата: 0 — только ok/warn, 1 — есть провалы или файл не разобран,
  ## 2 — файл не читается (среда).
  let target = singleFileArg(args, "project validate")
  if not target.ok: return target.rep
  let loaded = loadAt(target.path)

  if not loaded.ok:
    # Файл не разобран: отчёт из одной проваленной проверки, но вид ответа
    # тот же, что при успешном чтении — агенту не нужен второй разбор.
    let section = Section(
      id: "file",
      title: "file: файл проекта",
      checks: @[mkCheck("read", "файл прочитан и разобран", csFail,
        lines = @["путь: " & target.path, "ошибка: " & loaded.rep.error],
        advice = validateHint(loaded.kind, target.path))])
    let broken = @[section]
    return errReport(loaded.code, kindName(loaded.code), loaded.rep.error,
      hint = loaded.rep.hint,
      lines = renderValidate(broken, target.path, ctx.verbose),
      body = validateBody(target.path, broken))

  let proj = loaded.proj
  let sections = @[
    validateFile(target.path),
    validateFormat(proj),
    validateMetadata(proj),
    validateGraph(proj),
    validateSequencer(proj),
    validatePlugins(proj),
  ]
  let total = counts(sections)
  let lines = renderValidate(sections, target.path, ctx.verbose)
  let body = validateBody(target.path, sections)

  if total.fail > 0:
    return errReport(exUsage, "usage",
      "проект невалиден: провалено проверок " & $total.fail,
      hint = "подробности: euterpia project validate " & target.path & " --json",
      lines = lines, body = body)
  okReport(body = body, lines = lines)

# =============================================================================
# project
# =============================================================================

proc runProject*(ctx: var Ctx; args: seq[string]): Report =
  ## Диспетчер `project <show|set|validate> [файл] ...`. Форма без файла —
  ## не магия, а задокументированное умолчание (`project.eut`): пример из
  ## MANIFEST §19 (`euterpia project set tempo 140`) работает как написан.
  if args.len == 0:
    return usageError("project требует подкоманду",
                      "подкоманды: " & ProjectSubcommands.join(", "))
  case args[0]
  of "show": runProjectShow(ctx, argsTail(args))
  of "set": runProjectSet(ctx, argsTail(args))
  of "validate": runProjectValidate(ctx, argsTail(args))
  else:
    usageError("неизвестная подкоманда project: " & args[0],
               "подкоманды: " & ProjectSubcommands.join(", "))
