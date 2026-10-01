# memory_pool.nim
#
# Назначение:
#   - фиксированные пулы памяти для realtime-объектов;
#   - предвыделение на старте;
#   - стабильные адреса блоков;
#   - O(1) acquire/release без линейного поиска;
#   - защита от двойного освобождения через generation handle;
#   - lock-free free-list с тегированным head для снижения ABA.
#
# Важно:
#   - init/destroy вызываются вне realtime-контекста;
#   - alloc/free сами по себе память не выделяют и не освобождают;
#   - разрушение пула допустимо только когда пул больше не используется.

import std/atomics
import signal_types

{.push raises: [].}

const
  PoolAlignment = 64

  # Должно помещаться в нижние IndexBits бит, так как индекс хранится как index+1,
  # а 0 означает "пусто".
  MaxPoolBlocks = 16384

  # 16 бит под индекс+1, остальные биты -- монотонный тег.
  IndexBits = 16
  IndexMask = (1'u64 shl IndexBits) - 1'u64

  # Поколение блока. Используем 1 бит под статус, остальные -- под поколение.
  MaxGeneration = high(uint64) shr 1

static:
  doAssert (PoolAlignment and (PoolAlignment - 1)) == 0
  doAssert MaxPoolBlocks < (1 shl IndexBits)

type
  ## Дескриптор владения блоком.
  ##
  ## Нельзя освобождать блок по сырому указателю: для освобождения используется
  ## только этот handle. Поле generation защищает от double-free и от
  ## освобождения уже переиспользованного блока старым указателем/дескриптором.
  PoolHandle* = object
    index*: int32
    generation*: uint64

  ## Внутренний блок пула.
  ##
  ## data -- стабильный адрес пользовательской памяти.
  ## nextFree -- связь в lock-free free-list, актуален только когда блок свободен.
  ## state -- (generation << 1) | status, где status: 0 = free, 1 = used.
  PoolBlock = object
    data: pointer
    nextFree: Atomic[int32]
    state: Atomic[uint64]

  ## Фиксированный пул блоков.
  ##
  ## Не содержит скрытого глобального состояния. Владеет памятью блоков.
  ## Копировать такой объект после инициализации нельзя.
  MemoryPool* = object
    blocks: ptr UncheckedArray[PoolBlock]
    freeHead: Atomic[uint64]  # (tag << IndexBits) | (index + 1), 0 = empty
    cap: int32
    blkSize: int32
    used: Atomic[int32]

# ==============================================================================
# Handle helpers
# ==============================================================================

proc invalidPoolHandle*(): PoolHandle {.inline.} =
  PoolHandle(index: -1'i32, generation: 0'u64)

proc isValidHandle*(h: PoolHandle): bool {.inline.} =
  h.generation != 0'u64 and h.index >= 0'i32

# ==============================================================================
# Alignment helpers
# ==============================================================================

proc alignUpInt(x: int, align: int): int {.inline.} =
  ## Выравнивание вверх для неотрицательных размеров.
  ## Только для степеней двойки.
  let m = align - 1
  let y = x + m
  y - (y and m)

proc alignUpUint(x: uint, align: uint): uint {.inline.} =
  ## Выравнивание вверх для адресов.
  ## Только для степеней двойки.
  let m = align - uint(1)
  let y = x + m
  y - (y and m)

# ==============================================================================
# Safe aligned allocation
# ==============================================================================
#
# Всегда резервируем место под заголовок перед выравниванием:
#
#   [raw pointer header][padding][aligned user area ...]
#
# Поэтому `aligned - sizeof(pointer)` всегда находится внутри выделенного блока.

proc alignedAlloc(size: int): pointer =
  if size <= 0:
    return nil

  let header = uint(sizeof(pointer))
  let total = uint(size) + uint(PoolAlignment) + header

  if total > uint(high(int)):
    return nil

  let raw = allocShared0(int(total))
  if raw == nil:
    return nil

  let rawAddr = cast[uint](raw)
  let alignedAddr = alignUpUint(rawAddr + header, uint(PoolAlignment))

  let headerPtr = cast[ptr pointer](alignedAddr - header)
  headerPtr[] = raw

  return cast[pointer](alignedAddr)

proc alignedDealloc(p: pointer) {.inline.} =
  ## Освобождает ровно то, что вернул `alignedAlloc`.
  ##
  ## Принимает ТОЛЬКО результат `alignedAlloc`: заголовок с сырым указателем
  ## лежит на `sizeof(pointer)` байт перед `p`. Чужой указатель — UB, поэтому
  ## есть хотя бы дешёвая проверка заголовка (issue #80): нулевой указатель
  ## означает, что освобождать нечего.
  if p == nil:
    return

  let header = uint(sizeof(pointer))
  let headerPtr = cast[ptr pointer](cast[uint](p) - header)
  if headerPtr[] == nil:
    return
  deallocShared(headerPtr[])

# ==============================================================================
# Internal state encoding
# ==============================================================================
#
# state = (generation << 1) | status
#
# status:
#   0 = free
#   1 = used
#
# generation монотонно растёт при каждой выдаче блока. Это позволяет отличить
# старый handle от нового владельца того же индекса.

proc freeState(gen: uint64): uint64 {.inline.} =
  gen shl 1

proc usedState(gen: uint64): uint64 {.inline.} =
  (gen shl 1) or 1'u64

proc stateGen(state: uint64): uint64 {.inline.} =
  state shr 1

proc isUsedState(state: uint64): bool {.inline.} =
  (state and 1'u64) != 0'u64

proc nextGeneration(oldGen: uint64): uint64 {.inline.} =
  result = oldGen + 1'u64

  # Генерация 0 зарезервирована под невалидный handle.
  # Переполнение практически невозможно, но защищаемся от него.
  if result == 0'u64 or result > MaxGeneration:
    result = 2'u64

# ==============================================================================
# Tagged free-list head
# ==============================================================================
#
# freeHead = (tag << IndexBits) | (index + 1)
#
# index + 1 используется, чтобы 0 означал "список пуст".
# Тег увеличивается при каждой успешной push/pop операции. Это снижает ABA
# в Treiber stack без 128-битного CAS.

proc packHead(tag: uint64, idxPlus1: int32): uint64 {.inline.} =
  (tag shl IndexBits) or uint64(idxPlus1)

# ==============================================================================
# MemoryPool lifecycle
# ==============================================================================

proc initMemoryPool*(
    pool: var MemoryPool,
    capacity: int32,
    blockSize: int32
): bool =
  ## Инициализирует пул.
  ##
  ## Возвращает false, если:
  ##   - пул уже инициализирован;
  ##   - переданы некорректные capacity/blockSize;
  ##   - не хватило памяти на старте.
  ##
  ## Все аллокации происходят только здесь.

  if pool.blocks != nil:
    return false

  pool.cap = 0'i32
  pool.blkSize = 0'i32
  pool.used.store(0'i32, moRelaxed)
  pool.freeHead.store(0'u64, moRelaxed)

  if capacity <= 0'i32 or blockSize <= 0'i32:
    return false

  let cap = min(capacity, int32(MaxPoolBlocks))
  let capInt = int(cap)

  let blocksPtr = cast[ptr UncheckedArray[PoolBlock]](
    allocShared0(sizeof(PoolBlock) * capInt)
  )

  if blocksPtr == nil:
    return false

  var initialized = 0

  for i in 0 ..< capInt:
    let p = alignedAlloc(int(blockSize))

    if p == nil:
      # Откатываем уже выделенные блоки и память под метаданные.
      for j in 0 ..< initialized:
        alignedDealloc(blocksPtr[j].data)

      deallocShared(blocksPtr)
      return false

    blocksPtr[i].data = p

    if i == capInt - 1:
      blocksPtr[i].nextFree.store(-1'i32, moRelaxed)
    else:
      blocksPtr[i].nextFree.store(int32(i) + 1'i32, moRelaxed)

    # Начальное свободное состояние: generation = 1, status = free.
    blocksPtr[i].state.store(freeState(1'u64), moRelaxed)

    inc initialized

  pool.blocks = blocksPtr
  pool.cap = cap
  pool.blkSize = blockSize
  pool.used.store(0'i32, moRelaxed)
  pool.freeHead.store(packHead(0'u64, 1'i32), moRelaxed)

  return true

proc destroyMemoryPool*(pool: var MemoryPool) =
  ## Освобождает всю память пула.
  ##
  ## Вызывать только вне realtime-контекста и только когда пул больше
  ## не используется ни одним потоком.

  if pool.blocks != nil:
    for i in 0 ..< int(pool.cap):
      alignedDealloc(pool.blocks[i].data)

    deallocShared(pool.blocks)
    pool.blocks = nil

  pool.cap = 0'i32
  pool.blkSize = 0'i32
  pool.used.store(0'i32, moRelaxed)
  pool.freeHead.store(0'u64, moRelaxed)

proc isInitialized*(pool: MemoryPool): bool {.inline.} =
  pool.blocks != nil and pool.cap > 0'i32

# ==============================================================================
# Lock-free pop/push
# ==============================================================================

proc popFreeIndex(pool: var MemoryPool): int32 =
  ## Забирает свободный индекс из lock-free стека.
  ## Возвращает -1, если свободных блоков нет.

  var expected = pool.freeHead.load(moAcquire)

  while true:
    let idxPlus1 = int32(expected and IndexMask)

    if idxPlus1 == 0'i32:
      return -1'i32

    let idx = idxPlus1 - 1'i32

    # Защита от поврежденного состояния. В корректном пуле это недостижимо.
    if idx < 0'i32 or idx >= pool.cap:
      return -1'i32

    let next = pool.blocks[idx].nextFree.load(moAcquire)

    let nextPlus1 =
      if next < 0'i32: 0'u64
      else: uint64(next + 1'i32)

    let tag = expected shr IndexBits
    let desired = ((tag + 1'u64) shl IndexBits) or nextPlus1

    if pool.freeHead.compareExchange(expected, desired):
      return idx

    # compareExchange обновил expected при неудаче; повторяем с новым значением.

  return -1'i32

proc pushFreeIndex(pool: var MemoryPool, idx: int32) =
  ## Возвращает индекс в lock-free стек свободных блоков.

  var expected = pool.freeHead.load(moAcquire)

  while true:
    let oldIdxPlus1 = int32(expected and IndexMask)

    let nextIdx =
      if oldIdxPlus1 == 0'i32: -1'i32
      else: oldIdxPlus1 - 1'i32

    pool.blocks[idx].nextFree.store(nextIdx, moRelaxed)

    let tag = expected shr IndexBits
    let desired = ((tag + 1'u64) shl IndexBits) or uint64(idx + 1'i32)

    if pool.freeHead.compareExchange(expected, desired):
      break

# ==============================================================================
# Core acquire/release
# ==============================================================================

proc allocBlockWithPtr(
    pool: var MemoryPool
): tuple[handle: PoolHandle, data: pointer] =
  ## Внутренняя операция: выдаёт блок и сразу возвращает его стабильный адрес.
  ##
  ## Не выполняет аллокаций. Работает за O(1) по числу операций над блоком,
  ## без поиска по всему пулу.

  let idx = popFreeIndex(pool)

  if idx < 0'i32:
    return (invalidPoolHandle(), nil)

  let st = pool.blocks[idx].state.load(moAcquire)

  # В корректном состоянии блок в free-list всегда свободен.
  # Если вдруг состояние used, это признак повреждения инварианта.
  # В такой ситуации безопаснее не выдавать блок повторно.
  if isUsedState(st):
    return (invalidPoolHandle(), nil)

  let gen = nextGeneration(stateGen(st))

  pool.blocks[idx].state.store(usedState(gen), moRelease)
  discard pool.used.fetchAdd(1'i32, moRelaxed)

  return (PoolHandle(index: idx, generation: gen), pool.blocks[idx].data)

proc allocBlock*(pool: var MemoryPool): PoolHandle {.inline.} =
  ## Выдаёт только handle. Если нужен указатель, используй `blockPtr`.
  allocBlockWithPtr(pool).handle

proc freeBlock*(pool: var MemoryPool, h: PoolHandle): bool =
  ## Освобождает блок по handle.
  ##
  ## Возвращает true только если блок действительно был активен и принадлежал
  ## именно этому handle. Повторный вызов с тем же handle вернёт false.

  if not isValidHandle(h) or h.index >= pool.cap:
    return false

  var expected = usedState(h.generation)
  let desired = freeState(h.generation)

  # CAS гарантирует, что только один поток освободит данный handle.
  if not pool.blocks[h.index].state.compareExchange(expected, desired):
    return false

  # Сначала возвращаем блок в free-list, потом уменьшаем счетчик.
  # Так `usedCount` не будет показывать свободный блок, который еще
  # недоступен через `allocBlock`.
  pushFreeIndex(pool, h.index)
  discard pool.used.fetchSub(1'i32, moRelaxed)

  return true

proc blockPtr*(pool: var MemoryPool, h: PoolHandle): pointer =
  ## Безопасно возвращает указатель на блок, если handle все еще активен.
  ##
  ## Для максимальной производительности в realtime-коде лучше один раз
  ## получить указатель при аренде и дальше работать с ним, не вызывая
  ## эту проверку на каждый буфер.

  if not isValidHandle(h) or h.index >= pool.cap:
    return nil

  let st = pool.blocks[h.index].state.load(moAcquire)

  if stateGen(st) != h.generation or not isUsedState(st):
    return nil

  return pool.blocks[h.index].data

# ==============================================================================
# Introspection
# ==============================================================================

proc capacity*(pool: MemoryPool): int32 {.inline.} =
  pool.cap

proc blockSize*(pool: MemoryPool): int32 {.inline.} =
  pool.blkSize

proc usedCount*(pool: var MemoryPool): int32 {.inline.} =
  ## Приблизительный счётчик для UI/диагностики.
  ## Не использовать для решения «пул полон» — используй allocBlock и проверяй handle.
  pool.used.load(moRelaxed)

proc freeCount*(pool: var MemoryPool): int32 {.inline.} =
  ## Приблизительный счётчик для UI/диагностики.
  ## Не использовать для решения о доступности блоков — используй allocBlock и проверяй handle.
  pool.cap - pool.used.load(moRelaxed)

# ==============================================================================
# AudioBufferPool
# ==============================================================================
#
# AudioBufferPool выделяет память под заголовок AudioBuffer и сразу
# за ним размещает моно-сэмплы с максимальной ёмкостью до MaxBlockSize.
# AudioBuffer.data указывает на эти сэмплы.

type
  AudioBufferHandle* = PoolHandle

  AudioBufferPool* = object
    pool: MemoryPool

  AudioBufferLease* = object
    handle*: AudioBufferHandle
    buffer*: PAudioBuffer

proc audioHeaderOffset(): int {.inline.} =
  alignUpInt(sizeof(AudioBuffer), PoolAlignment)

proc audioBlockBytes(): int {.inline.} =
  audioHeaderOffset() + MaxBlockSize * sizeof(float32)

proc initInlineMonoAudioBuffer(p: pointer, frames: int32) {.inline.} =
  if p == nil:
    return

  let buf = cast[PAudioBuffer](p)
  let offset = audioHeaderOffset()
  let dataAddr = cast[uint](p) + uint(offset)

  buf.data = cast[ptr UncheckedArray[float32]](dataAddr)
  buf.channels = 1'i32
  buf.frames = clamp(frames, 1'i32, int32(MaxBlockSize))
  buf.stride = 1'i32
  # Обнуление — не здесь, а у потребителя через clearAudioBuffer или при синтезе.

proc initAudioBufferPool*(
    pool: var AudioBufferPool,
    capacity: int32
): bool =
  let bytes = audioBlockBytes()

  if bytes <= 0 or bytes > int(high(int32)):
    return false

  initMemoryPool(pool.pool, capacity, int32(bytes))

proc destroyAudioBufferPool*(pool: var AudioBufferPool) {.inline.} =
  destroyMemoryPool(pool.pool)

proc allocAudioBuffer*(
    pool: var AudioBufferPool,
    frames: int32 = int32(MaxBlockSize)
): AudioBufferLease =
  let (h, p) = allocBlockWithPtr(pool.pool)

  if not isValidHandle(h) or p == nil:
    return AudioBufferLease(handle: invalidPoolHandle(), buffer: nil)

  initInlineMonoAudioBuffer(p, frames)

  result = AudioBufferLease(handle: h, buffer: cast[PAudioBuffer](p))

proc freeAudioBuffer*(
    pool: var AudioBufferPool,
    h: AudioBufferHandle
): bool {.inline.} =
  freeBlock(pool.pool, h)

proc freeAudioBuffer*(
    pool: var AudioBufferPool,
    lease: var AudioBufferLease
): bool =
  ## Рекомендуемая форма: после успешного освобождения инвалидирует lease.
  result = freeBlock(pool.pool, lease.handle)

  if result:
    lease.handle = invalidPoolHandle()
    lease.buffer = nil

proc clearAudioBuffer*(buf: PAudioBuffer) {.inline.} =
  ## Обнуляет сэмплы в том объеме, который описан в `frames`.
  ## Для данного пула предполагается моно-буфер.

  if buf == nil or buf.data == nil:
    return

  let n =
    if buf.frames > 0'i32 and buf.frames <= int32(MaxBlockSize):
      int(buf.frames)
    else:
      MaxBlockSize

  for i in 0 ..< n:
    buf.data[i] = 0.0f

# ==============================================================================
# EventQueuePool
# ==============================================================================

type
  EventQueueHandle* = PoolHandle

  EventQueuePool* = object
    pool: MemoryPool

  EventQueueLease* = object
    handle*: EventQueueHandle
    queue*: ptr EventQueue

proc initEventQueuePool*(
    pool: var EventQueuePool,
    capacity: int32
): bool {.inline.} =
  initMemoryPool(pool.pool, capacity, int32(sizeof(EventQueue)))

proc destroyEventQueuePool*(pool: var EventQueuePool) {.inline.} =
  destroyMemoryPool(pool.pool)

proc allocEventQueue*(pool: var EventQueuePool): EventQueueLease =
  let (h, p) = allocBlockWithPtr(pool.pool)

  if not isValidHandle(h) or p == nil:
    return EventQueueLease(handle: invalidPoolHandle(), queue: nil)

  let q = cast[ptr EventQueue](p)

  clearEvents(q)

  result = EventQueueLease(handle: h, queue: q)

proc freeEventQueue*(
    pool: var EventQueuePool,
    h: EventQueueHandle
): bool {.inline.} =
  freeBlock(pool.pool, h)

proc freeEventQueue*(
    pool: var EventQueuePool,
    lease: var EventQueueLease
): bool =
  ## Рекомендуемая форма: после успешного освобождения инвалидирует lease.
  result = freeBlock(pool.pool, lease.handle)

  if result:
    lease.handle = invalidPoolHandle()
    lease.queue = nil

{.pop.}