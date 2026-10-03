# nodes/builtin/instruments/flute.nim
#
# Флейта на C-ядре eut_inst.c: почти синус + верхние нечётные гармоники,
# дыхательный шум и «чиф» атаки. Нода — источник (аудиовходов нет, ноты
# приходят событиями); render-путь общий — instrument_common.nim.

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
  FluteParamTone*    = 0'u32   # яркость (верхние гармоники), 0..1
  FluteParamBreath*  = 1'u32   # дыхание (шум), 0..1
  FluteParamVibrato* = 2'u32   # глубина вибрато, центы
  FluteParamPan*     = 3'u32
  FluteParamLevel*   = 4'u32   # dB

  FluteVoices = 8
  FluteDefaultSampleRate = 48000.0f
  FluteLevelMinDb = -80.0f
  FluteLevelMaxDb = 6.0f

type
  FluteState* = object
    g: Flute
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    tone, breath, vibrato, pan, levelLin: float32

var
  fluteDesc: NodeDesc
  fluteFactory: NodeFactory
  fluteReady = false

proc initFluteDesc() =
  fluteDesc = NodeDesc(
    id: fixedId("euterpia.flute"),
    name: fixedName("Flute"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5
  )
  fluteDesc.params[0] = NodeParamDesc(
    id: FluteParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.55f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  fluteDesc.params[1] = NodeParamDesc(
    id: FluteParamBreath, name: fixedParamName("breath"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  fluteDesc.params[2] = NodeParamDesc(
    id: FluteParamVibrato, name: fixedParamName("vibrato"),
    minValue: 0.0f, maxValue: 60.0f, defaultValue: 14.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  fluteDesc.params[3] = NodeParamDesc(
    id: FluteParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  fluteDesc.params[4] = NodeParamDesc(
    id: FluteParamLevel, name: fixedParamName("level"),
    minValue: FluteLevelMinDb, maxValue: FluteLevelMaxDb, defaultValue: -6.0f,
    step: 0.1f, flags: uint32(npfAutomatable))

proc createFluteState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not fluteReady:
    initFluteDesc()
    fluteReady = true
  result = allocShared0(sizeof(FluteState))
  if result.isNil:
    return nil
  let st = cast[ptr FluteState](result)
  st.sampleRate = FluteDefaultSampleRate
  st.g = newFlute(FluteVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = fluteAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tone = 0.55f; st.breath = 0.35f; st.vibrato = 14.0f
  st.pan = 0.0f; st.levelLin = dbToLin(-6.0f)

proc destroyFluteState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeFlute(addr (cast[ptr FluteState](state)).g)
  deallocShared(state)

proc resetFluteState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr FluteState](state)
  fluteAllOff(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setFluteParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr FluteState](state)
  let raw = if normalized: fluteDesc.paramFromNormalized(paramId, value) else: value
  case paramId
  of FluteParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of FluteParamBreath:  st.breath = clamp(raw, 0.0f, 1.0f)
  of FluteParamVibrato: st.vibrato = clamp(raw, 0.0f, 60.0f)
  of FluteParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of FluteParamLevel:   st.levelLin = dbToLin(clamp(raw, FluteLevelMinDb, FluteLevelMaxDb))
  else: return

proc getFluteParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr FluteState](state)
  case paramId
  of FluteParamTone:    outValue[] = st.tone
  of FluteParamBreath:  outValue[] = st.breath
  of FluteParamVibrato: outValue[] = st.vibrato
  of FluteParamPan:     outValue[] = st.pan
  of FluteParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processFluteNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                      ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                      userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr FluteState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if fluteInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  # Параметры применяются раз в блок: движок хранит их, а нода — цели.
  fluteSet(addr st.g, st.tone, st.breath, st.vibrato, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getFluteDesc*(): ptr NodeDesc =
  if not fluteReady:
    initFluteDesc()
    fluteReady = true
  addr fluteDesc

proc getFluteFactory*(): ptr NodeFactory =
  if not fluteReady:
    initFluteDesc()
    fluteReady = true
  if fluteFactory.create.isNil:
    fluteFactory = NodeFactory(
      create: createFluteState, destroy: destroyFluteState,
      process: processFluteNode, setParam: setFluteParam,
      getParam: getFluteParam, reset: resetFluteState)
  addr fluteFactory

{.pop.}

