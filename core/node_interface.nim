# node_interface.nim
import signal_types

{.push raises: [].}

const
  MaxAudioPorts* = 8
  MaxCtrlPorts* = 4
  MaxEventPorts* = 4

type
  # Processing flags для различных режимов работы
  ProcessingFlags* = enum
    pfRealtime         # Realtime processing (vs offline rendering)
    pfOffline          # Offline rendering mode
    pfFirstBlock       # First block in session
    pfLastBlock        # Last block in session
    pfTransportPlaying # Transport is currently playing

  # Transport information - полная информация о таймлайне
  TransportInfo* = object
    tempo*: float64           # BPM
    timeSigNum*: int32        # Time signature numerator (e.g., 4 for 4/4)
    timeSigDen*: int32        # Time signature denominator (e.g., 4 for 4/4)
    barPosition*: float64     # Position in bars (PPQ - pulses per quarter)
    beatPosition*: float64    # Position in beats (PPQ)
    cycleStart*: float64      # Cycle/loop start position (PPQ)
    cycleEnd*: float64        # Cycle/loop end position (PPQ)
    flags*: set[ProcessingFlags]

  # Node processing context - минимальная общая информация для всех нод
  NodeProcessContext* = object
    sampleRate*: float32
    blockSize*: int32
    samplePosition*: int64    # Absolute sample position in timeline
    timeInSeconds*: float64   # Time in seconds
    transport*: TransportInfo
    flags*: set[ProcessingFlags]

  # Audio ports container - все аудио-порты ноды
  NodeAudioPorts* = object
    inputs*: array[MaxAudioPorts, PAudioBuffer]
    outputs*: array[MaxAudioPorts, PAudioBuffer]
    inputCount*: int32
    outputCount*: int32

  # Control ports container - все control-rate порты ноды
  NodeControlPorts* = object
    inputs*: array[MaxCtrlPorts, ptr float32]
    outputs*: array[MaxCtrlPorts, ptr float32]
    inputCount*: int32
    outputCount*: int32

  # Event ports container - все event-порты ноды
  NodeEventPorts* = object
    inputs*: array[MaxEventPorts, ptr EventQueue]
    outputs*: array[MaxEventPorts, ptr EventQueue]
    inputCount*: int32
    outputCount*: int32

  # Pipeline step - представляет одну DSP-ноду в графе
  PipelineStep* = object
    processProc*: ProcessProc
    userData*: pointer
    audio*: NodeAudioPorts
    ctrl*: NodeControlPorts
    events*: NodeEventPorts

  # ProcessProc - контракт для DSP-обработки
  # ctx: общая информация о сессии
  # audio: аудио-порты
  # ctrl: control-порты  
  # events: event-порты
  # userData: пользовательские данные ноды
  ProcessProc* = proc(ctx: ptr NodeProcessContext,
                      audio: ptr NodeAudioPorts,
                      ctrl: ptr NodeControlPorts,
                      events: ptr NodeEventPorts,
                      userData: pointer) {.cdecl, raises: [].}

{.pop.}