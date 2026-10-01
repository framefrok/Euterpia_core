# ipc_bus.nim
import std/atomics

# Если твой компилятор ругается, что атомарные операции могут поднимать
# Exception, закомментируй эту строку. В актуальных версиях Nim std/atomics
# обычно совместим с raises: [].
{.push raises: [].}

const
  CacheLine = 64

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

  # Multi-Producer Single-Consumer queue.
  # Подходит для пути UI -> Audio, где отправителей может быть несколько.
  # Инвариант: потоки-производители не должны принудительно уничтожаться (pthread_cancel)
  # во время исполнения push, чтобы избежать бесконечного Head-of-Line ожидания слота.
  MpscQueue*[T; Size: static[int]] = object
    buffer: array[Size, T]
    ready: array[Size, Atomic[uint8]]
    head: Atomic[uint64]
    pad1: array[CacheLine, byte]
    tail: Atomic[uint64]
    pad2: array[CacheLine, byte]

  # Single-Producer Single-Consumer queue.
  # Подходит для пути Audio -> UI, где отправитель один.
  SpscQueue*[T; Size: static[int]] = object
    buffer: array[Size, T]
    head: Atomic[uint64]
    pad1: array[CacheLine, byte]
    tail: Atomic[uint64]
    pad2: array[CacheLine, byte]

  SharedBlock* = object
    data*: array[SharedBlockSize, byte]
    size*: uint32
    inUse*: Atomic[uint8]

  SharedPool* = object
    blocks*: array[SharedBlockCount, SharedBlock]

# ==============================================================================
# MPSC queue: UI/control threads -> audio thread
# ==============================================================================

proc initMpscQueue*[T; Size: static[int]](q: var MpscQueue[T, Size]) =
  q.head.store(0'u64, moRelaxed)
  q.tail.store(0'u64, moRelaxed)
  for i in 0 ..< Size:
    q.ready[i].store(0'u8, moRelaxed)

proc push*[T; Size: static[int]](
    q: var MpscQueue[T, Size],
    item: T
): bool {.inline.} =
  var t = q.tail.load(moRelaxed)

  while true:
    let h = q.head.load(moAcquire)

    # Защита от underflow: если поток был вытеснен планировщиком и consumer
    # успел продвинуть head дальше локального снимка t (t < h), вычисление
    # (t - h) даст огромное беззнаковое число (~2^64). В этом случае снимок t
    # гарантированно устарел: обновляем его из актуального tail и повторяем.
    if t < h:
      t = q.tail.load(moRelaxed)
      continue

    if (t - h) >= uint64(Size):
      # Очередь заполнена. В realtime-системе команду отбрасываем,
      # чтобы не блокировать вызывающий поток.
      return false

    if q.tail.compareExchangeWeak(t, t + 1, moRelaxed, moRelaxed):
      break

  let idx = int(t mod uint64(Size))
  q.buffer[idx] = item
  # Публикация слота: moRelease гарантирует, что запись в buffer[idx]
  # станет видна Consumer'у строго до или одновременно с ready[idx] == 1.
  q.ready[idx].store(1'u8, moRelease)
  return true

proc pop*[T; Size: static[int]](
    q: var MpscQueue[T, Size],
    item: var T
): bool {.inline.} =
  let h = q.head.load(moRelaxed)
  let idx = int(h mod uint64(Size))

  # Если производитель захватил слот, но ещё не успел записать данные в buffer,
  # pop мгновенно возвращает false без блокировки аудиопотока.
  if q.ready[idx].load(moAcquire) == 0'u8:
    return false

  item = q.buffer[idx]

  # Замечание по порядку памяти (Ошибка 20):
  # moRelaxed для ready[idx] абсолютно корректен, так как последующая запись
  # q.head.store(..., moRelease) служит односторонним барьером: она гарантирует,
  # что и чтение buffer[idx], и сброс ready[idx] в 0 станут глобально видимыми
  # до того, как Producer увидит обновлённый head. Сам Consumer читает ready[idx]
  # только в рамках этого же потока через полный круг (Size шагов).
  q.ready[idx].store(0'u8, moRelaxed)
  q.head.store(h + 1, moRelease)
  return true

# ==============================================================================
# SPSC queue: audio thread -> UI
# ==============================================================================

proc initSpscQueue*[T; Size: static[int]](q: var SpscQueue[T, Size]) =
  q.head.store(0'u64, moRelaxed)
  q.tail.store(0'u64, moRelaxed)

proc push*[T; Size: static[int]](
    q: var SpscQueue[T, Size],
    item: T
): bool {.inline.} =
  let t = q.tail.load(moRelaxed)
  let h = q.head.load(moAcquire)

  if (t - h) >= uint64(Size):
    return false

  q.buffer[int(t mod uint64(Size))] = item
  q.tail.store(t + 1, moRelease)
  return true

proc pop*[T; Size: static[int]](
    q: var SpscQueue[T, Size],
    item: var T
): bool {.inline.} =
  let h = q.head.load(moRelaxed)
  let t = q.tail.load(moAcquire)

  if h >= t:
    return false

  item = q.buffer[int(h mod uint64(Size))]
  q.head.store(h + 1, moRelease)
  return true

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