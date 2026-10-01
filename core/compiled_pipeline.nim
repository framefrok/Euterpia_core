# compiled_pipeline.nim

import
  std/atomics,
  node_interface,
  signal_types

var gPipelineVersionCounter*: Atomic[uint64]

proc nextPipelineVersion*(): uint64 {.inline.} =
  ## Генерирует уникальный монотонно возрастающий номер версии графа (начиная с 1).
  gPipelineVersionCounter.fetchAdd(1'u64, moRelaxed) + 1'u64

const
  ## Каналов обслуживает кольцо компенсации задержки (PDC).
  ##
  ## Проект — стерео: `MaxInputChannels = 2` в audio_engine и
  ## `maxChannels: 2` в дескрипторах нод. Кольцо обязано покрывать все
  ## каналы, иначе каналы перемешиваются (issue #72).
  DelayCompensationRingChannels* = 2

type
  PipelineRenderProc* = proc(
    ctx: ptr NodeProcessContext;
    p: ptr CompiledPipeline;
    outBuf: ptr UncheckedArray[float32];
    frames: int32
  ) {.cdecl, raises: [], gcsafe.}

  BindMasterProc* = proc(
    p: ptr CompiledPipeline;
    outBuf: ptr UncheckedArray[float32];
    frames: int32
  ) {.cdecl, raises: [], gcsafe.}

  ApplyParamProc* = proc(
    p: ptr CompiledPipeline;
    nodeId: int32;
    paramId: uint32;
    value: float32;
    normalized: bool
  ) {.cdecl, raises: [], gcsafe.}

  PipelineDestroyProc* = proc(
    p: ptr CompiledPipeline
  ) {.cdecl, raises: [], gcsafe.}

  DelayCompensationData* = object
    delayFrames*: int
    ## Позиция записи в КАДРАХ (не в сэмплах): кольцо per-frame, слоты
    ## канала `ch` лежат на `frame * ringChannels + ch` (issue #72).
    writePos*: int
    buffer*: ptr UncheckedArray[float32]
    ## Ёмкость буфера в СЛОТАХ: `ringFrames * ringChannels`.
    bufferSize*: int
    ## Число каналов, которое обслуживает кольцо (стерео-модель проекта).
    ringChannels*: int32

  PoolFlag* = enum
    pfNeedsZeroing
    pfIsAudioBuffer

  CompiledPipeline* = object
    graphVersion*: uint64

    # Пошаговый режим
    steps*: ptr UncheckedArray[PipelineStep]
    stepCount*: int32

    # Пулы ресурсов графа
    audioBufferPoolCount*: int
    audioBufferPool*: ptr UncheckedArray[AudioBuffer]
    # Арена сэмплов под все аудиобуферы пула.
    #
    # Пул описывает ТОЛЬКО структуры буферов (указатели на порты нод).
    # Сами сэмплы лежат здесь, одной непересекающейся ареной:
    # на блок это одна большая аллокация вместо сотни мелких, а в
    # audio thread не остаётся ни одной возможности что-то аллоцировать.
    #
    # Формат буферов — planar stereo: channels = 2, stride = arenaFrames.
    audioArena*: ptr UncheckedArray[float32]
    arenaFrames*: int32
    ctrlPoolCount*: int
    ctrlPool*: ptr UncheckedArray[float32]
    eventPoolCount*: int
    eventPool*: ptr UncheckedArray[EventQueue]
    poolFlags*: ptr UncheckedArray[set[PoolFlag]]

    # Стейты компенсации задержки (PDC)
    delayStateCount*: int
    delayStates*: ptr UncheckedArray[DelayCompensationData]

    # Монолитный рендер (если поддерживается)
    renderProc*: PipelineRenderProc

    # Подключение мастер-выхода к буферу аудиокарты
    bindMasterProc*: BindMasterProc

    # Применение параметров
    applyParamProc*: ApplyParamProc

    # Деструктор пользовательских ресурсов
    destroyProc*: PipelineDestroyProc

    userData*: pointer

proc newCompiledPipeline*(): ptr CompiledPipeline {.inline.} =
  ## Аллоцирует очищенный пайплайн в shared memory и проставляет свежий
  ## graphVersion. Единственная точка создания пайплайна: иначе версию
  ## пришлось бы ставить в двух местах и её можно забыть (issue #79).
  ## Возвращает nil, если памяти не хватило.
  result = createShared(CompiledPipeline)
  if result.isNil:
    return
  result.graphVersion = nextPipelineVersion()

proc destroyPipeline*(p: ptr CompiledPipeline) {.raises: [].} =
  if p == nil:
    return

  if p.destroyProc != nil:
    p.destroyProc(p)

  if p.delayStates != nil:
    for i in 0 ..< p.delayStateCount:
      if p.delayStates[i].buffer != nil:
        deallocShared(p.delayStates[i].buffer)
    deallocShared(p.delayStates)

  if p.steps != nil: deallocShared(p.steps)
  if p.audioBufferPool != nil: deallocShared(p.audioBufferPool)
  if p.audioArena != nil: deallocShared(p.audioArena)
  if p.ctrlPool != nil: deallocShared(p.ctrlPool)
  if p.eventPool != nil: deallocShared(p.eventPool)
  if p.poolFlags != nil: deallocShared(p.poolFlags)

  # Защита от UAF при отладке
  p.graphVersion = 0'u64

  deallocShared(p)