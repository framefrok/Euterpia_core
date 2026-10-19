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
  audio_recorder,
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
    inputPeakL*, inputPeakR*: float32
      ## Пики входного тракта (issue #94): по сырому буферу драйвера.
    inputXruns*: uint32

  LiveSession* = object
    ## Владелец движка в живом режиме. Адрес объекта передаётся драйверу,
    ## поэтому объект обязан жить на стабильном адресе (не копировать).
    engine*: ptr AudioEngine

  LiveRecorder* = object
    ## Запись входа (issue #94). Владелец — CLI: движок держит только
    ## указатель (`attachLiveRecorder`) и обязан быть отсоединён до
    ## уничтожения рекордера.
    rec*: AudioRecorder
    trackId*: int32

  LiveRegion* = audio_recorder.RecordedRegion
    ## Завершённый регион записи — DTO без внутренних структур рекордера.

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
# Запись входа (issue #94)
# =============================================================================
#
# CLI не импортирует `audio_recorder` (§20): он получает этот узкий фасад.
# Владение остаётся у CLI, движок хранит только указатель — контракт
# `attachRecorder`/`detachRecorder` не меняется.

proc initLiveRecorder*(r: var LiveRecorder; sampleRate, blockSize: int32;
                       outputDir: string; inputChannels: int32 = 1;
                       ringFrames: int32 = 65536)
    {.raises: [CatchableError].} =
  ## Создать рекордер и один трек записи. Поток записи запускается здесь
  ## же (control-path), до открытия аудиопотока — иначе первые блоки
  ## потерялись бы на создании файла.
  r.rec = default(AudioRecorder)
  initAudioRecorder(r.rec, sampleRate, blockSize, outputDir,
                    inputChannels, ringFrames)
  r.trackId = 1

proc addLiveRecorderTrack*(r: var LiveRecorder; inputChannel: int32 = 0;
                           channels: int32 = 1;
                           preRollFrames: int32 = 0): bool =
  ## Вооружаемый трек: канал входа, ширина (1/2) и pre-roll.
  addTrackRecorder(r.rec, r.trackId, inputChannel, channels, preRollFrames)

proc armLiveRecorder*(r: var LiveRecorder) =
  armTrack(r.rec, r.trackId)

proc startLiveRecording*(r: var LiveRecorder; currentSample: int64) =
  startRecording(r.rec, currentSample)

proc stopLiveRecording*(r: var LiveRecorder) =
  stopRecording(r.rec)

proc liveRecordedRegions*(r: var LiveRecorder): seq[LiveRegion] =
  getRecordedRegions(r.rec)

proc liveDroppedFrames*(r: var LiveRecorder): int64 =
  getTrackDroppedFrames(r.rec, r.trackId)

proc isLiveRecording*(r: var LiveRecorder): bool =
  isRecording(r.rec)

proc closeLiveRecorder*(r: var LiveRecorder) =
  destroyAudioRecorder(r.rec)

proc attachLiveRecorder*(s: LiveSession; r: var LiveRecorder) =
  ## Движок начинает вызывать `recordBlock`. Рекордер обязан пережить
  ## отсоединение: сначала `detachLiveRecorder`, потом `closeLiveRecorder`.
  attachRecorder(s.engine, addr r.rec)

proc detachLiveRecorder*(s: LiveSession) =
  detachRecorder(s.engine)

proc setLiveInputChannels*(s: LiveSession; channels: int32) =
  ## Сколько каналов входа у открытого устройства (0 — входа нет).
  setInputChannels(s.engine, channels)

proc initEmptyLiveSession*(sampleRate: float32; blockSize: int32): LiveSession =
  ## Сеанс без графа: запись входа не нуждается в нодах, но движку нужен
  ## опубликованный (пустой) пайплайн — публикация пустого разрешена §402.
  initLiveSession(sampleRate, blockSize, newOwnedPipeline())

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
  m.inputPeakL = raw.inputPeakL
  m.inputPeakR = raw.inputPeakR
  m.inputXruns = raw.inputXruns
  m.transportState = engineStateName(ipc_bus.TransportState(raw.transportState))
  true

{.pop.}
