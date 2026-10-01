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

import std/atomics
import node_interface

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
  # Runtime shared state
  # --------------------------------------------------------------------------

  SchedulerShared = object
    tasks: ptr UncheckedArray[DspTask]
    taskCount: int

    levelCount: int
    executorCount: int

    levelOffsets: ptr UncheckedArray[int32]
    flatTasks: ptr UncheckedArray[int32]
    flatCount: int

    currentCtx: Atomic[pointer]
    currentLevel: Atomic[int32]
    commandBlock: Atomic[uint64]
    stopFlag: Atomic[uint8]

    workerProgress: ptr UncheckedArray[Atomic[uint64]]

  WorkerArg = object
    sh: ptr SchedulerShared
    index: int32

  DspScheduler* = object
    shared: ptr SchedulerShared
    workerArgs: ptr UncheckedArray[WorkerArg]
    threads: array[MaxWorkerThreads, Thread[ptr WorkerArg]]
    workerCount: int
    running: bool

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

proc findResource(list: openArray[ResourceRef], r: ResourceRef): int =
  for i in 0 ..< list.len:
    if list[i] == r:
      return i
  return -1

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
  sh: ptr SchedulerShared,
  taskId: int32,
  ctx: ptr NodeProcessContext
) {.inline, raises: [].} =
  if ctx.isNil:
    return
  let t = addr sh.tasks[int(taskId)]
  if t.process != nil:
    t.process(ctx, t.audio, t.ctrl, t.events, t.userData)

# ----------------------------------------------------------------------------
# Worker thread
# ----------------------------------------------------------------------------

proc workerMain(arg: ptr WorkerArg) {.thread, raises: [].} =
  let sh = arg.sh
  let w = int(arg.index)
  let levelCount = sh.levelCount

  if levelCount == 0:
    return

  let stride = levelCount + 1
  let executor = w + 1
  let base = executor * stride
  var lastBlock = 0'u64

  while true:
    if sh.stopFlag.load(moAcquire) != 0'u8:
      break

    let blockId = sh.commandBlock.load(moAcquire)
    if blockId == 0'u64 or blockId == lastBlock:
      cpuRelax()
      continue

    lastBlock = blockId

    let ctx = cast[ptr NodeProcessContext](sh.currentCtx.load(moAcquire))

    var level = 0
    while level < levelCount:
      # Fix 15: Wait for exact level match. -1 means block is not ready yet.
      while sh.currentLevel.load(moAcquire) != level.int32:
        if sh.stopFlag.load(moAcquire) != 0'u8:
          return
        cpuRelax()

      let start = sh.levelOffsets[base + level]
      let finish = sh.levelOffsets[base + level + 1]

      var p = start
      while p < finish:
        runTask(sh, sh.flatTasks[p], ctx)
        inc p

      let stamp = blockId * uint64(stride) + uint64(level + 1)
      sh.workerProgress[w].store(stamp, moRelease)

      inc level

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

  var resources: seq[ResourceRef] = @[]
  var writers: seq[int32] = @[]

  for i in 0 ..< taskCount:
    for w in descs[i].writes:
      let idx = findResource(resources, w)
      if idx < 0:
        resources.add(w)
        writers.add(i.int32)
      else:
        if writers[idx] != i.int32:
          return false

  var adj = newSeq[seq[int32]](taskCount)
  var indeg = newSeq[int32](taskCount)

  for i in 0 ..< taskCount:
    for r in descs[i].reads:
      let idx = findResource(resources, r)
      if idx >= 0:
        let src = int(writers[idx])
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

proc initScheduler*(
  s: var DspScheduler,
  descs: openArray[TaskDesc],
  workerCount: int
): bool =
  # Note (Fix 16 documentation):
  # initScheduler tears down and recreates threads.
  # Do not call during active realtime audio processing!
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

  sh.taskCount = built.tasks.len
  sh.levelCount = built.levelCount
  sh.executorCount = built.executorCount
  sh.flatCount = built.flat.len

  sh.tasks = allocSharedArray[DspTask](built.tasks.len)
  sh.levelOffsets = allocSharedArray[int32](built.offsets.len)
  sh.flatTasks = allocSharedArray[int32](built.flat.len)

  if built.tasks.len > 0 and sh.tasks.isNil:
    deinitScheduler(s)
    return false

  if built.offsets.len > 0 and sh.levelOffsets.isNil:
    deinitScheduler(s)
    return false

  if built.flat.len > 0 and sh.flatTasks.isNil:
    deinitScheduler(s)
    return false

  let startThreads = wc > 0 and built.levelCount > 0

  if startThreads:
    sh.workerProgress = allocSharedArray[Atomic[uint64]](wc)
    if sh.workerProgress.isNil:
      deinitScheduler(s)
      return false
  else:
    sh.workerProgress = nil

  for i in 0 ..< built.tasks.len:
    sh.tasks[i] = built.tasks[i]

  for i in 0 ..< built.offsets.len:
    sh.levelOffsets[i] = built.offsets[i]

  for i in 0 ..< built.flat.len:
    sh.flatTasks[i] = built.flat[i]

  sh.currentCtx.store(nil, moRelaxed)
  # -1 signifies unstarted block
  sh.currentLevel.store(-1'i32, moRelaxed)
  sh.commandBlock.store(0'u64, moRelaxed)
  sh.stopFlag.store(0'u8, moRelaxed)

  if startThreads:
    for i in 0 ..< wc:
      sh.workerProgress[i].store(0'u64, moRelaxed)

    s.workerArgs = allocSharedArray[WorkerArg](wc)
    if s.workerArgs.isNil:
      deinitScheduler(s)
      return false

    for i in 0 ..< wc:
      s.workerArgs[i] = WorkerArg(sh: sh, index: i.int32)
      createThread(s.threads[i], workerMain, addr s.workerArgs[i])

    s.running = true
  else:
    s.workerArgs = nil
    s.running = false

  return true

proc deinitScheduler*(s: var DspScheduler) =
  if s.shared.isNil:
    s.workerCount = 0
    return

  if s.running and s.workerCount > 0:
    s.shared.stopFlag.store(1'u8, moRelease)

    for i in 0 ..< s.workerCount:
      joinThread(s.threads[i])

    s.running = false

  if not s.shared.tasks.isNil:
    deallocShared(cast[pointer](s.shared.tasks))

  if not s.shared.levelOffsets.isNil:
    deallocShared(cast[pointer](s.shared.levelOffsets))

  if not s.shared.flatTasks.isNil:
    deallocShared(cast[pointer](s.shared.flatTasks))

  if not s.shared.workerProgress.isNil:
    deallocShared(cast[pointer](s.shared.workerProgress))

  if not s.workerArgs.isNil:
    deallocShared(cast[pointer](s.workerArgs))

  deallocShared(cast[pointer](s.shared))

  s.shared = nil
  s.workerArgs = nil
  s.workerCount = 0

proc renderBlock*(
  s: var DspScheduler,
  ctx: ptr NodeProcessContext
) {.raises: [], gcsafe.} =
  let sh = s.shared
  if sh.isNil or sh.levelCount == 0:
    return

  # Fix 15: 1. Reset level to -1 before publishing new command block
  sh.currentLevel.store(-1'i32, moRelease)
  sh.currentCtx.store(ctx, moRelease)
  let blockId = sh.commandBlock.load(moRelaxed) + 1'u64
  sh.commandBlock.store(blockId, moRelease)

  let stride = sh.levelCount + 1

  var level = 0
  while level < sh.levelCount:
    # Fix 15: 2. Explicitly authorize workers to enter this specific level
    sh.currentLevel.store(level.int32, moRelease)

    let start = sh.levelOffsets[level]
    let finish = sh.levelOffsets[level + 1]

    var p = start
    while p < finish:
      runTask(sh, sh.flatTasks[p], ctx)
      inc p

    # Fix 15: 3. Wait for all workers to complete this exact level
    let target = blockId * uint64(stride) + uint64(level + 1)

    var w = 0
    while w < s.workerCount:
      while sh.workerProgress[w].load(moAcquire) < target:
        cpuRelax()
      inc w

    inc level