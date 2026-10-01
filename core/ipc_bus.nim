# ipc_bus.nim
#
# Очереди control <-> audio поверх канонического кольца Core (issue #37).
#
# Раньше MpscQueue/SpscQueue были здесь собственной реализацией на атомиках.
# Теперь это ТОНКИЕ ОБЁРТКИ над core/ring_buffer.nim: одна memory-модель на
# всё ядро, никаких расхождений в порядке acquire/release.
import std/atomics
import ring_buffer

# Имена push/pop/size/isEmpty живут в ring_buffer и реэкспортируются:
# для вызывающей стороны API очередей не меняется (engine.toAudio.push(...)).
export ring_buffer

# Если твой компилятор ругается, что атомарные операции могут поднимать
# Exception, закомментируй эту строку. В актуальных версиях Nim std/atomics
# обычно совместим с raises: [].
{.push raises: [].}

const
  SharedBlockSize* = 4096
  SharedBlockCount* = 64

type
  CommandKind* = enum
    cmdNop = 0,
    cmdSetParam,
    cmdSetParamNormalized,
    cmdTransportPlay,
    cmdTransportStop,
    cmdSetTempo,
    cmdSetPlayhead,
    cmdMidiNoteOn,
    cmdMidiNoteOff,
    cmdMidiCC,
    cmdAutomationBlock,
    cmdGraphUpdate,
    cmdLoadResource

  # Команда должна оставаться компактным POD-объектом.
  # Ветки варианта не должны содержать seq/string/ref.
  EngineCommand* = object
    case kind*: CommandKind
    of cmdSetParam, cmdSetParamNormalized:
      nodeId*: int32
      paramId*: uint32
      value*: float32
    of cmdMidiNoteOn, cmdMidiNoteOff, cmdMidiCC:
      channel*: uint8
      data1*: uint8
      data2*: uint8
      midiPad*: uint8
    of cmdSetTempo, cmdSetPlayhead:
      transportValue*: float64
    of cmdAutomationBlock, cmdGraphUpdate, cmdLoadResource:
      sharedBufferId*: int32
      dataSize*: uint32
    else:
      discard

  TransportState* = enum
    tsStopped = 0,
    tsPlaying,
    tsRecording

  EngineMetric* = object
    peakL*: float32
    peakR*: float32
    rmsL*: float32
    rmsR*: float32
    cpuLoad*: float32
    xruns*: uint32
    sampleRate*: float64
    bufferSize*: uint32
    transportState*: uint8
    activeVoices*: int32
    graphVersion*: uint64

  # Multi-Producer Single-Consumer queue: путь UI/control -> Audio,
  # отправителей может быть несколько. Обёртка над MpscRingBuffer
  # (core/ring_buffer.nim). Инвариант «producers не уничтожаются
  # принудительно внутри push» унаследован из ring_buffer.
  MpscQueue*[T; Size: static[int]] = MpscRingBuffer[T, Size]

  # Single-Producer Single-Consumer queue: путь Audio -> UI,
  # отправитель один. Обёртка над SpscRingBuffer (core/ring_buffer.nim).
  SpscQueue*[T; Size: static[int]] = SpscRingBuffer[T, Size]

  SharedBlock* = object
    data*: array[SharedBlockSize, byte]
    size*: uint32
    inUse*: Atomic[uint8]

  SharedPool* = object
    blocks*: array[SharedBlockCount, SharedBlock]

# ==============================================================================
# Инициализация очередей
# ==============================================================================
#
# push/pop/size/isEmpty реэкспортированы из ring_buffer и работают с
# алиасами напрямую — отдельной реализации здесь больше нет.

proc initMpscQueue*[T; Size: static[int]](q: var MpscQueue[T, Size]) =
  q.initRing()

proc initSpscQueue*[T; Size: static[int]](q: var SpscQueue[T, Size]) =
  q.initRing()

# ==============================================================================
# Shared pool для крупных данных
# ==============================================================================
# Используется для команд вида:
# - загрузка ресурса;
# - обновление графа;
# - передача блока автоматизации;
# - любые другие данные, которые не помещаются в маленькую команду.
#
# В очереди передается только sharedBufferId.

proc initSharedPool*(pool: var SharedPool) =
  for i in 0 ..< SharedBlockCount:
    pool.blocks[i].size = 0
    pool.blocks[i].inUse.store(0'u8, moRelaxed)

proc acquireBlock*(pool: var SharedPool): int32 =
  for i in 0 ..< SharedBlockCount:
    var expected = 0'u8

    if pool.blocks[i].inUse.compareExchangeWeak(
      expected,
      1'u8,
      moAcquire,
      moAcquire
    ):
      let id = int32(i)
      pool.blocks[id].size = 0
      return id

  return -1

proc releaseBlock*(pool: var SharedPool, id: int32) =
  if id >= 0 and id < int32(SharedBlockCount):
    pool.blocks[id].size = 0
    pool.blocks[id].inUse.store(0'u8, moRelease)

{.pop.}