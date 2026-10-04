# nodes/builtin/instruments/brass.nim
#
# Медь (труба/валторна) на C-ядре eut_inst.c: пила через формантный резонатор,
# мягкий ФНЧ-раструб, вибрато после атаки, шумовой «въезд» в ноту.
# Нода — источник; render-путь общий — instrument_common.nim.

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
  BrassParamTone*    = 0'u32   # яркость/открытость раструба, 0..1
  BrassParamRasp*    = 1'u32   # жёсткость атаки, 0..1
  BrassParamVibrato* = 2'u32   # глубина вибрато, центы
  BrassParamPan*     = 3'u32
  BrassParamLevel*   = 4'u32   # dB

  BrassVoices = 8
  BrassDefaultSampleRate = 48000.0f
  BrassLevelMinDb = -80.0f
  BrassLevelMaxDb = 6.0f

type
  BrassState* = object
    g: Brass
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    tone, rasp, vibrato, pan, levelLin: float32

var
  brassDesc: NodeDesc
  brassFactory: NodeFactory
  brassReady = false

proc initBrassDesc() =
  brassDesc = NodeDesc(
    id: fixedId("euterpia.brass"),
    name: fixedName("Brass"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5)
  brassDesc.params[0] = NodeParamDesc(
    id: BrassParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.55f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  brassDesc.params[1] = NodeParamDesc(
    id: BrassParamRasp, name: fixedParamName("rasp"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  brassDesc.params[2] = NodeParamDesc(
    id: BrassParamVibrato, name: fixedParamName("vibrato"),
    minValue: 0.0f, maxValue: 60.0f, defaultValue: 6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  brassDesc.params[3] = NodeParamDesc(
    id: BrassParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  brassDesc.params[4] = NodeParamDesc(
    id: BrassParamLevel, name: fixedParamName("level"),
    minValue: BrassLevelMinDb, maxValue: BrassLevelMaxDb,
    defaultValue: -8.0f, step: 0.1f, flags: uint32(npfAutomatable))

proc createBrassState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not brassReady:
    initBrassDesc()
    brassReady = true
  result = allocShared0(sizeof(BrassState))
  if result.isNil:
    return nil
  let st = cast[ptr BrassState](result)
  st.sampleRate = BrassDefaultSampleRate
  st.g = newBrass(BrassVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = brassAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tone = 0.55f; st.rasp = 0.35f; st.vibrato = 6.0f
  st.pan = 0.0f; st.levelLin = dbToLin(-8.0f)

proc destroyBrassState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeBrass(addr (cast[ptr BrassState](state)).g)
  deallocShared(state)

proc resetBrassState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr BrassState](state)
  brassReset(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setBrassParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr BrassState](state)
  let raw = if normalized: brassDesc.paramFromNormalized(paramId, value)
            else: value
  case paramId
  of BrassParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of BrassParamRasp:    st.rasp = clamp(raw, 0.0f, 1.0f)
  of BrassParamVibrato: st.vibrato = clamp(raw, 0.0f, 60.0f)
  of BrassParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of BrassParamLevel:   st.levelLin = dbToLin(clamp(raw, BrassLevelMinDb,
                                                    BrassLevelMaxDb))
  else: return

proc getBrassParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr BrassState](state)
  case paramId
  of BrassParamTone:    outValue[] = st.tone
  of BrassParamRasp:    outValue[] = st.rasp
  of BrassParamVibrato: outValue[] = st.vibrato
  of BrassParamPan:     outValue[] = st.pan
  of BrassParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processBrassNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                      ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                      userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr BrassState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if brassInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  brassSet(addr st.g, st.tone, st.rasp, st.vibrato, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getBrassDesc*(): ptr NodeDesc =
  if not brassReady:
    initBrassDesc()
    brassReady = true
  addr brassDesc

proc getBrassFactory*(): ptr NodeFactory =
  if not brassReady:
    initBrassDesc()
    brassReady = true
  if brassFactory.create.isNil:
    brassFactory = NodeFactory(
      create: createBrassState, destroy: destroyBrassState,
      process: processBrassNode, setParam: setBrassParam,
      getParam: getBrassParam, reset: resetBrassState)
  addr brassFactory

{.pop.}

