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
import project
import catalog
import control/query
import control_bridge
import control/document
import control/commands
import control/history
import history_file

import audio_backend_api
import backend_manager
import backend_registry
import live_session
import src_api
import stream_resampler
import transport
import signal_types
import logger

import audio_backend_miniaudio
import midi_api
import midi_backend_rtmidi
import sdk/node_registry
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

  RecordSpec* = CommandSpec(
    name: "record",
    summary: "запись входа в WAV через аудиоустройство (arm/start/stop, метрики)",
    synopsis: "record <выход.wav> [--seconds N] [--channels 1|2] [--input-channel N]",
    args: @[
      arg("выход.wav", "куда писать запись; расширение `.wav` обязательно"),
    ],
    options: @[
      opt("--project", "проект, чей граф держать открытым во время записи",
          value = "проект.eproj"),
      opt("--backend", "аудио-бэкенд: miniaudio", value = "имя"),
      opt("--device", "индекс или имя устройства вывода", value = "N|имя"),
      opt("--input-device", "индекс устройства ввода", value = "N"),
      opt("--sample-rate", "частота дискретизации записи", value = "Гц"),
      opt("--block", "размер блока", value = "кадры", default = $DefaultBlock),
      opt("--seconds", "писать N секунд; без ключа — до SIGINT", value = "секунды"),
      opt("--channels", "ширина записи: 1 (моно) или 2 (стерео)", value = "1|2",
          default = "1"),
      opt("--input-channel", "первый канал входа (0 — первый доступный)", value = "N",
          default = "0"),
      opt("--count-in", "отсчёт N тактов клика до старта записи (нужна нода метронома)",
          value = "такты"),
    ],
    example: "euterpia record take.wav --seconds 30 --channels 2",
    fields: @[
      field("path", "записанный WAV"),
      field("project", "проект, если он был указан"),
      field("backend", "открытый бэкенд"),
      field("device", "индекс устройства вывода"),
      field("inputDevice", "индекс устройства ввода"),
      field("sampleRate", "частота записи"),
      field("blockSize", "размер блока"),
      field("channels", "каналов в файле"),
      field("seconds", "длительность сеанса"),
      field("frames", "записано кадров"),
      field("droppedFrames", "потерянные кадры (переполнение кольца)"),
      field("inputPeakL", "последний пик входа, левый канал"),
      field("inputPeakR", "последний пик входа, правый канал"),
      field("inputXruns", "xrun'ы входного тракта"),
      field("countIn", "тактов отсчёта до старта записи"),
      field("exitReason", "`seconds`|`signal`"),
    ],
    notes: @[
      "на машине без входного устройства команда завершается кодом 2, файл не создаётся",
      "рекордер создаётся ДО открытия потока: открытие файла не даёт xrun на старте",
      "SIGINT/SIGTERM: запись останавливается, WAV-заголовок закрывается, exit 0",
      "--channels 1 пишет первый входной канал, --channels 2 — пару каналов",
      "--count-in N: N тактов клика метронома, запись стартует на сильной доле",
      "отсчёт требует --project с нодой `euterpia.metronome`; клик идёт через граф",
      "потери кольца считаются (`droppedFrames`) и печатаются в отчёте, а не теряются молча",
      "`--json` печатает итоговый конверт один раз (запись — не поток метрик)",
    ])

  MetronomeSpec* = CommandSpec(
    name: "metronome",
    summary: "метроном проекта: включить/выключить, звук и уровень",
    synopsis: "metronome <проект.eproj> on|off [--level N] [--sound имя]",
    args: @[
      arg("проект.eproj", "проект с нодой `euterpia.metronome`"),
      arg("состояние", "`on` или `off`"),
    ],
    options: @[
      opt("--level", "уровень клика 0…2 (сильная и слабая доли)", value = "N"),
      opt("--sound", "звук клика: click, beep, woodblock, cowbell", value = "имя"),
    ],
    example: "euterpia metronome demo.eproj on --sound woodblock --level 0.7",
    fields: @[
      field("project", "проект"),
      field("nodeId", "нода метронома"),
      field("enabled", "включён ли метроном"),
      field("sound", "звук клика"),
      field("accent", "уровень сильной доли"),
      field("normal", "уровень слабой доли"),
      field("applied", "была ли запись (false при отсутствии изменений)"),
    ],
    notes: @[
      "метроном — нода `euterpia.metronome`; добавьте её: euterpia node add metronome",
      "включённая нода кликает по сетке транспорта: темп и размер берутся из проекта",
      "сильная доля акцентируется; 4/4, 3/4, 6/8 и 5/4 считаются по numerator/denominator",
      "выключенный метроном пишет тишину и не триггерит голоса",
      "правка — транзакция истории: `euterpia undo` вернёт прежние параметры",
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
      opt("--sample-rate", "частота ПРОЕКТА; без ключа — из проекта", value = "Гц"),
      opt("--device-rate", "частота УСТРОЙСТВА; без ключа — родная частота устройства", value = "Гц"),
      opt("--src", "ресемплинг между устройством и проектом: auto|on|off", value = "auto|on|off",
          default = "auto"),
      opt("--block", "размер блока", value = "кадры", default = $DefaultBlock),
      opt("--seconds", "играть N секунд; без ключа — до SIGINT", value = "секунды"),
      opt("--master", "id ноды, подключённой к мастеру", value = "id ноды"),
      opt("--midi-in", "MIDI-порт для живой игры (индекс или имя)", value = "N|имя"),
      opt("--midi-target", "id ноды-приёмника MIDI; по умолчанию — единственный инструмент", value = "id ноды"),
    ],
    example: "euterpia play demo.eproj --seconds 10",
    fields: @[
      field("path", "проект"),
      field("backend", "открытый бэкенд"),
      field("device", "индекс устройства вывода"),
      field("sampleRate", "частота проекта"),
      field("deviceSampleRate", "частота устройства"),
      field("resampling", "мост частот включён (устройство ≠ проект)"),
      field("resamplerLatency", "задержка моста, кадров устройства"),
      field("blockSize", "размер блока драйвера"),
      field("engineBlockSize", "размер блока движка (может отличаться при SRC)"),
      field("seconds", "сколько длился сеанс"),
      field("frames", "отрендерено кадров"),
      field("xruns", "xrun'ы за сеанс"),
      field("droppedMetrics", "потерянные снимки метрик"),
      field("peakL", "последний пик левого канала"),
      field("peakR", "последний пик правого канала"),
      field("rmsL", "последний RMS левого канала"),
      field("rmsR", "последний RMS правого канала"),
      field("graphVersion", "версия играющего графа"),
      field("midiPort", "открытый MIDI-вход (пусто — живого входа нет)"),
      field("midiTarget", "нода-приёмник MIDI"),
      field("midiEvents", "принято MIDI-событий"),
      field("midiDropped", "события, не влезшие в очередь блока"),
      field("midiLate", "события вне текущего блока"),
      field("automationLanes", "линий автоматизации в живом пути"),
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
    deviceRate: int
    srcMode: string
    blockSize: int
    seconds: float64
    haveSeconds: bool
    master: int
    midiIn: int
    midiInName: string
    haveMidiIn: bool
    midiTarget: int

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
  result.midiTarget = -1
  result.srcMode = "auto"
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
    of "--device-rate":
      inc i
      if i >= args.len:
        return LiveScan(ok: false,
          rep: usageError("--device-rate: нужно значение в Гц"))
      let parsed = intArg(args[i], "--device-rate", 1, 1_000_000)
      if not parsed.ok:
        return LiveScan(ok: false, rep: usageError(parsed.message))
      result.deviceRate = parsed.value
    of "--src":
      inc i
      if i >= args.len:
        return LiveScan(ok: false,
          rep: usageError("--src: нужно auto, on или off"))
      let mode = args[i].toLowerAscii()
      if mode notin ["auto", "on", "off"]:
        return LiveScan(ok: false,
          rep: usageError("--src: ожидается auto|on|off, получено «" & args[i] & "»"))
      result.srcMode = mode
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
    of "--midi-in":
      inc i
      if i >= args.len:
        return LiveScan(ok: false,
          rep: usageError("--midi-in: нужен индекс или имя порта"))
      let parsed = intArg(args[i], "--midi-in", 0, 1_000_000)
      if parsed.ok:
        result.midiIn = parsed.value
      else:
        result.midiInName = args[i]
      result.haveMidiIn = true
    of "--midi-target":
      inc i
      if i >= args.len:
        return LiveScan(ok: false,
          rep: usageError("--midi-target: нужен id ноды"))
      let parsed = intArg(args[i], "--midi-target", 0, int(high(int32)))
      if not parsed.ok:
        return LiveScan(ok: false, rep: usageError(parsed.message))
      result.midiTarget = parsed.value
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

proc deviceRateOf(backend: string; device: int): float64 =
  ## Родная частота устройства вывода (0 — неизвестна). Нужна мосту SRC (#8):
  ## проект 44.1k на устройстве 48k должен играть в темпе, а не «на полтона
  ## ниже». Список берётся у адаптера, устройство при этом не открывается.
  var infos: seq[AudioDeviceInfo]
  if not listOutputs(backend, infos):
    return 0.0
  for info in infos:
    if int(info.id) == device and info.defaultSampleRate > 0.0:
      return info.defaultSampleRate
  0.0

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

type
  RecordScan = object
    ok: bool
    rep: Report
    path: string
    project: string
    backend: string
    device: int
    deviceName: string
    haveDevice: bool
    inputDevice: int
    sampleRate: int
    blockSize: int
    seconds: float64
    haveSeconds: bool
    channels: int
    inputChannel: int
    countIn: int

proc scanRecordArgs(args: seq[string]): RecordScan =
  ## Разбор `record`. Выход — позиционный и обязательный: запись без пути
  ## означала бы «куда-нибудь», а таких решений CLI не принимает.
  result.device = -1
  result.inputDevice = -1
  result.inputChannel = 0
  result.channels = 1
  result.blockSize = DefaultBlock

  var haveOut = false
  var i = 0
  while i < args.len:
    let key = args[i]
    if key in ["--project", "--backend", "--device", "--input-device",
               "--sample-rate", "--block", "--seconds", "--channels",
               "--input-channel", "--count-in"]:
      if i + 1 >= args.len:
        return RecordScan(ok: false,
          rep: usageError(key & ": нужно значение",
            "например: euterpia record take.wav --seconds 10"))
      let value = args[i + 1]
      case key
      of "--project":
        if not isProjectPath(value):
          return RecordScan(ok: false,
            rep: usageError("--project: ожидается проект (*.eproj), получено: " & value,
              "историческое расширение .eut принимается"))
        result.project = value
      of "--backend":
        result.backend = value
      of "--device":
        let parsed = intArg(value, "--device", -1, 1_000_000)
        if not parsed.ok:
          result.deviceName = value
        else:
          result.device = parsed.value
          result.haveDevice = true
      of "--input-device":
        let parsed = intArg(value, "--input-device", 0, 1_000_000)
        if not parsed.ok:
          return RecordScan(ok: false, rep: usageError(parsed.message,
            "индекс устройства ввода: euterpia device list"))
        result.inputDevice = parsed.value
      of "--sample-rate":
        let parsed = intArg(value, "--sample-rate", 1, 1_000_000)
        if not parsed.ok:
          return RecordScan(ok: false, rep: usageError(parsed.message,
            "частота дискретизации в герцах"))
        result.sampleRate = parsed.value
      of "--block":
        let parsed = intArg(value, "--block", 1, MaxBlockSize)
        if not parsed.ok:
          return RecordScan(ok: false, rep: usageError(parsed.message,
            "размер блока в кадрах: 1 … " & $MaxBlockSize))
        result.blockSize = parsed.value
      of "--seconds":
        let parsed = floatArg(value, "--seconds", MaxPlaySeconds)
        if not parsed.ok:
          return RecordScan(ok: false, rep: usageError(parsed.message,
            "длительность записи в секундах; без ключа — до SIGINT"))
        result.seconds = parsed.value
        result.haveSeconds = true
      of "--channels":
        let parsed = intArg(value, "--channels", 1, 2)
        if not parsed.ok:
          return RecordScan(ok: false, rep: usageError(parsed.message,
            "ширина записи: 1 (моно) или 2 (стерео)"))
        result.channels = parsed.value
      of "--input-channel":
        let parsed = intArg(value, "--input-channel", 0, 64)
        if not parsed.ok:
          return RecordScan(ok: false, rep: usageError(parsed.message,
            "первый канал входа: 0 — первый доступный"))
        result.inputChannel = parsed.value
      else: # --count-in
        let parsed = intArg(value, "--count-in", 1, 64)
        if not parsed.ok:
          return RecordScan(ok: false, rep: usageError(parsed.message,
            "отсчёт: 1…64 такта"))
        result.countIn = parsed.value
      i += 2
      continue
    elif key.startsWith("-"):
      return RecordScan(ok: false,
        rep: usageError("неизвестный ключ: " & key,
          "ключи record: --project, --backend, --device, --input-device, " &
          "--sample-rate, --block, --seconds, --channels, --input-channel, " &
          "--count-in"))
    else:
      if haveOut:
        return RecordScan(ok: false,
          rep: usageError("файл записи указан дважды: " & result.path & " и " & key,
            "выход задаётся одним позиционным аргументом"))
      result.path = key
      haveOut = true
    inc i

  if not haveOut:
    return RecordScan(ok: false,
      rep: usageError("record: не указан файл записи",
        "например: euterpia record take.wav --seconds 10"))
  if not result.path.toLowerAscii().endsWith(".wav"):
    return RecordScan(ok: false,
      rep: usageError("record пишет только WAV: " & result.path,
        "запись в сжатые форматы — кодировщик сдачи (#411), не recorder"))
  if result.countIn > 0 and result.project.len == 0:
    return RecordScan(ok: false,
      rep: usageError("--count-in требует --project: кликать нечем",
        "отсчёт идёт по метроному проекта: добавьте ноду metronome и " &
        "укажите --project"))
  result.ok = true

# =============================================================================
# Живой MIDI-вход (issue #413)
# =============================================================================

type
  MidiInputRig = object
    api: ptr MidiBackendApi
    port: MidiPortHandle
    name: string
    index: int

proc autoMidiTarget(proj: ProjectFormat): tuple[ok: bool; nodeId: int;
                                               message: string] =
  ## Нода-приёмник MIDI по умолчанию — единственная нода с event-входом.
  ## Угадывать среди нескольких нельзя: ноты ушли бы не в тот инструмент.
  var reg = builtinRegistry()
  var candidates: seq[int] = @[]
  for node in proj.graph.nodes:
    let entry = reg.findNodeType(node.nodeType)
    if not entry.isNil and entry.desc.eventInCount > 0:
      candidates.add node.id
  if candidates.len == 0:
    return (false, -1, "в проекте нет ноды с MIDI-входом")
  if candidates.len > 1:
    var list: seq[string] = @[]
    for id in candidates: list.add "#" & $id
    return (false, -1, "на MIDI-вход претендует несколько нод (" &
                       list.join(", ") & "): укажите --midi-target")
  (true, candidates[0], "")

proc openMidiInput(scan: LiveScan): tuple[rig: MidiInputRig; error: string] =
  ## Открыть порт входа. Пустой `error` — успех; иначе причина для кода 2.
  var log = silentLogger()
  let api = createRtMidiBackend(log)
  if api.isNil:
    return (MidiInputRig(), "MIDI-адаптер не создан")
  let initErr = midiInit(api, addr log)
  if initErr != meOk:
    destroyRtMidiBackend(api)
    return (MidiInputRig(), "MIDI-адаптер недоступен: " & $initErr)

  let count = midiDeviceCount(api, mpdInput)
  var index = scan.midiIn
  if scan.midiInName.len > 0:
    index = -1
    var i = 0'i32
    while i < count:
      var info: MidiBackendPortInfo
      if midiDeviceInfo(api, mpdInput, i, info) and info.name == scan.midiInName:
        index = int(i)
        break
      inc i
    if index < 0:
      midiShutdown(api)
      destroyRtMidiBackend(api)
      return (MidiInputRig(), "MIDI-порт не найден: «" & scan.midiInName & "»")
  elif index < 0 or index >= int(count):
    midiShutdown(api)
    destroyRtMidiBackend(api)
    return (MidiInputRig(), "MIDI-порта #" & $index & " нет: входов " & $count)

  var info: MidiBackendPortInfo
  discard midiDeviceInfo(api, mpdInput, int32(index), info)
  let port = midiOpenPort(api, mpdInput, int32(index))
  if port.isNil:
    midiShutdown(api)
    destroyRtMidiBackend(api)
    return (MidiInputRig(), "не удалось открыть MIDI-порт #" & $index)
  result.rig = MidiInputRig(api: api, port: port, name: info.name, index: index)

proc closeMidiInput(rig: var MidiInputRig) =
  if rig.api.isNil:
    return
  if not rig.port.isNil:
    midiClosePort(rig.api, rig.port)
    rig.port = nil
  midiShutdown(rig.api)
  destroyRtMidiBackend(rig.api)
  rig.api = nil

proc liveAutomationFromProject(proj: ProjectFormat):
    tuple[lanes: seq[LiveAutomationLane]; droppedPoints: int] =
  ## Линии проекта -> POD-набор живого пути. Точки сверх лимита линии
  ## считаются (`droppedPoints`), а не теряются молча.
  let offline = automationFromProject(proj)
  for lane in offline:
    var item = LiveAutomationLane(nodeId: lane.nodeId, paramId: lane.paramId)
    var dropped = 0
    for p in lane.points:
      if item.pointCount >= MaxLiveAutomationPoints:
        inc dropped
        continue
      item.addLiveAutomationPoint(p.tick, p.value, uint8(ord(p.curve)))
    result.droppedPoints += dropped
    if item.pointCount > 0:
      result.lanes.add item

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

  # --- частоты: устройство ↔ проект (issue #8) ----------------------------
  # `--device-rate` задаёт частоту драйвера явно; иначе берётся родная
  # частота устройства. Если она отличается от частоты проекта, включается
  # мост: движок считает в частоте проекта (темп, автоматизация, PDC),
  # драйвер — в своей. `--src off` запрещает мост (диагностика/совместимость).
  var deviceRate = sr
  var srcEnabled = false
  let nativeRate =
    if scan.deviceRate > 0: float64(scan.deviceRate)
    else: deviceRateOf(backend, device)
  if scan.srcMode != "off" and nativeRate > 0.0 and
     abs(nativeRate - float64(sr)) > 0.5:
    if not liveRateCompatible(nativeRate, float64(sr)):
      return usageError("частота устройства и проекта несовместимы: " &
        $nativeRate & " Гц и " & $sr & " Гц",
        "отношение вне 1/16..16; проверьте `euterpia device list`")
    deviceRate = int(round(nativeRate))
    srcEnabled = true
  let engineBlock: int32 =
    if srcEnabled: liveProjectBlock(int32(bs), float64(deviceRate), float64(sr))
    else: int32(bs)
  if engineBlock <= 0 or engineBlock > MaxBlockSize:
    return usageError("блок движка вне диапазона: " & $engineBlock,
      "уменьшите --block (при SRC блок движка пересчитывается)")

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
  var session = initLiveSession(float32(sr), int32(engineBlock), move(pipeline))
  if not session.isActive:
    destroyScene(scene)
    return panicError("не удалось создать живой сеанс",
      "проверьте sampleRate/blockSize: " & $sr & "/" & $bs)
  discard session.postSetTempo(tempo)
  discard session.postSetMeter(num, den)
  discard session.postPlay()
  session.flushQueuedCommands()

  # Мост создаётся ДО открытия устройства: его буферы и ресемплеры обязаны
  # существовать к первому callback (в RT-пути аллокаций нет).
  var srcApi: ptr SrcApi = nil
  var srcLatency = 0'i32
  var srcLog = silentLogger()
  if srcEnabled:
    srcApi = newSrcApi()
    var srcReady = false
    if not srcApi.isNil and srcInit(srcApi, addr srcLog) == seOk:
      srcReady = session.enableLiveResampling(
        srcApi, int32(bs), float64(deviceRate), float64(sr))
    if not srcReady:
      if not srcApi.isNil:
        srcShutdown(srcApi)
        freeSrcApi(srcApi)
        srcApi = nil
      discard session.postStop()
      session.closeLiveSession()
      destroyScene(scene)
      return envError("ресемплинг недоступен: адаптер SRC не создан",
        "проверьте EUTERPIA_SRC_LIB и сборку; либо `--src off` на устройстве " &
        "с частотой проекта")
    srcLatency = session.liveResamplingLatency()

  var cfg = AudioStreamConfig(
    sampleRate: float64(deviceRate),
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
    if not srcApi.isNil:
      srcShutdown(srcApi)
      freeSrcApi(srcApi)
      srcApi = nil
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


  # --- живой MIDI-вход и автоматизация (issue #413) ------------------------
  # MIDI открывается ПОСЛЕ устройства: порт без работающего audio-потока
  # бессмыслен, а путь раннего отказа остаётся коротким (закрыть движок).
  var midiRig = MidiInputRig()
  var midiTarget = scan.midiTarget
  var midiAccepted = 0
  if scan.haveMidiIn:
    if midiTarget < 0:
      let target = autoMidiTarget(proj)
      if not target.ok:
        discard session.postStop()
        mgr.closeBackend()
        session.closeLiveSession()
        if not srcApi.isNil:
          srcShutdown(srcApi)
          freeSrcApi(srcApi)
          srcApi = nil
        destroyScene(scene)
        return usageError("живой MIDI-вход: " & target.message,
          "укажите ноду явно: euterpia play ... --midi-in 0 --midi-target 1")
      midiTarget = target.nodeId
    let opened = openMidiInput(scan)
    if opened.error.len > 0:
      discard session.postStop()
      mgr.closeBackend()
      session.closeLiveSession()
      if not srcApi.isNil:
        srcShutdown(srcApi)
        freeSrcApi(srcApi)
        srcApi = nil
      destroyScene(scene)
      return envError("живой MIDI-вход недоступен: " & opened.error,
        "список портов: euterpia midi list")
    midiRig = opened.rig
    session.setMidiInputTarget(int32(midiTarget))

  # Автоматизация проекта применяется живым продюсером на границе блока.
  # До этого `play` брал только стартовые значения параметров.
  let auto = liveAutomationFromProject(proj)
  let autoAccepted = session.postLiveAutomation(auto.lanes)

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

    if not midiRig.port.isNil:
      # Порт опрашивается часто (2 мс): задержка входа — свойство живого
      # режима, а не «побочный эффект» 10-миллисекундного ожидания.
      var scratch: array[64, MidiMessage]
      let got = midiPoll(midiRig.api, midiRig.port,
        cast[ptr UncheckedArray[MidiMessage]](addr scratch[0]),
        int32(scratch.len))
      var k = 0'i32
      while k < got:
        let m = scratch[k]
        # timestamp порта — секунды от открытия; транспорт начинает с 0,
        # поэтому кадр проекта = timestamp * projectRate.
        let frame = int64(m.timestamp * float64(sr))
        if session.postMidiEventAtFrame(m.status, m.data1, m.data2, frame):
          inc midiAccepted
        inc k
      sleep(2)
    else:
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
  closeMidiInput(midiRig)
  session.closeLiveSession()
  if not srcApi.isNil:
    srcShutdown(srcApi)
    freeSrcApi(srcApi)
    srcApi = nil
  destroyScene(scene)

  let elapsedMs = (getMonoTime() - started).inMilliseconds
  var body = %*{
    "path": path,
    "backend": backend,
    "device": device,
    "sampleRate": sr,
    "deviceSampleRate": deviceRate,
    "resampling": srcEnabled,
    "resamplerLatency": srcLatency,
    "blockSize": bs,
    "engineBlockSize": engineBlock,
    "seconds": float64(elapsedMs) / 1000.0,
    "frames": finalFrame,
    "xruns": totalXruns,
    "droppedMetrics": dropped,
    "graphVersion": (if haveMetric: lastMetric.graphVersion else: 0'u64),
    "midiPort": (if midiRig.port.isNil: "" else: midiRig.name),
    "midiTarget": midiTarget,
    "midiEvents": midiAccepted,
    "midiDropped": session.midiDroppedCount(),
    "midiLate": session.midiLateCount(),
    "automationLanes": autoAccepted,
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
# Метроном (#112)
# =============================================================================

const
  MetronomeSoundNames = ["click", "beep", "woodblock", "cowbell"]

type
  MetroScan = object
    ok: bool
    rep: Report
    project: string
    enabled: bool
    level: float32
    haveLevel: bool
    sound: int
    haveSound: bool

proc scanMetronomeArgs(args: seq[string]): MetroScan =
  result.sound = -1
  var haveState = false
  var i = 0
  while i < args.len:
    let key = args[i]
    if key in ["--level", "--sound"]:
      if i + 1 >= args.len:
        return MetroScan(ok: false,
          rep: usageError(key & ": нужно значение",
            "например: euterpia metronome demo.eproj on --level 0.7"))
      let value = args[i + 1]
      if key == "--level":
        let parsed = floatArg(value, "--level", 2.0)
        if not parsed.ok:
          return MetroScan(ok: false, rep: usageError(parsed.message,
            "уровень клика 0…2"))
        result.level = float32(parsed.value)
        result.haveLevel = true
      else:
        let name = value.toLowerAscii()
        var idx = -1
        for k, candidate in MetronomeSoundNames:
          if candidate == name:
            idx = k
        if idx < 0:
          return MetroScan(ok: false,
            rep: usageError("--sound: неизвестный звук «" & value & "»",
              "допустимо: " & MetronomeSoundNames.join(", ")))
        result.sound = idx
        result.haveSound = true
      i += 2
      continue
    if key.startsWith("-"):
      return MetroScan(ok: false,
        rep: usageError("неизвестный ключ: " & key,
          "ключи metronome: --level, --sound"))
    if result.project.len == 0 and isProjectPath(key):
      result.project = key
    elif not haveState and key in ["on", "off"]:
      result.enabled = key == "on"
      haveState = true
    else:
      return MetroScan(ok: false,
        rep: usageError("непонятный аргумент: " & key,
          "форма: euterpia metronome <проект> on|off [--level N] [--sound имя]"))
    inc i
  if result.project.len == 0:
    return MetroScan(ok: false,
      rep: usageError("metronome: не указан проект",
        "например: euterpia metronome demo.eproj on"))
  if not haveState:
    return MetroScan(ok: false,
      rep: usageError("metronome: укажите on или off",
        "состояние — обязательный аргумент, а не догадка"))
  result.ok = true

proc metroParam(node: NodeInfo; name: string): float32 =
  for p in node.params:
    if p.name == name:
      return p.value
  0.0f

proc runMetronomeCmd*(ctx: var Ctx; args: seq[string]): Report =
  let sc = scanMetronomeArgs(args)
  if not sc.ok:
    return sc.rep

  let loaded = loadAt(sc.project)
  if not loaded.ok:
    return loaded.rep
  var doc = openDocument(sc.project, loaded.proj)

  var node: NodeInfo
  var found = false
  for item in queryNodes(doc).nodes:
    if item.nodeType == "euterpia.metronome":
      node = item
      found = true
      break
  if not found:
    return usageError("в проекте нет ноды метронома: " & sc.project,
      "добавьте ноду: euterpia node add metronome " & sc.project)

  let beforeEnabled = metroParam(node, "enabled") >= 0.5f
  let beforeSound = int(metroParam(node, "sound"))
  let beforeAccent = metroParam(node, "accent")
  let beforeNormal = metroParam(node, "normal")

  var cmds: seq[ControlCommand] = @[
    setParameter(int32(node.id), (if sc.enabled: 1.0f else: 0.0f), "enabled")
  ]
  if sc.haveLevel:
    cmds.add setParameter(int32(node.id), sc.level, "accent")
    cmds.add setParameter(int32(node.id), sc.level, "normal")
  if sc.haveSound:
    cmds.add setParameter(int32(node.id), float32(sc.sound), "sound")

  let plan = doc.applyTransaction(cmds, "metronome " &
    (if sc.enabled: "on" else: "off"))
  if not plan.frame.isOk():
    return frameReport(plan.frame)

  var after: NodeInfo
  for item in queryNodes(doc).nodes:
    if item.id == node.id:
      after = item
  let applied =
    beforeEnabled != sc.enabled or
    (sc.haveSound and beforeSound != sc.sound) or
    (sc.haveLevel and (beforeAccent != sc.level or beforeNormal != sc.level))

  var body = %*{
    "project": sc.project,
    "nodeId": node.id,
    "enabled": metroParam(after, "enabled") >= 0.5f,
    "sound": MetronomeSoundNames[int(metroParam(after, "sound"))],
    "accent": metroParam(after, "accent"),
    "normal": metroParam(after, "normal"),
    "applied": applied,
  }
  var lines = @[
    "метроном " & (if sc.enabled: "включён" else: "выключен") &
      " (нода #" & $node.id & ")",
    "звук: " & body["sound"].getStr &
      ", сильная: " & formatFloat(float64(body["accent"].getFloat), ffDecimal, 2) &
      ", слабая: " & formatFloat(float64(body["normal"].getFloat), ffDecimal, 2),
  ]

  if ctx.dryRun:
    return okReport(body = body, lines = lines &
      @["не записан: " & sc.project & " (--dry-run)"])
  if not applied:
    return okReport(body = body, lines = lines & @["изменений нет"])

  let saved = writeAtomic(sc.project, doc.proj)
  if not saved.success:
    return saveError(saved, sc.project)
  let entry = HistoryEntry(redo: plan.redo, undo: plan.undo,
                           description: plan.description)
  let recorded = recordEntry(sc.project, entry)
  if not recorded.isOk():
    return frameReport(recorded)
  lines.add "записан: " & sc.project
  okReport(body = body, lines = lines)


proc runRecord(ctx: var Ctx; scan: RecordScan): Report =
  ## Запись входа в WAV. Порядок важен и зафиксирован:
  ##   1. рекордер и файл трека — ДО открытия потока (иначе первый блок
  ##      тратится на fopen и даёт xrun);
  ##   2. движок/сцена → attachRecorder → openBackend;
  ##   3. stop → закрыть поток → detach → уничтожить движок → уничтожить
  ##      рекордер. Обратный порядок оставил бы висячий указатель в callback.
  let outPath = scan.path
  let outDir = if parentDir(outPath).len > 0: parentDir(outPath) else: "."
  if not dirExists(outDir):
    try:
      createDir(outDir)
    except CatchableError:
      return envError("каталог записи недоступен: " & outDir,
        "проверьте права и путь", errorKind = "io")

  # --- проект и частота -----------------------------------------------------
  var proj: ProjectFormat
  var haveProject = false
  var sr = scan.sampleRate
  var tempo = 120.0
  var tsNum = 4'i32
  var tsDen = 4'i32
  if scan.project.len > 0:
    let loaded = loadAt(scan.project)
    if not loaded.ok:
      return loaded.rep
    proj = loaded.proj
    haveProject = true
    let meta = queryMetadata(openDocument(scan.project, proj))
    if meta.tempo > 1.0f:
      tempo = float64(meta.tempo)
    if meta.tsNumerator > 0:
      tsNum = meta.tsNumerator
    if meta.tsDenominator > 0:
      tsDen = meta.tsDenominator
    if sr <= 0:
      let fromProject = int(round(float64(meta.sampleRate)))
      if fromProject > 0:
        sr = fromProject
    if scan.countIn > 0:
      var hasMetronome = false
      for node in queryNodes(openDocument(scan.project, proj)).nodes:
        if node.nodeType == "euterpia.metronome":
          hasMetronome = true
      if not hasMetronome:
        return usageError("--count-in: в проекте нет ноды метронома",
          "добавьте ноду: euterpia node add metronome " & scan.project)
  if sr <= 0:
    sr = configInt(ctx, "sampleRate", 48000)
  let bs = if scan.blockSize > 0: scan.blockSize
           else: configInt(ctx, "blockSize", DefaultBlock)

  # --- рекордер -------------------------------------------------------------
  var rec: LiveRecorder
  initLiveRecorder(rec, int32(sr), int32(bs), outDir,
                   int32(scan.channels))
  if not addLiveRecorderTrack(rec, int32(scan.inputChannel),
                              int32(scan.channels), 0):
    closeLiveRecorder(rec)
    return envError("не удалось создать трек записи",
      "проверьте каталог " & outDir & " и ширину --channels")
  armLiveRecorder(rec)

  # --- сцена/сеанс ----------------------------------------------------------
  var scene: Scene
  var session: LiveSession
  if haveProject:
    var reg = builtinRegistry()
    scene = loadScene(reg, proj, -1, int32(sr), parentDir(scan.project))
    if not scene.ok:
      closeLiveRecorder(rec)
      return usageError(scene.error,
        "проверьте граф: euterpia graph check " & scan.project)
    session = initLiveSession(float32(sr), int32(bs), detachPipeline(scene))
  else:
    session = initEmptyLiveSession(float32(sr), int32(bs))

  if not session.isActive:
    if haveProject:
      destroyScene(scene)
    closeLiveRecorder(rec)
    return panicError("не удалось создать сеанс записи",
      "проверьте sampleRate/blockSize: " & $sr & "/" & $bs)

  attachLiveRecorder(session, rec)
  setLiveInputChannels(session, int32(scan.channels))

  # --- бэкенд и устройство --------------------------------------------------
  var mgr = initBackendManager()
  registerCliBackends(mgr)
  var backend = scan.backend
  if backend.len == 0:
    backend = ctx.config.entry("backend").value
  if backend.len == 0:
    backend = "miniaudio"
  if not mgr.hasBackend(backend):
    detachLiveRecorder(session)
    session.closeLiveSession()
    if haveProject: destroyScene(scene)
    closeLiveRecorder(rec)
    return usageError("неизвестный аудио-бэкенд: " & backend,
      "доступны: " & mgr.backendNames().join(", "))

  var device = int(DefaultDeviceIndex)
  if scan.haveDevice:
    device = if scan.deviceName.len > 0: resolveDevice(backend, scan.deviceName)
             else: scan.device
    if device == -2:
      detachLiveRecorder(session)
      session.closeLiveSession()
      if haveProject: destroyScene(scene)
      closeLiveRecorder(rec)
      return envError("устройство вывода не найдено: «" & scan.deviceName & "»",
        "список устройств: euterpia device list")

  var cfg = AudioStreamConfig(
    sampleRate: float64(sr),
    blockSize: int32(bs),
    inputChannels: int32(scan.channels),
    outputChannels: MaxAudioChannels,
    inputDevice: int32(scan.inputDevice),
    outputDevice: int32(device),
    reportStatus: liveStatus
  )

  let explicit = scan.backend.len > 0 or
                 ctx.config.entry("backend").value.len > 0
  let openErr =
    if explicit:
      mgr.openBackend(backend, cfg, liveRender, cast[pointer](addr session))
    else:
      mgr.openPreferred(cfg, liveRender, cast[pointer](addr session),
                        ["miniaudio"])

  if openErr != bmOk:
    detachLiveRecorder(session)
    session.closeLiveSession()
    if haveProject: destroyScene(scene)
    closeLiveRecorder(rec)
    let reason =
      case openErr
      of bmUnknownBackend: "бэкенд не зарегистрирован: " & backend
      of bmUnavailable: "адаптер недоступен"
      of bmOpenFailed: "не удалось открыть устройство ввода/вывода"
      of bmAlreadyOpen: "менеджер уже открыт"
      else: "неизвестная ошибка бэкенда"
    return envError("запись недоступна: " & reason,
      "проверьте `euterpia device list --json`; нужен вход с " &
      $scan.channels & " каналом(ами)")

  # --- сеанс записи ---------------------------------------------------------
  installStopHandlers()
  var recordStart = 0'i64
  if scan.countIn > 0:
    # Отсчёт: транспорт играет клик N тактов, запись стартует на сильной
    # доле следующего такта. Рекордер получает целевой сэмпл и сам делает
    # sample-accurate старт (pre-roll уже в кольце).
    let barFrames = float64(sr) * 60.0 / tempo *
                    float64(tsNum) * 4.0 / float64(tsDen)
    recordStart = int64(round(barFrames * float64(scan.countIn)))
    discard session.postSetTempo(tempo)
    discard session.postSetMeter(tsNum, tsDen)
    discard session.postPlay()
    session.flushQueuedCommands()
  startLiveRecording(rec, recordStart)
  let started = getMonoTime()
  let limitMs = if scan.haveSeconds: int64(scan.seconds * 1000.0) else: -1'i64
  var lastMetric: LiveMetrics
  var haveMetric = false
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
    sleep(10)

  stopLiveRecording(rec)

  # Worker финализирует файл по rcStop. Ждём регион коротко; ждать вечно
  # нельзя — «повисший» writer не должен превращать запись в зависание.
  var regions: seq[LiveRegion] = @[]
  for _ in 0 ..< 200:
    for r in liveRecordedRegions(rec):
      regions.add r
    if regions.len > 0:
      break
    sleep(10)

  let dropped = liveDroppedFrames(rec)
  mgr.closeBackend()
  detachLiveRecorder(session)
  session.closeLiveSession()
  if haveProject:
    destroyScene(scene)
  closeLiveRecorder(rec)

  var finalPath = outPath
  var frames = 0'i64
  if regions.len > 0:
    frames = regions[0].lengthSamples
    let src = regions[0].filename
    if src != outPath:
      try:
        if fileExists(outPath):
          removeFile(outPath)
        moveFile(src, outPath)
      except CatchableError:
        finalPath = src
  else:
    return envError("запись не создала файл: " & outPath,
      "устройство не отдало входные кадры; проверьте `--channels`, " &
      "`--input-device` и `euterpia device list`")

  let elapsedMs = (getMonoTime() - started).inMilliseconds
  var body = %*{
    "path": finalPath,
    "project": scan.project,
    "backend": backend,
    "device": device,
    "inputDevice": scan.inputDevice,
    "sampleRate": sr,
    "blockSize": bs,
    "channels": scan.channels,
    "seconds": float64(elapsedMs) / 1000.0,
    "frames": frames,
    "droppedFrames": dropped,
    "inputXruns": (if haveMetric: int(lastMetric.inputXruns) else: 0),
    "countIn": scan.countIn,
    "exitReason": exitReason,
  }
  if haveMetric:
    body["inputPeakL"] = %lastMetric.inputPeakL
    body["inputPeakR"] = %lastMetric.inputPeakR

  var lines = @[
    "запись остановлена (" &
      (if exitReason == "seconds": "истекло --seconds"
       else: "сигнал завершения") & ")",
    "бэкенд: " & backend & ", выход: " & $device &
      ", вход: " & $scan.inputChannel & ", " & $sr & " Гц / " &
      $bs & " кадров",
    "кадров: " & $frames & ", потеряно: " & $dropped &
      ", файл: " & finalPath,
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

proc runRecordCmd*(ctx: var Ctx; args: seq[string]): Report =
  let scan = scanRecordArgs(args)
  if not scan.ok:
    return scan.rep
  runRecord(ctx, scan)

