# tests/unit/test_memory_pool.nim
#
# MemoryPool — фиксированные пулы realtime-объектов (issue #57, MANIFEST §34/§75).
#
# Что проверяется:
#   - валидация init (нулевые capacity/blockSize, повторный init);
#   - capacity/blockSize/usedCount/freeCount согласованы;
#   - выравнивание адресов блоков (PoolAlignment = 64);
#   - исчерпание пула даёт невалидный handle, а не крэш;
#   - double-free отвергается (CAS по state);
#   - ABA: старый handle не освобождает переиспользованный блок и не даёт
#     доступ к его памяти;
#   - AudioBufferPool и EventQueuePool: lease выдаёт готовый объект.

import std/unittest
import signal_types
import memory_pool

suite "memory_pool: lifecycle":
  test "некорректные параметры отвергаются, пул не инициализируется":
    var pool: MemoryPool
    check not pool.isInitialized()
    check not initMemoryPool(pool, 0, 64)
    check not initMemoryPool(pool, 4, 0)
    check not initMemoryPool(pool, -1, 64)
    check not pool.isInitialized()

  test "повторный init отвергается":
    var pool: MemoryPool
    check initMemoryPool(pool, 4, 64)
    defer: destroyMemoryPool(pool)
    check not initMemoryPool(pool, 4, 64)

  test "capacity/blockSize/счётчики согласованы":
    var pool: MemoryPool
    check initMemoryPool(pool, 3, 128)
    defer: destroyMemoryPool(pool)
    check pool.capacity() == 3
    check pool.blockSize() == 128
    check pool.usedCount() == 0
    check pool.freeCount() == 3

  test "destroy обнуляет пул":
    var pool: MemoryPool
    check initMemoryPool(pool, 2, 64)
    destroyMemoryPool(pool)
    check not pool.isInitialized()
    check pool.capacity() == 0
    check pool.usedCount() == 0

suite "memory_pool: alloc/free":
  test "alloc выдаёт валидный handle с выравненным адресом":
    var pool: MemoryPool
    check initMemoryPool(pool, 2, 64)
    defer: destroyMemoryPool(pool)

    let h = pool.allocBlock()
    check h.isValidHandle()
    check pool.usedCount() == 1
    check pool.freeCount() == 1

    let p = pool.blockPtr(h)
    check p != nil
    check (cast[uint](p) and 63'u) == 0'u   # PoolAlignment = 64

    check pool.freeBlock(h)
    check pool.usedCount() == 0
    check pool.freeCount() == 2

  test "исчерпание пула даёт невалидный handle":
    var pool: MemoryPool
    check initMemoryPool(pool, 2, 64)
    defer: destroyMemoryPool(pool)

    let h0 = pool.allocBlock()
    let h1 = pool.allocBlock()
    check h0.isValidHandle()
    check h1.isValidHandle()
    check h0.index != h1.index

    let h2 = pool.allocBlock()
    check not h2.isValidHandle()
    check pool.usedCount() == 2

  test "double free отвергается":
    var pool: MemoryPool
    check initMemoryPool(pool, 2, 64)
    defer: destroyMemoryPool(pool)

    let h = pool.allocBlock()
    check pool.freeBlock(h)
    check not pool.freeBlock(h)

  test "ABA: старый handle не трогает переиспользованный блок":
    var pool: MemoryPool
    check initMemoryPool(pool, 1, 64)
    defer: destroyMemoryPool(pool)

    let old = pool.allocBlock()
    check pool.freeBlock(old)

    let fresh = pool.allocBlock()
    check fresh.index == old.index
    check fresh.generation != old.generation

    # Устаревший handle больше не владеет блоком.
    check pool.blockPtr(old) == nil
    check not pool.freeBlock(old)

    # Актуальный handle — владеет.
    check pool.blockPtr(fresh) != nil
    check pool.freeBlock(fresh)

  test "blockPtr отвергает невалидные и выходящие за границы handle":
    var pool: MemoryPool
    check initMemoryPool(pool, 2, 64)
    defer: destroyMemoryPool(pool)

    check pool.blockPtr(invalidPoolHandle()) == nil
    check pool.blockPtr(PoolHandle(index: 99'i32, generation: 1'u64)) == nil
    check pool.blockPtr(PoolHandle(index: -1'i32, generation: 1'u64)) == nil

suite "memory_pool: специализированные пулы":
  test "AudioBufferPool: lease инициализирует моно-буфер":
    var pool: AudioBufferPool
    check initAudioBufferPool(pool, 2)
    defer: destroyAudioBufferPool(pool)

    var lease = allocAudioBuffer(pool, 256)
    check lease.handle.isValidHandle()
    check lease.buffer != nil
    check lease.buffer.channels == 1
    check lease.buffer.frames == 256
    check lease.buffer.stride == 1
    check lease.buffer.data != nil

    clearAudioBuffer(lease.buffer)
    lease.buffer.data[0] = 0.5f
    lease.buffer.data[255] = -0.5f
    check lease.buffer.data[0] == 0.5f
    check lease.buffer.data[255] == -0.5f

    check freeAudioBuffer(pool, lease)
    # Рекомендуемая форма инвалидирует lease после освобождения.
    check lease.buffer == nil
    check not lease.handle.isValidHandle()
    check not freeAudioBuffer(pool, lease.handle)

  test "EventQueuePool: выданная очередь пуста":
    var pool: EventQueuePool
    check initEventQueuePool(pool, 2)
    defer: destroyEventQueuePool(pool)

    var lease = allocEventQueue(pool)
    check lease.queue != nil
    check lease.queue.count == 0

    var ev: RealtimeEvent
    ev.kind = evNoteOn
    check pushEvent(lease.queue, ev)
    check lease.queue.count == 1

    check freeEventQueue(pool, lease)
    check lease.queue == nil
    check not lease.handle.isValidHandle()
