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

  # Transport information - полная информация о таймлайне.
  #
  # ЕДИНЫЙ time-coordinate contract (issue #387), тот же, что у
  # `transport.TransportSnapshot`. Одно значение — одно имя во всех API:
  #
  #   * barPosition        — позиция в ТАКТАХ (0-базная, дробная);
  #   * beatPosition       — позиция в ДОЛЯХ, где доля = знаменатель размера
  #                          (в 6/8 доля — восьмая, а не четверть);
  #   * quarterNotePosition— позиция в ЧЕТВЕРТНЫХ нотах (1.0 = четверть, PPQ-основа);
  #   * tickPosition       — тик ВНУТРИ текущей доли при 960 PPQ на четверть;
  #   * cycleStart/cycleEnd— границы цикла в ДОЛЯХ (та же единица, что beatPosition).
  #
  # Раньше `beatPosition` здесь была в PPQ, а в snapshot — номером доли; цикл
  # приходил в секундах. Всё это сведено к одному контракту.
  TransportInfo* = object
    tempo*: float64           # BPM
    timeSigNum*: int32        # Time signature numerator (e.g., 4 for 4/4)
    timeSigDen*: int32        # Time signature denominator (e.g., 4 for 4/4)
    barPosition*: float64     # Позиция в тактах (0-базная, дробная)
    beatPosition*: float64    # Позиция в долях (доля = знаменатель размера)
    quarterNotePosition*: float64  # Позиция в четвертных нотах
    tickPosition*: int32      # Тик внутри текущей доли (960 PPQ на четверть)
    cycleStart*: float64      # Начало цикла (в долях, как beatPosition)
    cycleEnd*: float64        # Конец цикла (в долях)
    flags*: set[ProcessingFlags]

  # Node processing context - минимальная общая информация для всех нод
  NodeProcessContext* = object
    sampleRate*: float32
    blockSize*: int32
    samplePosition*: int64    # Absolute sample position in timeline
    timeInSeconds*: float64   # Time in seconds
    transport*: TransportInfo
    flags*: set[ProcessingFlags]

    ## Входной тракт (issue #3).
    ##
    ## `input` указывает на planar-буфер драйверного входа: `channels` —
    ## фактическое число входных каналов устройства (1 или 2), `stride` —
    ## шаг между каналами в арене, `frames` — длина блока. Указатель
    ## валиден всегда, пока движок рендерит блок.
    ##
    ## `channels == 0` означает «входа нет» (устройство без входных
    ## каналов или offline-рендер): ноды обязаны выдать тишину.
    input*: PAudioBuffer
    inputChannels*: int32

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
                      userData: pointer) {.cdecl, raises: [], gcsafe.}

{.pop.}