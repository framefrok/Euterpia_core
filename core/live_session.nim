# core/live_session.nim
#
# Публичный API живого сеанса (issue #92).
#
# Зачем модуль: CLI не имеет права импортировать `audio_engine` и `ipc_bus`
# (§20, джоб `architecture`): это внутренности ядра. Но живому режиму нужен
# движок, его метрики и callback драйвера. Поэтому здесь — узкий фасад:
#
#   * владение `AudioEngine` и пайплайном;
#   * `liveRender`/`liveStatus` — ровно те cdecl-процедуры, которые ждёт
#     `AudioRenderProc`/`AudioStatusProc` адаптера;
#   * метрики в виде DTO `LiveMetrics`, а не внутреннего `EngineMetric`;
#   * команды транспорта и чтение позиции.
#
# Всё, что здесь есть, — control-path. Callback не аллоцирует и не логирует:
# он вызывает `renderBlock`/`noteStatus` ядра.

import
  audio_engine,
  compiled_pipeline,
  ipc_bus

{.push raises: [].}

type
  LiveMetrics* = object
    ## Снимок метрик для CLI/Editor. Копия `EngineMetric` без внутренних
    ## типов: клиент не должен тянуть `ipc_bus` ради полей.
    peakL*, peakR*, rmsL*, rmsR*: float32
    cpuLoad*: float32
    xruns*: uint32
    graphVersion*: uint64
    activeVoices*: int32
    transportState*: string
      ## `stopped`|`playing`|`recording`|`paused` — те же имена, что у CLI.

  LiveSession* = object
    ## Владелец движка в живом режиме. Адрес объекта передаётся драйверу,
    ## поэтому объект обязан жить на стабильном адресе (не копировать).
    engine*: ptr AudioEngine

proc engineStateName(s: ipc_bus.TransportState): string =
  case s
  of ipc_bus.tsStopped: "stopped"
  of ipc_bus.tsPlaying: "playing"
  of ipc_bus.tsRecording: "recording"
  of ipc_bus.tsPaused: "paused"

proc initLiveSession*(sampleRate: float32; blockSize: int32;
                      owned: sink OwnedPipeline): LiveSession =
  ## Создать движок и опубликовать граф. Пауза/игра — отдельными командами.
  ## При отказе публикации возвращается `engine == nil`, а владение
  ## пайплайном освобождает движок/ручка (как в `postGraphUpdate`).
  if sampleRate <= 0.0f or blockSize <= 0:
    return
  result.engine = createAudioEngine(sampleRate, blockSize)
  if result.engine.isNil:
    return
  if not result.engine.postGraphUpdate(move(owned)):
    destroyAudioEngine(result.engine)
    result.engine = nil

proc isActive*(s: LiveSession): bool {.inline.} =
  s.engine != nil

proc closeLiveSession*(s: var LiveSession) =
  if s.engine.isNil:
    return
  destroyAudioEngine(s.engine)
  s.engine = nil

# =============================================================================
# Callback драйвера
# =============================================================================

proc liveRender*(
  engineCtx: pointer;
  driverIn: ptr UncheckedArray[float32];
  driverOut: ptr UncheckedArray[float32];
  frames: int32;
  inputChannels: int32;
  outputChannels: int32
) {.cdecl, raises: [], gcsafe.} =
  ## Audio callback: без `$`, логов и аллокаций (§9, #4). `engineCtx` — это
  ## `ptr LiveSession`, переданный в `AudioStreamConfig`.
  discard outputChannels
  if engineCtx.isNil or driverOut.isNil:
    return
  let session = cast[ptr LiveSession](engineCtx)
  renderBlock(session.engine, driverIn, inputChannels, driverOut)

proc liveStatus*(engineCtx: pointer; statusFlags: uint32)
    {.cdecl, raises: [], gcsafe.} =
  ## Приёмник xrun'ов драйвера → счётчик движка (`noteStatus`, #4).
  if engineCtx.isNil:
    return
  let session = cast[ptr LiveSession](engineCtx)
  noteStatus(session.engine, statusFlags)

# =============================================================================
# Control-path
# =============================================================================

proc postPlay*(s: LiveSession): bool = postPlay(s.engine)

proc postStop*(s: LiveSession): bool = postStop(s.engine)

proc postSetTempo*(s: LiveSession; bpm: float64): bool =
  postSetTempo(s.engine, bpm)

proc postSetMeter*(s: LiveSession; numerator, denominator: int32): bool =
  postSetMeter(s.engine, numerator, denominator)

proc flushQueuedCommands*(s: LiveSession) =
  flushQueuedCommands(s.engine)

proc postSeekSamples*(s: LiveSession; frame: int64): bool =
  postSeekSamples(s.engine, frame)

proc pollReclamation*(s: LiveSession) =
  pollReclamation(s.engine)

proc currentFrame*(s: LiveSession): int64 = currentFrame(s.engine)

proc xrunCount*(s: LiveSession): uint32 = xrunCount(s.engine)

proc droppedMetrics*(s: LiveSession): uint32 = droppedMetricsCount(s.engine)

proc pollMetrics*(s: LiveSession; m: var LiveMetrics): bool =
  ## Прочитать последнюю метрику из очереди. `false` — новых снимков нет
  ## (очередь пуста), а не ошибка.
  var raw: EngineMetric
  if not pollMetrics(s.engine, raw):
    return false
  m.peakL = raw.peakL
  m.peakR = raw.peakR
  m.rmsL = raw.rmsL
  m.rmsR = raw.rmsR
  m.cpuLoad = raw.cpuLoad
  m.xruns = raw.xruns
  m.graphVersion = raw.graphVersion
  m.activeVoices = raw.activeVoices
  m.transportState = engineStateName(ipc_bus.TransportState(raw.transportState))
  true

{.pop.}
