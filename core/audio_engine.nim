# audio_engine.nim

import
  std/math,
  signal_types,
  ipc_bus,
  node_interface,
  compiled_pipeline

{.pragma: rt, raises: [].}

const
  AudioCommandQueueCapacity = 1024
  AudioMetricQueueCapacity = 256
  AudioRetireQueueCapacity = 1024

  LocalRetireCapacity = 1024
  MaxPendingParams = 256

  # Должно совпадать с твоим секвенсором/хостом.
  PpqResolution = 960.0


type
  TransportRuntime = object
    frame: int64
    sampleRate: float32
    tempo: float64
    playing: bool
    timeSigNum: int32
    timeSigDen: int32
    loopEnabled: bool
    loopStartFrame: int64
    loopEndFrame: int64

  AudioEngine* = object
    blockSize*: int32

    # Audio-owned state
    activePipeline: ptr CompiledPipeline
    transport: TransportRuntime
    firstBlockPending: bool

    # Shared data pool for graph updates / large payloads.
    sharedPool: SharedPool

    # Control -> Audio
    toAudio: MpscQueue[EngineCommand, AudioCommandQueueCapacity]

    # Audio -> Control
    fromAudioMetrics: SpscQueue[EngineMetric, AudioMetricQueueCapacity]
    fromAudioRetire: SpscQueue[ptr CompiledPipeline, AudioRetireQueueCapacity]

    # Audio-local overflow for retired pipelines.
    # Используется, если SPSC retirement очередь временно заполнена.
    localRetire: array[LocalRetireCapacity, ptr CompiledPipeline]
    localRetireCount: int32

    # Публичный снапшот позиции для control plane.
    # Не атомарный сознательно: в большинстве случаев этого достаточно
    # для UI/редактора, а метрики остаются основным источником.
    frameSnapshot: int64

    # Diagnostics
    blockIndex: uint64
    droppedMetrics: uint32
    droppedRetirements: uint32

    # Небольшая очередь параметров, пришедших до появления пайплайна.
    pendingParams: array[MaxPendingParams, EngineCommand]
    pendingParamCount: int32


# ==============================================================================
# Small helpers & Invariant Validators
# ==============================================================================

proc clearStereoBuffer(
  outBuf: ptr UncheckedArray[float32];
  frames: int32
) {.inline, rt.} =
  var i = 0
  let n = frames * 2

  while i < n:
    outBuf[i] = 0.0f
    inc i


proc isPipelineValid(p: ptr CompiledPipeline): bool {.inline, rt.} =
  ## Проверяет инвариант готовности пайплайна к рендерингу:
  ## Пайплайн обязан иметь точку входа:
  ## 1. Либо монолитную процедуру исполнения (renderProc != nil).
  ## 2. Либо пошаговое исполнение с процедурой привязки мастер-буфера
  ##    к выходу драйвера (bindMasterProc != nil).
  if p == nil:
    return true
  result = (p.renderProc != nil) or (p.bindMasterProc != nil and (p.stepCount == 0 or p.steps != nil))


proc flushLocalRetire(engine: ptr AudioEngine) {.rt.} =
  if engine.localRetireCount == 0:
    return

  var pushed: int32 = 0

  while pushed < engine.localRetireCount:
    if engine.fromAudioRetire.push(engine.localRetire[pushed]):
      inc pushed
    else:
      break

  if pushed > 0:
    let remaining = engine.localRetireCount - pushed

    var i: int32 = 0
    while i < remaining:
      engine.localRetire[i] = engine.localRetire[pushed + i]
      inc i

    engine.localRetireCount = remaining


proc retirePipelineRT(
  engine: ptr AudioEngine;
  p: ptr CompiledPipeline
) {.rt.} =
  if p == nil:
    return

  # Сначала пробуем протолкнуть то, что уже лежит в локальном overflow.
  flushLocalRetire(engine)

  # Затем пробуем отправить новый пайплайн.
  if engine.fromAudioRetire.push(p):
    return

  # Если очередь всё ещё заполнена, сохраняем локально.
  if engine.localRetireCount < LocalRetireCapacity.int32:
    engine.localRetire[engine.localRetireCount] = p
    inc engine.localRetireCount
  else:
    # Крайне нежелательная ситуация: контроль не разбирает очередь.
    # В реальном времени удалять нельзя, поэтому здесь только счётчик.
    inc engine.droppedRetirements


proc writeUint64ToBlock(
  blk: var SharedBlock;
  v: uint64
) {.inline.} =
  var i = 0
  while i < 8:
    blk.data[i] = byte((v shr (i * 8)) and 0xFF'u64)
    inc i

  blk.size = 8.uint32


proc readUint64FromBlock(
  blk: var SharedBlock
): uint64 {.inline, rt.} =
  var v: uint64 = 0

  var i = 0
  while i < 8:
    v = v or (uint64(blk.data[i]) shl (i * 8))
    inc i

  v


proc consumeGraphUpdate(
  engine: ptr AudioEngine;
  id: int32
): ptr CompiledPipeline {.rt.} =
  if id < 0 or id >= int32(SharedBlockCount):
    return nil

  if engine.sharedPool.blocks[id].size < 8.uint32:
    engine.sharedPool.releaseBlock(id)
    return nil

  let val = readUint64FromBlock(engine.sharedPool.blocks[id])
  engine.sharedPool.releaseBlock(id)

  when sizeof(pointer) == 8:
    result = cast[ptr CompiledPipeline](val)
  else:
    result = cast[ptr CompiledPipeline](uint32(val and 0xFFFFFFFF'u64))


proc applyParamCommand(
  p: ptr CompiledPipeline;
  cmd: EngineCommand
) {.inline, rt.} =
  if p == nil or p.applyParamProc == nil:
    return

  p.applyParamProc(
    p,
    cmd.nodeId,
    cmd.paramId,
    cmd.value,
    cmd.kind == cmdSetParamNormalized
  )


proc replayPendingParams(
  engine: ptr AudioEngine;
  p: ptr CompiledPipeline
) {.rt.} =
  if p == nil or engine.pendingParamCount == 0:
    return

  var i: int32 = 0

  while i < engine.pendingParamCount:
    applyParamCommand(p, engine.pendingParams[i])
    inc i

  engine.pendingParamCount = 0


# ==============================================================================
# Creation / destruction
# ==============================================================================

proc createAudioEngine*(
  sampleRate: float32;
  blockSize: int32
): ptr AudioEngine =
  if sampleRate <= 0.0f:
    return nil

  if blockSize <= 0 or blockSize > signal_types.MaxBlockSize:
    return nil

  result = cast[ptr AudioEngine](allocShared0(sizeof(AudioEngine)))
  if result == nil:
    return nil

  result.blockSize = blockSize

  result.transport = TransportRuntime(
    frame: 0,
    sampleRate: sampleRate,
    tempo: 120.0,
    playing: false,
    timeSigNum: 4,
    timeSigDen: 4,
    loopEnabled: false,
    loopStartFrame: 0,
    loopEndFrame: 0
  )

  result.firstBlockPending = false
  result.activePipeline = nil
  result.frameSnapshot = 0

  result.blockIndex = 0
  result.droppedMetrics = 0
  result.droppedRetirements = 0

  result.localRetireCount = 0
  result.pendingParamCount = 0

  initSharedPool(result.sharedPool)

  initMpscQueue(result.toAudio)
  initSpscQueue(result.fromAudioMetrics)
  initSpscQueue(result.fromAudioRetire)


proc destroyAudioEngine*(engine: ptr AudioEngine) =
  if engine == nil:
    return

  # Control thread only.
  # Audio callback must already be stopped.

  # Сначала выгребаем команды, которые могли остаться в очереди.
  var cmd: EngineCommand

  while engine.toAudio.pop(cmd):
    case cmd.kind

    of cmdGraphUpdate:
      let p = consumeGraphUpdate(engine, cmd.sharedBufferId)

      # Защита от двойного удаления, если вдруг в очереди
      # оказался тот же самый активный пайплайн.
      if p != nil and p != engine.activePipeline:
        destroyPipeline(p)

    of cmdAutomationBlock, cmdLoadResource:
      if cmd.sharedBufferId >= 0 and cmd.sharedBufferId < int32(SharedBlockCount):
        engine.sharedPool.releaseBlock(cmd.sharedBufferId)

    else:
      discard

  # Затем выгребаем retired pipelines из SPSC.
  var retired: ptr CompiledPipeline

  while engine.fromAudioRetire.pop(retired):
    if retired != nil:
      destroyPipeline(retired)

  # Локальный аудио-оверфлоу.
  var i: int32 = 0
  while i < engine.localRetireCount:
    destroyPipeline(engine.localRetire[i])
    inc i

  # Активный пайплайн.
  if engine.activePipeline != nil:
    destroyPipeline(engine.activePipeline)

  deallocShared(engine)


# ==============================================================================
# Command application
# ==============================================================================

proc applyCommands(engine: ptr AudioEngine) {.rt.} =
  var cmd: EngineCommand

  while engine.toAudio.pop(cmd):
    case cmd.kind

    of cmdTransportPlay:
      if not engine.transport.playing:
        engine.firstBlockPending = true
      engine.transport.playing = true

    of cmdTransportStop:
      engine.transport.playing = false

    of cmdSetTempo:
      if cmd.transportValue > 0.0:
        engine.transport.tempo = cmd.transportValue

    of cmdSetPlayhead:
      # Интерпретируем как секунды.
      if engine.transport.sampleRate > 0.0f:
        var seconds = cmd.transportValue

        if seconds < 0.0:
          seconds = 0.0

        engine.transport.frame =
          int64(seconds * float64(engine.transport.sampleRate))

    of cmdSetParam, cmdSetParamNormalized:
      if engine.activePipeline != nil:
        applyParamCommand(engine.activePipeline, cmd)
      else:
        # Если пайплайна ещё нет, кэшируем разумное количество команд.
        if engine.pendingParamCount < MaxPendingParams.int32:
          engine.pendingParams[engine.pendingParamCount] = cmd
          inc engine.pendingParamCount

    of cmdGraphUpdate:
      let newPipeline = consumeGraphUpdate(engine, cmd.sharedBufferId)
      let oldPipeline = engine.activePipeline

      if newPipeline != oldPipeline:
        # Гарантия инварианта до первого renderBlock:
        # Проверяем корректность структуры и наличие процедур рендеринга/привязки буферов.
        if newPipeline != nil and not isPipelineValid(newPipeline):
          # Пайплайн повреждён или не удовлетворяет контракту привязки мастер-буфера:
          # не активируем его, отправляя сразу на утилизацию во избежание сбоя в RT.
          retirePipelineRT(engine, newPipeline)
        else:
          engine.activePipeline = newPipeline

          if oldPipeline != nil:
            retirePipelineRT(engine, oldPipeline)

          if newPipeline == nil:
            engine.pendingParamCount = 0
          else:
            replayPendingParams(engine, newPipeline)

    of cmdAutomationBlock, cmdLoadResource:
      # Пока просто освобождаем общий блок.
      # Если нужна обработка, добавь отдельный обработчик в CompiledPipeline.
      if cmd.sharedBufferId >= 0 and cmd.sharedBufferId < int32(SharedBlockCount):
        engine.sharedPool.releaseBlock(cmd.sharedBufferId)

    else:
      # cmdNop, MIDI и т.д. пока не обрабатываются.
      discard


# ==============================================================================
# Context / pipeline processing
# ==============================================================================

proc setupContext(
  engine: ptr AudioEngine;
  ctx: var NodeProcessContext;
  offline: bool;
  lastBlock: bool;
  transportActive: bool
) {.rt.} =
  ctx.sampleRate = engine.transport.sampleRate
  ctx.blockSize = engine.blockSize
  ctx.samplePosition = engine.transport.frame

  if engine.transport.sampleRate > 0.0f:
    ctx.timeInSeconds =
      float64(engine.transport.frame) / float64(engine.transport.sampleRate)
  else:
    ctx.timeInSeconds = 0.0

  ctx.transport.tempo = engine.transport.tempo
  ctx.transport.timeSigNum = engine.transport.timeSigNum
  ctx.transport.timeSigDen = engine.transport.timeSigDen

  let beats =
    if engine.transport.tempo > 0.0:
      ctx.timeInSeconds * engine.transport.tempo / 60.0
    else:
      0.0

  # beatPosition — в PPQ.
  # barPosition — в барах.
  ctx.transport.beatPosition = beats * PpqResolution

  if engine.transport.timeSigNum > 0:
    ctx.transport.barPosition = beats / float64(engine.transport.timeSigNum)
  else:
    ctx.transport.barPosition = 0.0

  if engine.transport.loopEnabled and engine.transport.sampleRate > 0.0f:
    let sr = float64(engine.transport.sampleRate)
    ctx.transport.cycleStart = float64(engine.transport.loopStartFrame) / sr
    ctx.transport.cycleEnd = float64(engine.transport.loopEndFrame) / sr
  else:
    ctx.transport.cycleStart = 0.0
    ctx.transport.cycleEnd = 0.0

  var flags: set[ProcessingFlags] = {}

  if offline:
    flags.incl(pfOffline)
  else:
    flags.incl(pfRealtime)

  if transportActive:
    flags.incl(pfTransportPlaying)

  if engine.firstBlockPending:
    flags.incl(pfFirstBlock)

  if lastBlock:
    flags.incl(pfLastBlock)

  ctx.flags = flags
  ctx.transport.flags = flags


proc processPipeline(
  engine: ptr AudioEngine;
  ctx: var NodeProcessContext;
  outBuf: ptr UncheckedArray[float32];
  frames: int32
) {.rt.} =
  ## Исполнение активного DSP-пайплайна.
  ##
  ## Архитектурный контракт привязки памяти:
  ## - Все внутренние соединения графа (audio.inputs[...].data / audio.outputs[...].data)
  ##   выделяются компилятором графа (AudioBufferPool) и обязаны иметь валидные указатели
  ##   на сэмплы (не nil) до отправки пайплайна в движок.
  ## - Процедура bindMasterProc связывает выходной мастер-буфер графа напрямую с
  ##   буфером аудиодрайвера outBuf (zero-copy) на каждом отрендеренном блоке.
  ##
  ## Инвариант исполнения:
  ## При отсутствии renderProc пошаговое выполнение шагов допустимо ТОЛЬКО при
  ## валидном bindMasterProc. Иначе мастер-буфер остаётся непривязанным (data == nil).
  let p = engine.activePipeline

  if p == nil:
    return

  # Вариант 1: пайплайн исполняет себя сам.
  if p.renderProc != nil:
    p.renderProc(addr ctx, p, outBuf, frames)
    return

  # Вариант 2: пошаговое исполнение.
  # Инвариант: привязка мастер-выхода к outBuf обязательна перед исполнением шагов.
  if p.bindMasterProc != nil:
    p.bindMasterProc(p, outBuf, frames)
  else:
    # Защита от SIGSEGV: мастер-буфер не привязан к драйверу, исполнение шагов прерывается.
    return

  if p.steps != nil and p.stepCount > 0:
    var i = 0

    while i < p.stepCount:
      let step = addr p.steps[i]

      if step.processProc != nil:
        step.processProc(
          addr ctx,
          addr step.audio,
          addr step.ctrl,
          addr step.events,
          step.userData
        )

      inc i


proc computeStereoMetrics(
  outBuf: ptr UncheckedArray[float32];
  frames: int32;
  m: var EngineMetric
) {.rt.} =
  var peakL = 0.0f
  var peakR = 0.0f
  var sumL = 0.0f
  var sumR = 0.0f

  var i = 0

  while i < frames:
    let l = outBuf[i * 2]
    let r = outBuf[i * 2 + 1]

    let al = if l < 0.0f: -l else: l
    let ar = if r < 0.0f: -r else: r

    if al > peakL: peakL = al
    if ar > peakR: peakR = ar

    sumL += l * l
    sumR += r * r

    inc i

  m.peakL = peakL
  m.peakR = peakR

  if frames > 0:
    let inv = 1.0f / float32(frames)
    m.rmsL = sqrt(sumL * inv)
    m.rmsR = sqrt(sumR * inv)
  else:
    m.rmsL = 0.0f
    m.rmsR = 0.0f


# ==============================================================================
# Main block renderer
# ==============================================================================

proc renderBlockInternal(
  engine: ptr AudioEngine;
  driverOut: ptr UncheckedArray[float32];
  offline: bool;
  lastBlock: bool;
  forceAdvance: bool
) {.rt.} =
  if engine == nil or driverOut == nil:
    return

  let frames = engine.blockSize

  if frames <= 0:
    return

  inc engine.blockIndex

  # Пытаемся освободить локальный retirement перед началом блока.
  flushLocalRetire(engine)

  applyCommands(engine)

  let transportActive = engine.transport.playing or forceAdvance

  # Всегда очищаем мастер-выход.
  clearStereoBuffer(driverOut, frames)

  if transportActive and engine.activePipeline != nil:
    var ctx: NodeProcessContext
    setupContext(engine, ctx, offline, lastBlock, transportActive)
    processPipeline(engine, ctx, driverOut, frames)

  if engine.firstBlockPending and transportActive:
    engine.firstBlockPending = false

  var metric: EngineMetric

  metric.peakL = 0.0f
  metric.peakR = 0.0f
  metric.rmsL = 0.0f
  metric.rmsR = 0.0f
  metric.cpuLoad = 0.0f
  metric.xruns = 0
  metric.sampleRate = float64(engine.transport.sampleRate)
  metric.bufferSize = uint32(engine.blockSize)

  if transportActive:
    metric.transportState = ord(tsPlaying).uint8
  else:
    metric.transportState = ord(tsStopped).uint8

  metric.activeVoices = 0

  if engine.activePipeline != nil:
    metric.graphVersion = engine.activePipeline.graphVersion
  else:
    metric.graphVersion = 0

  computeStereoMetrics(driverOut, frames, metric)

  if not engine.fromAudioMetrics.push(metric):
    inc engine.droppedMetrics

  if transportActive:
    engine.transport.frame += int64(frames)
    if engine.transport.loopEnabled:
      let ls = engine.transport.loopStartFrame
      let le = engine.transport.loopEndFrame
      if le > ls and engine.transport.frame >= le:
        engine.transport.frame = ls + ((engine.transport.frame - ls) mod (le - ls))

  engine.frameSnapshot = engine.transport.frame


proc renderBlock*(
  engine: ptr AudioEngine;
  driverOut: ptr UncheckedArray[float32]
) {.cdecl, rt.} =
  renderBlockInternal(
    engine,
    driverOut,
    offline = false,
    lastBlock = false,
    forceAdvance = false
  )


# ==============================================================================
# Offline rendering
# ==============================================================================

proc renderOffline*(
  engine: ptr AudioEngine;
  totalFrames: int64;
  outputBuffer: ptr UncheckedArray[float32];
  scratch: ptr UncheckedArray[float32]
) =
  #
  # scratch должен вмещать минимум:
  #   engine.blockSize * 2 float32
  #
  if engine == nil or outputBuffer == nil or scratch == nil:
    return

  if totalFrames <= 0:
    return

  engine.firstBlockPending = true

  var done: int64 = 0

  while done < totalFrames:
    let remaining = totalFrames - done

    if remaining >= engine.blockSize.int64:
      let dst = cast[ptr UncheckedArray[float32]](
        addr outputBuffer[int(done * 2)]
      )

      let isLast =
        (done + engine.blockSize.int64) >= totalFrames

      renderBlockInternal(
        engine,
        dst,
        offline = true,
        lastBlock = isLast,
        forceAdvance = true
      )

      done += engine.blockSize.int64

    else:
      # Финальный неполный блок.
      renderBlockInternal(
        engine,
        scratch,
        offline = true,
        lastBlock = true,
        forceAdvance = true
      )

      var i: int64 = 0

      while i < remaining:
        let outIdx = int((done + i) * 2)
        let inIdx = int(i * 2)

        outputBuffer[outIdx + 0] = scratch[inIdx + 0]
        outputBuffer[outIdx + 1] = scratch[inIdx + 1]

        inc i

      # renderBlockInternal продвинул транспорт на полный блок,
      # а нам нужен только остаток.
      let overshoot = engine.blockSize.int64 - remaining
      engine.transport.frame -= overshoot
      engine.frameSnapshot = engine.transport.frame

      done = totalFrames


# ==============================================================================
# Control-plane command posting & transport control
# ==============================================================================

proc postPlay*(engine: ptr AudioEngine): bool =
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(kind: cmdTransportPlay)
  )


proc postStop*(engine: ptr AudioEngine): bool =
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(kind: cmdTransportStop)
  )


proc postSetTempo*(engine: ptr AudioEngine; bpm: float64): bool =
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(
      kind: cmdSetTempo,
      transportValue: bpm
    )
  )


proc postSeekSeconds*(engine: ptr AudioEngine; seconds: float64): bool =
  if engine == nil:
    return false

  var s = seconds

  if s < 0.0:
    s = 0.0

  engine.toAudio.push(
    EngineCommand(
      kind: cmdSetPlayhead,
      transportValue: s
    )
  )


proc postSeekSamples*(engine: ptr AudioEngine; samples: int64): bool =
  if engine == nil:
    return false

  if engine.transport.sampleRate <= 0.0f:
    return false

  var s = samples

  if s < 0:
    s = 0

  let seconds = float64(s) / float64(engine.transport.sampleRate)
  postSeekSeconds(engine, seconds)


proc setLoop*(
  engine: ptr AudioEngine;
  enabled: bool;
  startFrame: int64;
  endFrame: int64
) =
  ## Управляет границами и состоянием зацикливания воспроизведения (Loop).
  if engine == nil:
    return

  engine.transport.loopEnabled = enabled
  engine.transport.loopStartFrame = startFrame
  engine.transport.loopEndFrame = endFrame


proc isLoopEnabled*(engine: ptr AudioEngine): bool =
  if engine == nil:
    return false
  engine.transport.loopEnabled


proc loopStartFrame*(engine: ptr AudioEngine): int64 =
  if engine == nil:
    return 0
  engine.transport.loopStartFrame


proc loopEndFrame*(engine: ptr AudioEngine): int64 =
  if engine == nil:
    return 0
  engine.transport.loopEndFrame


proc postSetParam*(
  engine: ptr AudioEngine;
  nodeId: int32;
  paramId: uint32;
  value: float32
): bool =
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(
      kind: cmdSetParam,
      nodeId: nodeId,
      paramId: paramId,
      value: value
    )
  )


proc postSetParamNormalized*(
  engine: ptr AudioEngine;
  nodeId: int32;
  paramId: uint32;
  value: float32
): bool =
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(
      kind: cmdSetParamNormalized,
      nodeId: nodeId,
      paramId: paramId,
      value: value
    )
  )


proc postGraphUpdate*(
  engine: ptr AudioEngine;
  p: ptr CompiledPipeline
): bool =
  if engine == nil:
    return false

  let id = engine.sharedPool.acquireBlock()

  if id < 0:
    return false

  let val = cast[uint](p).uint64
  writeUint64ToBlock(engine.sharedPool.blocks[id], val)

  let cmd = EngineCommand(
    kind: cmdGraphUpdate,
    sharedBufferId: id,
    dataSize: 8.uint32
  )

  if engine.toAudio.push(cmd):
    return true

  engine.sharedPool.releaseBlock(id)
  return false


proc postSharedCommand*(
  engine: ptr AudioEngine;
  kind: CommandKind;
  data: pointer;
  size: uint32
): bool =
  if engine == nil:
    return false

  if kind notin {cmdAutomationBlock, cmdLoadResource}:
    return false

  if size > uint32(SharedBlockSize):
    return false

  if size > 0 and data == nil:
    return false

  let id = engine.sharedPool.acquireBlock()

  if id < 0:
    return false

  if size > 0:
    copyMem(
      addr engine.sharedPool.blocks[id].data[0],
      data,
      int(size)
    )

  engine.sharedPool.blocks[id].size = size

  var cmd: EngineCommand

  case kind
  of cmdAutomationBlock:
    cmd = EngineCommand(
      kind: cmdAutomationBlock,
      sharedBufferId: id,
      dataSize: size
    )

  of cmdLoadResource:
    cmd = EngineCommand(
      kind: cmdLoadResource,
      sharedBufferId: id,
      dataSize: size
    )

  else:
    engine.sharedPool.releaseBlock(id)
    return false

  if engine.toAudio.push(cmd):
    return true

  engine.sharedPool.releaseBlock(id)
  return false


# ==============================================================================
# Control-plane polling / queries
# ==============================================================================

proc pollMetrics*(
  engine: ptr AudioEngine;
  m: var EngineMetric
): bool =
  if engine == nil:
    return false

  engine.fromAudioMetrics.pop(m)


proc pollReclamation*(engine: ptr AudioEngine) =
  if engine == nil:
    return

  var p: ptr CompiledPipeline

  while engine.fromAudioRetire.pop(p):
    if p != nil:
      destroyPipeline(p)


proc currentFrame*(engine: ptr AudioEngine): int64 =
  if engine == nil:
    return 0

  engine.frameSnapshot


proc currentPositionSeconds*(engine: ptr AudioEngine): float64 =
  if engine == nil:
    return 0.0

  if engine.transport.sampleRate <= 0.0f:
    return 0.0

  float64(engine.currentFrame()) / float64(engine.transport.sampleRate)


proc droppedMetricsCount*(engine: ptr AudioEngine): uint32 =
  if engine == nil:
    return 0

  engine.droppedMetrics


proc droppedRetirementsCount*(engine: ptr AudioEngine): uint32 =
  if engine == nil:
    return 0

  engine.droppedRetirements