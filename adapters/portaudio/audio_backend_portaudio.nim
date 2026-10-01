# adapters/portaudio/audio_backend_portaudio.nim
#
# Адаптер PortAudio для audio_backend_api.
#
# Это ЕДИНСТВЕННЫЙ файл дерева, который знает про PortAudio
# (MANIFEST §41, §42). Core о нём не знает: он видит только таблицу
# методов AudioBackendApi.
#
# Отличия от прежней версии, лежавшей в core/audio_backend.nim:
# - нет ни одного echo: диагностика идёт через Logger (MANIFEST §6, §43);
# - статус-флаги драйвера больше не выбрасываются: они считаются в
#   xrun-счётчике адаптера (issue #4);
# - входной путь присутствует в контракте render (driverIn), но пока
#   не заполняется — это отдельная задача (issue #3);
# - повторный open без close отклоняется, а не молча перезаписывает поток.

import std/atomics
import audio_backend_api
import logger

when defined(windows):
  const PortAudioLib = "portaudio_x64.dll"
elif defined(macosx):
  const PortAudioLib = "libportaudio.dylib"
else:
  const PortAudioLib = "libportaudio.so"

# ==============================================================================
# PortAudio C ABI
# ==============================================================================

type
  PaStream = pointer
  PaError = cint
  PaSampleFormat = culong

  PaDeviceInfo {.bycopy.} = object
    structVersion: cint
    name: cstring
    hostApi: cint
    maxInputChannels: cint
    maxOutputChannels: cint
    defaultLowInputLatency: cdouble
    defaultLowOutputLatency: cdouble
    defaultHighInputLatency: cdouble
    defaultHighOutputLatency: cdouble
    defaultSampleRate: cdouble

  PaStreamParameters {.bycopy.} = object
    device: cint
    channelCount: cint
    sampleFormat: PaSampleFormat
    suggestedLatency: cdouble
    hostApiSpecificStreamInfo: pointer

  PaStreamCallback = proc(
    input: pointer,
    output: pointer,
    frameCount: culong,
    timeInfo: pointer,
    statusFlags: culong,
    userData: pointer
  ): cint {.cdecl.}

{.pragma: pa_import, importc, dynlib: PortAudioLib.}

proc Pa_Initialize(): PaError {.pa_import.}
proc Pa_Terminate(): PaError {.pa_import.}
proc Pa_GetDefaultOutputDevice(): cint {.pa_import.}
proc Pa_GetDefaultInputDevice(): cint {.pa_import.}
proc Pa_GetDeviceCount(): cint {.pa_import.}
proc Pa_GetDeviceInfo(device: cint): ptr PaDeviceInfo {.pa_import.}
proc Pa_OpenStream(
  stream: ptr PaStream,
  inputParameters: ptr PaStreamParameters,
  outputParameters: ptr PaStreamParameters,
  sampleRate: cdouble,
  framesPerBuffer: culong,
  streamFlags: culong,
  streamCallback: PaStreamCallback,
  userData: pointer
): PaError {.pa_import.}
proc Pa_StartStream(stream: PaStream): PaError {.pa_import.}
proc Pa_StopStream(stream: PaStream): PaError {.pa_import.}
proc Pa_CloseStream(stream: PaStream): PaError {.pa_import.}
proc Pa_IsStreamActive(stream: PaStream): PaError {.pa_import.}
proc Pa_GetErrorText(errorCode: PaError): cstring {.pa_import.}

const
  paFloat32: PaSampleFormat = 0x00000001'u64
  paNoFlag: culong = 0'u64

  paInputUnderflow: culong = 0x00000001'u64
  paInputOverflow: culong = 0x00000002'u64
  paOutputUnderflow: culong = 0x00000004'u64
  paOutputOverflow: culong = 0x00000008'u64

  paStatusMask: culong =
    paInputUnderflow or paInputOverflow or paOutputUnderflow or paOutputOverflow

  DefaultAdaptiveLatency = 0.01

# ==============================================================================
# Состояние адаптера
# ==============================================================================

type
  PortAudioBackend = object
    ## Владеет потоком PortAudio и счётчиками диагностики.
    ##
    ## Аллоцируется в shared-куче: указатель уходит в audio callback.
    ##
    ## Объект не содержит GC-полей, поэтому его можно размещать в
    ## shared-памяти и передавать между потоками.
    stream: PaStream
    render: AudioRenderProc
    engineCtx: pointer

    log: Logger

    requestedInputChannels: int32
    requestedOutputChannels: int32
    requestedLatencyFrames: int32

    paInitialized: bool
    opened: bool
    running: bool
    sampleRate: float64

    ## Диагностика. Пишется из audio callback, читается с control-path.
    xruns: Atomic[uint64]
    lastStatusFlags: Atomic[uint64]

proc implOf(api: ptr AudioBackendApi): ptr PortAudioBackend {.inline.} =
  if api.isNil:
    return nil
  cast[ptr PortAudioBackend](api.impl)

proc describe(err: PaError): string =
  ## Текст ошибки PortAudio. Вызывается только на control-path.
  let txt = Pa_GetErrorText(err)
  if txt.isNil: "unknown error" else: $txt

# ==============================================================================
# Audio callback
# ==============================================================================

proc paCallback(
  input: pointer,
  output: pointer,
  frameCount: culong,
  timeInfo: pointer,
  statusFlags: culong,
  userData: pointer
): cint {.cdecl.} =
  ## Выполняется в аудио-потоке.
  ##
  ## Запрещено: аллокации, локи, файловый I/O, логирование.
  ## Разрешено: запись в атомарные счётчики и вызов render.
  let pb = cast[ptr PortAudioBackend](userData)

  if pb.isNil:
    return 0

  if (statusFlags and paStatusMask) != 0'u64:
    discard pb.xruns.fetchAdd(1'u64, moRelaxed)
    discard pb.lastStatusFlags.fetchOr(uint64(statusFlags), moRelaxed)

  let render = pb.render
  if render.isNil:
    # Поток открыт, но рендер не привязан: отдаём тишину.
    if output != nil and pb.requestedOutputChannels > 0:
      let outBuf = cast[ptr UncheckedArray[float32]](output)
      let total = int(frameCount) * int(pb.requestedOutputChannels)
      var i = 0
      while i < total:
        outBuf[i] = 0.0f
        inc i
    return 0

  let inBuf =
    if input.isNil: nil
    else: cast[ptr UncheckedArray[float32]](input)

  let outBuf =
    if output.isNil: nil
    else: cast[ptr UncheckedArray[float32]](output)

  render(
    pb.engineCtx,
    inBuf,
    outBuf,
    int32(frameCount),
    pb.requestedInputChannels,
    pb.requestedOutputChannels
  )

  0

# ==============================================================================
# Таблица методов
# ==============================================================================

proc paInit(api: ptr AudioBackendApi; log: ptr Logger): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return abeUnavailable

  if not log.isNil:
    pb.log = log[]

  if pb.paInitialized:
    return abeOk

  let err = Pa_Initialize()
  if err != 0:
    logError(addr pb.log, "portaudio: Pa_Initialize failed: " & describe(err))
    return abeInitFailed

  pb.paInitialized = true
  logInfo(addr pb.log, "portaudio: initialized")
  abeOk

proc paOpen(
  api: ptr AudioBackendApi;
  cfg: AudioStreamConfig;
  render: AudioRenderProc;
  engineCtx: pointer
): AudioBackendError {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.paInitialized:
    return abeNotOpen

  if render.isNil or cfg.outputChannels <= 0:
    return abeOpenFailed

  # Повторный open без close запрещён: молчаливая перезапись потока
  # оставляет висеть старый callback.
  if pb.opened:
    return abeOpenFailed

  let outDev =
    if cfg.outputDevice >= 0: cfg.outputDevice
    else: Pa_GetDefaultOutputDevice()

  if outDev < 0:
    logError(addr pb.log, "portaudio: no output device")
    return abeNoDevice

  var outParams: PaStreamParameters
  outParams.device = outDev
  outParams.channelCount = cfg.outputChannels
  outParams.sampleFormat = paFloat32
  outParams.hostApiSpecificStreamInfo = nil

  if cfg.suggestedOutputLatency > 0.0:
    outParams.suggestedLatency = cfg.suggestedOutputLatency
  else:
    let info = Pa_GetDeviceInfo(outDev)
    outParams.suggestedLatency =
      if info.isNil: DefaultAdaptiveLatency
      else: info.defaultLowOutputLatency

  var inParams: PaStreamParameters
  var inParamsPtr: ptr PaStreamParameters = nil

  if cfg.inputChannels > 0:
    let inDev =
      if cfg.inputDevice >= 0: cfg.inputDevice
      else: Pa_GetDefaultInputDevice()

    if inDev < 0:
      logError(addr pb.log, "portaudio: no input device")
      return abeNoDevice

    inParams.device = inDev
    inParams.channelCount = cfg.inputChannels
    inParams.sampleFormat = paFloat32
    inParams.hostApiSpecificStreamInfo = nil

    if cfg.suggestedInputLatency > 0.0:
      inParams.suggestedLatency = cfg.suggestedInputLatency
    else:
      let info = Pa_GetDeviceInfo(inDev)
      inParams.suggestedLatency =
        if info.isNil: DefaultAdaptiveLatency
        else: info.defaultLowInputLatency

    inParamsPtr = addr inParams

  pb.render = render
  pb.engineCtx = engineCtx
  pb.sampleRate = cfg.sampleRate
  pb.requestedInputChannels = cfg.inputChannels
  pb.requestedOutputChannels = cfg.outputChannels
  pb.requestedLatencyFrames =
    int32(outParams.suggestedLatency * cfg.sampleRate)

  let err = Pa_OpenStream(
    addr pb.stream,
    inParamsPtr,
    addr outParams,
    cdouble(cfg.sampleRate),
    culong(cfg.blockSize),
    paNoFlag,
    paCallback,
    cast[pointer](pb)
  )

  if err != 0:
    logError(addr pb.log, "portaudio: Pa_OpenStream failed: " & describe(err))
    pb.render = nil
    pb.engineCtx = nil
    return abeOpenFailed

  pb.opened = true
  logInfo(
    addr pb.log,
    "portaudio: stream opened, sr=" & $cfg.sampleRate &
      ", block=" & $cfg.blockSize &
      ", in=" & $cfg.inputChannels &
      ", out=" & $cfg.outputChannels
  )
  abeOk

proc paStart(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.opened:
    return abeNotOpen

  if pb.running:
    return abeOk

  let err = Pa_StartStream(pb.stream)
  if err != 0:
    logError(addr pb.log, "portaudio: Pa_StartStream failed: " & describe(err))
    return abeStartFailed

  pb.running = true
  abeOk

proc paStop(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.opened:
    return abeNotOpen

  if not pb.running:
    return abeOk

  # Остановка best-effort: независимо от кода возврата PortAudio
  # адаптер обязан остаться в состоянии «не запущен».
  let err = Pa_StopStream(pb.stream)
  pb.running = false

  if err != 0:
    logWarn(addr pb.log, "portaudio: Pa_StopStream failed: " & describe(err))

  abeOk

proc paClose(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.opened:
    return

  if pb.running:
    discard Pa_StopStream(pb.stream)
    pb.running = false

  if not pb.stream.isNil:
    discard Pa_CloseStream(pb.stream)
    pb.stream = nil

  pb.opened = false
  pb.render = nil
  pb.engineCtx = nil
  pb.requestedInputChannels = 0
  pb.requestedOutputChannels = 0

proc paShutdown(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return

  paClose(api)

  if pb.paInitialized:
    discard Pa_Terminate()
    pb.paInitialized = false

proc paIsRunning(api: ptr AudioBackendApi): bool
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return false
  pb.running

proc paDeviceCount(api: ptr AudioBackendApi; wantInput: bool): int32
    {.cdecl, raises: [], gcsafe.} =
  ## Общее число устройств PortAudio.
  ##
  ## Фильтрацию «есть ли у устройства вход/выход» делает вызывающий по
  ## AudioDeviceInfo.maxInputChannels / maxOutputChannels.
  let pb = implOf(api)
  if pb.isNil or not pb.paInitialized:
    return 0

  let count = Pa_GetDeviceCount()
  if count < 0: 0'i32 else: int32(count)

proc paDeviceInfo(
  api: ptr AudioBackendApi;
  index: int32;
  wantInput: bool;
  info: var AudioDeviceInfo
): bool {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.paInitialized or index < 0:
    return false

  let dev = Pa_GetDeviceInfo(cint(index))
  if dev.isNil:
    return false

  info.id = index
  info.name = if dev.name.isNil: "" else: $dev.name
  info.maxInputChannels = int32(dev.maxInputChannels)
  info.maxOutputChannels = int32(dev.maxOutputChannels)
  info.defaultSampleRate = dev.defaultSampleRate
  info.defaultLowInputLatency = dev.defaultLowInputLatency
  info.defaultLowOutputLatency = dev.defaultLowOutputLatency

  let idx = cint(index)
  info.isDefault =
    if wantInput: Pa_GetDefaultInputDevice() == idx
    else: Pa_GetDefaultOutputDevice() == idx

  true

proc paXrunCount(api: ptr AudioBackendApi): uint64
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return 0'u64
  pb.xruns.load(moRelaxed)

proc paLatencyFrames(api: ptr AudioBackendApi): int32
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return 0
  pb.requestedLatencyFrames

# ==============================================================================
# Создание / уничтожение (control-path)
# ==============================================================================

proc createPortAudioBackend*(log: Logger = silentLogger()): ptr AudioBackendApi =
  ## Собирает адаптер в shared-куче.
  ##
  ## Возвращает nil, если память недоступна. Отсутствие установленной
  ## libportaudio здесь НЕ ошибка: библиотека грузится через dynlib при
  ## первом вызове Pa_Initialize, поэтому недоступность проявится как
  ## abeInitFailed из backendInit.
  let api = cast[ptr AudioBackendApi](allocShared0(sizeof(AudioBackendApi)))
  if api.isNil:
    return nil

  let pb = cast[ptr PortAudioBackend](allocShared0(sizeof(PortAudioBackend)))
  if pb.isNil:
    deallocShared(cast[pointer](api))
    return nil

  pb.log = log

  api.backendName = cstring"portaudio"
  api.impl = cast[pointer](pb)

  api.init = paInit
  api.shutdown = paShutdown
  api.open = paOpen
  api.start = paStart
  api.stop = paStop
  api.close = paClose
  api.isRunning = paIsRunning
  api.deviceCount = paDeviceCount
  api.deviceInfo = paDeviceInfo
  api.xrunCount = paXrunCount
  api.latencyFrames = paLatencyFrames

  api

proc destroyPortAudioBackend*(api: ptr AudioBackendApi) =
  if api.isNil:
    return

  # Сначала корректно закрываем поток и вызываем Pa_Terminate.
  backendShutdown(api)

  let pb = implOf(api)
  if not pb.isNil:
    api.impl = nil
    deallocShared(cast[pointer](pb))

  deallocShared(cast[pointer](api))


