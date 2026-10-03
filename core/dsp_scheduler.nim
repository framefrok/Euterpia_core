# dsp_scheduler.nim
#
# Static block scheduler for EUTERPIA.
#
# Rules:
# - Graph is compiled outside realtime.
# - Schedule is immutable after init.
# - renderBlock() must be allocation-free, lock-free, exception-free.
# - Dependencies include audio, control and event resources.
# - Worker threads are persistent for the lifetime of DspScheduler instance.
#
# Architectural Note (v1 vs v2):
# - In v1, initScheduler/deinitScheduler allocate and join OS threads. This must
#   be called strictly OUTSIDE the realtime audio thread (cold-path only).
# - Hot-swapping graphs during playback without thread teardown requires
#   a persistent worker pool with double-buffered schedule swapping (planned for v2).

when not compileOption("threads"):
  {.error: "dsp_scheduler requires --threads:on".}

import std/[atomics, tables, hashes]
import node_interface
import rt_guard

const
  MaxWorkerThreads* = 8

type
  # --------------------------------------------------------------------------
  # Task / resource model
  # --------------------------------------------------------------------------

  DspTaskProc* = proc(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
  ) {.cdecl, raises: [], gcsafe.}

  DspTask* = object
    process*: DspTaskProc
    audio*: ptr NodeAudioPorts
    ctrl*: ptr NodeControlPorts
    events*: ptr NodeEventPorts
    userData*: pointer
    nodeId*: int32

  ResourceKind* = enum
    rkAudio,
    rkControl,
    rkEvent

  ResourceRef* = object
    kind*: ResourceKind
    node*: int32
    port*: int32
  TaskDesc* = object
    task*: DspTask
    reads*: seq[ResourceRef]
    writes*: seq[ResourceRef]

  # --------------------------------------------------------------------------
  # Schedule slot (issue #9)
  # --------------------------------------------------------------------------
  # Расписание вынесено в ОТДЕЛЬНУЮ структуру и хранится в двух экземплярах.
  # Прежде массивы лежали прямо в SchedulerShared, и смена графа требовала
  # teardown воркеров (а значит разрыва звука и гонки с renderBlock).
  #
  # Слот НЕИЗМЕНЯЕМ после публикации: writer его больше не трогает, пока
  # не убедится, что читателей не осталось (см. `retireSchedule`).
  ScheduleSlot = object
    tasks: ptr UncheckedArray[DspTask]
    taskCount: int

    levelCount: int
    executorCount: int

    levelOffsets: ptr UncheckedArray[int32]
    flatTasks: ptr UncheckedArray[int32]
    flatCount: int

    ## Сколько воркеров/главный поток сейчас читают этот слот. Control-path
    ## ждёт нуля перед переиспользованием слота. Счётчик, а не флаг:
    ## читателей (воркеров) много, и они могут войти в слот не одновременно.
    readers: Atomic[int32]

  # --------------------------------------------------------------------------
  # Runtime shared state
  # --------------------------------------------------------------------------

  SchedulerShared = object
    ## Два слота: `activeIndex` указывает на текущий, второй — кандидат
    ## на следующую смену графа. Слоты аллоцируются ОДИН раз при
    ## `initScheduler` и переиспользуются при каждом `swapSchedule` —
    ## именно это и даёт отсутствие разрывов (issue #9).
    slots: array[2, ptr ScheduleSlot]
    activeIndex: Atomic[int32]

    ## Слот, на котором ИДЁТ текущий блок. Публикует главный поток перед
    ## `commandBlock` (issue #9).
    ##
    ## Почему не читать `activeIndex` в воркере: своп может попасть ровно
    ## между чтением главным потоком и чтением воркером. Тогда главный ждал бы
    ## прогресса по УРОВНЯМ старого расписания, а воркер публиковал бы штампы
    ## по уровням нового (у него своя `stride`). При разном числе уровней
    ## ожидание либо зависало бы навсегда, либо прошло бы раньше времени.
    ## Здесь слот выбирается ОДИН раз на блок и доезжает до воркеров вместе
    ## с командой блока, поэтому обе стороны всегда согласованы.
    blockSlot: Atomic[pointer]

    currentCtx: Atomic[pointer]
    currentLevel: Atomic[int32]
    commandBlock: Atomic[uint64]
    stopFlag: Atomic[uint8]

    ## Диагностика (issue #74). Читается control-path, пишется в audio-потоке.
    ##
    ## `inRender` — сколько рендеров идёт прямо сейчас (0 или 1: рендер
    ## вызывает один поток). По нему `deinitScheduler` проверяет инвариант
    ## «не разбирать планировщик во время рендера».
    ##
    ## `abortedBlocks` — сколько блоков прервано из-за запроса остановки:
    ## воркеры уже выходят и прогресс по уровням не придёт.
    inRender: Atomic[int32]
    abortedBlocks: Atomic[uint64]

    ## Сколько расписаний сменилось за жизнь планировщика. Показывает, что
    ## горячая замена действительно работает, а не проворачивает teardown.
    swaps: Atomic[uint64]

    ## Штамп прогресса: номер блока, до которого воркер домёл (issue #9).
    workerProgress: ptr UncheckedArray[Atomic[uint64]]

    ## Уровень внутри ТЕКУЩЕГО блока, завершённый воркером (issue #9).
    ##
    ## Без него главный не мог дождаться реального завершения уровня:
    ## `workerProgress` публикуется на КАЖДОМ уровне одним и тем же
    ## `blockId`, поэтому со второго уровня ожидание проходило мгновенно,
    ## главный убегал вперёд, а отставший воркер навсегда застревал в
    ## ожидании `currentLevel == level` (сравнение было строгим).
    ## Уровень хранится отдельно и строго растёт внутри блока.
    workerLevel: ptr UncheckedArray[Atomic[int32]]

  WorkerArg = object
    sh: ptr SchedulerShared
    index: int32

  DspScheduler* = object
    shared: ptr SchedulerShared
    workerArgs: ptr UncheckedArray[WorkerArg]
    threads: array[MaxWorkerThreads, Thread[ptr WorkerArg]]
    workerCount: int
    running: bool

    ## Control-path: слот, вышедший из обращения, но ещё не дождавшийся
    ## читателей. `-1` — освобождать нечего.
    pendingRetire: int32

  BuiltSchedule = object
    tasks: seq[DspTask]
    levelCount: int
    executorCount: int
    offsets: seq[int32]
    flat: seq[int32]

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

proc audioResource*(node: int32, port: int32): ResourceRef {.inline.} =
  ResourceRef(kind: rkAudio, node: node, port: port)

proc controlResource*(node: int32, port: int32): ResourceRef {.inline.} =
  ResourceRef(kind: rkControl, node: node, port: port)

proc eventResource*(node: int32, port: int32): ResourceRef {.inline.} =
  ResourceRef(kind: rkEvent, node: node, port: port)

proc `==`*(a, b: ResourceRef): bool {.inline.} =
  a.kind == b.kind and a.node == b.node and a.port == b.port

proc hash*(r: ResourceRef): Hash {.inline.} =
  ## Хеш ресурса: нужен, чтобы `buildSchedule` искал писателя ресурса
  ## за O(1), а не линейным проходом (issue #78).
  var h: Hash = 0
  h = h !& hash(ord(r.kind))
  h = h !& hash(r.node)
  h = h !& hash(r.port)
  result = !$h

# Fix 14: Hardware-assisted pause/yield primitives for spin-loops
proc cpuRelax* {.inline, raises: [].} =
  when defined(vcc):
    when defined(windows):
      {.emit: "YieldProcessor();".}
    else:
      {.emit: "_mm_pause();".}
  elif defined(amd64) or defined(i386):
    {.emit: "__builtin_ia32_pause();".}
  elif defined(arm64) or defined(arm):
    {.emit: "asm volatile(\"yield\" ::: \"memory\");".}
  elif defined(windows):
    {.emit: "SwitchToThread();".}
  else:
    {.emit: "sched_yield();".}

proc allocSharedArray[T](n: int): ptr UncheckedArray[T] =
  if n <= 0:
    return nil
  result = cast[ptr UncheckedArray[T]](allocShared0(n * sizeof(T)))

# ----------------------------------------------------------------------------
# Task execution
# ----------------------------------------------------------------------------

proc runTask(
  slot: ptr ScheduleSlot,
  taskId: int32,
  ctx: ptr NodeProcessContext
) {.inline, raises: [].} =
  if ctx.isNil:
    return
  let t = addr slot.tasks[int(taskId)]
  if t.process != nil:
    t.process(ctx, t.audio, t.ctrl, t.events, t.userData)

# ----------------------------------------------------------------------------
# Worker thread
# ----------------------------------------------------------------------------

proc workerMain(arg: ptr WorkerArg) {.thread, raises: [].} =
  ## Воркер живёт весь lifetime планировщика (issue #9): он НЕ перезапускается
  ## при смене графа, а на каждом блоке заново смотрит `activeIndex`.
  ##
  ## `levelCount` и `stride` поэтому НЕ кэшируются при старте (в v1 они были
  ## константами): новое расписание может иметь другое число уровней, и
  ## закешированное значение увело бы воркер в несуществующий уровень —
  ## либо, что хуже, пропустило бы реальные задачи.
  let sh = arg.sh
  let w = int(arg.index)
  var lastBlock = 0'u64

  while true:
    if sh.stopFlag.load(moAcquire) != 0'u8:
      break

    let blockId = sh.commandBlock.load(moAcquire)
    if blockId == 0'u64 or blockId == lastBlock:
      cpuRelax()
      continue

    # Слот и номер блока читаются ВМЕСТЕ и перечитываются до согласия.
    #
    # Воркер может отстать от главного потока на блок или больше. Тогда
    # `blockSlot` уже указывает на слот СЛЕДУЮЩЕГО блока, а `blockId` —
    # на текущий. Использовать такой слот нельзя: у него своя `stride`
    # (своё число уровней), и вычисленный из неё штамп прогресса вечно
    # оставался бы меньше цели главного потока — тот висел бы в ожидании
    # вечно, а воркер крутился бы в spin. Поэтому пара «блок + слот»
    # принимается только если блок не сменился повторно; иначе ждём
    # следующей согласованной пары.
    var slot = cast[ptr ScheduleSlot](sh.blockSlot.load(moAcquire))
    if slot.isNil or sh.commandBlock.load(moAcquire) != blockId:
      cpuRelax()
      continue

    # Пара согласована: блок принят. Обновляется ДО выполнения, иначе
    # повторный вход крутил бы один и тот же блок бесконечно.
    lastBlock = blockId

    let ctx = cast[ptr NodeProcessContext](sh.currentCtx.load(moAcquire))

    # Читатели: control-path не освободит слот, пока этот счётчик не вернётся
    # в ноль. Инкремент до выполнения, декремент в любом выходе.
    discard slot.readers.fetchAdd(1'i32, moAcquireRelease)
    let levelCount = slot.levelCount
    let stride = levelCount + 1
    # Строка офсетов этого исполнителя в слоте. Главный поток — исполнитель
    # 0, воркеры идут следом; у каждого своя полоса уровней.
    let base = (w + 1) * stride

    if levelCount > 0:
      # Открываем блок: сначала уровень «не выполнен» (-1), затем штамп блока.
      # Порядок обязателен: `release`-барьер гарантирует, что главный, увидев
      # новый `blockId`, увидит и `workerLevel = -1`. В обратном порядке он мог
      # бы принять старый уровень предыдущего блока за текущий и уйти вперёд до
      # реального завершения уровня.
      sh.workerLevel[w].store(-1'i32, moRelease)
      sh.workerProgress[w].store(blockId, moRelease)

      var level = 0
      while level < levelCount:
        # Fix 15: ждём разрешения на уровень. Условие НЕРАВЕНСТВА снизу:
        # главный публикует `currentLevel` строго по возрастанию (0,1,2,...),
        # и воркер обязан ДОГНАТЬ уровень, а не требовать точного совпадения.
        #
        # Это и было причиной дедлока: при строгом `!= level` отставший
        # воркер (главный уже на уровне 3) вечно ждал `currentLevel == 1`,
        # который никогда не вернётся. Воркер держал слот в `readers`, а
        # `awaitSlotFree` следующего `swapSchedule` ждал освобождения вечно.
        #
        # Отрицательный `currentLevel` — защита от рассинхрона: главный такой
        # сентинел больше не публикует (уровень 0 выставляется ДО команды
        # блока), но если он когда-нибудь появится, воркер обязан выйти и
        # опубликовать штамп, иначе главный остался бы в ожидании вечно.
        var stale = false
        while true:
          let cl = sh.currentLevel.load(moAcquire)
          if cl >= level.int32:
            # Уровень разрешён (равен или главный уже ушёл вперёд — догоняем).
            break
          if cl < 0:
            # Блок закрыт: ждать больше нечего.
            sh.workerLevel[w].store(level.int32, moRelease)
            stale = true
            break
          if sh.commandBlock.load(moAcquire) != blockId:
            # Пришёл следующий блок: текущий для нас устарел. Публикуем штамп,
            # чтобы главный предыдущего блока не ждал вечно, и выходим.
            sh.workerLevel[w].store(level.int32, moRelease)
            stale = true
            break
          if sh.stopFlag.load(moAcquire) != 0'u8:
            discard slot.readers.fetchAdd(-1'i32, moAcquireRelease)
            return
          cpuRelax()

        if stale:
          break

        let start = slot.levelOffsets[base + level]
        let finish = slot.levelOffsets[base + level + 1]

        var p = start
        while p < finish:
          runTask(slot, slot.flatTasks[p], ctx)
          inc p

        # Публикуем завершённый УРОВЕНЬ этого блока. Именно по нему главный
        # ждёт реального окончания уровня; `blockId` растёт медленнее и один
        # на весь блок, поэтому его для синхронизации уровней недостаточно.
        sh.workerLevel[w].store(level.int32, moRelease)
        sh.workerProgress[w].store(blockId, moRelease)

        inc level

    discard slot.readers.fetchAdd(-1'i32, moAcquireRelease)

# ----------------------------------------------------------------------------
# Compile-time schedule builder
# ----------------------------------------------------------------------------

proc addEdge(
  adj: var seq[seq[int32]],
  indeg: var seq[int32],
  src, dst: int
) =
  if src == dst:
    return

  for x in adj[src]:
    if x == dst.int32:
      return

  adj[src].add(dst.int32)
  inc indeg[dst]

proc buildSchedule(
  descs: openArray[TaskDesc],
  workerCount: int,
  outSchedule: var BuiltSchedule
): bool =
  let taskCount = descs.len
  let executorCount = workerCount + 1

  outSchedule.tasks = @[]
  outSchedule.levelCount = 0
  outSchedule.executorCount = executorCount
  outSchedule.offsets = @[]
  outSchedule.flat = @[]

  if taskCount == 0:
    outSchedule.offsets = newSeq[int32](executorCount)
    return true

  # Ресурс -> индекс пишущей задачи. Раньше это были два параллельных
  # списка с линейным поиском, что давало O((N·M)^2) на построение
  # расписания; теперь O(1) на ресурс (issue #78).
  var writers = initTable[ResourceRef, int32]()

  for i in 0 ..< taskCount:
    for w in descs[i].writes:
      if writers.hasKey(w):
        # Второй писатель того же ресурса — расписание невозможно.
        if writers[w] != i.int32:
          return false
      else:
        writers[w] = i.int32

  var adj = newSeq[seq[int32]](taskCount)
  var indeg = newSeq[int32](taskCount)

  for i in 0 ..< taskCount:
    for r in descs[i].reads:
      let w = writers.getOrDefault(r, -1'i32)
      if w >= 0:
        let src = int(w)
        addEdge(adj, indeg, src, i)

  var current = newSeq[int32]()
  var nextLevel = newSeq[int32]()

  for i in 0 ..< taskCount:
    if indeg[i] == 0:
      current.add(i.int32)

  var processed = 0
  var levelCount = 0
  var assignCounter = 0

  var buckets = newSeq[seq[int32]](executorCount)
  var execFlat = newSeq[seq[int32]](executorCount)
  var execOffsets = newSeq[seq[int32]](executorCount)

  for e in 0 ..< executorCount:
    execOffsets[e] = @[0'i32]

  while current.len > 0:
    for e in 0 ..< executorCount:
      buckets[e].setLen(0)

    for t in current:
      let e = assignCounter mod executorCount
      buckets[e].add(t)
      inc assignCounter

    for e in 0 ..< executorCount:
      for item in buckets[e]:
        execFlat[e].add(item)
      execOffsets[e].add(execFlat[e].len.int32)

    inc levelCount
    nextLevel.setLen(0)

    for t in current:
      inc processed
      for dst in adj[int(t)]:
        dec indeg[int(dst)]
        if indeg[int(dst)] == 0:
          nextLevel.add(dst)

    swap(current, nextLevel)

  if processed != taskCount:
    return false

  let stride = levelCount + 1

  outSchedule.levelCount = levelCount
  outSchedule.executorCount = executorCount
  outSchedule.offsets = newSeq[int32](executorCount * stride)
  outSchedule.flat = newSeq[int32]()

  for e in 0 ..< executorCount:
    var pos = outSchedule.flat.len.int32
    outSchedule.offsets[e * stride + 0] = pos

    for l in 0 ..< levelCount:
      let start = execOffsets[e][l]
      let finish = execOffsets[e][l + 1]

      var k = int(start)
      while k < int(finish):
        outSchedule.flat.add(execFlat[e][k])
        inc k

      pos = outSchedule.flat.len.int32
      outSchedule.offsets[e * stride + l + 1] = pos

  outSchedule.tasks = newSeq[DspTask](taskCount)
  for i in 0 ..< taskCount:
    outSchedule.tasks[i] = descs[i].task

  return true

# ----------------------------------------------------------------------------
# Public scheduler API
# ----------------------------------------------------------------------------

proc deinitScheduler*(s: var DspScheduler)

proc freeSlotArrays(slot: ptr ScheduleSlot) =
  ## Освободить массивы слота. Control-path (cold): вызывается при
  ## переиспользовании слота и при `deinitScheduler`.
  if slot.isNil:
    return
  if not slot.tasks.isNil:
    deallocShared(cast[pointer](slot.tasks))
    slot.tasks = nil
  if not slot.levelOffsets.isNil:
    deallocShared(cast[pointer](slot.levelOffsets))
    slot.levelOffsets = nil
  if not slot.flatTasks.isNil:
    deallocShared(cast[pointer](slot.flatTasks))
    slot.flatTasks = nil
  slot.taskCount = 0
  slot.flatCount = 0
  slot.levelCount = 0
  slot.executorCount = 0

proc publishSlot(slot: ptr ScheduleSlot, built: BuiltSchedule): bool =
  ## Залить построенное расписание в слот. Control-path (cold).
  ##
  ## Вызывается ТОЛЬКО когда `slot.readers == 0` (см. `swapSchedule`),
  ## поэтому запись в поля слота не гоняется с воркерами.
  slot.taskCount = built.tasks.len
  slot.levelCount = built.levelCount
  slot.executorCount = built.executorCount
  slot.flatCount = built.flat.len

  slot.tasks = allocSharedArray[DspTask](built.tasks.len)
  slot.levelOffsets = allocSharedArray[int32](built.offsets.len)
  slot.flatTasks = allocSharedArray[int32](built.flat.len)

  if built.tasks.len > 0 and slot.tasks.isNil:
    freeSlotArrays(slot)
    return false
  if built.offsets.len > 0 and slot.levelOffsets.isNil:
    freeSlotArrays(slot)
    return false
  if built.flat.len > 0 and slot.flatTasks.isNil:
    freeSlotArrays(slot)
    return false

  for i in 0 ..< built.tasks.len:
    slot.tasks[i] = built.tasks[i]
  for i in 0 ..< built.offsets.len:
    slot.levelOffsets[i] = built.offsets[i]
  for i in 0 ..< built.flat.len:
    slot.flatTasks[i] = built.flat[i]

  slot.readers.store(0'i32, moRelaxed)
  return true

proc initScheduler*(
  s: var DspScheduler,
  descs: openArray[TaskDesc],
  workerCount: int
): bool =
  ## Cold-path: создать пул воркеров и первое расписание.
  ##
  ## ВАЖНО (issue #9): после инициализации смена графа во время
  ## воспроизведения делается через `swapSchedule`, а НЕ повторным
  ## `initScheduler`. Повторный `initScheduler` по-прежнему делает teardown
  ## потоков — это холодный путь (старт сессии, смена числа воркеров).
  deinitScheduler(s)

  let wc =
    if workerCount < 0: 0
    elif workerCount > MaxWorkerThreads: MaxWorkerThreads
    else: workerCount

  var built: BuiltSchedule
  if not buildSchedule(descs, wc, built):
    return false

  let sh = cast[ptr SchedulerShared](allocShared0(sizeof(SchedulerShared)))
  if sh.isNil:
    return false

  s.shared = sh
  s.workerCount = wc
  s.pendingRetire = -1

  # Оба слота аллоцируются ОДИН раз и живут до deinit (issue #9).
  for i in 0 .. 1:
    sh.slots[i] = cast[ptr ScheduleSlot](allocShared0(sizeof(ScheduleSlot)))
    if sh.slots[i].isNil:
      deinitScheduler(s)
      return false

  if not publishSlot(sh.slots[0], built):
    deinitScheduler(s)
    return false

  sh.activeIndex.store(0'i32, moRelaxed)

  # Воркеры поднимаются, только если в первом расписании есть уровни.
  let startThreads = wc > 0 and built.levelCount > 0

  if startThreads:
    sh.workerProgress = allocSharedArray[Atomic[uint64]](wc)
    if sh.workerProgress.isNil:
      deinitScheduler(s)
      return false
    for i in 0 ..< wc:
      sh.workerProgress[i].store(0'u64, moRelaxed)

    sh.workerLevel = allocSharedArray[Atomic[int32]](wc)
    if sh.workerLevel.isNil:
      deinitScheduler(s)
      return false
    for i in 0 ..< wc:
      sh.workerLevel[i].store(-1'i32, moRelaxed)

    s.workerArgs = allocSharedArray[WorkerArg](wc)
    if s.workerArgs.isNil:
      deinitScheduler(s)
      return false

    for i in 0 ..< wc:
      s.workerArgs[i] = WorkerArg(sh: sh, index: i.int32)
      createThread(s.threads[i], workerMain, addr s.workerArgs[i])

    s.running = true
  else:
    sh.workerProgress = nil
    sh.workerLevel = nil
    s.workerArgs = nil
    s.running = false

  sh.currentCtx.store(nil, moRelaxed)
  # -1 signifies unstarted block
  sh.currentLevel.store(-1'i32, moRelaxed)
  sh.commandBlock.store(0'u64, moRelaxed)
  sh.stopFlag.store(0'u8, moRelaxed)
  sh.inRender.store(0'i32, moRelaxed)
  sh.abortedBlocks.store(0'u64, moRelaxed)
  sh.swaps.store(0'u64, moRelaxed)

  return true

proc ensureWorkers*(s: var DspScheduler): bool =
  ## Control-path: поднять пул воркеров, если он ещё не поднят.
  ##
  ## Нужен для случая «первое расписание пустое, потоки не создавались»:
  ## без этого `swapSchedule` на живой сессии молча оставил бы рендер
  ## без параллелизма. Возвращает false, если воркеров не нужно или
  ## создание не удалось.
  if s.shared.isNil:
    return false
  if s.running:
    return true
  if s.workerCount <= 0:
    return false

  let sh = s.shared

  if sh.workerProgress.isNil:
    sh.workerProgress = allocSharedArray[Atomic[uint64]](s.workerCount)
    if sh.workerProgress.isNil:
      return false

  for i in 0 ..< s.workerCount:
    sh.workerProgress[i].store(0'u64, moRelaxed)

  if sh.workerLevel.isNil:
    sh.workerLevel = allocSharedArray[Atomic[int32]](s.workerCount)
    if sh.workerLevel.isNil:
      return false

  for i in 0 ..< s.workerCount:
    sh.workerLevel[i].store(-1'i32, moRelaxed)

  if s.workerArgs.isNil:
    s.workerArgs = allocSharedArray[WorkerArg](s.workerCount)
    if s.workerArgs.isNil:
      return false

  for i in 0 ..< s.workerCount:
    s.workerArgs[i] = WorkerArg(sh: sh, index: i.int32)
    createThread(s.threads[i], workerMain, addr s.workerArgs[i])

  s.running = true
  return true

proc reclaimRetired*(s: var DspScheduler) =
  ## Control-path: освободить слот, вышедший из обращения, как только его
  ## читатели рассосались. Ничего не делает, если воркеры ещё в старом слоте.
  if s.shared.isNil or s.pendingRetire < 0:
    return
  let idx = int(s.pendingRetire)
  if idx < 0 or idx > 1:
    s.pendingRetire = -1
    return
  let slot = s.shared.slots[idx]
  if slot.isNil:
    s.pendingRetire = -1
    return
  if slot.readers.load(moAcquire) != 0:
    return
  freeSlotArrays(slot)
  s.pendingRetire = -1

proc awaitSlotFree(slot: ptr ScheduleSlot, sh: ptr SchedulerShared): bool =
  ## Control-path: дождаться, пока из слота выйдут ВСЕ читатели.
  ##
  ## Раньше `swapSchedule` в такой ситуации просто возвращал `false`, и
  ## смена графа могла молча не произойти: из 10 000 свопов около 1 700
  ## отклонялись, потому что воркер ещё доигрывал предыдущий блок. Для
  ## control-path это неприемлемо — «добавил ноду, а она не появилась».
  ##
  ## Ждать здесь безопасно: читатель держит слот только на время одного
  ## блока, а `stopFlag` даёт аварийный выход, если audio-поток остановлен
  ## и блок никогда не завершится.
  if slot.isNil:
    return false
  while slot.readers.load(moAcquire) != 0:
    if sh.stopFlag.load(moAcquire) != 0'u8:
      return false
    cpuRelax()
  return true

proc swapSchedule*(
  s: var DspScheduler,
  descs: openArray[TaskDesc]
): bool =
  ## Control-path: заменить расписание БЕЗ teardown воркеров (issue #9).
  ##
  ## Порядок (двухбуферная публикация):
  ##   1. достроить новое расписание в НЕактивный слот;
  ##   2. опубликовать индекс через `activeIndex` (release);
  ##   3. старый слот пометить к утилизации — память освободится позже,
  ##      когда воркеры выйдут из него (`reclaimRetired`).
  ##
  ## Своп разрешён во время воспроизведения: audio-поток подхватит новый
  ## слот на границе блока, а не посреди уровня.
  if s.shared.isNil:
    return false

  let sh = s.shared

  # Освобождаем прошлый отставной слот, если он уже никому не нужен:
  # без этого второй своп подряд не смог бы переиспользовать слот.
  reclaimRetired(s)

  let wc = s.workerCount

  var built: BuiltSchedule
  if not buildSchedule(descs, wc, built):
    return false

  # Кандидат — слот, который сейчас НЕ активен.
  let target = 1 - sh.activeIndex.load(moAcquire)
  if target < 0 or target > 1:
    return false
  let slot = sh.slots[target]

  # Слот должен быть свободен. Если воркер ещё доигрывает на нём блок,
  # ЖДЁМ освобождения: молча отказывать в смене графа нельзя, иначе
  # «добавил ноду во время playback» тихо не сработает.
  if not awaitSlotFree(slot, sh):
    return false

  # Отставной слот освобождаем только после того, как кандидат признан
  # свободным: иначе второй своп подряд не смог бы освободить слот.
  if s.pendingRetire == target.int32:
    freeSlotArrays(slot)
    s.pendingRetire = -1

  if not publishSlot(slot, built):
    return false

  # Публикация. Барьер release/acquire гарантирует, что воркер, увидевший
  # новый индекс, увидит и полностью залитые массивы.
  let old = sh.activeIndex.exchange(target, moAcquireRelease)
  s.pendingRetire = old
  discard sh.swaps.fetchAdd(1'u64, moRelaxed)

  # Первое непустое расписание может прийти на «пустой» сессии — воркеры
  # тогда не были подняты. Поднимаем их здесь, а не в renderBlock.
  if built.levelCount > 0 and wc > 0 and not s.running:
    discard ensureWorkers(s)

  return true

proc scheduleSwaps*(s: DspScheduler): uint64 =
  ## Сколько расписаний сменилось через `swapSchedule`. Control-path.
  if s.shared.isNil:
    return 0'u64
  s.shared.swaps.load(moRelaxed)

proc activeTaskCount*(s: DspScheduler): int =
  ## Сколько задач в текущем расписании. Control-path (диагностика).
  if s.shared.isNil:
    return 0
  let idx = s.shared.activeIndex.load(moAcquire)
  if idx < 0 or idx > 1:
    return 0
  let slot = s.shared.slots[idx]
  if slot.isNil:
    return 0
  slot.taskCount

proc activeLevelCount*(s: DspScheduler): int =
  ## Сколько уровней в текущем расписании. Control-path (диагностика).
  if s.shared.isNil:
    return 0
  let idx = s.shared.activeIndex.load(moAcquire)
  if idx < 0 or idx > 1:
    return 0
  let slot = s.shared.slots[idx]
  if slot.isNil:
    return 0
  slot.levelCount


proc requestStop*(s: var DspScheduler) {.raises: [], gcsafe.} =
  ## Control-path: попросить планировщик остановиться. Воркеры выходят, а
  ## `renderBlock` прерывает текущий/следующий блок вместо ожидания
  ## прогресса, которого уже не будет (issue #74).
  ##
  ## Вызывать во время активного рендера всё равно нельзя (см.
  ## `deinitScheduler`): это аварийный выход, а не штатный способ смены
  ## расписания.
  if s.shared.isNil:
    return
  s.shared.stopFlag.store(1'u8, moRelease)

proc abortedBlocks*(s: DspScheduler): uint64 =
  ## Сколько блоков прервано из-за запроса остановки. Control-path.
  if s.shared.isNil:
    return 0'u64
  s.shared.abortedBlocks.load(moRelaxed)

proc inRenderCount*(s: DspScheduler): int32 =
  ## Сколько рендеров идёт прямо сейчас (0 или 1). Control-path:
  ## `deinitScheduler` по этому значению проверяет инвариант владения.
  if s.shared.isNil:
    return 0'i32
  s.shared.inRender.load(moAcquire)

proc deinitScheduler*(s: var DspScheduler) =
  if s.shared.isNil:
    s.workerCount = 0
    return

  # Инвариант владения (issue #74): разбирать планировщик нельзя, пока идёт
  # рендер — воркеры выйдут, прогресс не придёт, а `renderBlock` остался бы
  # в spin-loop (и читал бы уже освобождённую shared-память). Проверяем это
  # явно, чтобы нарушение было видно в debug, а не превращалось в зависание.
  doAssert(s.shared.inRender.load(moAcquire) == 0'i32,
    "deinitScheduler вызван во время renderBlock: сначала остановите рендер")

  if s.running and s.workerCount > 0:
    s.shared.stopFlag.store(1'u8, moRelease)

    for i in 0 ..< s.workerCount:
      joinThread(s.threads[i])

    s.running = false

  # Массивы расписания теперь живут в слотах (issue #9) и освобождаются
  # в цикле ниже — отдельных полей tasks/levelOffsets/flatTasks в
  # SchedulerShared больше нет.
  if not s.shared.workerProgress.isNil:
    deallocShared(cast[pointer](s.shared.workerProgress))

  if not s.shared.workerLevel.isNil:
    deallocShared(cast[pointer](s.shared.workerLevel))

  # Оба слота освобождаются целиком: к моменту deinit воркеры уже joined,
  # поэтому читателей не осталось (проверено doAssert выше по inRender).
  for i in 0 .. 1:
    if not s.shared.slots[i].isNil:
      freeSlotArrays(s.shared.slots[i])
      deallocShared(cast[pointer](s.shared.slots[i]))
      s.shared.slots[i] = nil

  if not s.workerArgs.isNil:
    deallocShared(cast[pointer](s.workerArgs))

  deallocShared(cast[pointer](s.shared))

  s.shared = nil
  s.workerArgs = nil
  s.workerCount = 0
  s.pendingRetire = -1

proc renderBlock*(
  s: var DspScheduler,
  ctx: ptr NodeProcessContext
) {.raises: [], gcsafe.} =
  ## Рендер одного блока: главный поток выполняет задачи уровня, затем ждёт,
  ## пока воркеры добьют свой уровень.
  ##
  ## Ожидание ОБЯЗАНО проверять `stopFlag` (issue #74): `deinitScheduler`
  ## выставляет флаг, воркеры после него выходят из `workerMain`, и прогресс
  ## уже не публикуется. Без проверки главный поток зависал бы в spin-loop
  ## навсегда. Достижимо это не в теории: `initScheduler` первой строкой
  ## вызывает `deinitScheduler`, то есть повторная инициализация на живом
  ## планировщике попадала бы в этот сценарий.
  ##
  ## При прерывании блок НЕ доводится до конца: часть уровней может быть не
  ## выполнена, поэтому вызывающий обязан трактовать такой блок как
  ## недостоверный (обычно это уже остановка рендера).
  let sh = s.shared
  if sh.isNil:
    return

  # Активный слот читается ОДИН раз на весь блок (issue #9). Своп расписания
  # может произойти в любой момент, но блок обязан быть однородным: смешивание
  # двух карт задач внутри одного блока нарушило бы порядок зависимостей.
  let slot = sh.slots[sh.activeIndex.load(moAcquire)]
  if slot.isNil or slot.levelCount == 0:
    return

  # После запроса остановки новый блок не начинаем: воркеры уже выходят.
  if sh.stopFlag.load(moAcquire) != 0'u8:
    discard sh.abortedBlocks.fetchAdd(1'u64, moRelaxed)
    return

  # Realtime-guard (issue #11): главный поток исполняет уровни сам,
  # поэтому он тоже audio-поток. Ранние `return` выше — до входа в scope.
  rtScope():
    # Инвариант владения: планировщик нельзя разбирать во время рендера.
    discard sh.inRender.fetchAdd(1'i32, moAcquireRelease)
    # Главный поток — тоже читатель слота: пока мы здесь, control-path
    # не освободит и не перезапишет его (важно для `swapSchedule`).
    discard slot.readers.fetchAdd(1'i32, moAcquireRelease)
    defer:
      discard slot.readers.fetchAdd(-1'i32, moAcquireRelease)
      discard sh.inRender.fetchAdd(-1'i32, moAcquireRelease)

    let levelCount = slot.levelCount

    # Уровень НЕ сбрасываем в -1: этот сентинел означает «блок закрыт», и
    # воркер, увидев его, немедленно вышел бы из только что начатого блока
    # (а начальное значение в `initScheduler` как раз -1). Публикуем сразу
    # уровень 0 — он гарантированно есть, ведь `levelCount > 0` проверено выше.
    sh.currentLevel.store(0'i32, moRelease)
    sh.currentCtx.store(ctx, moRelease)

    # Слот и номер блока публикуются в строгом порядке: сначала слот,
    # потом команда. Воркер читает пару «commandBlock -> blockSlot» и
    # перепроверяет `commandBlock`; при таком порядке он не может получить
    # слот от СЛЕДУЮЩЕГО блока вместе с номером ТЕКУЩЕГО.
    let blockId = sh.commandBlock.load(moRelaxed) + 1'u64
    sh.blockSlot.store(cast[pointer](slot), moRelease)
    sh.commandBlock.store(blockId, moRelease)

    # Каждому блоку присвоен СВОЙ номер, и прогресс воркера кодируется как
    # пара «блок + уровень». Раньше здесь стоял монолитный счётчик
    # `blockId * stride + level`, где `stride = levelCount + 1`.
    #
    # Эта схема ломалась при смене числа уровней: stride менялся (например
    # с 9 на 3), и цель ожидания уезжала за пределы, достижимые старым
    # штампом. Воркер тогда публиковал прогресс уже никогда, а главный
    # поток ждал вечно — дедлок, воспроизводимый обычной сменой графа.
    #
    # Теперь уровень хранится ОТДЕЛЬНО от номера блока. Сравнение идёт по
    # номеру блока, а уровень внутри блока строго растёт, поэтому штамп от
    # предыдущего блока не может удовлетворить ожидание текущего ни при
    # каком stride.
    let target = blockId

    var level = 0
    while level < levelCount:
      # Fix 15: 2. Explicitly authorize workers to enter this specific level
      sh.currentLevel.store(level.int32, moRelease)

      let start = slot.levelOffsets[level]
      let finish = slot.levelOffsets[level + 1]

      var p = start
      while p < finish:
        runTask(slot, slot.flatTasks[p], ctx)
        inc p

      # Fix 15: 3. Ждём, пока КАЖДЫЙ воркер реально добьёт этот уровень.
      #
      # Одного `workerProgress == blockId` недостаточно: он публикуется один
      # раз на весь блок, поэтому со второго уровня условие было бы истинно
      # сразу и главный убегал бы вперёд. Именно из-за этого отставший воркер
      # навсегда застревал в ожидании своего уровня, удерживал слот в
      # `readers`, и следующий `swapSchedule` ждал освобождения вечно.
      # Завершение уровня подтверждается отдельным штампом `workerLevel`.
      var w = 0
      while w < s.workerCount:
        while true:
          let bp = sh.workerProgress[w].load(moAcquire)
          if bp == target and
             sh.workerLevel[w].load(moAcquire) >= level.int32:
            break
          # Запрос остановки пришёл во время ожидания: выходим, иначе тут
          # будет вечный spin (issue #74).
          if sh.stopFlag.load(moAcquire) != 0'u8:
            discard sh.abortedBlocks.fetchAdd(1'u64, moRelaxed)
            return
          cpuRelax()
        inc w

      inc level