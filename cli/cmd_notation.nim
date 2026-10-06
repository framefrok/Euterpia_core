# cli/cmd_notation.nim
#
# `euterpia notation check|import` — текстовая нотация как интерфейс к
# партитуре (issue #92).
#
# Зачем команда существует:
#   парсер нотации (`core/notation.nim`) умеет превращать текст в тики, но
#   до этой команды проверить запись было нечем — музыкант узнавал об
#   опечатке только на слух. `check` разбирает файл и печатает, что понято,
#   с указанием «строка:колонка» для ошибки; `import` кладёт разобранную
#   партитуру в дорожку проекта, чтобы её можно было отрендерить.
#
# Границы (§20): разбор — Core (`parseNotation`), хранение — Core
# (`project.nim`), запись — атомарная (`cmd_project.writeAtomic`). CLI не
# разбирает текст сам и не знает формата файла проекта; он только решает,
# куда положить результат и что напечатать.
#
# Что `import` делает с дорожкой:
#   * файл нотации задаёт КЛИП ЦЕЛИКОМ — ноты, длину и имя. Это не
#     «дозапись»: повторный импорт той же партитуры даёт тот же проект
#     (идемпотентность важнее, чем возможность дописать ноту кнопкой);
#   * дорожка и клип создаются, если их ещё нет: импорт партитуры не должен
#     требовать ручной подготовки пустого проекта. Индекс дорожки не может
#     перескочить через пустые: дорожки создаются по порядку;
#   * длина клипа округляется вверх до целого такта размера проекта —
#     иначе клипы не совпадают с сеткой и «поехали» бы друг относительно
#     друга при любой правке;
#   * `--start-tick` сдвигает ноты внутри клипа, `--length` задаёт длину
#     явно (сильнее расчётной).
#
# Коды возврата (#88): 0 — успех, 1 — данные (ошибка разбора, плохой
# индекс), 2 — среда (файл не читается/не пишется), 3 — внутренняя ошибка.

import std/[json, os, strutils]

import notation
import project
import sequencer
import context
import cmd_project
import cli_spec

const
  NotationSubcommands* = @["check", "import"]
    ## Подкоманды `notation`: кандидаты автодополнения второго уровня.

  CheckKeys* = @["--start-tick", "--time-sig", "--velocity"]
    ## Ключи `notation check`. Остальные ключи относятся к `import`: у
    ## разбора без записи нет ни дорожки, ни имени клипа.

  DefaultVelocity = 100
    ## Velocity по умолчанию (MIDI): совпадает с умолчанием
    ## `parseNotation`, чтобы `notation check` показывал то, что получит
    ## импорт.
  MaxVelocity = 127
    ## Потолок MIDI velocity.
  MaxTickValue = 1_000_000_000
    ## Потолок тика: ~1.1 млн тактов 4/4. Опечатка в `--start-tick` не
    ## должна превращаться в клип длиной в год.
  MaxNotesPerClipImport = MaxNotesPerClip
    ## Потолок нот в клипе — тот же, что в формате проекта (Core).
  NotationHint* = "нотация: `c4/4 d e f g`, аккорд `(c4 e4 g4)/2`, пауза `r/8`, " &
    "velocity `:V`, такт `|`, комментарий `#`"

  NotationSpec* = CommandSpec(
    name: "notation",
    summary: "текстовая нотация: проверка файла и импорт в проект",
    synopsis: "notation <check|import> <файл.notes> [ключи]",
    subcommands: NotationSubcommands,
    args: @[
      arg("файл.notes", "партитура: ноты, аккорды и паузы текстом"),
    ],
    options: @[
      opt("--file", "проект для `import`; без ключа — " & DefaultProjectFile,
          value = "проект.eproj"),
      opt("--track", "индекс дорожки с нуля; дорожка создаётся при необходимости",
          value = "число", default = "0"),
      opt("--clip", "индекс клипа дорожки с нуля", value = "число"),
      opt("--name", "имя клипа; без ключа — имя файла партитуры", value = "строка"),
      opt("--start-tick", "сдвиг партитуры от начала клипа", value = "тики",
          default = "0"),
      opt("--time-sig", "размер для проверки тактов", value = "числитель/знаменатель"),
      opt("--velocity", "velocity нот без `:V`", value = "1..127",
          default = $DefaultVelocity),
      opt("--length", "длина клипа в тиках; без ключа — по партитуре, вверх до такта",
          value = "тики"),
      opt("--loop", "повтор рисунка клипа внутри его длины", value = "true или false",
          default = "false"),
    ],
    example: "euterpia notation check score.notes",
    fields: @[
      field("path", "проверенная или импортированная партитура"),
      field("notes", "сколько нот разобрано (или импортировано)"),
      field("endTick", "конец партитуры в тиках"),
      field("barTicks", "длина такта в тиках — по ней проверяются неполные такты"),
      field("timeSignature", "размер, по которому шла проверка"),
      field("velocity", "velocity, которым записаны ноты без `:V`"),
      field("warnings", "предупреждения разбора (неполный такт, пустой файл)"),
      field("project", "проект, в который прошёл импорт"),
      field("track", "индекс дорожки"),
      field("trackName", "имя дорожки"),
      field("createdTrack", "дорожка была создана импортом"),
      field("clip", "индекс клипа"),
      field("clipName", "имя клипа"),
      field("createdClip", "клип был создан импортом"),
      field("lengthTicks", "длина клипа"),
      field("loop", "клип зациклен"),
      field("written", "проект записан на диск (при `--dry-run` — false)"),
    ],
    notes: @[
      "notation check — разбор с указанием «строка:колонка»; ошибка разбора даёт код 1",
      "notation import — партитура становится клипом дорожки проекта; дорожка и клип создаются при необходимости",
      "файл задаёт клип целиком: повторный импорт той же партитуры даёт тот же проект",
      "длина клипа округляется вверх до целого такта размера проекта; --length задаёт её явно",
      "проект у `import` задаётся ключом --file: позиционно команда принимает только партитуру",
      "ключи check: " & CheckKeys.join(", "),
      "нотация: " & NotationHint,
    ])

  NotationKeys* = NotationSpec.optionKeys
    ## Ключи `notation` — из спецификации: разбор, справка и автодополнение
    ## читают одно описание (#259, #330).

type
  NotArg = object
    ## Значение ключа: результат, а не исключение. Разбирает и объясняет
    ## одна функция — иначе текст ошибки и проверка диапазона разошлись бы.
    ok: bool
    value: int
    message: string

  TimeSigArg = object
    ## Размер: два числа, поэтому и тип свой, а не переиспользованный
    ## `NotArg` с упаковкой.
    ok: bool
    num, den: int
    message: string

  ScoreRead = object
    ## Результат чтения и разбора файла: отдельный флаг нужен потому, что
    ## `Report(ok: false)` сам по себе не говорит, была ли попытка чтения —
    ## а команда должна различать «файла нет» и «разбор не удался».
    ok: bool
    rep: Report

  NotationScan = object
    ok: bool
    rep: Report
    sub: string
    path: string
    projectPath: string
    track: int
    clip: int
    name: string
    haveName: bool
    startTick: int
    timeSigNum, timeSigDen: int
    velocity: int
    length: int
    haveLength: bool
    loop: bool

# =============================================================================
# Разбор значений
# =============================================================================

proc tickArg(text, key: string; allowZero: bool): NotArg =
  ## Тик из аргумента. Отдельная функция от `intArg` у `render`: здесь у
  ## значения другой смысл (позиция в партитуре), поэтому и текст ошибки
  ## другой — «тик», а не «целое».
  var number: int
  try:
    number = parseInt(text.strip())
  except ValueError:
    return NotArg(ok: false, message: key & ": ожидается целое число тиков, " &
      "получено «" & text & "»")
  if number < 0 or (number == 0 and not allowZero):
    return NotArg(ok: false, message: key & ": " &
      (if allowZero: "тик не может быть отрицательным"
       else: "тик не может быть нулевым или отрицательным"))
  if number > MaxTickValue:
    return NotArg(ok: false, message: key & ": " & $number &
      " тиков превышает потолок " & $MaxTickValue)
  NotArg(ok: true, value: number)

proc intArg(text, key: string; lowInclusive, highInclusive: int): NotArg =
  ## Индекс дорожки/клипа. Границы включительные: 0 — первая дорожка.
  var number: int
  try:
    number = parseInt(text.strip())
  except ValueError:
    return NotArg(ok: false, message: key & ": ожидается целое число, получено «" &
      text & "»")
  if number < lowInclusive or number > highInclusive:
    return NotArg(ok: false, message: key & ": ожидается целое от " &
      $lowInclusive & " до " & $highInclusive & ", получено «" & text & "»")
  NotArg(ok: true, value: number)

proc velocityArg(text, key: string): NotArg =
  ## Velocity в единицах MIDI. Ноль отвергается: нота с нулевой силой —
  ## это выключение, а не нота, и в партитуре такую запись читают как ошибку.
  var number: int
  try:
    number = parseInt(text.strip())
  except ValueError:
    return NotArg(ok: false, message: key & ": ожидается целое 1…" &
      $MaxVelocity & ", получено «" & text & "»")
  if number < 1 or number > MaxVelocity:
    return NotArg(ok: false, message: key & ": velocity " & $number &
      " вне диапазона 1…" & $MaxVelocity)
  NotArg(ok: true, value: number)

proc timeSigArg(text, key: string): TimeSigArg =
  ## Размер «N/D». Отдельный тип: размер — это два числа, и упаковывать их
  ## в одно поле значило бы прятать распаковку от читателя. Проверяются обе
  ## границы: нулевой знаменатель сломал бы счёт тактов, а размер «1/1» —
  ## это уже не музыка, а опечатка.
  let parts = text.split('/')
  if parts.len != 2:
    return TimeSigArg(ok: false, message: key & ": ожидается размер вида 4/4, " &
      "получено «" & text & "»")
  var num, den: int
  try:
    num = parseInt(parts[0].strip())
    den = parseInt(parts[1].strip())
  except ValueError:
    return TimeSigArg(ok: false, message: key & ": числитель и знаменатель " &
      "должны быть целыми, получено «" & text & "»")
  if num < 1 or num > 32 or den < 1 or den > 32:
    return TimeSigArg(ok: false, message: key & ": обе части размера — от 1 до 32, " &
      "получено «" & text & "»")
  TimeSigArg(ok: true, num: num, den: den)



# =============================================================================
# Разбор аргументов
# =============================================================================

proc scanArgs(args: seq[string]): NotationScan =
  ## Подкоманда, затем один позиционный файл партитуры, затем ключи.
  ##
  ## Ключи проверяются по подкоманде, а не «применяются молча»: `--track`
  ## у `check` не имеет смысла, и проглотить его значило бы сделать вид,
  ## что он что-то изменил (§82).
  result.ok = false
  result.sub = ""
  result.projectPath = DefaultProjectFile
  result.track = 0
  result.clip = 0
  result.startTick = 0
  result.velocity = DefaultVelocity
  result.timeSigNum = 4
  result.timeSigDen = 4

  var i = 0
  while i < args.len:
    let token = args[i]
    if token.startsWith("--"):
      var key = token
      var value = ""
      var haveInline = false
      let eq = token.find('=')
      if eq > 0:
        key = token[0 ..< eq]
        value = token[eq + 1 .. ^1]
        haveInline = true
      if key notin NotationKeys:
        result.rep = usageError("неизвестный ключ: " & key,
          "ключи notation: " & NotationKeys.join(", "))
        return
      if result.sub.len == 0:
        result.rep = usageError("ключ " & key & " указан до подкоманды",
          "порядок: `euterpia notation <" & NotationSubcommands.join("|") &
          "> <файл> [ключи]`")
        return
      if result.sub == "check" and key notin CheckKeys:
        result.rep = usageError("ключ " & key & " у подкоманды check смысла не " &
          "имеет", "check только разбирает партитуру: ключи " &
          CheckKeys.join(", "))
        return

      if not haveInline:
        if i + 1 >= args.len:
          result.rep = usageError(key & " требует значение",
                                  "например: euterpia notation import " &
                                  key & " …")
          return
        inc i
        value = args[i]

      case key
      of "--file":
        result.projectPath = value
      of "--track":
        let parsed = intArg(value, key, 0, 4096)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "индекс дорожки с нуля: первая дорожка — 0")
          return
        result.track = parsed.value
      of "--clip":
        let parsed = intArg(value, key, 0, 4096)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "индекс клипа с нуля: первый клип дорожки — 0")
          return
        result.clip = parsed.value
      of "--name":
        if value.len == 0:
          result.rep = usageError("--name: пустое имя",
            "имя клипа — подпись в списке, пустая подпись неотличима от сбоя")
          return
        result.name = value
        result.haveName = true
      of "--start-tick":
        let parsed = tickArg(value, key, allowZero = true)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "тик — позиция от начала клипа; по умолчанию 0")
          return
        result.startTick = parsed.value
      of "--time-sig":
        let parsed = timeSigArg(value, key)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "размер участвует в проверке тактов: неполный такт — предупреждение")
          return
        result.timeSigNum = parsed.num
        result.timeSigDen = parsed.den
      of "--velocity":
        let parsed = velocityArg(value, key)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "velocity по умолчанию — " & $DefaultVelocity &
            "; ноты с `:V` её переопределяют")
          return
        result.velocity = parsed.value
      of "--length":
        let parsed = tickArg(value, key, allowZero = false)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "длина клипа в тиках; без ключа — по длине партитуры")
          return
        result.length = parsed.value
        result.haveLength = true
      else: # --loop
        let lowered = value.toLowerAscii()
        if lowered in @["true", "yes", "on", "1"]:
          result.loop = true
        elif lowered in @["false", "no", "off", "0"]:
          result.loop = false
        else:
          result.rep = usageError("--loop: ожидается true или false, получено «" &
            value & "»", "повтор рисунка клипа внутри его длины")
          return
      inc i
      continue

    if result.sub.len == 0:
      if token notin NotationSubcommands:
        result.rep = usageError("неизвестная подкоманда notation: " & token,
          "подкоманды: " & NotationSubcommands.join(", "))
        return
      result.sub = token
    elif result.path.len == 0:
      result.path = token
    else:
      result.rep = usageError("лишний аргумент: " & token,
        "notation принимает одну партитуру: `euterpia notation " & result.sub &
        " <файл.notes>`")
      return
    inc i

  if result.sub.len == 0:
    result.rep = usageError("не указана подкоманда notation",
      "подкоманды: " & NotationSubcommands.join(", "))
    return
  if result.path.len == 0:
    result.rep = usageError("не указан файл партитуры",
      "например: euterpia notation " & result.sub & " scores/lead.notes")
    return

  result.ok = true


# =============================================================================
# Общие части отчёта
# =============================================================================

proc readScore(path: string; scan: NotationScan;
               parsed: var NotationResult): ScoreRead =
  ## Читает и разбирает партитуру. Отсутствующий файл — данные (код 1),
  ## нечитаемый существующий — среда (код 2): от этой разницы зависит,
  ## исправлять путь или права.
  if not fileExists(path):
    return ScoreRead(ok: false,
      rep: usageError("файл партитуры не найден: " & path, NotationHint))

  var text: string
  try:
    text = readFile(path)
  except CatchableError as e:
    return ScoreRead(ok: false,
      rep: envError("не удалось прочитать файл партитуры: " & e.msg,
                    "проверьте права: " & path, errorKind = "io"))

  parsed = parseNotation(text, int32(scan.startTick), int32(scan.timeSigNum),
                         int32(scan.timeSigDen), int32(scan.velocity))
  ScoreRead(ok: true)

proc warningLines(warnings: seq[NotationIssue]): seq[string] =
  ## Замечания разбора. `строка:колонка` — первым делом: без места
  ## замечание бесполезно, файл правит человек.
  for item in warnings:
    result.add "предупреждение: " & $item.line & ":" & $item.column & " " &
      item.message

proc warningsJson(warnings: seq[NotationIssue]): JsonNode =
  result = newJArray()
  for item in warnings:
    result.add %*{"line": item.line, "column": item.column,
                  "message": item.message}

proc barsText(ticks: int32; scan: NotationScan): string =
  ## Тики — единица машины, такты — единица музыканта. Печатаются обе,
  ## потому что по тикам находят ошибку, а в тактах её замечают.
  let bar = notationBarTicks(int32(scan.timeSigNum), int32(scan.timeSigDen))
  if bar <= 0:
    return $ticks & " тиков"
  $ticks & " тиков = " & formatFloat(float64(ticks) / float64(bar), ffDecimal, 2) &
    " такта " & $scan.timeSigNum & "/" & $scan.timeSigDen

# =============================================================================
# notation check
# =============================================================================

proc runNotationCheck(scan: NotationScan): Report =
  ## Разбор без записи: что понято, где ошибка, чем недоволен контроль такта.
  var parsed: NotationResult
  let read = readScore(scan.path, scan, parsed)
  if not read.ok:
    return read.rep

  var body = %*{
    "path": scan.path,
    "notes": parsed.notes.len,
    "endTick": int(parsed.endTick),
    "barTicks": int(parsed.barTicks),
    "timeSignature": $scan.timeSigNum & "/" & $scan.timeSigDen,
    "velocity": scan.velocity,
    "warnings": warningsJson(parsed.warnings),
  }
  let lines = @[
    CliName & " notation check — разбор партитуры",
    "файл: " & scan.path,
    "нот: " & $parsed.notes.len,
    "длина: " & barsText(parsed.endTick - int32(scan.startTick), scan),
  ]

  if not parsed.ok:
    # Ошибка разбора — данные: и код, и место указывает ядро, CLI добавляет
    # только подсказку по формату.
    body["error"] = %*{"line": parsed.error.line, "column": parsed.error.column,
                       "message": parsed.error.message}
    return usageError(
      "строка " & $parsed.error.line & ", колонка " & $parsed.error.column &
      ": " & parsed.error.message,
      NotationHint, ecInvalidArgument, lines = lines, body = body)

  var report = lines
  report.add warningLines(parsed.warnings)
  okReport(body = body, lines = report)



# =============================================================================
# notation import
# =============================================================================

proc nextTrackId(tracks: seq[TrackFormat]): int32 =
  ## id новой дорожки — «на единицу больше максимального». Именно максимум,
  ## а не «число дорожек»: после удаления дорожки счётчик длины выдал бы
  ## повтор id, и две дорожки стали бы неразличимы для автоматизации.
  for track in tracks:
    if track.id + 1 > result:
      result = track.id + 1
  if result < 1:
    result = 1

proc nextClipId(clips: seq[ClipFormat]): int32 =
  ## То же правило, что у дорожек: id клипа уникален внутри дорожки.
  for clip in clips:
    if clip.id + 1 > result:
      result = clip.id + 1
  if result < 1:
    result = 1

proc roundUpToBar(ticks: int32; scan: NotationScan): int32 =
  ## Длина клипа — целое число тактов: клип, оборванный посреди такта, не
  ## совпадает с сеткой, и следующий клип «поехал» бы относительно него.
  let bar = notationBarTicks(int32(scan.timeSigNum), int32(scan.timeSigDen))
  if bar <= 0 or ticks <= 0:
    return bar
  ((ticks + bar - 1) div bar) * bar

proc toNoteFormats(notes: seq[NotationNote]): seq[NoteFormat] =
  ## Ноты нотации → ноты формата проекта. Приведение типов явное, потому
  ## что разборщик держит значения в MIDI-диапазоне, а формат файла — байты.
  for note in notes:
    result.add NoteFormat(
      startTick: note.startTick,
      duration: max(note.durationTicks, 1'i32),
      pitch: uint8(clamp(note.pitch, 0, 127)),
      velocity: uint8(clamp(note.velocity, 1, 127)),
      channel: 0
    )

proc runNotationImport(ctx: var Ctx; scan: NotationScan): Report =
  ## Партитура из файла → клип дорожки проекта. Дорожка и клип создаются,
  ## если их ещё нет: импорт нот не должен требовать ручной подготовки.
  var parsed: NotationResult
  let read = readScore(scan.path, scan, parsed)
  if not read.ok:
    return read.rep

  let head = @[
    CliName & " notation import — партитура в проект",
    "файл: " & scan.path,
  ]
  if not parsed.ok:
    return usageError(
      "строка " & $parsed.error.line & ", колонка " & $parsed.error.column &
      ": " & parsed.error.message,
      NotationHint, ecInvalidArgument, lines = head,
      body = %*{"path": scan.path,
                "error": %*{"line": parsed.error.line,
                            "column": parsed.error.column,
                            "message": parsed.error.message}})

  if parsed.notes.len == 0:
    return usageError("в файле нет нот: импортировать нечего",
      "пауза (`r`) и комментарий (`#`) нот не создают")

  if parsed.notes.len > MaxNotesPerClipImport:
    return usageError("нот " & $parsed.notes.len & " — больше потолка клипа " &
      $MaxNotesPerClipImport,
      "разделите партитуру на несколько клипов: формат проекта хранит не больше " &
      $MaxNotesPerClipImport & " нот на клип")

  let loaded = loadAt(scan.projectPath)
  if not loaded.ok:
    return loaded.rep
  var proj = loaded.proj

  # --- дорожка --------------------------------------------------------------
  # Создавать можно только следующую дорожку: «дырка» в нумерации сделала бы
  # индексы в отчёте неотличимыми от опечатки.
  if scan.track > proj.sequencer.tracks.len:
    return usageError("дорожка #" & $scan.track & " недостижима: в проекте " &
      $proj.sequencer.tracks.len & " дорожек",
      "дорожки создаются по порядку: следующий доступный индекс — " &
      $proj.sequencer.tracks.len)

  var createdTrack = false
  while proj.sequencer.tracks.len <= scan.track:
    let id = nextTrackId(proj.sequencer.tracks)
    proj.sequencer.tracks.add TrackFormat(
      id: id,
      name: "Track " & $id,
      trackType: ord(ttMidi),
      volume: 1.0'f32,
      pan: 0.0'f32,
      inputChannel: 0,
      outputBus: 0
    )
    createdTrack = true

  # --- клип ----------------------------------------------------------------
  if scan.clip > proj.sequencer.tracks[scan.track].clips.len:
    return usageError("клип #" & $scan.clip & " недостижим: в дорожке #" &
      $scan.track & " клипов " &
      $proj.sequencer.tracks[scan.track].clips.len,
      "клипы создаются по порядку: следующий доступный индекс — " &
      $proj.sequencer.tracks[scan.track].clips.len)

  let notes = toNoteFormats(parsed.notes)
  let contentTicks = notationLengthTicks(parsed.notes)
  var lengthTicks =
    if scan.haveLength: int32(scan.length)
    else: roundUpToBar(contentTicks, scan)
  if lengthTicks < contentTicks:
    return usageError("--length " & $lengthTicks & " меньше партитуры (" &
      $contentTicks & " тиков)",
      "ноты не поместились бы в клип: увеличьте --length или уберите ключ")

  var createdClip = false
  if scan.clip == proj.sequencer.tracks[scan.track].clips.len:
    let id = nextClipId(proj.sequencer.tracks[scan.track].clips)
    proj.sequencer.tracks[scan.track].clips.add ClipFormat(
      id: id,
      clipType: ord(ctMidi),
      name: "Clip " & $id,
      startTick: 0,
      lengthTicks: lengthTicks,
      loopEnabled: false,
      audioBufferId: -1,
      color: 0xFF6B6B'u32
    )
    createdClip = true

  # Файл задаёт клип целиком: ноты, длина, имя и повтор. `startTick` клипа
  # сохраняется — импорт одной партитуры не двигает остальные клипы дорожки.
  block:
    let clip = addr proj.sequencer.tracks[scan.track].clips[scan.clip]
    clip[].notes = notes
    clip[].lengthTicks = lengthTicks
    clip[].loopEnabled = scan.loop
    if scan.haveName:
      clip[].name = scan.name
    elif createdClip and scan.name.len == 0:
      # Имя из имени файла — подпись, по которой клип узнаётся: `lead.notes`
      # даёт клип «lead». Это лучше, чем «Clip 7» без подсказки о содержимом.
      let stem = extractFilename(scan.path).changeFileExt("")
      if stem.len > 0:
        clip[].name = stem

  proj.metadata.modified = nowStamp()

  let clipRef = proj.sequencer.tracks[scan.track].clips[scan.clip]
  var body = %*{
    "path": scan.path,
    "project": scan.projectPath,
    "track": scan.track,
    "trackName": proj.sequencer.tracks[scan.track].name,
    "createdTrack": createdTrack,
    "clip": scan.clip,
    "clipName": clipRef.name,
    "createdClip": createdClip,
    "notes": clipRef.notes.len,
    "lengthTicks": int(clipRef.lengthTicks),
    "loop": clipRef.loopEnabled,
    "endTick": int(clipRef.startTick + lengthTicks),
    "warnings": warningsJson(parsed.warnings),
    "written": not ctx.dryRun,
  }

  var lines = @[
    CliName & " notation import — партитура в проект",
    "файл: " & scan.path & " (" & $clipRef.notes.len & " нот)",
    "проект: " & scan.projectPath,
    "дорожка: #" & $scan.track & " «" & proj.sequencer.tracks[scan.track].name &
      "»" & (if createdTrack: " (создана)" else: ""),
    "клип: #" & $scan.clip & " «" & clipRef.name & "»" &
      (if createdClip: " (создан)" else: ""),
    "длина клипа: " & barsText(lengthTicks, scan),
    "повтор: " & (if clipRef.loopEnabled: "включён" else: "выключен"),
  ]
  lines.add warningLines(parsed.warnings)

  if ctx.dryRun:
    return okReport(body = body,
                    lines = lines & @["не записан: " & scan.projectPath &
                                      " (--dry-run)"])

  let saved = writeAtomic(scan.projectPath, proj)
  if not saved.success:
    return saveError(saved, scan.projectPath)
  okReport(body = body, lines = lines & @["записан: " & scan.projectPath])

# =============================================================================
# Точка входа
# =============================================================================

proc runNotation*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia notation check|import <файл.notes> [ключи]`.
  let scan = scanArgs(args)
  if not scan.ok:
    return scan.rep
  if scan.sub == "check":
    return runNotationCheck(scan)
  runNotationImport(ctx, scan)

