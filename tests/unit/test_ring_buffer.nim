# tests/unit/test_ring_buffer.nim
#
# Канонический кольцевой буфер Core (issue #37).
#
# Что проверяется:
#   - FIFO и переполнение без молчаливой перезаписи непрочитанного;
#   - size/space/isEmpty/isFull и pushSlice/popSlice;
#   - resetP работает только как control-path сброс;
#   - SPSC под двумя потоками: без потерь, дублей и порчи порядка;
#   - MPSC под двумя producers: каждый элемент ровно один раз.
#
# Стресс-часть — тот же прогон, что гоняется под TSan в CI (см. ci.yml).
# Она специально не полагается на GC: всё состояние — в shared-памяти,
# счётчики — атомарные.

import std/[unittest, atomics]
import ring_buffer

# ==============================================================================
# Однопоточная корректность
# ==============================================================================

suite "ring_buffer: SPSC":
  test "пустое кольцо не отдаёт элементы":
    var rb: SpscRingBuffer[uint64, 8]
    rb.initRing()
    check rb.isEmpty()
    check rb.size() == 0
    check rb.space() == 8
    check rb.capacity() == 8
    var v: uint64
    check rb.pop(v) == false

  test "FIFO-порядок сохраняется":
    var rb: SpscRingBuffer[uint64, 8]
    rb.initRing()

    for i in 0'u64 ..< 5'u64:
      check rb.push(i)
    check rb.size() == 5
    check rb.space() == 3
    check not rb.isEmpty()

    for i in 0'u64 ..< 5'u64:
      var v: uint64
      check rb.pop(v)
      check v == i
    check rb.isEmpty()

  test "переполнение не перезаписывает непрочитанное":
    var rb: SpscRingBuffer[uint64, 4]
    rb.initRing()

    for i in 0'u64 ..< 4'u64:
      check rb.push(i)
    check rb.isFull()

    # Полный буфер: push обязан отказать, а не затоптать элемент 0.
    check rb.push(999'u64) == false

    for i in 0'u64 ..< 4'u64:
      var v: uint64
      check rb.pop(v)
      check v == i

  test "индексы прокручиваются через кольцо":
    var rb: SpscRingBuffer[int32, 4]
    rb.initRing()

    # Многократная прокрутка: индексы монотонные, маска берёт остаток.
    for round in 0 ..< 100:
      for i in 0'i32 ..< 4'i32:
        check rb.push(i + int32(round))
      for i in 0'i32 ..< 4'i32:
        var v: int32
        check rb.pop(v)
        check v == i + int32(round)
      check rb.isEmpty()

  test "pushSlice/popSlice работают блоками и не режут хвост":
    var rb: SpscRingBuffer[int32, 8]
    rb.initRing()

    var src = [1'i32, 2, 3, 4, 5, 6]
    # Влезает 8, записываем 6 — ок.
    check rb.pushSlice(src) == 6
    check rb.size() == 6

    # Ещё 4 не влезают целиком: пишем только 2, хвост не трогаем.
    var more = [7'i32, 8, 9, 10]
    check rb.pushSlice(more) == 2
    check rb.size() == 8
    check rb.isFull()

    var dst: array[8, int32]
    check rb.popSlice(dst) == 8
    check dst == [1'i32, 2, 3, 4, 5, 6, 7, 8]
    check rb.isEmpty()

  test "resetP очищает кольцо (control-path)":
    var rb: SpscRingBuffer[int32, 4]
    rb.initRing()
    discard rb.push(1'i32)
    discard rb.push(2'i32)
    check rb.size() == 2

    rb.resetP()
    check rb.isEmpty()
    discard rb.push(42'i32)
    var v: int32
    check rb.pop(v)
    check v == 42

suite "ring_buffer: MPSC":
  test "очередь принимает элементы и отдаёт их в порядке добавления":
    var rb: MpscRingBuffer[int32, 4]
    rb.initRing()

    check rb.isEmpty()
    for i in 0'i32 ..< 4'i32:
      check rb.push(i)
    check rb.push(9'i32) == false

    for i in 0'i32 ..< 4'i32:
      var v: int32
      check rb.pop(v)
      check v == i
    check rb.isEmpty()

# ==============================================================================
# Многопоточный стресс (тот же сценарий идёт под TSan в CI)
# ==============================================================================

const
  SpscStressItems = 1_000_000'u64
  MpscStressItems = 200_000'u64
  StressCapacity = 1024

type
  SpscStressCtx = object
    rb: SpscRingBuffer[uint64, StressCapacity]
    received: Atomic[uint64]
    orderErrors: Atomic[uint64]

  MpscStressCtx = object
    rb: MpscRingBuffer[uint64, StressCapacity]
    received: Atomic[uint64]
    dupErrors: Atomic[uint64]
    seen: ptr UncheckedArray[uint8]

proc spscProducer(arg: pointer) {.thread.} =
  let ctx = cast[ptr SpscStressCtx](arg)
  var v = 0'u64
  while v < SpscStressItems:
    if ctx.rb.push(v):
      inc v

proc spscConsumer(arg: pointer) {.thread.} =
  let ctx = cast[ptr SpscStressCtx](arg)
  var expected = 0'u64
  while expected < SpscStressItems:
    var got: uint64
    if ctx.rb.pop(got):
      if got != expected:
        discard ctx.orderErrors.fetchAdd(1'u64, moRelaxed)
      inc expected
  ctx.received.store(expected, moRelease)

proc mpscProducerEven(arg: pointer) {.thread.} =
  let ctx = cast[ptr MpscStressCtx](arg)
  var v = 0'u64
  while v < MpscStressItems:
    if ctx.rb.push(v):
      v += 2'u64

proc mpscProducerOdd(arg: pointer) {.thread.} =
  let ctx = cast[ptr MpscStressCtx](arg)
  var v = 1'u64
  while v < MpscStressItems:
    if ctx.rb.push(v):
      v += 2'u64

proc mpscConsumer(arg: pointer) {.thread.} =
  let ctx = cast[ptr MpscStressCtx](arg)
  var count = 0'u64
  while count < MpscStressItems:
    var got: uint64
    if ctx.rb.pop(got):
      if got >= MpscStressItems:
        discard ctx.dupErrors.fetchAdd(1'u64, moRelaxed)
      elif ctx.seen[got] != 0'u8:
        # Значение уже приходило: дублирование или порча индекса.
        discard ctx.dupErrors.fetchAdd(1'u64, moRelaxed)
      else:
        ctx.seen[got] = 1'u8
      inc count
  ctx.received.store(count, moRelease)

suite "ring_buffer: многопоточный стресс":
  test "SPSC: миллион элементов без потерь и перестановок":
    let ctx = cast[ptr SpscStressCtx](allocShared0(sizeof(SpscStressCtx)))
    check ctx != nil
    ctx.rb.initRing()
    ctx.received.store(0'u64, moRelaxed)
    ctx.orderErrors.store(0'u64, moRelaxed)

    var producer: Thread[pointer]
    var consumer: Thread[pointer]
    createThread(producer, spscProducer, cast[pointer](ctx))
    createThread(consumer, spscConsumer, cast[pointer](ctx))
    joinThread(producer)
    joinThread(consumer)

    check ctx.received.load(moAcquire) == SpscStressItems
    check ctx.orderErrors.load(moAcquire) == 0'u64
    check ctx.rb.isEmpty()

    deallocShared(ctx)

  test "MPSC: два producers, каждый элемент ровно один раз":
    let ctx = cast[ptr MpscStressCtx](allocShared0(sizeof(MpscStressCtx)))
    check ctx != nil
    ctx.seen = cast[ptr UncheckedArray[uint8]](allocShared0(MpscStressItems))
    check ctx.seen != nil

    ctx.rb.initRing()
    ctx.received.store(0'u64, moRelaxed)
    ctx.dupErrors.store(0'u64, moRelaxed)

    var p1: Thread[pointer]
    var p2: Thread[pointer]
    var c: Thread[pointer]
    createThread(p1, mpscProducerEven, cast[pointer](ctx))
    createThread(p2, mpscProducerOdd, cast[pointer](ctx))
    createThread(c, mpscConsumer, cast[pointer](ctx))
    joinThread(p1)
    joinThread(p2)
    joinThread(c)

    check ctx.received.load(moAcquire) == MpscStressItems
    check ctx.dupErrors.load(moAcquire) == 0'u64

    deallocShared(ctx.seen)
    deallocShared(ctx)
