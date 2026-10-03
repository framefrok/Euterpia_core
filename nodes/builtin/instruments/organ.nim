# nodes/builtin/instruments/organ.nim
#
# Орган на C-ядре eut_inst.c (аддитивный синтез, 8 частий, вибрато).
#
# Нода — «инструмент»: аудиовходов у неё нет, ноты приходят событиями
# (eventIn). Render-путь общий для всех четырёх инструментов и живёт в
# instrument_common.nim, а здесь только то, что отличает орган от
# фортепиано: набор параметров и их перевод в вызовы ядра.
#
# Орган — единственный инструмент без сустейн-педали: барочный орган
# держит ноту до note-off, и CC64 ему не передаётся (`pedal: nil`).

import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../../sdk/dsp_units,
  ../native/eut_native,
  instrument_common

{.push raises: [].}

const
  # Идентификаторы параметров числовые и стабильные: проект,
  # автоматизация и CLI ссылаются на них, а не на названия.
  OrganParamBars*    = 0'u32   # положение регистровой ручки, 0..1
  OrganParamTone*    = 1'u32   # яркость частий, 0..1
  OrganParamClick*   = 2'u32   # уровень щелчка атаки, 0..1
  OrganParamVibrato* = 3'u32   # глубина вибрато, центы
  OrganParamPan*     = 4'u32   # -1..+1
  OrganParamLevel*   = 5'u32   # dB

  ## 12 голосов — «две руки и педаль»: для органной литературы
  ## большего не нужно, а голос считает 8 частий каждый сэмпл.
  OrganVoices = 12

  ## Частота, на которой движок создаётся до первого блока. Реальная
  ## приходит из `ctx.sampleRate` и применяется через `organInitAt`.
  OrganDefaultSampleRate = 48000.0f

  OrganLevelMinDb = -80.0f
  OrganLevelMaxDb = 6.0f

type
  OrganState* = object
    ## Состояние ноды. POD: владение памятью остаётся за движком,
    ## нода хранит только дескрипторы и «медленные» параметры.
    g: Organ
    abi: InstAbi
    midi: InstMidi

    ## Временный planar-буфер для interleaved-выхода (последний в цепочке,
    ## мастер-шина). Живёт в состоянии ноды: память выдаёт `create` на
    ## control-path, audio thread только пишет в него. См. InstScratchFrames.
    scratch: array[2 * InstScratchFrames, float32]

    sampleRate: float32

    ## Параметры в единицах ЯДРА (level — линейный). Держим их, чтобы
    ## `organ_set` не звался на каждый `setParam`: он пересчитывает
    ## таблицу регистров, поэтому достаточно одного вызова на блок.
    bars, tone, click, vibrato, pan, levelLin: float32
    live: bool

var
  organDesc: NodeDesc
  organFactory: NodeFactory
  organReady = false

# ==============================================================================
# Descriptor (холодная сторона)
# ==============================================================================

proc initOrganDesc() =
  organDesc = NodeDesc(
    id: fixedId("euterpia.organ"),
    name: fixedName("Organ"),
    category: fixedName("instrument"),
    audioInCount: 0,       # источник: вход ему не нужен
    audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1,       # MIDI-подписка на ноты
    eventOutCount: 0,
    latencyFrames: 0,
    maxChannels: 2,
    paramCount: 6
  )

  organDesc.params[0] = NodeParamDesc(
    id: OrganParamBars, name: fixedParamName("bars"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  organDesc.params[1] = NodeParamDesc(
    id: OrganParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.6f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  organDesc.params[2] = NodeParamDesc(
    id: OrganParamClick, name: fixedParamName("click"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable)
  )
  organDesc.params[3] = NodeParamDesc(
    id: OrganParamVibrato, name: fixedParamName("vibrato"),
    minValue: 0.0f, maxValue: 60.0f, defaultValue: 6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  organDesc.params[4] = NodeParamDesc(
    id: OrganParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  organDesc.params[5] = NodeParamDesc(
    id: OrganParamLevel, name: fixedParamName("level"),
    minValue: OrganLevelMinDb, maxValue: OrganLevelMaxDb,
    defaultValue: -6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc organApplyParams(st: ptr OrganState) =
  organSet(addr st.g, st.bars, st.tone, st.click, st.vibrato, st.pan, st.levelLin)
  st.live = false

proc createOrganState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not organReady:
    initOrganDesc()
    organReady = true

  result = allocShared0(sizeof(OrganState))
  if result.isNil:
    return nil

  let st = cast[ptr OrganState](result)
  st.sampleRate = OrganDefaultSampleRate
  st.g = newOrgan(OrganVoices, st.sampleRate)
  if not st.g.isReady:
    # Память под голоса выделить не удалось: состояние без движка
    # бесполезно, а отдавать наружу «полуживую» ноду — хуже отказа.
    deallocShared(result)
    return nil

  st.abi = organAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

  st.bars = organDesc.params[0].defaultValue
  st.tone = organDesc.params[1].defaultValue
  st.click = organDesc.params[2].defaultValue
  st.vibrato = organDesc.params[3].defaultValue
  st.pan = organDesc.params[4].defaultValue
  st.levelLin = dbToLin(organDesc.params[5].defaultValue)
  st.live = true

proc destroyOrganState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  freeOrgan(addr (cast[ptr OrganState](state)).g)
  deallocShared(state)

proc resetOrganState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Паника: голоса снимаются, MIDI-состояние обнуляется.
  ##
  ## Параметры не трогаем — сброс транспорта не повод менять регистровку;
  ## `live = true` заставит движок принять их заново на следующем блоке.
  if state.isNil:
    return
  let st = cast[ptr OrganState](state)
  organReset(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.live = true

# ==============================================================================
# Параметры
#
# setParam зовётся и из control plane, и из audio thread (команда
# cmdSetParam). Поэтому здесь только запись цели в поле состояния:
# само изменение звука происходит в process() на границе блока.
# ==============================================================================

proc setOrganParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr OrganState](state)
  let raw = if normalized: organDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of OrganParamBars:    st.bars = clamp(raw, 0.0f, 1.0f)
  of OrganParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of OrganParamClick:   st.click = clamp(raw, 0.0f, 1.0f)
  of OrganParamVibrato: st.vibrato = clamp(raw, 0.0f, 60.0f)
  of OrganParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of OrganParamLevel:   st.levelLin = dbToLin(clamp(raw, OrganLevelMinDb, OrganLevelMaxDb))
  else: return

  st.live = true

proc getOrganParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr OrganState](state)

  case paramId
  of OrganParamBars:    outValue[] = st.bars
  of OrganParamTone:    outValue[] = st.tone
  of OrganParamClick:   outValue[] = st.click
  of OrganParamVibrato: outValue[] = st.vibrato
  of OrganParamPan:     outValue[] = st.pan
  of OrganParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false

  true

# ==============================================================================
# Обработка (audio thread)
# ==============================================================================

proc processOrganNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr OrganState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1:
    return

  let outBuf = audio.outputs[0]
  if outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  # --- Частота дискретизации -------------------------------------------
  # Ядро фиксирует её в `eut_organ_init`, а нода узнаёт фактическую
  # только из контекста. Переинициализация идёт по уже выделенному
  # блоку и не аллоцирует, поэтому безопасна в audio thread.
  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if organInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)
      st.live = true

  if st.live:
    organApplyParams(st)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]

  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

# ==============================================================================
# Экспорт
# ==============================================================================

proc getOrganDesc*(): ptr NodeDesc =
  if not organReady:
    initOrganDesc()
    organReady = true
  addr organDesc

proc getOrganFactory*(): ptr NodeFactory =
  if not organReady:
    initOrganDesc()
    organReady = true
  if organFactory.create.isNil:
    organFactory = NodeFactory(
      create: createOrganState,
      destroy: destroyOrganState,
      process: processOrganNode,
      setParam: setOrganParam,
      getParam: getOrganParam,
      reset: resetOrganState
    )
  addr organFactory

{.pop.}
