# cli/cmd_live.nim
#
# `euterpia device list` и `euterpia play` — живой звук через аудиоустройство
# (issue #92).
#
# Границы (§20): CLI не открывает драйвер сам и не считает звук — адаптером
# владеет `core/backend_manager`, рендер идёт по существующему
# `AudioRenderProc` (`AudioEngine.renderBlock`), а CLI читает метрики
# (`pollMetrics`) и печатает их. Ни одной асинхронной структуры драйвера CLI
# не трогает.
#
# Почему это отдельная команда от `render`: офлайн-рендер проверяет граф и
# DSP, но не проверяет то, что ломается только на живом драйвере — xrun'ы,
# метрики, корректное завершение по SIGINT. `play` закрывает именно этот
# пробел.
#
# Формат `--json`: живой режим не может ответить одним конвертом «в конце» —
# пользователю нужны метрики ПО ХОДУ. Поэтому `play --json` печатает NDJSON:
# одна строка — один снимок в секунду, последняя строка — обычный конверт
# CLI с итогом. Это осознанное исключение из «одна строка JSON на команду»
# (MANIFEST §21), зафиксированное в спецификации команды.
#
# Коды возврата (#88): 0 — успех, 1 — данные/использование, 2 — среда (нет
# устройства, нет бэкенда), 3 — внутренняя.

import std/[json, math, monotimes, os, strutils, times]

import context
import cli_spec
import config
import cmd_project
import catalog
import control/query
import control_bridge

import audio_backend_api
import backend_manager
import backend_registry
import live_session
import transport
import signal_types
import logger

import audio_backend_miniaudio
import builtin/scene_loader

when defined(posix):
  import std/posix


const
  DeviceSubcommands* = @["list"]

  DefaultBlock = 512
  MaxPlaySeconds = 24.0 * 3600.0
    ## Потолок `--seconds`: опечатка не должна превращать сеанс в сутки.
  MetricsIntervalMs* = 1000
    ## Период снимка метрик. Один раз в секунду — компромисс между
    ## «видно, что происходит» и объёмом NDJSON.

  DeviceSpec* = CommandSpec(
    name: "device",
    summary: "аудио-бэкенды и устройства вывода/ввода",
    synopsis: "device list [ключи]",
    subcommands: DeviceSubcommands,
    args: @[
      arg("<подкоманда>", "list"),
    ],
    options: @[
      opt("--backend", "бэкенд: какое устройство перечислять", value = "имя"),
    ],
    example: "euterpia device list --json",
    fields: @[
      field("backends", "зарегистрированные бэкенды CLI"),
      field("backend", "бэкенд, который перечислял устройства"),
      field("outputs", "число устройств вывода"),
      field("inputs", "число устройств ввода"),
      field("devices", "устройства вывода: `index`, `name`, `channels`, `sampleRate`, `latency`, `default`"),
      field("initError", "почему адаптер не инициализировался (пустой список — не ошибка)"),
    ],
    notes: @[
      "на машине без звуковой подсистемы команда успешна: пустой список и причина, а не паника (#92)",
      "CLI собирается с miniaudio статически; portaudio в этой сборке не залинкован",
      "устройства описываются данными адаптера (`backendDeviceInfo`), CLI не угадывает поля",
    ])

  PlaySpec* = CommandSpec(
    name: "play",
    summary: "живое воспроизведение проекта через аудиоустройство",
    synopsis: "play [проект.eproj] [ключи]",
    args: @[
      arg("проект.eproj", "что играть; без аргумента — `project.eproj`, если он есть"),
    ],
    options: @[
      opt("--file", "проект, если он не задан позиционно", value = "проект.eproj"),
      opt("--backend", "аудио-бэкенд: miniaudio", value = "имя"),
      opt("--device", "индекс или имя устройства вывода", value = "N|имя"),
      opt("--sample-rate", "частота дискретизации; без ключа — из проекта", value = "Гц"),
      opt("--block", "размер блока", value = "кадры", default = $DefaultBlock),
      opt("--seconds", "играть N секунд; без ключа — до SIGINT", value = "секунды"),
      opt("--master", "id ноды, подключённой к мастеру", value = "id ноды"),
    ],
    example: "euterpia play demo.eproj --seconds 10",
    fields: @[
      field("path", "проект"),
      field("backend", "открытый бэкенд"),
      field("device", "индекс устройства вывода"),
      field("sampleRate", "частота сеанса"),
      field("blockSize", "размер блока"),
      field("seconds", "сколько длился сеанс"),
      field("frames", "отрендерено кадров"),
      field("xruns", "xrun'ы за сеанс"),
      field("droppedMetrics", "потерянные снимки метрик"),
      field("peakL", "последний пик левого канала"),
      field("peakR", "последний пик правого канала"),
      field("rmsL", "последний RMS левого канала"),
      field("rmsR", "последний RMS правого канала"),
      field("graphVersion", "версия играющего графа"),
      field("position", "позиция: `frames`, `bar`, `beat`, `tick`"),
      field("state", "состояние транспорта"),
      field("exitReason", "`seconds`|`signal`|`transport-stopped`"),
    ],
    notes: @[
      "на машине без устройства `play` завершается кодом 2 с понятным сообщением, а не паникой (#92)",
      "SIGINT/SIGTERM останавливают транспорт, закрывают адаптер и уничтожают движок; exit 0",
      "xruns приходят из адаптера (`noteStatus`), CLI их только читает",
      "`--json` печатает NDJSON: снимок в секунду, последняя строка — итоговый конверт CLI",
    ])

type
  LiveScan = object
    ok: bool
    rep: Report
    subcommand: string
    path: string
    backend: string
    device: int
    deviceName: string
    haveDevice: bool
    sampleRate: int
    blockSize: int
    seconds: float64
    haveSeconds: bool
    master: int

# =============================================================================
# Разбор аргументов
# =============================================================================

proc intArg(text, key: string; low, high: int): tuple[ok: bool; value: int;
                                                     message: string] =
  try:
    let v = parseInt(text.strip())
    if v < low or v > high:
      return (false, 0, key & ": диапазон " & $low & ".." & $high &
              ", получено «" & text & "»")
    (true, v, "")
  except ValueError:
    (false, 0, key & ": ожидается целое, получено «" & text & "»")

proc floatArg(text, key: string; high: float64): tuple[ok: bool; value: float64;
                                                       message: string] =
  try:
    let v = parseFloat(text.strip())
    if v != v or v <= 0.0 or v > high:
      return (false, 0.0, key & ": ожидается положительное число до " &
              $high & ", получено «" & text & "»")
    (true, v, "")
  except ValueError:
    (false, 0.0, key & ": ожидается число, получено «" & text & "»")

proc scanArgs(args: seq[string]; isDevice: bool): LiveScan =
  result.blockSize = DefaultBlock
  result.master = -1
  var positionals: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--file":
      inc i
      if i >= args.len:
        return LiveScan(ok: false, rep: usageError("--file: нужен путь к проекту"))
      result.path = args[i]
    of "--backend":
      inc i
      if i >= args.len:
        return LiveScan(ok: false,
          rep: usageError("--backend: нужно имя бэкенда"))
      result.backend = args[i]
    of "--device":
      inc i
      if i >= args.len:
        return LiveScan(ok: false,
          rep: usageError("--device: нужен индекс или имя устройства"))
      let parsed = intArg(args[i], "--device", -1, 1_000_000)
      if parsed.ok:
        result.device = parsed.value
      else:
        result.deviceName = args[i]
      result.haveDevice = true
    of "--sample-rate":
      inc i
      if i >= args.len:
        return LiveScan(ok: false,
          rep: usageError("--sample-rate: нужно значение в Гц"))
      let parsed = intArg(args[i], "--sample-rate", 1, 1_000_000)
      if not parsed.ok:
        return LiveScan(ok: false, rep: usageError(parsed.message))
      result.sampleRate = parsed.value
    of "--block":
      inc i
      if i >= args.len:
        return LiveScan(ok: false, rep: usageError("--block: нужно число кадров"))
      let parsed = intArg(args[i], "--block", 1, MaxBlockSize)
      if not parsed.ok:
        return LiveScan(ok: false, rep: usageError(parsed.message))
      result.blockSize = parsed.value
    of "--seconds":
      inc i
      if i >= args.len:
        return LiveScan(ok: false, rep: usageError("--seconds: нужно значение"))
      let parsed = floatArg(args[i], "--seconds", MaxPlaySeconds)
      if not parsed.ok:
        return LiveScan(ok: false, rep: usageError(parsed.message))
      result.seconds = parsed.value
      result.haveSeconds = true
    of "--master":
      inc i
      if i >= args.len:
        return LiveScan(ok: false, rep: usageError("--master: нужен id ноды"))
      let parsed = intArg(args[i], "--master", 0, int(high(int32)))
      if not parsed.ok:
        return LiveScan(ok: false, rep: usageError(parsed.message))
      result.master = parsed.value
    else:
      if a.len > 1 and a[0] == '-':
        return LiveScan(ok: false, rep: usageError("неизвестный ключ: " & a))
      positionals.add a
    inc i

  if isDevice:
    if positionals.len == 0:
      return LiveScan(ok: false, rep: usageError(
        "device: нужна подкоманда", "подкоманды: " & DeviceSubcommands.join(", ")))
    result.subcommand = positionals[0]
    if positionals.len > 1:
      return LiveScan(ok: false, rep: usageError(
        "device " & result.subcommand & ": лишний аргумент: " & positionals[1]))
    result.ok = true
    return

  # play: проект позиционно, если он не задан ключом.
  for p in positionals:
    if result.path.len == 0 and isProjectPath(p):
      result.path = p
    else:
      return LiveScan(ok: false, rep: usageError("play: лишний аргумент: " & p))
  result.ok = true


# =============================================================================
# Бэкенд и устройства
# =============================================================================

proc miniaudioFactory(log: Logger): ptr AudioBackendApi =
  createMiniaudioBackend(log)

proc miniaudioDestroy(api: ptr AudioBackendApi) =
  destroyMiniaudioBackend(api)

proc registerCliBackends(m: var BackendManager) =
  ## CLI собирается с miniaudio статически. PortAudio — dynlib-адаптер:
  ## импорт загрузил бы библиотеку при старте процесса, поэтому в этой
  ## сборке его нет, и обещать его нельзя (#52).
  discard m.registerBackend("miniaudio", miniaudioFactory, miniaudioDestroy)

proc chosenBackend(ctx: Ctx; scan: LiveScan): string =
  if scan.backend.len > 0:
    return scan.backend
  let fromConfig = ctx.config.entry("backend").value
  if fromConfig.len > 0: fromConfig else: "miniaudio"

proc configInt(ctx: Ctx; key: string; fallback: int): int =
  try:
    let v = parseInt(ctx.config.entry(key).value.strip())
    if v > 0: v else: fallback
  except ValueError:
    fallback

proc deviceJson(info: AudioDeviceInfo): JsonNode =
  %*{
    "index": info.id,
    "name": info.name,
    "channels": info.maxOutputChannels,
    "inputChannels": info.maxInputChannels,
    "sampleRate": info.defaultSampleRate,
    "latency": info.defaultLowOutputLatency,
    "default": info.isDefault,
  }

proc listDevices(ctx: var Ctx; scan: LiveScan): Report =
  ## Перечисление идёт через РЕЕСТР (как в `doctor`), а не через менеджер:
  ## устройство нужно описать, а не открыть, и временный адаптер обязан быть
  ## освобождён до выхода (критерий #105: все адаптеры освобождены).
  let backend = chosenBackend(ctx, scan)
  var reg = initBackendRegistry()
  discard reg.registerBackend("miniaudio", miniaudioFactory, miniaudioDestroy)

  var body = %*{
    "backend": backend,
    "backends": reg.backendNames(),
    "outputs": 0,
    "inputs": 0,
    "devices": newJArray(),
    "initError": "",
  }

  if not reg.hasBackend(backend):
    return usageError("неизвестный аудио-бэкенд: " & backend,
      "доступны: " & reg.backendNames().join(", ") &
      "; portaudio в этой сборке CLI не залинкован (#52)")

  var log = silentLogger()
  let (api, createErr) = reg.createBackend(backend, log)
  if api.isNil:
    body["initError"] = %("адаптер не создан: " & $createErr)
    return okReport(body = body,
      lines = @["бэкенд: " & backend, "адаптер не создан: " & $createErr])

  let initErr = backendInit(api, addr log)
  if initErr != abeOk:
    body["initError"] = %("init: " & $initErr)
    discard reg.destroyBackend(backend, api)
    # Отсутствие звуковой подсистемы — не ошибка команды: список пуст,
    # причина названа (критерий #92).
    return okReport(body = body,
      lines = @["бэкенд: " & backend,
                "устройств нет: init → " & $initErr])

  let outs = int(backendDeviceCount(api, false))
  let ins = int(backendDeviceCount(api, true))
  var devices = newJArray()
  var lines = @["бэкенд: " & backend,
                "устройств вывода: " & $outs & "; ввода: " & $ins]
  for i in 0 ..< outs:
    var info: AudioDeviceInfo
    if backendDeviceInfo(api, int32(i), false, info):
      devices.add deviceJson(info)
      lines.add "  #" & $info.id & " " & info.name &
        (if info.isDefault: " (по умолчанию)" else: "") &
        " — каналов " & $info.maxOutputChannels &
        ", " & formatFloat(info.defaultSampleRate, ffDecimal, 0) & " Гц"

  body["outputs"] = %outs
  body["inputs"] = %ins
  body["devices"] = devices
  discard reg.destroyBackend(backend, api)
  okReport(body = body, lines = lines)



proc listOutputs(backend: string; infos: var seq[AudioDeviceInfo]): bool

proc validateDevice(backend: string; device: int): string =
  ## Пустая строка — устройство годится; иначе причина для кода 2.
  ## Индекс проверяется по списку: адаптер молча открыл бы устройство по
  ## умолчанию, и `--device 99` играл бы не туда, куда просили.
  if device < 0:
    return ""
  var infos: seq[AudioDeviceInfo]
  if not listOutputs(backend, infos):
    return "звуковая подсистема недоступна"
  for info in infos:
    if int(info.id) == device:
      return ""
  "устройства вывода #" & $device & " нет: доступно " & $infos.len

# =============================================================================
# Живой рендер
# =============================================================================

var gStop {.volatile.}: bool

when defined(posix):
  proc onStopSignal(sig: cint) {.noconv.} =
    gStop = true

proc installStopHandlers() =
  when defined(posix):
    discard signal(SIGINT, onStopSignal)
    discard signal(SIGTERM, onStopSignal)

proc liveRequested(): bool {.inline.} = gStop

proc listOutputs(backend: string; infos: var seq[AudioDeviceInfo]): bool =
  ## Перечислить выходные устройства временным адаптером. `false` — адаптер
  ## не создался/не инициализировался (нет звуковой подсистемы).
  var reg = initBackendRegistry()
  discard reg.registerBackend("miniaudio", miniaudioFactory, miniaudioDestroy)
  var log = silentLogger()
  let (api, _) = reg.createBackend(backend, log)
  if api.isNil:
    return false
  defer: discard reg.destroyBackend(backend, api)
  if backendInit(api, addr log) != abeOk:
    return false
  let count = int(backendDeviceCount(api, false))
  for i in 0 ..< count:
    var info: AudioDeviceInfo
    if backendDeviceInfo(api, int32(i), false, info):
      infos.add info
  true

proc resolveDevice(backend, name: string): int =
  ## Имя → индекс устройства вывода. Нужен потому, что настройка `device`
  ## задаётся именем, а `AudioStreamConfig` — индексом. Временный адаптер
  ## освобождается сразу.
  ##
  ## -1 — устройство по умолчанию (пустое имя), -2 — имя не найдено:
  ## «молча взять другое устройство» значило бы играть не туда, куда просили.
  if name.len == 0:
    return int(DefaultDeviceIndex)
  var infos: seq[AudioDeviceInfo]
  if not listOutputs(backend, infos):
    return -2
  for info in infos:
    if info.name == name:
      return int(info.id)
  -2


proc positionJson(frame: int64; tempo: float64; sr: float32;
                  num, den: int32): JsonNode =
  var t = initTransport(sr)
  t.setTempo(float32(tempo))
  t.timeSignature = TimeSignature(numerator: num, denominator: den)
  t.setPosition(frame)
  let snap = t.getSnapshot()
  %*{
    "frames": frame,
    "bar": snap.barPosition,
    "beat": snap.beatPosition,
    "tick": snap.tickPosition,
    "quarter": snap.quarterNotePosition,
  }

proc metricSnapshot(m: LiveMetrics; frame: int64; tempo: float64;
                    sr: float32; num, den: int32;
                    xrunsTotal, xrunsDelta: uint64): JsonNode =
  %*{
    "peakL": m.peakL,
    "peakR": m.peakR,
    "rmsL": m.rmsL,
    "rmsR": m.rmsR,
    "cpuLoad": m.cpuLoad,
    "xruns": xrunsTotal,
    "xrunsDelta": xrunsDelta,
    "graphVersion": m.graphVersion,
    "currentFrame": frame,
    "position": positionJson(frame, tempo, sr, num, den),
    "state": m.transportState,
  }

proc metricLine(snap: JsonNode): string =
  "такт " & formatFloat(snap{"position"}{"bar"}.getFloat, ffDecimal, 3) &
    ", peak " & formatFloat(snap{"peakL"}.getFloat, ffDecimal, 3) & "/" &
    formatFloat(snap{"peakR"}.getFloat, ffDecimal, 3) & ", RMS " &
    formatFloat(snap{"rmsL"}.getFloat, ffDecimal, 3) & "/" &
    formatFloat(snap{"rmsR"}.getFloat, ffDecimal, 3) & ", xruns " &
    $snap{"xruns"}.getBiggestInt & " (+" & $snap{"xrunsDelta"}.getBiggestInt &
    "), граф v" & $snap{"graphVersion"}.getBiggestInt

# =============================================================================
# play
# =============================================================================

proc runPlay(ctx: var Ctx; scan: LiveScan): Report =
  var path = scan.path
  if path.len == 0 and fileExists(DefaultProjectFile):
    path = DefaultProjectFile
  if path.len == 0:
    return usageError("play: не указан проект",
      "например: euterpia play project.eproj --seconds 10")

  let loaded = loadAt(path)
  if not loaded.ok:
    return loaded.rep
  let proj = loaded.proj
  let meta = queryMetadata(openDocument(path, proj))

  # --- частота и блок: argv > проект > настройки > умолчание --------------
  var sr = scan.sampleRate
  if sr <= 0:
    let fromProject = int(round(float64(meta.sampleRate)))
    sr = if fromProject > 0: fromProject
         else: configInt(ctx, "sampleRate", 48000)
  let bs = if scan.blockSize > 0: scan.blockSize
           else: configInt(ctx, "blockSize", DefaultBlock)

  # --- бэкенд и устройство ------------------------------------------------
  var mgr = initBackendManager()
  registerCliBackends(mgr)
  let backend = chosenBackend(ctx, scan)
  if not mgr.hasBackend(backend):
    return usageError("неизвестный аудио-бэкенд: " & backend,
      "доступны: " & mgr.backendNames().join(", ") &
      "; portaudio в этой сборке CLI не залинкован (#52)")

  var device = int(DefaultDeviceIndex)
  if scan.haveDevice:
    if scan.deviceName.len > 0:
      device = resolveDevice(backend, scan.deviceName)
    else:
      device = scan.device
  else:
    let fromConfig = ctx.config.entry("device").value
    if fromConfig.len > 0:
      let parsed = intArg(fromConfig, "device", -1, 1_000_000)
      device = if parsed.ok: parsed.value
               else: resolveDevice(backend, fromConfig)

  if device == -2:
    return envError("устройство вывода не найдено: «" & scan.deviceName & "»",
      "список устройств: euterpia device list")
  let deviceProblem = validateDevice(backend, device)
  if deviceProblem.len > 0:
    return envError("живое воспроизведение недоступно: " & deviceProblem,
      "список устройств: euterpia device list; без устройства работает " &
      "офлайн-рендер: euterpia render " & path)

  # --- сцена --------------------------------------------------------------
  var reg = builtinRegistry()
  var scene = loadScene(reg, proj, scan.master, int32(sr), parentDir(path))
  if not scene.ok:
    return usageError(scene.error,
      "проверьте граф: euterpia graph check " & path)

  let tempo = if meta.tempo > 1.0f: float64(meta.tempo) else: 120.0
  let num = if meta.tsNumerator > 0: meta.tsNumerator else: 4'i32
  let den = if meta.tsDenominator > 0: meta.tsDenominator else: 4'i32

  # Пайплайн переходит живому сеансу; сцена остаётся владельцем состояний
  # нод и скомпилированных секвенсоров, поэтому живёт до `closeLiveSession`.
  var pipeline = detachPipeline(scene)
  var session = initLiveSession(float32(sr), int32(bs), move(pipeline))
  if not session.isActive:
    destroyScene(scene)
    return panicError("не удалось создать живой сеанс",
      "проверьте sampleRate/blockSize: " & $sr & "/" & $bs)
  discard session.postSetTempo(tempo)
  discard session.postSetMeter(num, den)
  discard session.postPlay()
  session.flushQueuedCommands()

  var cfg = AudioStreamConfig(
    sampleRate: float64(sr),
    blockSize: int32(bs),
    inputChannels: 0,
    outputChannels: MaxAudioChannels,
    inputDevice: DefaultDeviceIndex,
    outputDevice: int32(device),
    reportStatus: liveStatus
  )

  # Политика выбора: явный ключ/настройка — ровно этот бэкенд; иначе
  # `openPreferred` пробует платформенный список и пропускает недоступные.
  let explicit = scan.backend.len > 0 or
                 ctx.config.entry("backend").value.len > 0
  let openErr =
    if explicit:
      mgr.openBackend(backend, cfg, liveRender, cast[pointer](addr session))
    else:
      mgr.openPreferred(cfg, liveRender, cast[pointer](addr session),
                        ["miniaudio"])

  if openErr != bmOk:
    discard session.postStop()
    session.closeLiveSession()
    destroyScene(scene)
    let reason =
      case openErr
      of bmUnknownBackend: "бэкенд не зарегистрирован: " & backend
      of bmUnavailable: "адаптер недоступен"
      of bmOpenFailed: "не удалось открыть устройство"
      of bmAlreadyOpen: "менеджер уже открыт"
      else: "неизвестная ошибка бэкенда"
    return envError("живое воспроизведение недоступно: " & reason,
      "проверьте `euterpia device list`; без звуковой подсистемы работает " &
      "офлайн-рендер: euterpia render " & path)


  # --- сеанс --------------------------------------------------------------
  installStopHandlers()
  let started = getMonoTime()
  let limitMs = if scan.haveSeconds: int64(scan.seconds * 1000.0) else: -1'i64
  var nextReport = 0'i64
  var lastXruns = 0'u64
  var lastMetric: LiveMetrics
  var haveMetric = false
  var snapshots = 0
  var exitReason = "signal"

  while not liveRequested():
    let elapsed = (getMonoTime() - started).inMilliseconds
    if limitMs >= 0 and elapsed >= limitMs:
      exitReason = "seconds"
      break

    session.pollReclamation()
    var m: LiveMetrics
    while session.pollMetrics(m):
      lastMetric = m
      haveMetric = true

    if haveMetric and elapsed >= nextReport:
      nextReport += MetricsIntervalMs
      let frame = session.currentFrame()
      let total = uint64(session.xrunCount())
      let delta = if total >= lastXruns: total - lastXruns else: 0'u64
      lastXruns = total
      let snap = metricSnapshot(lastMetric, frame, tempo, float32(sr),
                                num, den, total, delta)
      if ctx.mode == omJson:
        cliStdout($snap)
      else:
        cliStdout(metricLine(snap))
      inc snapshots

    sleep(10)

  # --- завершение: транспорт → адаптер → движок → сцена --------------------
  # Итоговую позицию снимаем ДО `postStop`: стоп сбрасывает её в ноль, и
  # отчёт «кадров: 0» после минутного сеанса был бы ложью.
  let finalFrame = session.currentFrame()
  let totalXruns = uint64(session.xrunCount())
  let dropped = session.droppedMetrics()
  discard session.postStop()
  session.flushQueuedCommands()
  mgr.closeBackend()
  session.closeLiveSession()
  destroyScene(scene)

  let elapsedMs = (getMonoTime() - started).inMilliseconds
  var body = %*{
    "path": path,
    "backend": backend,
    "device": device,
    "sampleRate": sr,
    "blockSize": bs,
    "seconds": float64(elapsedMs) / 1000.0,
    "frames": finalFrame,
    "xruns": totalXruns,
    "droppedMetrics": dropped,
    "graphVersion": (if haveMetric: lastMetric.graphVersion else: 0'u64),
    "position": positionJson(finalFrame, tempo, float32(sr), num, den),
    "state": "stopped",
    "exitReason": exitReason,
  }
  if haveMetric:
    body["peakL"] = %lastMetric.peakL
    body["peakR"] = %lastMetric.peakR
    body["rmsL"] = %lastMetric.rmsL
    body["rmsR"] = %lastMetric.rmsR

  var lines = @[
    "воспроизведение остановлено (" &
      (if exitReason == "seconds": "истекло --seconds"
       else: "сигнал завершения") & ")",
    "бэкенд: " & backend & ", устройство: " & $device &
      ", " & $sr & " Гц / " & $bs & " кадров",
    "кадров: " & $finalFrame & ", xruns: " & $totalXruns &
      ", снимков метрик: " & $snapshots,
  ]
  okReport(body = body, lines = lines)

# =============================================================================
# Точки входа команд
# =============================================================================

proc runDevice*(ctx: var Ctx; args: seq[string]): Report =
  let scan = scanArgs(args, isDevice = true)
  if not scan.ok:
    return scan.rep
  case scan.subcommand
  of "list": listDevices(ctx, scan)
  else:
    usageError("device: неизвестная подкоманда «" & scan.subcommand & "»",
      "подкоманды: " & DeviceSubcommands.join(", "))

proc runPlay*(ctx: var Ctx; args: seq[string]): Report =
  let scan = scanArgs(args, isDevice = false)
  if not scan.ok:
    return scan.rep
  runPlay(ctx, scan)

