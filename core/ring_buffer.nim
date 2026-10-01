# ring_buffer.nim
#
# Канонический lock-free кольцевой буфер Core (issue #37).
#
# Зачем отдельный модуль:
#   В дереве было ТРИ разных кольца на атомиках (MpscQueue/SpscQueue в
#   ipc_bus, MidiRingBuffer в commons, pa_ringbuffer снаружи). Три
#   реализации одного realtime-примитива — это три разные memory-модели
#   и три повода разойтись. Здесь ровно одна реализация SPSC и её
#   multi-producer-вариант, которыми пользуются все остальные модули.
#
# MANIFEST §9  «Realtime — неприкосновенная зона»
# MANIFEST §77 «Determinism»
# MANIFEST §82 «Запрещается магия»
#
# ==============================================================================
# Модель памяти (memory model) — обязательна к прочтению перед правкой
# ==============================================================================
#
#   producer thread ──push──▶ [ buffer[0..N) ] ──pop──▶ consumer thread
#
# * Индексы `head`/`tail` монотонные uint64, НИКОГДА не нормализуются.
#   Нормализация выполняется только при доступе к массиву через маску
#   `and (N-1)`, что требует N == степень двойки.
# * Занято слотов:  `size  = tail - head`
#   Свободно слотов: `space = N - size`
# * Публикация элемента (producer):  store(tail, moRelease).
#   Потребление элемента (consumer): store(head, moRelease).
#   Парные чтения — load(..., moAcquire).
#   Классический release/acquire обмен: запись в buffer[i] видна consumer'у
#   до того, как он увидит новый tail, и наоборот.
# * Инвариант «один producer / один consumer» для SpscRingBuffer
#   НЕ проверяется в рантайме — его обеспечивает вызывающая сторона.
#   Для нескольких producers используйте MpscRingBuffer.
# * Слоты не перезаписываются молча: при переполнении push возвращает
#   false. Ни один непрочитанный элемент не теряется.
#
# Свойства:
#   - отсутствие аллокаций после init: буфер и индексы лежат inline;
#   - отсутствие блокировок и спин-ожидания в push/pop;
#   - POD-типы: тип элемента не должен содержать GC-полей (ref/string/seq),
#     иначе запись в shared-буфер превратится в скрытую инкрементацию
#     счётчика ссылок в audio-потоке.

import std/atomics

{.push raises: [].}

const
  CacheLineSize* = 64
    ## Размер кэш-линии, по которому выравниваются индексы. Держит
    ## `head` producer'а и `tail` consumer'а в разных линиях, иначе
    ## потоки будут инвалидировать кэш друг друга на каждом push/pop.

# ==============================================================================
# Компиляторные проверки
# ==============================================================================

template requirePow2Size(N: static[int]) =
  ## Размер обязан быть степенью двойки >= 2: только тогда `and (N-1)`
  ## заменяет деление и остаётся корректной маской индекса.
  static:
    doAssert (N and (N - 1)) == 0,
      "RingBuffer: N должен быть степенью двойки, получено " & $N
    doAssert N >= 2,
      "RingBuffer: N должен быть >= 2, получено " & $N

template requirePlainPod(T: typedesc) =
  ## Кольцо передаётся между потоками и, как правило, живёт в shared-памяти.
  ## Тип с GC-полем (ref/string/seq) в таком буфере означает работу GC
  ## в audio-потоке. Такой тип в realtime-кольцо не пускаем вообще.
  ##
  ## Сырые указатели (`ptr`/`pointer`) разрешены: они не GC-managed и
  ## именно так передаётся, например, `ptr CompiledPipeline`.
  when T is string or T is seq or T is ref:
    {.error: "RingBuffer: тип элемента не должен иметь GC-полей (ref/string/seq)".}

template requireRingShape(T: typedesc; N: static[int]) =
  ## Единая точка проверки формы кольца. Вызывается из initRing: Nim не
  ## допускает шаблонные вызовы внутри тела `object`, поэтому проверка
  ## стоит в первой же функции, которую вызывает любой пользователь кольца.
  requirePow2Size(N)
  requirePlainPod(T)

# ==============================================================================
# SPSC — один producer, один consumer
# ==============================================================================

type
  SpscRingBuffer*[T; N: static[int]] = object
    ## Один producer, один consumer. Размер N — степень двойки.
    ## Форма кольца (степень двойки + POD) проверяется в initRing.
    buffer: array[N, T]

    ## Индекс чтения (consumer). Пишет только consumer.
    head: Atomic[uint64]
    pad0: array[CacheLineSize, byte]

    ## Индекс записи (producer). Пишет только producer.
    tail: Atomic[uint64]
    pad1: array[CacheLineSize, byte]

proc initRing*[T; N: static[int]](rb: var SpscRingBuffer[T, N]) {.inline.} =
  ## Холодная сторона: кольцо пустое.
  requireRingShape(T, N)
  rb.head.store(0'u64, moRelaxed)
  rb.tail.store(0'u64, moRelaxed)

proc resetP*[T; N: static[int]](rb: var SpscRingBuffer[T, N]) {.inline.} =
  ## Сброс в пустое состояние.
  ##
  ## ВНИМАНИЕ: НЕ потокобезопасен. Допустим ТОЛЬКО на control-path, когда
  ## producer и consumer гарантированно остановлены (например, при пересборке
  ## графа). В audio-потоке вызывать нельзя.
  rb.initRing()

proc capacity*[T; N: static[int]](rb: SpscRingBuffer[T, N]): int {.inline.} =
  N

proc size*[T; N: static[int]](rb: var SpscRingBuffer[T, N]): int {.inline.} =
  ## Сколько элементов готово к чтению.
  let t = rb.tail.load(moAcquire)
  let h = rb.head.load(moAcquire)
  int(t - h)

proc space*[T; N: static[int]](rb: var SpscRingBuffer[T, N]): int {.inline.} =
  ## Сколько слотов свободно.
  N - rb.size()

proc isEmpty*[T; N: static[int]](rb: var SpscRingBuffer[T, N]): bool {.inline.} =
  rb.tail.load(moAcquire) == rb.head.load(moAcquire)

proc isFull*[T; N: static[int]](rb: var SpscRingBuffer[T, N]): bool {.inline.} =
  (rb.tail.load(moAcquire) - rb.head.load(moAcquire)) >= uint64(N)

proc push*[T; N: static[int]](rb: var SpscRingBuffer[T, N], item: T): bool {.inline.} =
  ## Producer. При переполнении возвращает false и НИЧЕГО не перезаписывает.
  let t = rb.tail.load(moRelaxed)
  let h = rb.head.load(moAcquire)

  if (t - h) >= uint64(N):
    return false

  rb.buffer[int(t and uint64(N - 1))] = item
  # Release: запись buffer[i] должна стать видимой строго до нового tail.
  rb.tail.store(t + 1, moRelease)
  return true

proc pop*[T; N: static[int]](rb: var SpscRingBuffer[T, N], item: var T): bool {.inline.} =
  ## Consumer. При пустом кольце возвращает false.
  let h = rb.head.load(moRelaxed)
  let t = rb.tail.load(moAcquire)

  if h >= t:
    return false

  item = rb.buffer[int(h and uint64(N - 1))]
  # Release: чтение buffer[i] должно стать видимым до нового head.
  rb.head.store(h + 1, moRelease)
  return true

proc pushSlice*[T; N: static[int]](
  rb: var SpscRingBuffer[T, N];
  items: openArray[T]
): int =
  ## Producer-путь для блока POD-элементов.
  ##
  ## Пишет столько элементов, сколько влезает целиком, и возвращает их число.
  ## Хвост, который не влез, НЕ пишется — частичная запись сделала бы
  ## «сколько записано» неоднозначным.
  let t = rb.tail.load(moRelaxed)
  let h = rb.head.load(moAcquire)
  let free = N - int(t - h)

  result = min(free, items.len)
  if result <= 0:
    return

  var i = 0
  let mask = uint64(N - 1)
  while i < result:
    rb.buffer[int((t + uint64(i)) and mask)] = items[i]
    inc i

  rb.tail.store(t + uint64(result), moRelease)

proc popSlice*[T; N: static[int]](
  rb: var SpscRingBuffer[T, N];
  dst: var openArray[T]
): int =
  ## Consumer-путь для блока POD-элементов: читает не больше, чем есть,
  ## и не больше, чем вмещает dst.
  let h = rb.head.load(moRelaxed)
  let t = rb.tail.load(moAcquire)
  let avail = int(t - h)

  result = min(avail, dst.len)
  if result <= 0:
    return

  var i = 0
  let mask = uint64(N - 1)
  while i < result:
    dst[i] = rb.buffer[int((h + uint64(i)) and mask)]
    inc i

  rb.head.store(h + uint64(result), moRelease)

# ==============================================================================
# MPSC — много producers, один consumer
# ==============================================================================
#
# Тот же принцип (монотонные индексы, маска, cache-line padding), но у
# каждого слота есть флаг готовности, а `tail` резервируется CAS-циклом.
#
# Схема:
#   producer:
#     t = tail
#     loop:
#       h = head (acquire)
#       if t - h >= N: return false          # полно, ничего не пишем
#       if CAS(tail, t, t+1): break          # слот зарезервирован за нами
#       t = tail (обновился, повторить)
#     buffer[t & mask] = item
#     ready[t & mask] = 1 (release)          # публикация содержимого
#   consumer:
#     h = head
#     if ready[h & mask] == 0: return false  # producer захватил, но не записал
#     item = buffer[h & mask]
#     ready[h & mask] = 0
#     head = h + 1 (release)
#
# Consumer'у не нужен мьютекс: он читает слот, только увидев ready==1,
# а producer выставляет ready лишь после полной записи buffer.
#
# Инвариант: producer'ы не должны принудительно уничтожаться (pthread_cancel)
# внутри push, иначе слот может остаться зарезервированным без публикации
# и consumer застрянет на нём (Head-of-Line).

type
  MpscRingBuffer*[T; N: static[int]] = object
    ## Форма кольца (степень двойки + POD) проверяется в initRing.
    buffer: array[N, T]
    ready: array[N, Atomic[uint8]]

    ## Индекс чтения (единственный consumer).
    head: Atomic[uint64]
    pad0: array[CacheLineSize, byte]

    ## Индекс записи (producers, резервируется CAS).
    tail: Atomic[uint64]
    pad1: array[CacheLineSize, byte]

proc initRing*[T; N: static[int]](rb: var MpscRingBuffer[T, N]) =
  requireRingShape(T, N)
  rb.head.store(0'u64, moRelaxed)
  rb.tail.store(0'u64, moRelaxed)
  for i in 0 ..< N:
    rb.ready[i].store(0'u8, moRelaxed)

proc resetP*[T; N: static[int]](rb: var MpscRingBuffer[T, N]) =
  ## Control-path сброс. Все producers и consumer обязаны быть остановлены.
  rb.initRing()

proc capacity*[T; N: static[int]](rb: MpscRingBuffer[T, N]): int {.inline.} =
  N

proc isEmpty*[T; N: static[int]](rb: var MpscRingBuffer[T, N]): bool {.inline.} =
  rb.tail.load(moAcquire) == rb.head.load(moAcquire)

proc size*[T; N: static[int]](rb: var MpscRingBuffer[T, N]): int {.inline.} =
  ## Приблизительно: конкурирующие producers могут резервировать слоты,
  ## поэтому точное значение доступно только consumer'у. Для диагностики
  ## этого достаточно.
  let t = rb.tail.load(moAcquire)
  let h = rb.head.load(moAcquire)
  if t <= h: 0 else: int(min(t - h, uint64(N)))

proc push*[T; N: static[int]](rb: var MpscRingBuffer[T, N], item: T): bool =
  ## Любой из producers. При переполнении возвращает false и не перезаписывает
  ## непрочитанные данные.
  var t = rb.tail.load(moRelaxed)

  while true:
    let h = rb.head.load(moAcquire)

    # Защита от underflow: если consumer уже прошёл дальше нашего снимка,
    # t - h может «уехать». Пере-снимаем tail.
    if t < h:
      t = rb.tail.load(moRelaxed)
      continue

    if (t - h) >= uint64(N):
      return false

    if rb.tail.compareExchangeWeak(t, t + 1, moRelaxed, moRelaxed):
      break

  let idx = int(t and uint64(N - 1))
  rb.buffer[idx] = item
  # Release: содержимое слота видно consumer'у до ready == 1.
  rb.ready[idx].store(1'u8, moRelease)
  return true

proc pop*[T; N: static[int]](rb: var MpscRingBuffer[T, N], item: var T): bool =
  ## Только единственный consumer.
  let h = rb.head.load(moRelaxed)
  let idx = int(h and uint64(N - 1))

  # Producer мог зарезервировать слот, но ещё не записать содержимое:
  # возвращаем false мгновенно, без спин-ожидания в audio-потоке.
  if rb.ready[idx].load(moAcquire) == 0'u8:
    return false

  item = rb.buffer[idx]
  rb.ready[idx].store(0'u8, moRelaxed)
  rb.head.store(h + 1, moRelease)
  return true

{.pop.}

