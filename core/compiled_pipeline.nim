# compiled_pipeline.nim

import
  std/atomics,
  node_interface,
  signal_types,
  aligned_mem

var gPipelineVersionCounter*: Atomic[uint64]

proc nextPipelineVersion*(): uint64 {.inline.} =
  ## Генерирует уникальный монотонно возрастающий номер версии графа (начиная с 1).
  gPipelineVersionCounter.fetchAdd(1'u64, moRelaxed) + 1'u64

const
  ## Каналов обслуживает кольцо компенсации задержки (PDC).
  ##
  ## Проект — стерео (issue #401): `MaxAudioChannels = 2` в signal_types,
  ## `MaxInputChannels` в audio_engine и `maxChannels <= 2` в дескрипторах
  ## нод. Кольцо обязано покрывать все каналы, иначе каналы перемешиваются
  ## (issue #72). Значение не дублируется: один источник — signal_types.
  DelayCompensationRingChannels* = signal_types.MaxAudioChannels

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
  # eventPool выровнен сильнее MemAlign, поэтому освобождается парной функцией
  # (issue #364): deallocShared вернул бы аллокатору не тот указатель.
  if p.eventPool != nil: alignedSharedDealloc(p.eventPool)
  if p.poolFlags != nil: deallocShared(p.poolFlags)

  # Защита от UAF при отладке
  p.graphVersion = 0'u64

  deallocShared(p)

# ==============================================================================
# Ownership (issue #402)
# ==============================================================================
#
# Раньше владение пайплайном передавалось «по соглашению», сырым
# `ptr CompiledPipeline`. История double-free в `core/offline_render.nim`
# показывает цену такого контракта: движок освобождал пайплайн, а сцена
# освобождала его повторно, и падала не она, а следующая крупная аллокация.
#
# Теперь владение выражено ТИПОМ:
#
#   * `OwnedPipeline` — единственный владелец указателя. Копировать его
#     нельзя (`=copy`/`=dup` — ошибки компиляции), поэтому один и тот же
#     пайплайн не может оказаться в двух владельцах;
#   * передача владения — `sink`-параметр (`postGraphUpdate`, `renderToWav`).
#     После передачи ручка пуста, и повторная передача отвергается API, а не
#     превращается в use-after-free;
#   * `BorrowedPipeline` — невладеющий вид для чтения метаданных. Он не
#     освобождает память и не продлевает жизнь объекта.
#
# `releasePipeline` — явный detach для тех мест, где ядру нужен сырой
# указатель (RT-утилизация). Он назван так, чтобы его было видно в ревью:
# каждая такая точка — осознанная передача владения, а не обычное чтение.

type
  OwnedPipeline* = object
    ## Единственный владелец `CompiledPipeline`. Move-only.
    raw: ptr CompiledPipeline

  BorrowedPipeline* = object
    ## Невладеющий вид на пайплайн. Живёт не дольше владельца.
    raw: ptr CompiledPipeline

proc `=destroy`(o: OwnedPipeline) =
  if o.raw != nil:
    destroyPipeline(o.raw)

proc `=copy`(dst: var OwnedPipeline; src: OwnedPipeline)
    {.error: "OwnedPipeline нельзя копировать: владение передаётся через move/sink".}

proc `=dup`(src: OwnedPipeline): OwnedPipeline
    {.error: "OwnedPipeline нельзя дублировать: владение передаётся через move/sink".}

proc ownPipeline*(p: ptr CompiledPipeline): OwnedPipeline {.inline.} =
  ## Принять сырой указатель во владение. Вызывающий обязан «забыть»
  ## исходный указатель (например, `CompileResult.pipeline = nil`), иначе
  ## владельцев станет два. Для `CompileResult` есть `takePipeline`.
  OwnedPipeline(raw: p)

proc newOwnedPipeline*(): OwnedPipeline {.inline.} =
  ## Новый пустой пайплайн под владением. `isEmpty` — если память не
  ## выделилась.
  ownPipeline(newCompiledPipeline())

proc releasePipeline*(o: var OwnedPipeline): ptr CompiledPipeline {.inline.} =
  ## Явный detach: вернуть сырой указатель и снять владение.
  ##
  ## Нужен только там, где API ядра исторически принимает `ptr` (например,
  ## очередь утилизации RT). Каждый вызов — точка передачи владения.
  result = o.raw
  o.raw = nil

proc destroyOwned*(o: var OwnedPipeline) {.inline.} =
  ## Освободить пайплайн раньше конца области видимости.
  if o.raw != nil:
    destroyPipeline(o.raw)
    o.raw = nil

proc isEmpty*(o: OwnedPipeline): bool {.inline.} =
  ## true — владения нет (пайплайн не создан или уже передан).
  o.raw == nil

proc borrow*(o: OwnedPipeline): BorrowedPipeline {.inline.} =
  ## Невладеющий вид. Не освобождает и не продлевает жизнь.
  BorrowedPipeline(raw: o.raw)

proc isNil*(b: BorrowedPipeline): bool {.inline.} =
  b.raw == nil

proc graphVersion*(b: BorrowedPipeline): uint64 {.inline.} =
  if b.raw == nil: 0'u64 else: b.raw.graphVersion

proc stepCount*(b: BorrowedPipeline): int32 {.inline.} =
  if b.raw == nil: 0'i32 else: b.raw.stepCount
