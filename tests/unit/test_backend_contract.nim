# tests/unit/test_backend_contract.nim
#
# Контракт аудио-бэкенда (MANIFEST §40, §41, §42).
#
# Главное утверждение теста: Core управляет аудиоустройством через таблицу
# методов audio_backend_api и не знает, PortAudio там, JACK или ничего.
#
# Fake-бэкенд определён здесь же, поэтому тест:
#   - не требует установленной libportaudio;
#   - не открывает настоящее устройство;
#   - воспроизводит поведение драйвера детерминированно (pump вместо потока).

import std/[unittest, atomics]
import audio_backend_api
import audio_engine
import ipc_bus

const
  FakeBlockSize = 128
  FakeOutChannels = 2

type
  FakeBackend = object
    ## Состояние «драйвера». Аллоцируется в shared-куче.
    opened: bool
    running: bool
    render: AudioRenderProc
    engineCtx: pointer
    ## Приёмник xrun'ов, как у реальных адаптеров (issue #4).
    reportStatus: AudioStatusProc
    outChannels: int32
    xruns: Atomic[uint64]
    pumpedBlocks: Atomic[uint64]

proc fakeImpl(api: ptr AudioBackendApi): ptr FakeBackend {.inline.} =
  if api.isNil:
    return nil
  cast[ptr FakeBackend](api.impl)

# ----------------------------------------------------------------------------
# Реализация таблицы методов
# ----------------------------------------------------------------------------

proc fakeInit(api: ptr AudioBackendApi; log: ptr Logger): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  abeOk

proc fakeShutdown(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let fb = fakeImpl(api)
  if fb.isNil:
    return
  fb.opened = false
  fb.running = false

proc fakeOpen(
  api: ptr AudioBackendApi;
  cfg: AudioStreamConfig;
  render: AudioRenderProc;
  engineCtx: pointer
): AudioBackendError {.cdecl, raises: [], gcsafe.} =
  let fb = fakeImpl(api)
  if fb.isNil or render.isNil:
    return abeUnavailable

  if fb.opened:
    return abeOpenFailed

  if cfg.outputChannels <= 0:
    return abeNoDevice

  fb.render = render
  fb.engineCtx = engineCtx
  fb.reportStatus = cfg.reportStatus
  fb.outChannels = cfg.outputChannels
  fb.opened = true
  abeOk

proc fakeStart(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let fb = fakeImpl(api)
  if fb.isNil or not fb.opened:
    return abeNotOpen
  fb.running = true
  abeOk

proc fakeStop(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let fb = fakeImpl(api)
  # Как и PortAudio-адаптер: stop на неоткрытом потоке — это abeNotOpen,
  # а не «тихий успех». Контракт должен быть одинаковым у всех адаптеров.
  if fb.isNil or not fb.opened:
    return abeNotOpen
  fb.running = false
  abeOk

proc fakeClose(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let fb = fakeImpl(api)
  if fb.isNil:
    return
  fb.opened = false
  fb.running = false
  fb.render = nil
  fb.engineCtx = nil
  fb.reportStatus = nil

proc fakeIsRunning(api: ptr AudioBackendApi): bool
    {.cdecl, raises: [], gcsafe.} =
  let fb = fakeImpl(api)
  if fb.isNil:
    return false
  fb.running

proc fakeDeviceCount(api: ptr AudioBackendApi; wantInput: bool): int32
    {.cdecl, raises: [], gcsafe.} =
  if wantInput: 1'i32 else: 2'i32

proc fakeDeviceInfo(
  api: ptr AudioBackendApi;
  index: int32;
  wantInput: bool;
  info: var AudioDeviceInfo
): bool {.cdecl, raises: [], gcsafe.} =
  if index < 0 or index > 1:
    return false
  info.id = index
  info.name = if wantInput: "fake input" else: "fake output"
  info.maxInputChannels = 1
  info.maxOutputChannels = 2
  info.defaultSampleRate = 48000.0
  info.defaultLowInputLatency = 0.01
  info.defaultLowOutputLatency = 0.01
  info.isDefault = index == 0
  true

proc fakeXrunCount(api: ptr AudioBackendApi): uint64
    {.cdecl, raises: [], gcsafe.} =
  let fb = fakeImpl(api)
  if fb.isNil:
    return 0'u64
  fb.xruns.load(moRelaxed)

proc fakeLatencyFrames(api: ptr AudioBackendApi): int32
    {.cdecl, raises: [], gcsafe.} =
  128'i32

# ----------------------------------------------------------------------------
# Создание / уничтожение и «драйвер» для тестов
# ----------------------------------------------------------------------------

proc fakeCreate(): ptr AudioBackendApi =
  let api = cast[ptr AudioBackendApi](allocShared0(sizeof(AudioBackendApi)))
  let fb = cast[ptr FakeBackend](allocShared0(sizeof(FakeBackend)))

  if api.isNil or fb.isNil:
    if not api.isNil:
      deallocShared(cast[pointer](api))
    if not fb.isNil:
      deallocShared(cast[pointer](fb))
    return nil

  api.backendName = cstring"fake"
  api.impl = cast[pointer](fb)

  api.init = fakeInit
  api.shutdown = fakeShutdown
  api.open = fakeOpen
  api.start = fakeStart
  api.stop = fakeStop
  api.close = fakeClose
  api.isRunning = fakeIsRunning
  api.deviceCount = fakeDeviceCount
  api.deviceInfo = fakeDeviceInfo
  api.xrunCount = fakeXrunCount
  api.latencyFrames = fakeLatencyFrames

  api

proc fakeDestroy(api: ptr AudioBackendApi) =
  if api.isNil:
    return
  backendShutdown(api)
  let fb = fakeImpl(api)
  if not fb.isNil:
    api.impl = nil
    deallocShared(cast[pointer](fb))
  deallocShared(cast[pointer](api))

proc fakePump(
  api: ptr AudioBackendApi;
  buf: ptr UncheckedArray[float32];
  frames: int32;
  statusFlags: uint64 = 0'u64
) =
  ## Аналог вызова audio callback драйвером. В тесте поток не нужен:
  ## блоки «прокручиваются» вручную, поэтому результат детерминирован.
  let fb = fakeImpl(api)
  if fb.isNil or not fb.running or fb.render.isNil or buf.isNil:
    return

  if statusFlags != 0'u64:
    discard fb.xruns.fetchAdd(1'u64, moRelaxed)
    # Как реальные адаптеры: сообщаем движку ДО render, чтобы xrun попал
    # именно в метрику этого блока (issue #4).
    if not fb.reportStatus.isNil:
      fb.reportStatus(fb.engineCtx, uint32(statusFlags))

  discard fb.pumpedBlocks.fetchAdd(1'u64, moRelaxed)
  fb.render(fb.engineCtx, nil, buf, frames, 0, fb.outChannels)

proc fakePumped(api: ptr AudioBackendApi): uint64 =
  let fb = fakeImpl(api)
  if fb.isNil:
    return 0'u64
  fb.pumpedBlocks.load(moRelaxed)

proc fakeConfig(
  outChannels: int32 = int32(FakeOutChannels);
  inChannels: int32 = 0
): AudioStreamConfig =
  AudioStreamConfig(
    sampleRate: 48000.0,
    blockSize: int32(FakeBlockSize),
    inputChannels: inChannels,
    outputChannels: outChannels,
    inputDevice: DefaultDeviceIndex,
    outputDevice: DefaultDeviceIndex
  )

# ----------------------------------------------------------------------------
# Тесты
# ----------------------------------------------------------------------------

proc engineRender(
  engineCtx: pointer;
  driverIn: ptr UncheckedArray[float32];
  driverOut: ptr UncheckedArray[float32];
  frames: int32;
  inputChannels: int32;
  outputChannels: int32
) {.cdecl, raises: [].} =
  ## Мост «контракт бэкенда -> AudioEngine».
  ##
  ## Ровно это и делает продакшн-код: адаптер не знает про AudioEngine,
  ## а Core не знает про PortAudio.
  let engine = cast[ptr AudioEngine](engineCtx)
  if engine.isNil or driverOut.isNil:
    return
  engine.renderBlock(driverOut)

suite "audio_backend_api":
  test "нулевой указатель даёт код ошибки, а не падение":
    check backendInit(nil, nil) == abeUnavailable
    check backendOpen(nil, fakeConfig(), engineRender, nil) == abeUnavailable
    check backendStart(nil) == abeUnavailable
    check backendStop(nil) == abeOk
    check backendIsRunning(nil) == false
    check backendDeviceCount(nil, true) == 0
    var info: AudioDeviceInfo
    check backendDeviceInfo(nil, 0, true, info) == false
    check backendXrunCount(nil) == 0'u64
    check backendLatencyFrames(nil) == 0
    check backendNameOf(nil) == "none"
    backendClose(nil)
    backendShutdown(nil)

  test "адаптер заполняет всю таблицу методов":
    let api = fakeCreate()
    check api != nil
    check backendNameOf(api) == "fake"
    check api.init != nil
    check api.shutdown != nil
    check api.open != nil
    check api.start != nil
    check api.stop != nil
    check api.close != nil
    check api.isRunning != nil
    check api.deviceCount != nil
    check api.deviceInfo != nil
    check api.xrunCount != nil
    check api.latencyFrames != nil
    fakeDestroy(api)

  test "перечисление устройств идёт через контракт":
    let api = fakeCreate()
    check backendDeviceCount(api, false) == 2
    check backendDeviceCount(api, true) == 1

    var info: AudioDeviceInfo
    check backendDeviceInfo(api, 0, false, info)
    check info.name == "fake output"
    check info.maxOutputChannels == 2
    check info.isDefault
    check backendDeviceInfo(api, 7, false, info) == false
    fakeDestroy(api)

  test "open -> start -> pump -> stop -> close":
    let api = fakeCreate()
    check backendOpen(api, fakeConfig(), engineRender, nil) == abeOk
    check backendIsRunning(api) == false
    check backendStart(api) == abeOk
    check backendIsRunning(api)

    var buf: array[FakeBlockSize * FakeOutChannels, float32]
    let p = cast[ptr UncheckedArray[float32]](addr buf[0])

    fakePump(api, p, int32(FakeBlockSize))
    check fakePumped(api) == 1'u64

    check backendStop(api) == abeOk
    check backendIsRunning(api) == false

    # после stop драйвер больше не рендерит
    fakePump(api, p, int32(FakeBlockSize))
    check fakePumped(api) == 1'u64

    backendClose(api)
    fakeDestroy(api)

  test "повторный open без close отклоняется":
    let api = fakeCreate()
    check backendOpen(api, fakeConfig(), engineRender, nil) == abeOk
    check backendOpen(api, fakeConfig(), engineRender, nil) == abeOpenFailed

    backendClose(api)

    # после close поток открывается снова
    check backendOpen(api, fakeConfig(), engineRender, nil) == abeOk
    backendClose(api)
    fakeDestroy(api)

  test "start и stop без open отклоняются":
    let api = fakeCreate()
    check backendStart(api) == abeNotOpen
    check backendStop(api) == abeNotOpen
    fakeDestroy(api)

  test "нулевое число выходных каналов не открывается":
    let api = fakeCreate()
    check backendOpen(api, fakeConfig(outChannels = 0), engineRender, nil) == abeNoDevice
    fakeDestroy(api)

  test "status flags драйвера попадают в xrun-счётчик":
    let api = fakeCreate()
    check backendOpen(api, fakeConfig(), engineRender, nil) == abeOk
    check backendStart(api) == abeOk

    var buf: array[FakeBlockSize * FakeOutChannels, float32]
    let p = cast[ptr UncheckedArray[float32]](addr buf[0])

    check backendXrunCount(api) == 0'u64

    fakePump(api, p, int32(FakeBlockSize))
    check backendXrunCount(api) == 0'u64

    # output-underflow: ровно один xrun за блок
    fakePump(api, p, int32(FakeBlockSize), statusFlags = 0x00000004'u64)
    check backendXrunCount(api) == 1'u64

    fakePump(api, p, int32(FakeBlockSize), statusFlags = 0x00000004'u64)
    check backendXrunCount(api) == 2'u64

    backendClose(api)
    fakeDestroy(api)

suite "audio_backend_api + AudioEngine":
  test "fake-бэкенд прокручивает настоящий AudioEngine":
    let engine = createAudioEngine(
      sampleRate = 48000.0f,
      blockSize = int32(FakeBlockSize)
    )
    check engine != nil

    let api = fakeCreate()
    check backendOpen(
      api, fakeConfig(), engineRender, cast[pointer](engine)
    ) == abeOk
    check backendStart(api) == abeOk

    var buf: array[FakeBlockSize * FakeOutChannels, float32]
    let p = cast[ptr UncheckedArray[float32]](addr buf[0])

    check engine.postPlay()

    fakePump(api, p, int32(FakeBlockSize))
    check engine.currentFrame() == int64(FakeBlockSize)

    # графа нет: движок обязан очистить мастер-выход
    for i in 0 ..< buf.len:
      check buf[i] == 0.0f

    fakePump(api, p, int32(FakeBlockSize))
    check engine.currentFrame() == int64(FakeBlockSize * 2)
    check fakePumped(api) == 2'u64

    check engine.postStop()

    backendClose(api)
    fakeDestroy(api)
    destroyAudioEngine(engine)


# ---------------------------------------------------------------------------
# Xruns доходят до EngineMetric (issue #4)
# ---------------------------------------------------------------------------

const
  ## paOutputUnderflow в терминах PortAudio. Обязан совпадать с битом
  ## AudioStreamFlag.asfOutputUnderflow — на этом стоит контракт
  ## cfg.reportStatus.
  FakeOutputUnderflowFlag = 0x00000004'u32

proc engineReportStatus(engineCtx: pointer; statusFlags: uint32)
    {.cdecl, raises: [].} =
  ## Хост передаёт сюда `engine.noteStatus` — адаптер о AudioEngine не знает.
  noteStatus(cast[ptr AudioEngine](engineCtx), statusFlags)

suite "audio_backend_api + AudioEngine: xruns (#4)":
  test "контракт: статус-флаг PortAudio совпадает с битом AudioStreamFlag":
    check FakeOutputUnderflowFlag == statusFlagMask(asfOutputUnderflow)
    check 0x00000002'u32 == statusFlagMask(asfInputOverflow)
    check 0x00000008'u32 == statusFlagMask(asfOutputOverflow)

  test "xrun драйвера доходит до EngineMetric ровно один раз за блок":
    let engine = createAudioEngine(
      sampleRate = 48000.0f,
      blockSize = int32(FakeBlockSize)
    )
    check engine != nil

    let api = fakeCreate()
    var cfg = fakeConfig()
    cfg.reportStatus = engineReportStatus
    check backendOpen(api, cfg, engineRender, cast[pointer](engine)) == abeOk
    check backendStart(api) == abeOk

    var buf: array[FakeBlockSize * FakeOutChannels, float32]
    let p = cast[ptr UncheckedArray[float32]](addr buf[0])
    var m: EngineMetric

    # Чистый блок: ни xrun'ов, ни статус-флагов.
    fakePump(api, p, int32(FakeBlockSize))
    check engine.pollMetrics(m)
    check m.xruns == 0'u32
    check m.driverStatusFlags == 0'u64
    check engine.xrunCount() == 0'u32
    check engine.driverStatusFlags() == 0'u64

    # output-underflow: ровно один xrun за блок.
    fakePump(api, p, int32(FakeBlockSize), statusFlags = uint64(FakeOutputUnderflowFlag))
    check engine.pollMetrics(m)
    check m.xruns == 1'u32
    check m.driverStatusFlags == uint64(FakeOutputUnderflowFlag)
    check engine.xrunCount() == 1'u32
    check engine.driverStatusFlags() == uint64(FakeOutputUnderflowFlag)

    # Метрика — ДЕЛЬТА за блок, тотал — монотонный.
    fakePump(api, p, int32(FakeBlockSize))
    check engine.pollMetrics(m)
    check m.xruns == 0'u32
    check engine.xrunCount() == 1'u32
    # «Какие xrun'ы наблюдались» накапливается: это не дельта.
    check m.driverStatusFlags == uint64(FakeOutputUnderflowFlag)

    # Второй xrun -> дельта снова 1, тотал 2.
    fakePump(api, p, int32(FakeBlockSize), statusFlags = uint64(FakeOutputUnderflowFlag))
    check engine.pollMetrics(m)
    check m.xruns == 1'u32
    check engine.xrunCount() == 2'u32

    backendClose(api)
    fakeDestroy(api)
    destroyAudioEngine(engine)

  test "входной статус (noteInputStatus) тоже виден в общей метрике":
    let engine = createAudioEngine(
      sampleRate = 48000.0f,
      blockSize = int32(FakeBlockSize)
    )
    check engine != nil
    defer: destroyAudioEngine(engine)

    # Как это делает адаптер входного тракта: отдельный счётчик входа + тотал.
    let flags = statusFlagMask(asfInputOverflow)
    engine.noteInputStatus(flags)
    check engine.inputXrunCount() == 1'u32
    check engine.xrunCount() == 1'u32

    var m: EngineMetric
    let api = fakeCreate()
    check backendOpen(api, fakeConfig(), engineRender, cast[pointer](engine)) == abeOk
    check backendStart(api) == abeOk
    var buf: array[FakeBlockSize * FakeOutChannels, float32]
    let p = cast[ptr UncheckedArray[float32]](addr buf[0])
    fakePump(api, p, int32(FakeBlockSize))
    check engine.pollMetrics(m)
    check m.xruns == 1'u32
    check m.inputXruns == 1'u32
    check m.driverStatusFlags == uint64(flags)
    backendClose(api)
    fakeDestroy(api)

  test "чистый прогон 10 000 блоков: xrun'ов нет":
    let engine = createAudioEngine(
      sampleRate = 48000.0f,
      blockSize = int32(FakeBlockSize)
    )
    check engine != nil

    let api = fakeCreate()
    var cfg = fakeConfig()
    cfg.reportStatus = engineReportStatus
    check backendOpen(api, cfg, engineRender, cast[pointer](engine)) == abeOk
    check backendStart(api) == abeOk

    var buf: array[FakeBlockSize * FakeOutChannels, float32]
    let p = cast[ptr UncheckedArray[float32]](addr buf[0])
    var m: EngineMetric

    for i in 0 ..< 10_000:
      fakePump(api, p, int32(FakeBlockSize))
      # Метрик-очередь ограничена: дренируем каждый блок.
      while engine.pollMetrics(m):
        check m.xruns == 0'u32

    check engine.xrunCount() == 0'u32
    check engine.driverStatusFlags() == 0'u64
    check backendXrunCount(api) == 0'u64

    backendClose(api)
    fakeDestroy(api)
    destroyAudioEngine(engine)

