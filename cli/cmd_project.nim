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
import handles
import context
import checks
import cli_spec
import stamp
import control/query
import control/document
import control/commands
import control/history
import control/error_frame
import control_bridge
import history_file

# Формат отметки и часы живут в `cli/stamp.nim` (там же объяснение, почему не
# здесь): команды получают их через этот модуль — он их и создаёт.
export stamp

const
  ProjectExt* = ".eproj"
    ## Основное расширение файла проекта.
    ##
    ## Расширение — **подпись файла, а не часть формата**: тип файла ядро
    ## определяет по содержимому (`ProjectFormatName` внутри JSON), поэтому
    ## переименование проекта (`demo.eut` → `demo.eproj`) ничего не ломает и
    ## миграции не требует (§58/§59).
  LegacyProjectExt* = ".eut"
    ## Историческое расширение проекта (из примера MANIFEST §19 прежних
    ## редакций). Принимается наравне с `ProjectExt`: существующие проекты,
    ## скрипты и примеры не должны перестать работать (§59).
    ##
    ## Это НЕ имя формата плагинов EUT и не имя внутреннего ABI ядер (§104):
    ## «EUT» там означает другое, и с расширением файла проекта не связано.
  ProjectSuffixes* = @[ProjectExt, LegacyProjectExt]
    ## Признак «позиционный аргумент — путь к проекту». Один список на все
    ## команды (граф, render, редактор): иначе правило «какой аргумент файл»
    ## разъедется по файлам, и команды начнут понимать разные наборы.
  DefaultProjectFile* = "project" & ProjectExt
    ## Проект по умолчанию: MANIFEST §19 показывает `euterpia init` и
    ## `euterpia project show` без аргументов. Один источник для всех команд.

  ProjectFields* = @["name", "author", "tempo", "sample-rate", "time-signature"]
    ## Поля, которыми управляет `project set`. Один источник для разбора,
    ## текста ошибки и справки — подсказка не может разойтись с кодом.

  ProjectSubcommands* = @["show", "set", "validate"]
    ## Подкоманды `project`: кандидаты автодополнения второго уровня (#259).

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

proc isProjectPath*(path: string): bool =
  ## Признак «путь похож на файл проекта»: основное расширение (`ProjectExt`)
  ## или историческое (`LegacyProjectExt`).
  ##
  ## Регистр не важен: `DEMO.EPROJ` и `demo.eproj` — один и тот же файл, и
  ## правило разбора не должно от него зависеть (§82: правило, а не
  ## угадывание). Само содержимое проверяет ядро (`loadProject`): здесь
  ## решается только «этот аргумент — путь, а не имя ноды».
  let lower = path.toLowerAscii()
  for ext in ProjectSuffixes:
    if lower.endsWith(ext):
      return true
  false

proc projectSuffixesHint*(): string =
  ## Одна формула для всех сообщений об ошибке: «*.eproj или *.eut». Копия
  ## строки в каждой команде разошлась бы с `ProjectSuffixes` — подсказка
  ## и разбор обязаны читать один список.
  var parts: seq[string] = @[]
  for ext in ProjectSuffixes:
    parts.add "*" & ext
  parts.join(" или ")

# =============================================================================
# Спецификации команд (#330)
# =============================================================================
#
# Описание живёт данными и стоит ЗДЕСЬ, рядом с разбором аргументов: ключ,
# которого нет в спецификации, не попадёт ни в справку, ни в автодополнение,
# а ключ, объявленный только в справке, не будет принят разбором — расхождение
# видно по `cli_spec.validateSpecs` (тест «CLI: спецификация команд»).

const
  InitSpec* = CommandSpec(
    name: "init",
    summary: "создать проект: метаданные и пустой граф",
    synopsis: "init [файл] [ключи]",
    args: @[
      arg("файл", "проект: " & projectSuffixesHint() &
        "; по умолчанию " & DefaultProjectFile),
    ],
    options: @[
      opt("--name", "имя проекта; без ключа имя берётся из имени файла",
          value = "строка"),
      opt("--author", "автор проекта", value = "строка"),
      opt("--sr", "частота дискретизации проекта", value = "Гц",
          default = $int(DefaultSampleRate), aliases = @["--sample-rate"]),
      opt("--tempo", "темп проекта", value = "число BPM",
          default = $int(DefaultTempo)),
      opt("--ts", "размер такта", value = "числитель/знаменатель",
          default = $DefaultTimeSigNumerator & "/" & $DefaultTimeSigDenominator,
          aliases = @["--time-signature"]),
      switch("--force", "перезаписать существующий файл"),
    ],
    example: "euterpia init demo.eproj --name Demo --tempo 140",
    fields: @[
      field("path", "куда записан проект"),
      field("documentId", "идентификатор документа: адреса одного файла отличимы от другого (#143)"),
      field("format", "имя формата файла — по нему ядро и узнаёт проект (§58)"),
      field("version", "версия формата"),
      field("metadata", "имя, автор, темп, частота дискретизации, размер"),
      field("graph", "ноды и связи (после `init` пустые)"),
      field("sequencer", "треки, клипы и автоматизация"),
      field("pluginStates", "состояния плагинов"),
      field("summary", "счётчики: ноды, связи, треки, клипы"),
    ],
    notes: @[
      "граф создаётся пустым: ноды добавляет `euterpia node add` (#90)",
      "существующий файл не затирается: перезапись требует --force",
      "расширение — подпись файла, а не формат: историческое `.eut` принимается наравне с `" &
        ProjectExt & "`, а тип файла ядро определяет по содержимому (§19/§58)",
    ])

  InitFlags* = InitSpec.optionKeys
    ## Ключи `init` — из спецификации (`InitSpec`), а не отдельным списком:
    ## подсказка об ошибке, справка и автодополнение читают одно описание.

  ProjectSpec* = CommandSpec(
    name: "project",
    summary: "показать, изменить или проверить файл проекта",
    synopsis: "project <show|set|validate>",
    subcommands: ProjectSubcommands,
    args: @[
      arg("файл", "проект: " & projectSuffixesHint() &
        "; по умолчанию " & DefaultProjectFile),
      arg("поле значение", "только `project set`: " & ProjectFields.join(", ")),
    ],
    example: "euterpia project show demo.eproj",
    fields: @[
      field("path", "путь прочитанного проекта"),
      field("documentId", "идентификатор документа (#143)"),
      field("metadata", "имя, автор, темп, частота, размер"),
      field("graph", "ноды и связи"),
      field("sequencer", "треки, клипы и автоматизация"),
      field("pluginStates", "состояния плагинов"),
      field("summary", "счётчики: ноды, связи, треки, клипы"),
      field("change", "что изменил `project set`: поле, до и после"),
      field("sections", "результат `project validate`: секции и проверки"),
    ],
    notes: @[
      "project show [файл] — метаданные, граф, треки/клипы, автоматизация, состояния плагинов",
      "project set [файл] <поле> <значение> — поля: " & ProjectFields.join(", "),
      "project set пишет атомарно (tmp + rename) и обновляет metadata.modified",
      "project validate [файл] — отчёт о формате и целостности: провал проверки даёт код 1",
      "без файла команды работают с `" & DefaultProjectFile &
        "` — как в примере MANIFEST §19",
    ])

type
  LoadedProject* = object
    ok*: bool
    proj*: ProjectFormat
    rep*: Report
      ## Готовый отчёт об ошибке чтения — печатается как есть, чтобы
      ## команда не переизобретала текст для каждого вида сбоя.
    code*: ExitCode
      ## Код возврата для этого сбоя. Нужен `validate`: он печатает отчёт
      ## в общем виде, но статус процесса обязан остаться «данные» (1) или
      ## «среда» (2), а не превратиться в «провал проверок» (тоже 1) для
      ## недоступного файла.
    kind*: ProjectErrorKind
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

proc errorCodeFor*(kind: ProjectErrorKind): ErrorCode =
  ## Вид ошибки формата → ПРИЧИНА control-слоя (#332). Код возврата даёт
  ## таблица (`cli/exit_codes.nim`), а не этот `case`.
  ##
  ## Классы прежние (проверены CLI-тестами): «файла нет» и битый файл — это
  ## ДАННЫЕ (код 1) — пользователь указал путь, а файла там нет или он не наш;
  ## «нет прав» — СРЕДА (код 2): файл верный, но недоступен.
  case kind
  of pekNone: ecOk
  of pekFileNotFound: ecNotFound
  of pekIOError: ecEnvironment
  of pekJsonParseError, pekInvalidFormat,
     pekUnsupportedVersion, pekMissingField: ecInvalidArgument
  of pekUnknownError: ecInternal

proc codeFor*(kind: ProjectErrorKind): ExitCode =
  ## Код возврата по виду ошибки формата: таблица причин (#332).
  exitCodeFor(errorCodeFor(kind))

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
  let ec = errorCodeFor(kind)
  case exitCodeFor(ec)
  of exOk: okReport()
  of exUsage: usageError(message, hint, ec)
  of exEnv: envError(message, hint, ec)
  of exPanic: panicError(message, hint)

proc loadAt*(path: string): LoadedProject =
  let loaded = loadProject(path)
  if not loaded.success:
    let code = codeFor(loaded.error.kind)
    let ec = errorCodeFor(loaded.error.kind)
    return LoadedProject(
      ok: false,
      code: code,
      kind: loaded.error.kind,
      rep: errReport(code, kindName(code), loaded.error.message,
                     hint = loadHint(loaded.error.kind, path),
                     errorCode = frameCodeValue(ec)))
  LoadedProject(ok: true, proj: loaded.value)

proc saveError*(saved: ProjectResult[void]; path: string): Report =
  ## Ошибку записи формирует ядро (`pekIOError`), CLI добавляет путь и код.
  projectError(saved.error.kind, saved.error.message, path,
               "проверьте каталог и права: " & path)

# =============================================================================
# Метаданные и машинный вид проекта
# =============================================================================

proc defaultName*(path: string): string =
  ## Имя проекта по умолчанию — имя файла без расширения. Это правило
  ## документировано в справке `init`, а не угадывается: `init demo.eproj`
  ## даёт проект «demo», и `project show` сразу показывает осмысленное имя.
  let stem = extractFilename(path).changeFileExt("")
  if stem.len > 0: stem else: "project"

proc display(value: string): string =
  ## Пустое поле печатается словами: «имя: » в выводе неотличимо от сбоя.
  if value.len > 0: value else: "(не задано)"

proc metadataLines*(meta: MetadataInfo): seq[string] =
  ## Метаданные в человекочитаемом виде. Порядок строк фиксирован: вывод
  ## CLI должен быть сравнимым между запусками (#88).
  ##
  ## Вход — DTO Query API, а не документ: строки отчёта и ответ `--json`
  ## берут значения из одного источника (#336).
  result.add "имя: " & display(meta.name)
  result.add "автор: " & display(meta.author)
  result.add "частота дискретизации: " & $meta.sampleRate & " Гц"
  result.add "темп: " & $meta.tempo & " BPM"
  result.add "размер: " & $meta.tsNumerator & "/" & $meta.tsDenominator
  result.add "создан: " & display(meta.created)
  result.add "изменён: " & display(meta.modified)

proc summarize*(summary: ProjectSummary): JsonNode =
  ## Счётчики содержимого: агент читает их, не разворачивая граф и треки.
  ## Считает ядро (`querySummary`) — CLI их только печатает: иначе отчёт и
  ## схема `--json` считались бы двумя разными проходами по модели (#336).
  %*{
    "nodes": summary.nodes,
    "connections": summary.connections,
    "tracks": summary.tracks,
    "clips": summary.clips,
    "notes": summary.notes,
    "automationLanes": summary.automationLanes,
    "automationPoints": summary.automationPoints,
    "pluginStates": summary.pluginStates,
    "pluginStateBytes": summary.pluginStateBytes,
  }

proc projectBody*(doc: Document; path: string): JsonNode =
  ## Машинный вид проекта: `toJson` из Core + путь и счётчики.
  ##
  ## Сериализация НЕ дублируется в CLI: если Core изменит схему файла
  ## (§58/§59), `project show --json` изменится вместе с ней — клиент узнает
  ## об этом по полю `version`, а не по тому, что «CLI забыл поле».
  ##
  ## Счётчики и идентификатор документа приходят из Query API (#336): поля
  ## отчёта не считаются вторым проходом по модели.
  let summary = querySummary(doc)
  result = toJson(doc.proj)
  result["path"] = %path
  # Идентификатор документа: по нему адреса из одного файла отличаются от
  # адресов другого, даже если у них совпадают номера нод (issue #143).
  result["documentId"] = %docIdText(summary.documentId)
  result["summary"] = summarize(summary)

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

proc readField*(meta: MetadataInfo; field: string): string =
  ## Текущее значение поля — для diff при `set`. Читает DTO Query API (#336):
  ## значение поля в отчёте и в `--json` берётся из одного источника.
  case field
  of "name": meta.name
  of "author": meta.author
  of "tempo": $meta.tempo
  of "sample-rate": $meta.sampleRate
  of "time-signature": $meta.tsNumerator & "/" & $meta.tsDenominator
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
                                "например: euterpia init demo.eproj --tempo 140")
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
      "например: euterpia init demo.eproj")
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

  let doc = openDocument(options.path, proj)
  let body = projectBody(doc, options.path)
  var lines: seq[string] = @[
    "проект: " & options.path,
    "формат: " & ProjectFormatName & " v" & $ProjectFormatVersion,
  ]
  lines.add metadataLines(queryMetadata(doc))
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

proc paramLines(params: seq[ParamInfo]): seq[string] =
  ## Параметры ноды печатаются по алфавиту: порядок описателя типа — контракт
  ## для правки, но в отчёте человек ищет имя, а вывод CLI обязан быть
  ## детерминированным (#88).
  var sorted = params
  sorted.sort(proc(a, b: ParamInfo): int = cmp(a.name, b.name))
  for p in sorted:
    result.add "      " & p.name & " = " & $p.value

proc trackFlags(track: TrackInfo): string =
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
  ##
  ## Читает через Query API (#336): CLI не ходит по структурам документа, а
  ## задаёт вопросы и печатает ответы. Потому же `project show` и Editor
  ## показывают одно и то же.
  discard ctx
  let target = singleFileArg(args, "project show")
  if not target.ok: return target.rep
  let loaded = loadAt(target.path)
  if not loaded.ok: return loaded.rep
  let doc = openDocument(target.path, loaded.proj)
  let meta = queryMetadata(doc)
  let found = doc.queryNodes()
  if not found.frame.isOk(): return frameReport(found.frame)
  let connections = doc.queryConnections()
  let tracks = doc.queryTracks()
  let summary = querySummary(doc)

  var lines: seq[string] = @[
    "проект: " & target.path,
    "формат: " & doc.proj.format & " v" & $doc.proj.version,
    "документ: " & docIdText(doc.docId),
    "",
    "Метаданные:",
  ]
  for line in metadataLines(meta):
    lines.add "  " & line

  lines.add ""
  lines.add "Граф: нод " & $summary.nodes & ", связей " & $summary.connections
  for node in found.nodes:
    let link = if node.handle.len > 0: node.handle else: "адрес недоступен"
    lines.add "  [" & $node.id & "] " & node.nodeType & " «" &
              display(node.name) & "» — audio " & $node.audioIn & "/" &
              $node.audioOut & ", ctrl " & $node.ctrlIn & "/" &
              $node.ctrlOut &
              (if node.isSubgraph: ", субграф" else: "") &
              " [" & link & "]"
    lines.add paramLines(node.params)
  for conn in connections:
    lines.add "  " & $conn.srcNodeId & ":" & $conn.srcPortIdx & " → " &
              $conn.dstNodeId & ":" & $conn.dstPortIdx &
              " (sig " & $conn.sigType & ")"

  lines.add ""
  lines.add "Секвенсор: треков " & $summary.tracks & ", клипов " &
            $summary.clips & ", нот " & $summary.notes
  if tracks.len == 0:
    lines.add "  (пусто)"
  for track in tracks:
    lines.add "  [" & $track.id & "] «" & display(track.name) & "» — клипов " &
              $track.clips.len & ", vol " & $track.volume & ", pan " &
              $track.pan & ", " & trackFlags(track) &
              " [" & track.handle & "]"
    for clip in track.clips:
      lines.add "      клип [" & $clip.id & "] «" & display(clip.name) &
                "»: тик " & $clip.startTick & ", длина " & $clip.lengthTicks &
                ", нот " & $clip.notes &
                (if clip.loopEnabled: ", loop" else: "") &
                " [" & clip.handle & "]"

  let lanes = doc.queryAutomationLanes()
  lines.add ""
  lines.add "Автоматизация: дорожек " & $lanes.len
  for lane in lanes:
    lines.add "  узел " & $lane.nodeId & ", параметр " & $lane.paramId &
              ", точек " & $lane.points

  let states = doc.queryPluginStates()
  lines.add ""
  lines.add "Состояния плагинов: " & $states.len
  for state in states:
    lines.add "  узел " & $state.nodeId & ": " & display(state.pluginId) &
              " (" & $state.bytes & " байт)"

  okReport(body = projectBody(doc, target.path), lines = lines)

# =============================================================================
# project set
# =============================================================================

proc runProjectSet*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia project set [файл] <поле> <значение>`.
  ##
  ## Файл можно не указывать (тогда `project.eproj`) — так пример из MANIFEST
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

  # Аргумент превращается в КОМАНДУ (issue #373): запись метаданных и проверки
  # границ делает control-слой, а CLI только переводит текст в типизированное
  # значение. Разбор формата (число? размер N/M?) остаётся за CLI — это разбор
  # аргумента, а не правило модели.
  var cmd: ControlCommand
  case field
  of "name":
    cmd = setProjectInfo(ProjectFieldName, name = value)
  of "author":
    cmd = setProjectInfo(ProjectFieldAuthor, author = value)
  of "tempo":
    let parsed = parseNumber(value, "tempo", MaxTempo)
    if not parsed.ok:
      return usageError(parsed.message, "поля: " & ProjectFields.join(", "))
    cmd = setProjectInfo(ProjectFieldTempo, tempo = float32(parsed.number))
  of "sample-rate":
    let parsed = parseNumber(value, "sample-rate", MaxSampleRate)
    if not parsed.ok:
      return usageError(parsed.message, "поля: " & ProjectFields.join(", "))
    cmd = setProjectInfo(ProjectFieldSampleRate,
                         sampleRate = float32(parsed.number))
  of "time-signature":
    let parsed = parseTimeSignature(value)
    if not parsed.ok:
      return usageError(parsed.message, "поля: " & ProjectFields.join(", "))
    cmd = setProjectInfo(ProjectFieldTimeSignature,
                         tsNum = parsed.numerator, tsDen = parsed.denominator)
  else:
    return usageError("неизвестное поле проекта: " & field,
                      "поля: " & ProjectFields.join(", "))

  let docBefore = openDocument(path, loaded.proj)
  let before = readField(queryMetadata(docBefore), field)

  # Проба на КОПИИ: каким станет поле. Идемпотентность (`set` на то же
  # значение не трогает файл) сохраняется без записи.
  var probe = openDocument(path, loaded.proj)
  discard probe.applyCommand(cmd)
  let after = readField(queryMetadata(probe), field)

  if before == after:
    # Значение уже такое: файл НЕ трогаем. Иначе идемпотентный `set`
    # переписывал бы проект и поднимал `metadata.modified` на ровном месте.
    let doc = openDocument(path, loaded.proj)
    var body = projectBody(doc, path)
    body["change"] = %*{"field": field, "before": before, "after": after,
                        "applied": false}
    return okReport(body = body,
                    lines = @[path & ": без изменений", field & ": " & after])

  # Транзакцией: она же даёт обратные команды для истории (#331), а отметку
  # `metadata.modified` ставит control-слой — не CLI.
  var doc = openDocument(path, loaded.proj)
  let plan = doc.applyTransaction(@[cmd], "project set " & field)
  if not plan.frame.isOk(): return frameReport(plan.frame)

  var body = projectBody(doc, path)
  body["change"] = %*{"field": field, "before": before, "after": after,
                      "applied": true}

  var lines: seq[string] = @[
    "изменено: " & path,
    field & ": " & before & " → " & after,
    "изменён: " & queryMetadata(doc).modified,
  ]

  if ctx.dryRun:
    lines.add "не записан: " & path & " (--dry-run)"
    return okReport(body = body, lines = lines)

  let saved = writeAtomic(path, doc.proj)
  if not saved.success:
    return saveError(saved, path)
  let entry = HistoryEntry(redo: plan.redo, undo: plan.undo,
                           description: plan.description)
  let recorded = recordEntry(path, entry)
  if not recorded.isOk():
    return frameReport(recorded)
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

proc validateMetadata(meta: MetadataInfo): Section =
  ## Секция «metadata». Две проверки с разной строгостью:
  ## - описательные поля (имя, автор, даты): пусто — предупреждение, потому
  ##   что проект без автора остаётся рабочим;
  ## - транспортные значения: темп 0 обнуляет `samplesPerQuarter` в ядре, а
  ##   размер с нулевым знаменателем — `beatsPerBar`, то есть это ПРОВАЛ.
  ##
  ## Вход — DTO Query API (#336): проверка показывает то же, что `project show`,
  ## и не читает документ заново.
  result.id = "metadata"
  result.title = "metadata: метаданные"

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
    lines = metadataLines(meta),
    advice = (if empty.len == 0: ""
              else: "не заполнено: " & empty.join(", ") &
                     " (`euterpia init` заполняет их при создании)"),
    body = %*{"empty": emptyJson})

  var problems: seq[string] = @[]
  if not (meta.tempo > 0.0): problems.add "tempo должен быть > 0"
  if not (meta.sampleRate > 0.0): problems.add "sampleRate должен быть > 0"
  if meta.tsNumerator < 1:
    problems.add "числитель размера должен быть ≥ 1"
  let denominator = int(meta.tsDenominator)
  if denominator < 1 or (denominator and (denominator - 1)) != 0:
    problems.add "знаменатель размера должен быть степенью двойки"
  var transportLines = @[
    "темп: " & $meta.tempo & " BPM",
    "частота дискретизации: " & $meta.sampleRate & " Гц",
    "размер: " & $meta.tsNumerator & "/" & $meta.tsDenominator,
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
              "numerator": meta.tsNumerator,
              "denominator": meta.tsDenominator,
              "problems": %problems})

proc validateGraph(doc: Document): Section =
  ## Секция «graph». Провал — только однозначная несогласованность: повтор
  ## id или связь с несуществующей нодой. Диапазон портов и самосоединение —
  ## предупреждение: счётчики портов есть не во всех файлах (формат
  ## дополнялся), а обратная связь допустима для ноды с явной задержкой.
  ##
  ## Чтение — через Query API (issue #373): валидатор не заходит в `ProjectFormat`.
  result.id = "graph"
  result.title = "graph: ноды и связи"
  let nodes = doc.queryNodes().nodes

  var seen: seq[int] = @[]
  var duplicates: seq[int] = @[]
  var outPorts = initTable[int, int]()
  var inPorts = initTable[int, int]()
  for node in nodes:
    if node.id in seen and node.id notin duplicates:
      duplicates.add node.id
    seen.add node.id
    outPorts[node.id] = node.audioOut + node.ctrlOut + node.eventOut
    inPorts[node.id] = node.audioIn + node.ctrlIn + node.eventIn

  var duplicateLines: seq[string] = @["нод: " & $nodes.len]
  if duplicates.len > 0:
    duplicateLines.add "повторяются id: " & joinInts(duplicates)
  result.checks.add mkCheck("node-ids", "идентификаторы нод уникальны",
    (if duplicates.len == 0: csOk else: csFail),
    lines = duplicateLines,
    advice = (if duplicates.len == 0: ""
              else: "повтор id делает выбор ноды неоднозначным"),
    body = %*{"nodes": nodes.len, "duplicates": %duplicates})

  let conns = doc.queryConnections()
  var dangling: seq[string] = @[]
  var outOfRange: seq[string] = @[]
  var selfLoops: seq[string] = @[]
  for conn in conns:
    if conn.srcNodeId notin outPorts or conn.dstNodeId notin outPorts:
      dangling.add $conn.srcNodeId & "→" & $conn.dstNodeId
      continue
    if conn.srcPortIdx < 0 or conn.srcPortIdx >= outPorts[conn.srcNodeId]:
      outOfRange.add $conn.srcNodeId & ":" & $conn.srcPortIdx
    if conn.dstPortIdx < 0 or conn.dstPortIdx >= inPorts[conn.dstNodeId]:
      outOfRange.add $conn.dstNodeId & ":" & $conn.dstPortIdx
    if conn.srcNodeId == conn.dstNodeId and conn.srcPortIdx == conn.dstPortIdx:
      selfLoops.add $conn.srcNodeId & ":" & $conn.srcPortIdx

  var connLines: seq[string] = @["связей: " & $conns.len]
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
    body = %*{"connections": conns.len,
              "dangling": %dangling, "outOfRange": %outOfRange,
              "selfLoops": %selfLoops})

proc validateSequencer(doc: Document): Section =
  ## Секция «sequencer»: треки, клипы, ноты, автоматизация (issue #373 —
  ## через Query API). Проверяются значения, которые ломают проигрывание:
  ## отрицательные тики, нулевая длина, pitch за пределами MIDI. Нота за
  ## границей клипа — предупреждение: прозвучит, но короче записанной.
  result.id = "sequencer"
  result.title = "sequencer: треки, клипы, автоматизация"

  let tracks = doc.queryTracks()
  var trackIds: seq[int32] = @[]
  var duplicateTracks: seq[int32] = @[]
  for track in tracks:
    if track.id in trackIds and track.id notin duplicateTracks:
      duplicateTracks.add track.id
    trackIds.add track.id
  var duplicateJson = newJArray()
  for id in duplicateTracks:
    duplicateJson.add %int(id)
  var trackLines: seq[string] = @["треков: " & $tracks.len]
  if duplicateTracks.len > 0:
    trackLines.add "повторяются id: " & joinInts(duplicateTracks)
  result.checks.add mkCheck("track-ids", "идентификаторы треков уникальны",
    (if duplicateTracks.len == 0: csOk else: csWarn),
    lines = trackLines,
    advice = (if duplicateTracks.len == 0: ""
              else: "повтор id делает выбор трека неоднозначным"),
    body = %*{"tracks": tracks.len, "duplicates": duplicateJson})

  var problems: seq[string] = @[]
  var clips = 0
  var notes = 0
  var outsideClip = 0
  for track in tracks:
    for c in 0 ..< track.clips.len:
      let clip = track.clips[c]
      inc clips
      if clip.startTick < 0:
        problems.add "клип " & $clip.id & " трека " & $track.id &
                     ": startTick < 0"
      if clip.lengthTicks <= 0:
        problems.add "клип " & $clip.id & " трека " & $track.id &
                     ": lengthTicks ≤ 0"
      let qn = doc.queryNotes(track.id, c)
      for note in qn.notes:
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

  let lanes = doc.queryAutomationLanes()
  var nodeIds: seq[int] = @[]
  for node in doc.queryNodes().nodes:
    nodeIds.add node.id
  var points = 0
  var negativeTicks = 0
  var unknownLanes: seq[int32] = @[]
  for lane in lanes:
    points += lane.points
    negativeTicks += lane.negativeTicks
    if int(lane.nodeId) notin nodeIds and lane.nodeId notin unknownLanes:
      unknownLanes.add lane.nodeId
  var unknownLanesJson = newJArray()
  for id in unknownLanes:
    unknownLanesJson.add %int(id)
  var autoLines: seq[string] = @[
    "дорожек: " & $lanes.len,
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
    body = %*{"automationLanes": lanes.len,
              "points": points, "negativeTicks": negativeTicks,
              "unknownNodes": unknownLanesJson})

proc validatePlugins(doc: Document): Section =
  ## Секция «plugins» (issue #373 — через Query API). Состояние — непрозрачные
  ## байты (Core не знает форматов плагинов, §29/§40), поэтому проверяется
  ## только связь с нодой и наличие данных. Два состояния одной ноды — провал:
  ## непонятно, какое восстанавливать.
  result.id = "plugins"
  result.title = "plugins: состояния плагинов"

  let states = doc.queryPluginStates()
  var nodeIds: seq[int] = @[]
  for node in doc.queryNodes().nodes:
    nodeIds.add node.id
  var seen: seq[int] = @[]
  var duplicates: seq[int] = @[]
  var unknown: seq[int] = @[]
  var empty = 0
  for state in states:
    if state.nodeId in seen and state.nodeId notin duplicates:
      duplicates.add state.nodeId
    seen.add state.nodeId
    if state.nodeId notin nodeIds and state.nodeId notin unknown:
      unknown.add state.nodeId
    if state.bytes == 0: inc empty

  var refLines: seq[string] = @["состояний: " & $states.len]
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
    body = %*{"pluginStates": states.len,
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
  # Все разделы читают модель через Query API (issue #336, #373): `validate` —
  # проверка целостности ДОКУМЕНТА, но и её предмет отдаётся DTO, а не
  # внутренностями `ProjectFormat`. Исключений в archGuard больше нет.
  let doc = openDocument(target.path, proj)
  let meta = queryMetadata(doc)
  let sections = @[
    validateFile(target.path),
    validateFormat(proj),
    validateMetadata(meta),
    validateGraph(doc),
    validateSequencer(doc),
    validatePlugins(doc),
  ]
  let total = counts(sections)
  let lines = renderValidate(sections, target.path, ctx.verbose)
  let body = validateBody(target.path, sections)

  if total.fail > 0:
    return checkFailedError(
      "проект невалиден: провалено проверок " & $total.fail,
      "подробности: euterpia project validate " & target.path & " --json",
      lines = lines, body = body)
  okReport(body = body, lines = lines)

# =============================================================================
# project
# =============================================================================

proc runProject*(ctx: var Ctx; args: seq[string]): Report =
  ## Диспетчер `project <show|set|validate> [файл] ...`. Форма без файла —
  ## не магия, а задокументированное умолчание (`project.eproj`): пример из
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
