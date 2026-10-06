# nodes/builtin/io/clip_player.nim
#
# Плеер аудиоклипов проекта (issue #107, срез 2).
#
# Нода — ИСТОЧНИК звука: у неё нет аудиовхода, а выход — сэмплы
# аудиоресурса проекта, наложенные на таймлайн в окне клипа.
#
# Владение:
#   сэмплы ресурса загружает и держит ЗАГРУЗЧИК сцены (`scene_loader`), нода
#   получает только указатель на interleaved-буфер. В audio-потоке нет ни
#   файлового I/O, ни аллокаций — только чтение и запись по индексу.
#
# Синхронизация с транспортом:
#   позиция берётся из `ctx.samplePosition` и темпа транспорта (как у нотной
#   ноды `euterpia.notes`): тик — непрерывная величина, поэтому сэмпл клипа
#   попадает в нужный кадр, а не в блок (sample-accurate).
#
# Почему нода, а не «магия сцены»:
#   граф проекта — это то, что пользователь собрал: клип обязан идти по
#   проводу в мастер/микс, как любой источник. Нода даёт это штатным путём,
#   а `scene_loader` лишь наполняет её сэмплами и окном.

import
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../../sdk/dsp_units

{.push raises: [].}

const
  ClipTypeId* = "euterpia.clip"
    ## Идентификатор типа ноды-плеера.
  ClipParamGain* = 0'u32
  MaxClipSlots* = 32
    ## Сколько клипов одной дорожки помещается в ноду. Ограничение как у
    ## нотной ноды: переполнение — замечание загрузки, а не потеря данных.

type
  ClipSlot* = object
    ## Один аудиоклип: окно в ресурсе + окно на таймлайне (в СЭМПЛАХ).
    data*: ptr UncheckedArray[float32]
      ## Interleaved-сэмплы ресурса (владеет сцена).
    channels*: int32
    resFrames*: int64
      ## Кадров в ресурсе.
    offsetFrames*: int64
      ## С какого кадра ресурса начинается клип.
    startSample*: int64
      ## Начало клипа в сэмплах таймлайна (тик → сэмпл считает загрузчик:
      ## арифметика в сэмплах целочисленная и не «плывёт» на дробном округлении).
    endSample*: int64

  ClipState* = object
    ## Состояние ноды. POD, без строк и владения памятью.
    clipCount*: int32
    clips*: array[MaxClipSlots, ClipSlot]
    gainDb: ParamSmoother

var
  clipDesc: NodeDesc
  clipFactory: NodeFactory
  clipReady = false

proc initClipDesc() =
  clipDesc = NodeDesc(
    id: fixedId(ClipTypeId),
    name: fixedName("Clip"),
    category: fixedName("io"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 1
  )
  clipDesc.params[0] = NodeParamDesc(
    id: ClipParamGain, name: fixedParamName("gain"),
    minValue: -80.0f, maxValue: 12.0f, defaultValue: 0.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc createClipState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not clipReady:
    initClipDesc()
    clipReady = true

  result = allocShared0(sizeof(ClipState))
  if result.isNil:
    return nil
  let st = cast[ptr ClipState](result)
  st.gainDb = initSmoother(15.0f, 48000.0f, 0.0f)

proc destroyClipState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  deallocShared(state)

proc resetClipState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr ClipState](state)
  for i in 0 ..< MaxClipSlots:
    st.clips[i] = ClipSlot()

proc setClipParam(state: pointer; paramId: uint32; value: float32;
                  normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil or paramId != ClipParamGain:
    return
  let st = cast[ptr ClipState](state)
  let raw = if normalized: clipDesc.paramFromNormalized(paramId, value) else: value
  st.gainDb.setTarget(clamp(raw, -80.0f, 12.0f))

proc getClipParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil or paramId != ClipParamGain:
    return false
  outValue[] = (cast[ptr ClipState](state)).gainDb.target
  true

# ==============================================================================
# Наполнение (control plane; зовёт scene_loader)
# ==============================================================================

proc clipClear*(st: var ClipState) =
  ## Пустая нода: клипов нет.
  st.clipCount = 0
  for i in 0 ..< MaxClipSlots:
    st.clips[i] = ClipSlot()

proc clipAddSlot*(st: var ClipState; data: ptr UncheckedArray[float32];
                  channels: int32; resFrames, offsetFrames: int64;
                  startSample, endSample: int64): bool =
  ## Добавить клип. `false` — нода переполнена или данные негодны
  ## (загрузчик превращает это в замечание, а не в тишину молча).
  if data.isNil or channels <= 0 or resFrames <= 0:
    return false
  if st.clipCount >= MaxClipSlots:
    return false
  st.clips[st.clipCount] = ClipSlot(
    data: data, channels: channels, resFrames: resFrames,
    offsetFrames: offsetFrames, startSample: startSample, endSample: endSample)
  inc st.clipCount

proc clipSlotCount*(st: ClipState): int {.inline.} = st.clipCount.int

proc clipLastSample*(st: ClipState): int64 =
  ## Последний сэмпл среди клипов: нужен загрузчику, чтобы знать конец.
  for i in 0 ..< st.clipCount:
    if st.clips[i].endSample > result:
      result = st.clips[i].endSample

# ==============================================================================
# Обработка (audio thread): без файлов, без аллокаций
# ==============================================================================

proc processClipNode(
    ctx: ptr NodeProcessContext;
    audio: ptr NodeAudioPorts;
    ctrl: ptr NodeControlPorts;
    events: ptr NodeEventPorts;
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events

  let st = cast[ptr ClipState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1:
    return
  let outBuf = audio.outputs[0]
  if outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  # Нода может ничего не вывести (нет клипов, транспорт стоит) — тогда тишина,
  # а не мусор прошлого блока.
  outBuf.fillZero(frames)

  if ctx.isNil or st.clipCount <= 0:
    return
  if pfTransportPlaying notin ctx.flags:
    return

  let lin = dbToLin(st.gainDb.advance(frames))
  let blockStart = ctx.samplePosition

  # Позиция — в СЭМПЛАХ таймлайна: `startSample`/`endSample` клипа уже
  # переведены из тиков загрузчиком, поэтому выборка из ресурса — целочисленная
  # и точная (никакого «тик ↔ кадр» на каждом блоке).
  for f in 0 ..< frames:
    let pos = blockStart + int64(f)
    var acc0 = 0.0f
    var acc1 = 0.0f
    for c in 0 ..< st.clipCount:
      let slot = st.clips[c]
      if slot.data.isNil:
        continue
      if pos < slot.startSample or pos >= slot.endSample:
        continue
      let idx = slot.offsetFrames + (pos - slot.startSample)
      if idx < 0 or idx >= slot.resFrames:
        continue
      let base = idx * int64(slot.channels)
      acc0 += slot.data[base]
      acc1 += slot.data[base + (if slot.channels > 1: 1'i64 else: 0'i64)]

    outBuf.setSampleAt(0, int32(f), acc0 * lin)
    outBuf.setSampleAt(1, int32(f), acc1 * lin)

# ==============================================================================
# Экспорт
# ==============================================================================

proc getClipDesc*(): ptr NodeDesc =
  if not clipReady:
    initClipDesc()
    clipReady = true
  addr clipDesc

proc getClipFactory*(): ptr NodeFactory =
  if not clipReady:
    initClipDesc()
    clipReady = true
  if clipFactory.create.isNil:
    clipFactory = NodeFactory(
      create: createClipState,
      destroy: destroyClipState,
      process: processClipNode,
      setParam: setClipParam,
      getParam: getClipParam,
      reset: resetClipState
    )
  addr clipFactory

{.pop.}

