# audio_engine.nim

import
  std/math,
  std/atomics,
  signal_types,
  ipc_bus,
  node_interface,
  compiled_pipeline,
  audio_recorder,
  rt_guard

## Прагма realtime-пути: собрана из двух требований контракта (MANIFEST §9/§10).
## `raises: []` — никаких исключений в audio-потоке;
## `gcsafe` — никаких обращений к глобальному GC-состоянию (issue #16).
## Всё, что помечено `{.rt.}`, проверяется компилятором на оба требования.
{.pragma: rt, raises: [], gcsafe.}

const
  AudioCommandQueueCapacity = 1024
  AudioMetricQueueCapacity = 256

  ## Ёмкость SPSC-очереди утилизированных пайплайнов: столько смен графа
  ## движок готов отдать control-plane через `pollReclamation` (issue #73).
  ##
  ## Увеличена (issue #385): фиксированный retirement-storage обязан с запасом
  ## покрывать `MaxRetireBacklog`, чтобы RT-путь никогда не освобождал память.
  AudioRetireQueueCapacity* = 4096

  ## Ёмкость локального overflow утилизации: столько пайплайнов движок
  ## держит в audio-потоке, если SPSC-очередь полна (issue #73, #385).
  LocalRetireCapacity* = 4096

  ## Максимум одновременных «незакрытых» смен графа (backpressure, #385).
  ## Строго меньше суммы ёмкостей утилизации (queue + localRetire): при любом
  ## раскладе хотя бы один уровень остаётся свободным, поэтому `retirePipelineRT`
  ## не может упереться в оба уровня и НЕ освобождает пайплайн в audio-потоке.
  MaxRetireBacklog* = AudioRetireQueueCapacity

  MaxPendingParams = 256

  ## Верхняя граница входного тракта. Ядро работает с моно/стерео входом;
  ## всё, что шире, микшируется до первых каналов. Такой же предел
  ## используют стерео-ноды (maxChannels = 2 в descriptor'ах).
  MaxInputChannels* = 2

  # Должно совпадать с твоим секвенсором/хостом.
  PpqResolution = 960.0


type
  TransportRuntime = object
    ## Состояние транспорта ВНУТРИ audio-потока. Меняется только из
    ## `applyCommands` (lock-free очередь), никогда — с control-path напрямую
    ## (#257). `state` различает стоп/игру/запись/паузу; предыдущее поле
    ## `playing: bool` не могло отличить паузу от стопа, хотя контракт
    ## (`core/transport.nim`) это требует.
    frame: int64
    sampleRate: float32
    tempo: float64
    state: TransportState
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
    #
    # Атомарный (issue #384): пишется в audio-потоке, читается control-path
    # (`currentFrame`). Обычный int64 давал формальный data race, а на 32-бит
    # платформах — рваный (torn) int64: control мог увидеть половину старого
    # и половину нового значения позиции.
    frameSnapshot: Atomic[int64]

    # Diagnostics
    blockIndex: uint64
    ## Оба — RT-инкремент / control-чтение (issue #384): сделаны атомарными,
    ## чтобы диагностика не создавала гонку данных.
    droppedMetrics: Atomic[uint32]
    droppedRetirements: Atomic[uint32]

    # Backpressure смены графа (issue #385).
    #
    # Счётчик «резервирований» смены графа: инкрементируется в
    # `postGraphUpdate` (по одному на публикацию), декрементируется при
    # применении команды, если утилизации не будет, и в `pollReclamation` при
    # каждом освобождённом пайплайне. Верхняя граница (`MaxRetireBacklog`)
    # гарантирует, что хранилище утилизации (SPSC + localRetire) никогда не
    # переполнится, а значит RT-путь НИКОГДА не освобождает память.
    retireBacklog: Atomic[int32]

    # Небольшая очередь параметров, пришедших до появления пайплайна.
    pendingParams: array[MaxPendingParams, EngineCommand]
    pendingParamCount: int32

    # =========================================================================
    # Входной тракт (issue #3)
    # =========================================================================
    #
    # Драйверный вход раскладывается в planar-арену, а не копируется в узлы.
    # Арена выделяется один раз при создании движка: в audio-потоке не
    # остаётся ни одной возможности что-то аллоцировать.
    #
    # inputBuffer — то, что видит граф через NodeProcessContext.input.
    # channels == 0 означает «входа нет» (offline или устройство без входов).
    inputBuffer: AudioBuffer
    inputArena: ptr UncheckedArray[float32]
    inputDeviceChannels: int32

    # Диагностика входа: статус-флаги драйвера и счётчик xrun'ов.
    # Пишется из audio callback через noteInputStatus, читается на control-path.
    inputStatusFlags: Atomic[uint32]
    inputXruns: Atomic[uint32]

    # Диагностика xrun'ов любого направления (issue #4).
    #
    # Адаптер сообщает статус через cfg.reportStatus -> engine.noteStatus:
    #   driverStatusFlags — накопленный битмаск «какие xrun'ы были»
    #                       (ординалы AudioStreamFlag, см. statusFlagMask);
    #   pendingXruns      — сколько xrun'ов накопилось С прошлого блока;
    #                       renderBlock забирает его как дельту (exchange 0);
    #   totalXruns        — монотонный счётчик за всё время жизни движка.
    # Все три — только атомики: в audio-потоке нет локов и аллокаций.
    driverStatusFlags: Atomic[uint64]
    pendingXruns: Atomic[uint32]
    totalXruns: Atomic[uint32]

    # Опциональная маршрутизация входа: input -> TrackInputRouting -> AudioRecorder.
    # Движок владеет только указателем; временем жизни рекордера владеет хост.
    recorder: ptr AudioRecorder


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


proc retirePipelineRT*(
  engine: ptr AudioEngine;
  p: ptr CompiledPipeline
) {.rt.} =
  ## Передать пайплайн на утилизацию. Вызывается из audio-пути при смене
  ## графа (и доступен хосту, который меняет пайплайны сам).
  ##
  ## Пайплайн уходит по первому свободному уровню:
  ##   1. SPSC-очередь `fromAudioRetire` — штатный путь, разбирает
  ##      control-plane через `pollReclamation`;
  ##   2. локальный overflow `localRetire` — если очередь полна.
  ##
  ## При переполнении ОБОИХ уровней пайплайн НЕ освобождается (issue #385):
  ## `deallocShared`/teardown чужих арен в audio-потоке нарушает MANIFEST
  ## §9/§10, а `destroyPipeline` — это полноценный teardown, не «быстрый free».
  ##
  ## Переполнение недостижимо: `postGraphUpdate` (backpressure, #385) держит
  ## число незакрытых смен графа ниже суммы ёмкостей утилизации, поэтому хотя
  ## бы один уровень всегда свободен. Ветка оставлена как защита от логической
  ## ошибки: фиксируем факт для control-plane через `droppedRetirementsCount()`,
  ## но память в RT не трогаем.
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
    # Недостижимо при корректном backpressure (#385): НЕ освобождаем в RT.
    discard engine.droppedRetirements.fetchAdd(1'u32, moRelaxed)


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
    state: tsStopped,
    timeSigNum: 4,
    timeSigDen: 4,
    loopEnabled: false,
    loopStartFrame: 0,
    loopEndFrame: 0
  )

  result.firstBlockPending = false
  result.activePipeline = nil
  result.frameSnapshot.store(0'i64, moRelaxed)

  result.blockIndex = 0
  result.droppedMetrics.store(0'u32, moRelaxed)
  result.droppedRetirements.store(0'u32, moRelaxed)
  result.retireBacklog.store(0'i32, moRelaxed)

  result.localRetireCount = 0
  result.pendingParamCount = 0

  # Входной тракт: арена на MaxInputChannels каналов по MaxBlockSize кадров.
  # allocShared0 даёт нулевую память, то есть «тишину по умолчанию».
  result.inputArena = cast[ptr UncheckedArray[float32]](
    allocShared0(
      sizeof(float32) * MaxInputChannels * signal_types.MaxBlockSize
    )
  )

  if result.inputArena == nil:
    deallocShared(cast[pointer](result))
    return nil

  result.inputBuffer = AudioBuffer(
    data: result.inputArena,
    channels: 0,
    frames: 0,
    stride: int32(signal_types.MaxBlockSize)
  )
  result.inputDeviceChannels = 0
  result.inputStatusFlags.store(0'u32, moRelaxed)
  result.inputXruns.store(0'u32, moRelaxed)
  result.driverStatusFlags.store(0'u64, moRelaxed)
  result.pendingXruns.store(0'u32, moRelaxed)
  result.totalXruns.store(0'u32, moRelaxed)
  result.recorder = nil

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

  if engine.inputArena != nil:
    deallocShared(cast[pointer](engine.inputArena))
    engine.inputArena = nil

  # Рекордер движку не принадлежит: хост обязан вызвать detachRecorder
  # до уничтожения AudioRecorder.
  engine.recorder = nil

  deallocShared(engine)


# ==============================================================================
# Command application
# ==============================================================================

proc applyCommands(engine: ptr AudioEngine) {.rt.} =
  var cmd: EngineCommand

  while engine.toAudio.pop(cmd):
    case cmd.kind

    of cmdTransportPlay:
      # Первый блок после старта помечается: ноты секвенсора не должны
      # «сыграть всё с начала песни», если play нажали не с нуля.
      if engine.transport.state != tsPlaying:
        engine.firstBlockPending = true
      engine.transport.state = tsPlaying

    of cmdTransportPause:
      # Пауза: остановка БЕЗ сброса позиции (#257). Именно этим она
      # отличается от стопа — иначе команда была бы косметической.
      if engine.transport.state != tsPaused:
        engine.transport.state = tsPaused

    of cmdTransportStop:
      # Стоп: остановка И возврат в 0 (#257). Позицию сбрасывает та же
      # команда, что и контрол-плоскость (`transport.stop`), — иначе два
      # представления одного состояния разошлись бы.
      engine.transport.state = tsStopped
      engine.transport.frame = 0

    of cmdTransportSetLoop:
      # Цикл приезжает командой через очередь, а не пишется в runtime с
      # control-path: audio-поток — единственный владелец своего состояния
      # (#257, MANIFEST §10).
      engine.transport.loopEnabled = cmd.loopEnabled
      engine.transport.loopStartFrame = cmd.loopStart
      engine.transport.loopEndFrame = cmd.loopEnd

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

      # Резервирование утилизации (backpressure, issue #385) снимается ровно
      # один раз на команду: либо здесь (если утилизации НЕ будет), либо в
      # `pollReclamation` (когда пайплайн реально освобождён).
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
          else:
            # Первый пайплайн: утилизировать нечего — возвращаем резерв.
            discard engine.retireBacklog.fetchAdd(-1'i32, moRelaxed)

          if newPipeline == nil:
            engine.pendingParamCount = 0
          else:
            replayPendingParams(engine, newPipeline)
      else:
        # `newPipeline == oldPipeline` — состояние не меняется, утилизации нет.
        discard engine.retireBacklog.fetchAdd(-1'i32, moRelaxed)

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
# Входной тракт (issue #3)
# ==============================================================================

proc clearInputArena(
  engine: ptr AudioEngine;
  frames: int32
) {.rt.} =
  ## Обнуляет используемую часть арены входа.
  ##
  ## Чистим именно «срез» frames на каждом канале, а не первые N float'ов
  ## подряд: буфер planar, канал ch начинается со смещения ch * MaxBlockSize.
  let stride = int32(signal_types.MaxBlockSize)

  var ch: int32 = 0
  while ch < int32(MaxInputChannels):
    let dst = cast[ptr UncheckedArray[float32]](
      addr engine.inputArena[int(ch) * int(stride)]
    )
    var f: int32 = 0
    while f < frames:
      dst[int(f)] = 0.0f
      inc f
    inc ch

proc publishInput(
  engine: ptr AudioEngine;
  driverIn: ptr UncheckedArray[float32];
  inputChannels: int32;
  frames: int32
) {.rt.} =
  ## Публикация входного блока в граф.
  ##
  ## Без входа (driverIn == nil, inputChannels <= 0 или offline) арена
  ## обнуляется: ноды получают тишину, а не мусор прошлого блока.
  ## Указатель ctx.input всегда валиден; «входа нет» выражается channels == 0.
  clearInputArena(engine, frames)

  let stride = int32(signal_types.MaxBlockSize)

  # ИСХОДНОЕ число каналов драйвера — это interleaved-stride (issue #383).
  # Раньше `chans` клампился до MaxInputChannels и использовался как шаг:
  # при 4-канальном входе сэмплы L/R лежат с шагом 4, а читались с шагом 2 —
  # раскладка каналов ломалась. Кламп должен ограничивать лишь ЧИСЛО
  # копируемых каналов, но не шаг исходного буфера.
  var driverChans = inputChannels
  if driverChans < 0:
    driverChans = 0

  var copyChans = driverChans
  if copyChans > int32(MaxInputChannels):
    copyChans = int32(MaxInputChannels)

  if not driverIn.isNil and copyChans > 0:
    var ch: int32 = 0
    while ch < copyChans:
      let dst = cast[ptr UncheckedArray[float32]](
        addr engine.inputArena[int(ch) * int(stride)]
      )
      var f: int32 = 0
      while f < frames:
        dst[int(f)] = driverIn[int(f) * int(driverChans) + int(ch)]
        inc f
      inc ch
    engine.inputDeviceChannels = copyChans
  else:
    copyChans = 0
    engine.inputDeviceChannels = 0

  engine.inputBuffer.data = engine.inputArena
  engine.inputBuffer.channels = copyChans
  engine.inputBuffer.frames = frames
  engine.inputBuffer.stride = stride

proc computeInputMetrics(
  buf: AudioBuffer;
  frames: int32;
  m: var EngineMetric
) {.rt.} =
  ## Пики входа — по сырому драйверному буферу, до нод.
  m.inputPeakL = 0.0f
  m.inputPeakR = 0.0f

  if buf.data.isNil or buf.channels <= 0 or frames <= 0:
    return

  let stride = if buf.stride > 0: buf.stride else: frames

  let c0 = cast[ptr UncheckedArray[float32]](addr buf.data[0])
  var f: int32 = 0
  while f < frames:
    let a = c0[int(f)]
    let aa = if a < 0.0f: -a else: a
    if aa > m.inputPeakL:
      m.inputPeakL = aa
    inc f

  if buf.channels > 1:
    let c1 = cast[ptr UncheckedArray[float32]](addr buf.data[int(stride)])
    f = 0
    while f < frames:
      let a = c1[int(f)]
      let aa = if a < 0.0f: -a else: a
      if aa > m.inputPeakR:
        m.inputPeakR = aa
      inc f

# ==============================================================================
# Control-path входного тракта
# ==============================================================================

proc setInputChannels*(engine: ptr AudioEngine; channels: int32) =
  ## Сколько входных каналов у открытого устройства (0 — входа нет).
  ## Control-path: вызывается хостом при open/close потока.
  if engine == nil:
    return
  engine.inputDeviceChannels =
    if channels < 0: 0
    elif channels > int32(MaxInputChannels): int32(MaxInputChannels)
    else: channels

proc noteXrunInternal(engine: ptr AudioEngine; statusFlags: uint32) {.inline.} =
  ## Общий хвост обоих приёмников статуса (issue #4): накопленный битмаск
  ## «какие xrun'ы были», дельта текущего блока и монотонный тотал.
  discard engine.driverStatusFlags.fetchOr(uint64(statusFlags), moRelaxed)
  discard engine.pendingXruns.fetchAdd(1'u32, moRelaxed)
  discard engine.totalXruns.fetchAdd(1'u32, moRelaxed)

proc noteStatus*(engine: ptr AudioEngine; statusFlags: uint32) {.cdecl, gcsafe.} =
  ## Realtime-safe: адаптер сообщает xrun любого направления (issue #4).
  ##
  ## Один вызов = один xrun. `statusFlags` — битмаск по ординалам
  ## `AudioStreamFlag` (см. `statusFlagMask` в audio_backend_api).
  ## Только атомарные операции: логирование и аллокации запрещены.
  if engine == nil or statusFlags == 0'u32:
    return
  noteXrunInternal(engine, statusFlags)

proc noteInputStatus*(engine: ptr AudioEngine; statusFlags: uint32) {.cdecl, gcsafe.} =
  ## Как `noteStatus`, но дополнительно ведёт отдельный счётчик ВХОДНЫХ
  ## xrun'ов (issue #3): драйвер сообщает входные overflow/underflow.
  if engine == nil or statusFlags == 0'u32:
    return
  # `statusFlags` — БИТМАСК (issue #383): накапливается через OR, как и
  # `driverStatusFlags`. `fetchAdd` складывал флаги: два одинаковых входных
  # xrun'а давали 2+2=4 — «чужой» флаг, которого драйвер не сообщал.
  discard engine.inputStatusFlags.fetchOr(statusFlags, moRelaxed)
  discard engine.inputXruns.fetchAdd(1'u32, moRelaxed)
  noteXrunInternal(engine, statusFlags)

proc inputXrunCount*(engine: ptr AudioEngine): uint32 =
  if engine == nil:
    return 0
  engine.inputXruns.load(moRelaxed)

proc inputStatusFlags*(engine: ptr AudioEngine): uint32 =
  ## Битмаск входных xrun-событий (issue #3, #383). Control-path. Накопление
  ## через OR (см. `noteInputStatus`), поэтому повтор одного и того же флага
  ## не меняет маску.
  if engine == nil:
    return 0'u32
  engine.inputStatusFlags.load(moRelaxed)

proc xrunCount*(engine: ptr AudioEngine): uint32 =
  ## Монотонный счётчик xrun'ов любого направления за время жизни движка.
  ## Control-path (issue #4).
  if engine == nil:
    return 0
  engine.totalXruns.load(moRelaxed)

proc driverStatusFlags*(engine: ptr AudioEngine): uint64 =
  ## Какие именно xrun'ы наблюдались: битмаск по ординалам `AudioStreamFlag`.
  ## Позволяет UI/CLI отличить input-overflow от output-underflow, не зная
  ## нативных констант драйвера. Control-path (issue #4).
  if engine == nil:
    return 0'u64
  engine.driverStatusFlags.load(moRelaxed)

proc attachRecorder*(engine: ptr AudioEngine; rec: ptr AudioRecorder) =
  ## Маршрутизация входного тракта в рекордер (issue #3).
  ##
  ## Движок вызывает rec.recordBlock(driverIn, transportFrame) каждый блок.
  ## Временем жизни рекордера владеет хост: перед его уничтожением обязателен
  ## detachRecorder.
  if engine == nil:
    return
  engine.recorder = rec

proc detachRecorder*(engine: ptr AudioEngine) =
  if engine == nil:
    return
  engine.recorder = nil

proc hasRecorder*(engine: ptr AudioEngine): bool {.inline.} =
  engine != nil and not engine.recorder.isNil

# ==============================================================================
# Main block renderer
# ==============================================================================

proc renderBlockInternal(
  engine: ptr AudioEngine;
  driverIn: ptr UncheckedArray[float32];
  driverOut: ptr UncheckedArray[float32];
  inputChannels: int32;
  offline: bool;
  lastBlock: bool;
  forceAdvance: bool
) {.rt.} =
  if engine == nil or driverOut == nil:
    return

  let frames = engine.blockSize

  if frames <= 0:
    return

  # Realtime-guard (issue #11): весь блок считается audio-потоком. Любая
  # аллокация/лок/IO ниже падает в debug-сборке, а не проявляется xrun'ом.
  rtScope():
    inc engine.blockIndex

    # Пытаемся освободить локальный retirement перед началом блока.
    flushLocalRetire(engine)

    applyCommands(engine)

    # Транспорт «идёт», если играет/пишет или это офлайн-рендер (forceAdvance).
    # Пауза и стоп — не идут: одновременно это «состояние без продвижения».
    let transportActive =
      engine.transport.state in {tsPlaying, tsRecording} or forceAdvance

    # Входной тракт: раскладываем драйверный вход в арену ДО рендера графа,
    # чтобы input-ноды увидели актуальный блок. Offline-путь передаёт driverIn
    # == nil, поэтому вход = тишина (pfOffline при этом сохраняется).
    publishInput(engine, driverIn, inputChannels, frames)

    # Маршрутизация входа в рекордер. Только realtime-путь и только при
    # реально подключённом входе.
    if not offline and not engine.recorder.isNil and not driverIn.isNil and
        inputChannels > 0:
      engine.recorder[].recordBlock(driverIn, engine.transport.frame)

    # Всегда очищаем мастер-выход.
    clearStereoBuffer(driverOut, frames)

    if transportActive and engine.activePipeline != nil:
      var ctx: NodeProcessContext
      setupContext(engine, ctx, offline, lastBlock, transportActive)
      # Публикация входа в граф (issue #3).
      ctx.input = addr engine.inputBuffer
      ctx.inputChannels = engine.inputBuffer.channels
      processPipeline(engine, ctx, driverOut, frames)

    if engine.firstBlockPending and transportActive:
      engine.firstBlockPending = false

    var metric: EngineMetric

    metric.peakL = 0.0f
    metric.peakR = 0.0f
    metric.rmsL = 0.0f
    metric.rmsR = 0.0f
    metric.cpuLoad = 0.0f
    metric.sampleRate = float64(engine.transport.sampleRate)
    metric.bufferSize = uint32(engine.blockSize)

    # Состояние в метрике — то, что реально лежит в runtime, а не вывод из
    # `transportActive`: пауза обязана доезжать до control-plane как пауза,
    # а не как стоп (#257).
    metric.transportState = ord(engine.transport.state).uint8

    metric.activeVoices = 0

    if engine.activePipeline != nil:
      metric.graphVersion = engine.activePipeline.graphVersion
    else:
      metric.graphVersion = 0

    computeStereoMetrics(driverOut, frames, metric)
    computeInputMetrics(engine.inputBuffer, frames, metric)
    metric.inputXruns = engine.inputXruns.load(moRelaxed)

    # Xrun'ы (issue #4). Адаптер сообщил их через cfg.reportStatus ДО вызова
    # render, поэтому exchange здесь забирает ровно этот блок и обнуляет
    # накопитель. Это только атомики: RT-путь чист.
    metric.xruns = engine.pendingXruns.exchange(0'u32, moRelaxed)
    metric.driverStatusFlags = engine.driverStatusFlags.load(moRelaxed)

    if not engine.fromAudioMetrics.push(metric):
      discard engine.droppedMetrics.fetchAdd(1'u32, moRelaxed)

    if transportActive:
      engine.transport.frame += int64(frames)
      if engine.transport.loopEnabled:
        let ls = engine.transport.loopStartFrame
        let le = engine.transport.loopEndFrame
        if le > ls and engine.transport.frame >= le:
          engine.transport.frame = ls + ((engine.transport.frame - ls) mod (le - ls))

    engine.frameSnapshot.store(engine.transport.frame, moRelease)


proc renderBlock*(
  engine: ptr AudioEngine;
  driverIn: ptr UncheckedArray[float32];
  inputChannels: int32;
  driverOut: ptr UncheckedArray[float32]
) {.cdecl, rt.} =
  ## Realtime-вход: драйвер отдаёт interleaved input и output одного блока.
  renderBlockInternal(
    engine,
    driverIn,
    driverOut,
    inputChannels,
    offline = false,
    lastBlock = false,
    forceAdvance = false
  )


proc renderBlock*(
  engine: ptr AudioEngine;
  driverOut: ptr UncheckedArray[float32]
) {.cdecl, rt.} =
  ## Совместимый путь без входа: вход = тишина (устройство без входов).
  renderBlockInternal(
    engine,
    nil,
    driverOut,
    0'i32,
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
        nil,
        dst,
        0'i32,
        offline = true,
        lastBlock = isLast,
        forceAdvance = true
      )

      done += engine.blockSize.int64

    else:
      # Финальный неполный блок.
      renderBlockInternal(
        engine,
        nil,
        scratch,
        0'i32,
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
      engine.frameSnapshot.store(engine.transport.frame, moRelease)

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
  ## Остановить транспорт И вернуть позицию в 0 (#257). Отличается от
  ## `postPause` именно сбросом позиции: стоп — «в начало», пауза — «на месте».
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(kind: cmdTransportStop)
  )


proc postPause*(engine: ptr AudioEngine): bool =
  ## Приостановить транспорт, сохранив позицию (#257). Команда идёт тем же
  ## путём control → queue → audio, что play/stop/seek: control-path не
  ## трогает `transport` напрямую.
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(kind: cmdTransportPause)
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


proc postSetLoop*(
  engine: ptr AudioEngine;
  enabled: bool;
  startFrame: int64;
  endFrame: int64
): bool =
  ## Управляет границами и активностью цикла (#257). В отличие от прежнего
  ## `setLoop`, который писал в `transport` прямо с control-path, команда
  ## кладётся в очередь и применяется в audio-потоке — единый путь для всего,
  ## что меняет состояние транспорта (MANIFEST §10).
  if engine == nil:
    return false

  engine.toAudio.push(
    EngineCommand(
      kind: cmdTransportSetLoop,
      loopEnabled: enabled,
      loopStart: startFrame,
      loopEnd: endFrame
    )
  )


proc transportState*(engine: ptr AudioEngine): TransportState =
  ## Состояние транспорта последнего обработанного блока (control-path).
  ## Для «живого» состояния, а не «намерения»: значение меняется в
  ## audio-потоке, когда приходит соответствующая команда (#257).
  if engine == nil:
    return tsStopped
  engine.transport.state


proc currentTempo*(engine: ptr AudioEngine): float64 =
  ## Темп, применяемый audio-потоком в данный момент (control-path).
  if engine == nil:
    return 0.0
  engine.transport.tempo


proc currentTimeSignature*(
  engine: ptr AudioEngine
): tuple[numerator, denominator: int32] =
  ## Размер такта, применяемый audio-потоком в данный момент (control-path).
  if engine == nil:
    return (4'i32, 4'i32)
  (engine.transport.timeSigNum, engine.transport.timeSigDen)


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
  ## Публикация нового графа в RT (MANIFEST §10). Control-path.
  ##
  ## Backpressure (issue #385): если незакрытых смен графа уже
  ## `MaxRetireBacklog`, публикация отклоняется. Это держит хранилище
  ## утилизации (SPSC + localRetire) ниже ёмкости, поэтому RT-путь НИКОГДА не
  ## доходит до освобождения памяти. Хост обязан периодически звать
  ## `pollReclamation`, чтобы очередь разбиралась.
  if engine == nil:
    return false

  if engine.retireBacklog.load(moAcquire) >= MaxRetireBacklog.int32:
    return false

  let id = engine.sharedPool.acquireBlock()

  if id < 0:
    return false

  # Резервируем слот утилизации ДО публикации: если команда создаст утилизацию,
  # резерв держится до `pollReclamation`; иначе возвращается в `applyCommands`.
  discard engine.retireBacklog.fetchAdd(1'i32, moRelaxed)

  let val = cast[uint](p).uint64
  writeUint64ToBlock(engine.sharedPool.blocks[id], val)

  let cmd = EngineCommand(
    kind: cmdGraphUpdate,
    sharedBufferId: id,
    dataSize: 8.uint32
  )

  if engine.toAudio.push(cmd):
    return true

  # Публикация не удалась — возвращаем резерв.
  discard engine.retireBacklog.fetchAdd(-1'i32, moRelaxed)
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
  ## Control-path: освободить все утилизированные аудиопотоком пайплайны.
  ##
  ## Каждый освобождённый пайплайн снимает одно резервирование backpressure
  ## (issue #385), открывая место для новых публикаций `postGraphUpdate`.
  if engine == nil:
    return

  var p: ptr CompiledPipeline

  while engine.fromAudioRetire.pop(p):
    if p != nil:
      destroyPipeline(p)
      discard engine.retireBacklog.fetchAdd(-1'i32, moRelaxed)


proc currentFrame*(engine: ptr AudioEngine): int64 =
  if engine == nil:
    return 0

  engine.frameSnapshot.load(moAcquire)


proc currentPositionSeconds*(engine: ptr AudioEngine): float64 =
  if engine == nil:
    return 0.0

  if engine.transport.sampleRate <= 0.0f:
    return 0.0

  float64(engine.currentFrame()) / float64(engine.transport.sampleRate)


proc droppedMetricsCount*(engine: ptr AudioEngine): uint32 =
  if engine == nil:
    return 0

  engine.droppedMetrics.load(moRelaxed)


proc droppedRetirementsCount*(engine: ptr AudioEngine): uint32 =
  ## Диагностика утилизации пайплайнов (issue #73, #385).
  ##
  ## При корректной работе всегда 0: backpressure (#385) не даёт хранилищу
  ## утилизации переполниться, а сам RT-путь больше НЕ освобождает пайплайны.
  ## Ненулевое значение — признак логической ошибки (счётчик «резервирований»
  ## разошёлся с числом утилизаций), а не штатного режима.
  if engine == nil:
    return 0

  engine.droppedRetirements.load(moRelaxed)


proc retirementBacklog*(engine: ptr AudioEngine): int32 =
  ## Сколько смен графа сейчас «в полёте»: опубликовано (`postGraphUpdate`),
  ## но ещё не утилизировано/применено. Control-path: по нему хост видит
  ## близость к backpressure-порогу (issue #385).
  if engine == nil:
    return 0

  engine.retireBacklog.load(moAcquire)