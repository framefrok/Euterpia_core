# cli/cmd_transport.nim
#
# `euterpia transport <подкоманда>` — транспорт без аудиоустройства (issue
# #257).
#
# Границы (#20, #27, #63): CLI не считает BBT и не хранит второй транспорт.
# Он работает с ТРАНСПОРТОМ ЯДРА (`core/transport`) и его offline-сессией:
#
#   * темп и размер — это ДОКУМЕНТ проекта (persist): `transport tempo 140`,
#     за которым идёт `render`, обязан дать правильную длительность. Поле
#     пишется через тот же путь, что `project set` (метаданные проекта);
#   * состояние/позиция/цикл — РАНТАЙМ offline-сессии (`core/transport`),
#     переживающей запуск процесса. Сессия рядом с проектом;
#   * BBT ↔ кадры, длительности долей и такта считает ядро (`Transport`):
#     `sampleToBarBeatTick`/`barBeatTickToSample`/`samplesPerQuarter`. Копий
#     этих формул в CLI нет — иначе Editor считал бы не так, как CLI.
#
# Живого пути (открыть устройство, реальный Play) здесь НЕТ намеренно: это
# #92. В #257 `play`/`pause`/`stop`/`seek` управляют offline-сессией и
# сообщают её состояние; сам контракт движка (`postPlay/postPause/postStop/
# postSeek*/postSetLoop`) лежит в Core и покрыт unit-тестом.
#
# Коды возврата (#88): 0 — успех, 1 — данные/использование, 2 — среда
# (файл сессии/проекта недоступен), 3 — внутренняя.

import std/[atomics, json, math, os, strutils]

import context
import transport
import cli_spec
import cmd_project
import control/query
import control/document
import control_bridge

const
  TransportSessionSuffix = ".transport.json"
    ## Суффикс файла offline-сессии рядом с проектом. Формат — ядра
    ## (`core/transport`): CLI только раскладывает срез в файл и обратно.
  FallbackSessionFile = ".euterpia.transport.json"
    ## Сессия без проекта (cwd): `transport state` должен работать и тогда,
    ## когда проекта рядом нет — с умолчаниями ядра.

  PositionUnits = @["bbt", "seconds", "frames"]
    ## Единицы позиции для `seek`/`loop set`/`position`.

  TransportSpec* = CommandSpec(
    name: "transport",
    summary: "транспорт: темп, размер, позиция, воспроизведение, цикл",
    synopsis: "transport <подкоманда> [аргументы] [проект.eproj] [ключи]",
    subcommands: @["tempo", "meter", "position", "seek", "play", "pause",
                   "stop", "loop", "state"],
    args: @[
      arg("<подкоманда>", "tempo|meter|position|seek|play|pause|stop|loop|state"),
      arg("проект.eproj", "проект; без аргумента — `project.eproj`, если он есть"),
    ],
    options: @[
      opt("--file", "проект, если он не задан позиционно", value = "проект.eproj"),
      opt("--unit", "единица позиции для seek/loop set",
          value = "bbt|seconds|frames", default = "bbt"),
      switch("--seconds", "то же, что `--unit seconds`"),
      switch("--frames", "то же, что `--unit frames`"),
    ],
    example: "euterpia transport tempo 140 demo.eproj",
    fields: @[
      field("schema", "версия схемы ответа: `euterpia.transport.v1`"),
      field("state", "состояние: `stopped`|`playing`|`recording`|`paused`"),
      field("position", "позиция: `frames`, `seconds`, `bar`, `beat`, `tick`, `quarter`"),
      field("tempo", "темп в BPM"),
      field("meter", "размер такта: `numerator`, `denominator`"),
      field("loop", "цикл: `enabled`, `startFrames`, `endFrames`"),
      field("metrics", "метрики: `xruns`, `cpuLoad` (offline — `null`)"),
      field("path", "проект, если команда его читала или меняла"),
      field("change", "что изменил `tempo`/`meter`: поле, до и после"),
    ],
    notes: @[
      "`tempo` и `meter` меняют ДОКУМЕНТ проекта: `transport tempo 140` + `render` учитывает новый темп",
      "`play`/`pause`/`stop`/`seek`/`loop` меняют offline-сессию рядом с проектом (живого устройства нет — это #92)",
      "позиция BBT ↔ кадры и длительности такта считает ядро (`core/transport`); CLI формул не копирует",
      "`position` — чтение, `seek` — запись: одна команда не совмещает get и set",
      "пауза сохраняет позицию, стоп возвращает в 0 (#257)",
      "`metrics.cpuLoad` в offline равен null: реальную загрузку предоставит живой backend (#92)",
      "`--dry-run` печатает план и не пишет ни проект, ни сессию",
    ])

# =============================================================================
# Offline-сессия: чтение и запись рантайм-среза
# =============================================================================

proc sessionPathFor(projectPath: string): string =
  if projectPath.len > 0: projectPath & TransportSessionSuffix
  else: FallbackSessionFile

proc loadSession(t: var Transport; path: string): tuple[ok: bool; message: string] =
  ## Читает рантайм-срез сессии. Нет файла — рантайм остаётся умолчанием
  ## ядра (стоп, позиция 0). Битый файл — отказ, а не «тихий стоп».
  if not fileExists(path):
    return (true, "")
  try:
    let node = parseJson(readFile(path))
    if not applySessionSnapshot(node, t):
      return (false, "сессия транспорта не распознана: " & path)
  except CatchableError as e:
    return (false, "не удалось прочитать сессию транспорта: " & e.msg)
  (true, "")

proc saveSession(t: var Transport; path: string): bool =
  try:
    writeFile(path, pretty(sessionSnapshotJson(t)))
    true
  except CatchableError:
    false

# =============================================================================
# Сборка транспорта и ответа
# =============================================================================

proc seedTransport(sampleRate: float32; hasProject: bool;
                   doc: Document): Transport =
  ## Транспорт, привязанный к проекту: темп и размер — из документа (их
  ## источник), частота — из метаданных. Без проекта — умолчания ядра.
  result = initTransport(sampleRate)
  if hasProject:
    let meta = queryMetadata(doc)
    result.setTempo(meta.tempo)
    result.timeSignature = TimeSignature(
      numerator: meta.tsNumerator, denominator: meta.tsDenominator)

proc positionJson(t: var Transport): JsonNode =
  let pos = t.samplePosition.load(moRelaxed)
  let (bar, beat, tick) = t.sampleToBarBeatTick(pos)
  let sr = float64(t.sampleRate)
  let spq = t.samplesPerQuarter()
  %*{
    "frames": pos,
    "seconds": (if sr > 0.0: float64(pos) / sr else: 0.0),
    "bar": bar,
    "beat": beat,
    "tick": tick,
    "quarter": (if spq > 0.0: float64(pos) / spq else: 0.0),
  }

proc stateBody(t: var Transport; path: string): JsonNode =
  result = %*{
    "schema": TransportSessionSchema,
    "state": transportStateName(t.currentState()),
    "position": positionJson(t),
    "tempo": t.tempo.load(moRelaxed),
    "meter": %*{
      "numerator": t.timeSignature.numerator,
      "denominator": t.timeSignature.denominator,
    },
    "loop": %*{
      "enabled": t.loopEnabled.load(moRelaxed),
      "startFrames": t.loopStart.load(moRelaxed),
      "endFrames": t.loopEnd.load(moRelaxed),
    },
    "metrics": %*{"xruns": 0, "cpuLoad": nil},
  }
  if path.len > 0:
    result["path"] = %path

proc stateLines(t: var Transport): seq[string] =
  let pos = t.samplePosition.load(moRelaxed)
  let (bar, beat, tick) = t.sampleToBarBeatTick(pos)
  let sr = float64(t.sampleRate)
  let seconds = if sr > 0.0: float64(pos) / sr else: 0.0
  let loop = t.loopEnabled.load(moRelaxed)
  result.add "состояние: " & transportStateName(t.currentState())
  result.add "позиция: " & $bar & "." & $beat & "." & $tick
  result.add "секунды: " & $seconds
  result.add "кадры: " & $pos
  result.add "темп: " & $t.tempo.load(moRelaxed) & " BPM"
  result.add "размер: " & $t.timeSignature.numerator & "/" &
    $t.timeSignature.denominator
  if loop:
    result.add "цикл: вкл (" & $t.loopStart.load(moRelaxed) & ".." &
      $t.loopEnd.load(moRelaxed) & ")"
  else:
    result.add "цикл: выкл"

# =============================================================================
# Разбор позиции
# =============================================================================

type
  PositionParse = object
    ok: bool
    frames: int64
    message: string

proc parsePosition(t: var Transport; text, unit: string): PositionParse =
  ## Позиция → кадры. BBT разбирает ядро (`barBeatTickToSample`) — формул в
  ## CLI нет. Формы BBT: `bar`, `bar.beat`, `bar.beat.tick`.
  case unit
  of "seconds":
    try:
      let sec = parseFloat(text)
      if sec < 0.0:
        return PositionParse(ok: false, message: "позиция отрицательна: " & text)
      return PositionParse(ok: true,
                           frames: int64(sec * float64(t.sampleRate)))
    except ValueError:
      return PositionParse(ok: false,
        message: "секунды: ожидается число, получено «" & text & "»")
  of "frames":
    try:
      let f = parseBiggestInt(text)
      if f < 0:
        return PositionParse(ok: false, message: "кадры отрицательны: " & text)
      return PositionParse(ok: true, frames: f)
    except ValueError:
      return PositionParse(ok: false,
        message: "кадры: ожидается целое, получено «" & text & "»")
  of "bbt":
    let parts = text.split('.')
    if parts.len < 1 or parts.len > 3:
      return PositionParse(ok: false,
        message: "bbt: ожидается `такт.доля.тик`, получено «" & text & "»")
    var bar = 1'i32
    var beat = 1'i32
    var tick = 0'i32
    try:
      bar = int32(parseInt(parts[0].strip()))
      if parts.len >= 2: beat = int32(parseInt(parts[1].strip()))
      if parts.len >= 3: tick = int32(parseInt(parts[2].strip()))
    except ValueError:
      return PositionParse(ok: false,
        message: "bbt: компоненты должны быть целыми, получено «" & text & "»")
    if bar < 1 or beat < 1 or tick < 0:
      return PositionParse(ok: false,
        message: "bbt: такт и доля от 1, тик от 0, получено «" & text & "»")
    return PositionParse(ok: true, frames: t.barBeatTickToSample(bar, beat, tick))
  else:
    PositionParse(ok: false, message: "неизвестная единица позиции: " & unit)

# =============================================================================
# Разбор аргументов
# =============================================================================

type
  TransportScan = object
    ok: bool
    rep: Report
    subcommand: string
    rest: seq[string]
    projectPath: string
    unit: string

proc scanArgs(args: seq[string]): TransportScan =
  result.unit = "bbt"
  var positionals: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--file":
      inc i
      if i >= args.len:
        return TransportScan(ok: false, rep: usageError("--file: нужен путь к проекту"))
      result.projectPath = args[i]
    elif a == "--unit":
      inc i
      if i >= args.len:
        return TransportScan(ok: false, rep: usageError("--unit: нужна единица позиции"))
      if args[i] notin PositionUnits:
        return TransportScan(ok: false, rep: usageError(
          "--unit: ожидается " & PositionUnits.join("|") & ", получено «" & args[i] & "»"))
      result.unit = args[i]
    elif a == "--seconds":
      result.unit = "seconds"
    elif a == "--frames":
      result.unit = "frames"
    elif a.len > 1 and a[0] == '-':
      return TransportScan(ok: false, rep: usageError("неизвестный ключ: " & a))
    else:
      positionals.add a
    inc i

  if positionals.len == 0:
    return TransportScan(ok: false, rep: usageError(
      "transport: нужна подкоманда",
      "подкоманды: " & TransportSpec.subcommands.join(", ")))

  result.subcommand = positionals[0]
  var tail = positionals[1 .. ^1]

  # Последний позиционный аргумент — проект, если похож на путь проекта.
  # `tempo 140` и `seek 4.2.120` сюда не попадают: они не заканчиваются на
  # `.eproj`/`.eut` (правило, а не угадывание — см. `isProjectPath`).
  if result.projectPath.len == 0 and tail.len > 0 and
     isProjectPath(tail[^1]):
    result.projectPath = tail[^1]
    tail = tail[0 .. ^2]

  result.rest = tail
  result.ok = true

# =============================================================================
# Запись поля проекта (tempo/meter) — тот же путь, что `project set`
# =============================================================================

proc setProjectField(path, field, value: string; dryRun: bool): Report =
  let loaded = loadAt(path)
  if not loaded.ok: return loaded.rep
  var proj = loaded.proj
  let docBefore = openDocument(path, proj)
  let before = readField(queryMetadata(docBefore), field)
  let applied = setField(proj, field, value)
  if not applied.ok:
    return usageError(applied.message,
      "темп: число BPM; размер: числитель/знаменатель (4/4, 6/8)")
  var doc = openDocument(path, proj)
  let after = readField(queryMetadata(doc), field)

  var body = %*{
    "path": path, "field": field, "before": before, "after": after,
    "applied": false,
  }
  if before == after:
    return okReport(body = body,
      lines = @[path & ": без изменений", field & ": " & after])
  if dryRun:
    body["dryRun"] = %true
    return okReport(body = body,
      lines = @["было бы изменено: " & path, field & ": " & before & " → " & after])
  proj.metadata.modified = nowStamp()
  let saved = writeAtomic(path, proj)
  if not saved.success:
    return saveError(saved, path)
  body["applied"] = %true
  okReport(body = body,
    lines = @["изменено: " & path, field & ": " & before & " → " & after])

# =============================================================================
# Точка входа
# =============================================================================

proc finishTransport(t: var Transport; dryRun: bool; path, sessionPath: string;
                     lines: seq[string]): Report =
  ## Сохраняет рантайм-сессию (кроме `--dry-run`) и печатает состояние.
  var repLines = lines
  repLines.add stateLines(t)
  if dryRun:
    repLines.add "сессия не записана: " & sessionPath & " (--dry-run)"
    return okReport(body = stateBody(t, path), lines = repLines)
  if not saveSession(t, sessionPath):
    return envError("не удалось записать сессию транспорта: " & sessionPath,
      "проверьте права и каталог", errorKind = "io")
  okReport(body = stateBody(t, path), lines = repLines)

proc runTransport*(ctx: var Ctx; args: seq[string]): Report =
  let sc = scanArgs(args)
  if not sc.ok:
    return sc.rep

  # Проект по умолчанию: если рядом лежит `project.eproj`, команды без
  # аргумента работают с ним (как `project show`/`project set`).
  var path = sc.projectPath
  if path.len == 0 and fileExists(DefaultProjectFile):
    path = DefaultProjectFile

  var hasProject = false
  var doc: Document
  var sampleRate = DefaultSampleRate
  if path.len > 0:
    let loaded = loadAt(path)
    if not loaded.ok: return loaded.rep
    doc = openDocument(path, loaded.proj)
    sampleRate = queryMetadata(doc).sampleRate
    hasProject = true

  var t = seedTransport(sampleRate, hasProject, doc)
  let sessionPath = sessionPathFor(path)
  let loadedSession = loadSession(t, sessionPath)
  if not loadedSession.ok:
    return envError(loadedSession.message,
      "удалите файл сессии или задайте другой проект", errorKind = "io")

  case sc.subcommand
  of "tempo":
    if not hasProject:
      return usageError("tempo: нужен файл проекта",
        "например: euterpia transport tempo 140 demo.eproj")
    if sc.rest.len != 1:
      return usageError("tempo: ожидается одно значение BPM",
        "например: euterpia transport tempo 140")
    let set = setProjectField(path, "tempo", sc.rest[0], ctx.dryRun)
    if not set.ok: return set
    let reloaded = loadAt(path)
    if reloaded.ok:
      # Значение читается через Query API (DTO), а не из `ProjectFormat`:
      # тот же источник, что у `transport state` (#336, §63).
      t.setTempo(queryMetadata(openDocument(path, reloaded.proj)).tempo)
    var body = stateBody(t, path)
    body["change"] = set.body
    var lines = set.lines
    lines.add stateLines(t)
    return okReport(body = body, lines = lines)

  of "meter":
    if not hasProject:
      return usageError("meter: нужен файл проекта",
        "например: euterpia transport meter 6/8 demo.eproj")
    if sc.rest.len != 1:
      return usageError("meter: ожидается размер вида `числитель/знаменатель`",
        "например: euterpia transport meter 6/8")
    let set = setProjectField(path, "time-signature", sc.rest[0], ctx.dryRun)
    if not set.ok: return set
    let reloaded = loadAt(path)
    if reloaded.ok:
      let meta = queryMetadata(openDocument(path, reloaded.proj))
      t.timeSignature = TimeSignature(
        numerator: meta.tsNumerator, denominator: meta.tsDenominator)
    var body = stateBody(t, path)
    body["change"] = set.body
    var lines = set.lines
    lines.add stateLines(t)
    return okReport(body = body, lines = lines)

  of "play":
    t.play()
    finishTransport(t, ctx.dryRun, path, sessionPath, @[])

  of "pause":
    t.pause()
    finishTransport(t, ctx.dryRun, path, sessionPath, @[])

  of "stop":
    t.stop()
    finishTransport(t, ctx.dryRun, path, sessionPath, @[])

  of "seek":
    if sc.rest.len != 1:
      return usageError("seek: ожидается одна позиция",
        "например: euterpia transport seek 4.2.120  (или --unit seconds/frames)")
    let parsed = parsePosition(t, sc.rest[0], sc.unit)
    if not parsed.ok:
      return usageError(parsed.message, "единицы: " & PositionUnits.join(", "))
    t.setPosition(parsed.frames)
    finishTransport(t, ctx.dryRun, path, sessionPath, @["позиция: " & sc.rest[0] & " (" & sc.unit & ")"])

  of "position":
    if sc.rest.len != 0:
      return usageError("position: лишний аргумент: " & sc.rest[0],
        "чтобы изменить позицию, используйте `transport seek`")
    okReport(body = stateBody(t, path), lines = stateLines(t))

  of "state":
    if sc.rest.len != 0:
      return usageError("state: лишний аргумент: " & sc.rest[0])
    okReport(body = stateBody(t, path), lines = stateLines(t))

  of "loop":
    if sc.rest.len == 0:
      return usageError("loop: ожидается `on`, `off` или `set`",
        "например: euterpia transport loop set 4.1.0 8.1.0")
    let action = sc.rest[0]
    case action
    of "on":
      t.setLoop(true, t.loopStart.load(moRelaxed), t.loopEnd.load(moRelaxed))
      finishTransport(t, ctx.dryRun, path, sessionPath, @["цикл включён"])
    of "off":
      t.setLoop(false, t.loopStart.load(moRelaxed), t.loopEnd.load(moRelaxed))
      finishTransport(t, ctx.dryRun, path, sessionPath, @["цикл выключен"])
    of "set":
      if sc.rest.len != 3:
        return usageError("loop set: ожидается начало и конец",
          "например: euterpia transport loop set 4.1.0 8.1.0")
      let start = parsePosition(t, sc.rest[1], sc.unit)
      if not start.ok: return usageError(start.message)
      let stop = parsePosition(t, sc.rest[2], sc.unit)
      if not stop.ok: return usageError(stop.message)
      if stop.frames <= start.frames:
        return usageError("loop set: конец должен быть больше начала",
          "границы в кадрах: " & $start.frames & " и " & $stop.frames)
      t.setLoop(true, start.frames, stop.frames)
      finishTransport(t, ctx.dryRun, path, sessionPath, @["цикл задан: " & $start.frames & ".." & $stop.frames])
    else:
      return usageError("loop: неизвестная подкоманда «" & action & "»",
        "подкоманды: on, off, set")

  else:
    usageError("transport: неизвестная подкоманда «" & sc.subcommand & "»",
      "подкоманды: " & TransportSpec.subcommands.join(", "))