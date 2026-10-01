# audio_backend.nim
import audio_engine

when defined(windows):
  const PortAudioLib = "portaudio_x64.dll"
elif defined(macosx):
  const PortAudioLib = "libportaudio.dylib"
else:
  const PortAudioLib = "libportaudio.so"

type
  PaStream = pointer
  PaError = cint
  PaSampleFormat = culong
  
  PaDeviceInfo* {.bycopy.} = object
    structVersion*: cint
    name*: cstring
    hostApi*: cint
    maxInputChannels*: cint
    maxOutputChannels*: cint
    defaultLowInputLatency*: cdouble
    defaultLowOutputLatency*: cdouble
    defaultHighInputLatency*: cdouble
    defaultHighOutputLatency*: cdouble
    defaultSampleRate*: cdouble

  PaStreamParameters* {.bycopy.} = object
    device*: cint
    channelCount*: cint
    sampleFormat*: PaSampleFormat
    suggestedLatency*: cdouble
    hostApiSpecificStreamInfo*: pointer
  
  PaStreamCallback* = proc(
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
proc Pa_GetErrorText(errorCode: PaError): cstring {.pa_import.}

const
  paFloat32: culong = 0x00000001
  paNoFlag: culong = 0
  paInputUnderflow {.used.}: culong = 0x00000001
  paInputOverflow: culong = 0x00000002
  paOutputUnderflow: culong = 0x00000004
  paOutputOverflow {.used.}: culong = 0x00000008

type
  AudioBackend* = object
    stream: PaStream
    engine: ptr AudioEngine
    isRunning: bool

proc paCallback(
  input: pointer,
  output: pointer,
  frameCount: culong,
  timeInfo: pointer,
  statusFlags: culong,
  userData: pointer
): cint {.cdecl.} =
  let backend = cast[ptr AudioBackend](userData)
  let outBuf = cast[ptr UncheckedArray[float32]](output)
  
  # Обработка xruns / status flags
  if (statusFlags and (paInputOverflow or paOutputUnderflow)) != 0:
    discard
  
  # Engine сам отвечает за advance transport и рендеринг.
  backend.engine.renderBlock(outBuf)
  
  return 0

proc initAudioBackend*(
  engine: ptr AudioEngine, 
  sampleRate: float32 = 48000.0, 
  blockSize: int32 = 128,
  inputChannels: int32 = 0,
  outputChannels: int32 = 2
): ptr AudioBackend =
  # Аллоцируем в shared куче для безопасного времени жизни в callback
  result = cast[ptr AudioBackend](allocShared0(sizeof(AudioBackend)))
  result.engine = engine
  result.isRunning = false
  
  let err = Pa_Initialize()
  if err != 0:
    echo "PortAudio init failed: ", $(Pa_GetErrorText(err))
    deallocShared(result)
    return nil
  
  var outputParams: PaStreamParameters
  let outDev = Pa_GetDefaultOutputDevice()
  if outDev < 0:
    echo "No default output device found"
    discard Pa_Terminate()
    deallocShared(result)
    return nil
    
  outputParams.device = outDev
  outputParams.channelCount = outputChannels
  outputParams.sampleFormat = paFloat32
  
  # Дефолтная низкая задержка устройства с защитой от nil
  let outInfo = Pa_GetDeviceInfo(outDev)
  if outInfo != nil:
    outputParams.suggestedLatency = outInfo.defaultLowOutputLatency
  else:
    outputParams.suggestedLatency = 0.01
  outputParams.hostApiSpecificStreamInfo = nil
  
  var inputParams: PaStreamParameters
  var inputParamsPtr: ptr PaStreamParameters = nil
  if inputChannels > 0:
    let inDev = Pa_GetDefaultInputDevice()
    if inDev >= 0:
      inputParams.device = inDev
      inputParams.channelCount = inputChannels
      inputParams.sampleFormat = paFloat32
      let inInfo = Pa_GetDeviceInfo(inDev)
      if inInfo != nil:
        inputParams.suggestedLatency = inInfo.defaultLowInputLatency
      else:
        inputParams.suggestedLatency = 0.01
      inputParams.hostApiSpecificStreamInfo = nil
      inputParamsPtr = addr inputParams
  
  let openErr = Pa_OpenStream(
    addr result.stream,
    inputParamsPtr,
    addr outputParams,
    cdouble(sampleRate),
    culong(blockSize),
    paNoFlag,
    paCallback,
    cast[pointer](result)
  )
  
  if openErr != 0:
    echo "PortAudio open failed: ", $(Pa_GetErrorText(openErr))
    discard Pa_Terminate()
    deallocShared(result)
    return nil

proc start*(backend: ptr AudioBackend): bool =
  if backend == nil or backend.stream == nil:
    return false
  
  let err = Pa_StartStream(backend.stream)
  if err == 0:
    backend.isRunning = true
    return true
  else:
    echo "PortAudio start failed: ", $(Pa_GetErrorText(err))
    return false

proc stop*(backend: ptr AudioBackend) =
  if backend != nil and backend.stream != nil and backend.isRunning:
    discard Pa_StopStream(backend.stream)
    backend.isRunning = false

proc cleanup*(backend: ptr AudioBackend) =
  if backend == nil: return
  backend.stop()
  if backend.stream != nil:
    discard Pa_CloseStream(backend.stream)
    backend.stream = nil
  discard Pa_Terminate()
  deallocShared(backend)