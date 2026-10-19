# core/runtime_session.nim
#
# Headless runtime-сессия (issue #407, EUT-NEW-048).
#
# Проблема, которую решает модуль: CLI — процесс на одну команду, поэтому
# `transport play` не мог «оставить AudioEngine жить». Живая семантика
# (play/stop на устройстве, позиция, которая идёт между вызовами CLI)
# требует ДОЛГОЖИВУЩЕГО владельца движка.
#
# Здесь живёт этот владелец: `RuntimeSession` держит `AudioEngine`, принимает
# команды транспорта и продвигает время по стенным часам. Транспорт процесса-
# демона — единственный источник истины; CLI-клиент (`cli/session_ipc`) лишь
# передаёт команды и читает состояние.
#
# Почему Core, а не CLI:
#   * владение движком и команды транспорта — контракт ядра (§10);
#   * протокол — данные (JSON), а не сокеты: транспорт (Unix-socket) и
#     демонизация — забота клиента/хоста, а не DSP-ядра.
#
# Realtime-дисциплина: команды идут обычным путём control → queue → audio
# (`postPlay`/`postStop`/...), а `flushQueuedCommands` применяет их синхронно,
# потому что демон однопоточный и не рендерит в этот момент. Сам рендер
# (`tickRuntimeSession`) идёт через `renderBlock` — тот же audio-путь, что у
# драйвера, включая `rtScope` и запрет аллокаций.

import std/[json, math]
import
  audio_engine,
  ipc_bus,
  signal_types,
  transport

{.push raises: [].}

const
  RuntimeSessionApiVersion* = 1

type
  RuntimeSession* = object
    ## Владелец AudioEngine в headless-процессе.
    engine*: ptr AudioEngine
    sampleRate*: float32
    blockSize*: int32
    startedMs*: int64
    lastTickMs*: int64
      ## Время последнего `tickRuntimeSession` (монотонные миллисекунды).
    pendingFrames*: int64
      ## Накопленный остаток меньше блока: не рендерим «пол-блока» в
      ## realtime-пути, чтобы не менять семантику blockSize.
    scratch: seq[float32]

proc engineStateName(s: ipc_bus.TransportState): string =
  ## Стабильное имя состояния — то же, что `euterpia.transport.v1`.
  case s
  of ipc_bus.tsStopped: "stopped"
  of ipc_bus.tsPlaying: "playing"
  of ipc_bus.tsRecording: "recording"
  of ipc_bus.tsPaused: "paused"

proc initRuntimeSession*(sampleRate: float32; blockSize: int32;
                         tempo: float64 = 120.0;
                         meterNum: int32 = 4;
                         meterDen: int32 = 4): RuntimeSession =
  ## Создаёт движок и применяет начальные темп/размер. `engine == nil` —
  ## сессию создать не удалось (вызывающий обязан проверить).
  result.sampleRate = sampleRate
  result.blockSize = blockSize
  result.startedMs = 0
  result.lastTickMs = -1
  result.pendingFrames = 0

  if sampleRate <= 0.0f or blockSize <= 0 or
     blockSize > signal_types.MaxBlockSize:
    result.engine = nil
    return

  result.engine = createAudioEngine(sampleRate, blockSize)
  if result.engine == nil:
    return

  result.scratch = newSeq[float32](int(blockSize) * signal_types.MaxAudioChannels)

  if tempo > 0.0:
    discard result.engine.postSetTempo(tempo)
  if meterNum > 0 and meterDen > 0:
    discard result.engine.postSetMeter(meterNum, meterDen)
  # Применяем стартовые команды до первого RPC: состояние сессии должно быть
  # готовым, а не «доедет когда-нибудь».
  result.engine.flushQueuedCommands()

proc isActive*(s: RuntimeSession): bool {.inline.} =
  s.engine != nil

proc closeRuntimeSession*(s: var RuntimeSession) =
  ## Закрыть сессию: уничтожить движок (освобождает граф, входную арену и
  ## очереди — то же, что делает `destroyAudioEngine`). Идемпотентно.
  if s.engine != nil:
    destroyAudioEngine(s.engine)
    s.engine = nil
  s.scratch.setLen(0)
  s.pendingFrames = 0

proc positionJson(s: RuntimeSession): JsonNode =
  let frames = s.engine.currentFrame()
  var t = initTransport(s.sampleRate)
  t.setTempo(s.engine.currentTempo())
  let (num, den) = s.engine.currentTimeSignature()
  t.timeSignature = TimeSignature(numerator: num, denominator: den)
  let (bar, beat, tick) = t.sampleToBarBeatTick(frames)
  let sr = float64(s.sampleRate)
  let spq = t.samplesPerQuarter()
  %*{
    "frames": frames,
    "seconds": (if sr > 0.0: float64(frames) / sr else: 0.0),
    "bar": bar,
    "beat": beat,
    "tick": tick,
    "quarter": (if spq > 0.0: float64(frames) / spq else: 0.0),
  }

proc stateJson*(s: RuntimeSession): JsonNode =
  ## Состояние сессии в схеме `euterpia.transport.v1` — том же контракте,
  ## что у offline-транспорта. Клиент не различает «живой» и «offline» ответ.
  if s.engine == nil:
    return %*{"schema": TransportSessionSchema, "state": "stopped",
              "error": "сессия не создана"}
  let (num, den) = s.engine.currentTimeSignature()
  result = %*{
    "schema": TransportSessionSchema,
    "state": engineStateName(s.engine.transportState()),
    "position": s.positionJson(),
    "tempo": s.engine.currentTempo(),
    "meter": %*{"numerator": num, "denominator": den},
    "loop": %*{
      "enabled": s.engine.isLoopEnabled(),
      "startFrames": s.engine.loopStartFrame(),
      "endFrames": s.engine.loopEndFrame(),
    },
    "metrics": %*{
      "xruns": int(s.engine.xrunCount()),
      "cpuLoad": nil,
    },
    "sampleRate": s.sampleRate,
    "blockSize": s.blockSize,
  }

proc snapshotJson*(s: RuntimeSession): JsonNode =
  ## Рантайм-срез в форме offline-сессии (`transport.sessionSnapshotJson`):
  ## по нему `session stop` записывает финальное состояние рядом с проектом,
  ## чтобы после остановки `transport state` не показывал устаревшее «играет».
  if s.engine == nil:
    return %*{"schema": TransportSessionSchema, "state": "stopped",
              "samplePosition": 0,
              "loop": %*{"enabled": false, "startFrames": 0, "endFrames": 0}}
  %*{
    "schema": TransportSessionSchema,
    "state": engineStateName(s.engine.transportState()),
    "samplePosition": s.engine.currentFrame(),
    "loop": %*{
      "enabled": s.engine.isLoopEnabled(),
      "startFrames": s.engine.loopStartFrame(),
      "endFrames": s.engine.loopEndFrame(),
    },
  }

proc errorResponse(message: string): JsonNode {.inline.} =
  %*{"ok": false, "api": RuntimeSessionApiVersion, "error": message}

proc okResponse(s: RuntimeSession; command: string): JsonNode =
  %*{
    "ok": true,
    "api": RuntimeSessionApiVersion,
    "command": command,
    "state": s.stateJson(),
    "snapshot": s.snapshotJson(),
  }

proc applyRuntimeCommand*(s: var RuntimeSession; request: JsonNode;
                          stopRequested: var bool): JsonNode =
  ## Одна команда сессии. `request` — JSON-объект с полем `command`.
  ## Возвращает конверт ответа; `ok == false` — отказ, а не частичное
  ## применение.
  if request.kind != JObject:
    return errorResponse("запрос должен быть JSON-объектом")
  if request.hasKey("api"):
    let api = request{"api"}.getInt()
    if api != RuntimeSessionApiVersion:
      return errorResponse("версия API сессии не поддерживается: " & $api)
  if s.engine == nil:
    return errorResponse("сессия не создана")

  let command = request{"command"}.getStr()
  if command.len == 0:
    return errorResponse("не указана команда")

  case command
  of "ping", "transport.state", "transport.position":
    discard

  of "transport.play":
    if not s.engine.postPlay():
      return errorResponse("очередь команд переполнена")

  of "transport.pause":
    if not s.engine.postPause():
      return errorResponse("очередь команд переполнена")

  of "transport.stop":
    if not s.engine.postStop():
      return errorResponse("очередь команд переполнена")

  of "transport.seek":
    if request.hasKey("frames"):
      if not s.engine.postSeekSamples(request{"frames"}.getBiggestInt()):
        return errorResponse("не удалось задать позицию")
    elif request.hasKey("seconds"):
      if not s.engine.postSeekSeconds(request{"seconds"}.getFloat()):
        return errorResponse("не удалось задать позицию")
    else:
      return errorResponse("transport.seek: нужен `frames` или `seconds`")

  of "transport.loop":
    let enabled = request{"enabled"}.getBool(true)
    var startFrame = s.engine.loopStartFrame()
    var endFrame = s.engine.loopEndFrame()
    if request.hasKey("startFrame"):
      startFrame = request{"startFrame"}.getBiggestInt()
    if request.hasKey("endFrame"):
      endFrame = request{"endFrame"}.getBiggestInt()
    if enabled and endFrame <= startFrame:
      return errorResponse("transport.loop: конец должен быть больше начала")
    if not s.engine.postSetLoop(enabled, startFrame, endFrame):
      return errorResponse("очередь команд переполнена")

  of "engine.tempo":
    let tempo = request{"tempo"}.getFloat()
    if tempo <= 0.0:
      return errorResponse("engine.tempo: темп должен быть положительным")
    if not s.engine.postSetTempo(tempo):
      return errorResponse("очередь команд переполнена")

  of "engine.meter":
    let num = request{"numerator"}.getInt()
    let den = request{"denominator"}.getInt()
    if not s.engine.postSetMeter(num.int32, den.int32):
      return errorResponse("engine.meter: некорректный размер")
  of "session.stop":
    stopRequested = true

  else:
    return errorResponse("неизвестная команда сессии: " & command)

  # Демон однопоточный: команды применяются сразу, чтобы ответ отражал
  # НАМЕРЕНИЕ и состояние не расходились.
  s.engine.flushQueuedCommands()
  okResponse(s, command)

proc tickRuntimeSession*(s: var RuntimeSession; nowMs: int64) =
  ## Продвинуть время сессии по стенным часам.
  ##
  ## Пока транспорт играет/пишет, рендерим столько полных блоков, сколько
  ## прошло времени. Это тот же `renderBlock`, что у драйвера, поэтому
  ## позиция и метрики ведут себя одинаково; без устройства звук просто
  ## никуда не выводится.
  if s.engine == nil:
    return

  if s.startedMs == 0:
    s.startedMs = nowMs

  if s.lastTickMs < 0:
    s.lastTickMs = nowMs
    return

  let elapsed = nowMs - s.lastTickMs
  s.lastTickMs = nowMs
  if elapsed <= 0:
    return

  let state = s.engine.transportState()
  if state notin {ipc_bus.tsPlaying, ipc_bus.tsRecording}:
    # На паузе/стопе время не копится: иначе после play был бы «прыжок».
    s.pendingFrames = 0
    return

  # Метрики некому читать — дренируем, чтобы очередь не забивалась.
  var metric: EngineMetric
  while s.engine.pollMetrics(metric):
    discard

  s.pendingFrames += (elapsed * int64(s.sampleRate)) div 1000
  let outBuf = cast[ptr UncheckedArray[float32]](addr s.scratch[0])
  while s.pendingFrames >= int64(s.blockSize):
    s.engine.renderBlock(outBuf)
    s.pendingFrames -= int64(s.blockSize)

proc startTimeMs*(s: var RuntimeSession; nowMs: int64) {.inline.} =
  ## Зафиксировать старт сессии (монотонные мс). Вызывает хост-демон.
  ## Момент последнего тика ставит первый `tickRuntimeSession`: так старт
  ## можно зафиксировать в 0 без «пустого» первого интервала.
  if s.startedMs == 0:
    s.startedMs = nowMs

{.pop.}

