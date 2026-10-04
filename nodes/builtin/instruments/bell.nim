# nodes/builtin/instruments/bell.nim
#
# Колокол (трубчатый/церковный) на C-ядре eut_inst.c: сумма ингармонических
# частичных с индивидуальным затуханием — высокие гаснут быстрее, звон со
# временем темнеет. Нода — источник; render-путь общий — instrument_common.nim.

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
  BellParamTune*  = 0'u32   # множитель строя (0.25..4)
  BellParamDecay* = 1'u32   # длина звона, секунды
  BellParamTone*  = 2'u32   # яркость (наклон частичных), 0..1
  BellParamPan*   = 3'u32
  BellParamLevel* = 4'u32   # dB

  BellVoices = 12
  BellDefaultSampleRate = 48000.0f
  BellLevelMinDb = -80.0f
  BellLevelMaxDb = 6.0f

type
  BellState* = object
    g: Bell
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    tune, decay, tone, pan, levelLin: float32

var
  bellDesc: NodeDesc
  bellFactory: NodeFactory
  bellReady = false

proc initBellDesc() =
  bellDesc = NodeDesc(
    id: fixedId("euterpia.bell"),
    name: fixedName("Bell"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5
  )
  bellDesc.params[0] = NodeParamDesc(
    id: BellParamTune, name: fixedParamName("tune"),
    minValue: 0.25f, maxValue: 4.0f, defaultValue: 1.0f, step: 0.001f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bellDesc.params[1] = NodeParamDesc(
    id: BellParamDecay, name: fixedParamName("decay"),
    minValue: 0.1f, maxValue: 30.0f, defaultValue: 4.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bellDesc.params[2] = NodeParamDesc(
    id: BellParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bellDesc.params[3] = NodeParamDesc(
    id: BellParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bellDesc.params[4] = NodeParamDesc(
    id: BellParamLevel, name: fixedParamName("level"),
    minValue: BellLevelMinDb, maxValue: BellLevelMaxDb, defaultValue: -8.0f,
    step: 0.1f, flags: uint32(npfAutomatable))

proc createBellState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not bellReady:
    initBellDesc()
    bellReady = true
  result = allocShared0(sizeof(BellState))
  if result.isNil:
    return nil
  let st = cast[ptr BellState](result)
  st.sampleRate = BellDefaultSampleRate
  st.g = newBell(BellVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = bellAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tune = 1.0f; st.decay = 4.0f; st.tone = 0.5f
  st.pan = 0.0f; st.levelLin = dbToLin(-8.0f)

proc destroyBellState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeBell(addr (cast[ptr BellState](state)).g)
  deallocShared(state)

proc resetBellState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr BellState](state)
  bellAllOff(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setBellParam(state: pointer; paramId: uint32; value: float32;
                  normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr BellState](state)
  let raw = if normalized: bellDesc.paramFromNormalized(paramId, value) else: value
  case paramId
  of BellParamTune:  st.tune = clamp(raw, 0.25f, 4.0f)
  of BellParamDecay: st.decay = clamp(raw, 0.1f, 30.0f)
  of BellParamTone:  st.tone = clamp(raw, 0.0f, 1.0f)
  of BellParamPan:   st.pan = clamp(raw, -1.0f, 1.0f)
  of BellParamLevel: st.levelLin = dbToLin(clamp(raw, BellLevelMinDb, BellLevelMaxDb))
  else: return

proc getBellParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr BellState](state)
  case paramId
  of BellParamTune:  outValue[] = st.tune
  of BellParamDecay: outValue[] = st.decay
  of BellParamTone:  outValue[] = st.tone
  of BellParamPan:   outValue[] = st.pan
  of BellParamLevel: outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processBellNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                     ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                     userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr BellState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if bellInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  bellSet(addr st.g, st.tune, st.decay, st.tone, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getBellDesc*(): ptr NodeDesc =
  if not bellReady:
    initBellDesc()
    bellReady = true
  addr bellDesc

proc getBellFactory*(): ptr NodeFactory =
  if not bellReady:
    initBellDesc()
    bellReady = true
  if bellFactory.create.isNil:
    bellFactory = NodeFactory(
      create: createBellState, destroy: destroyBellState,
      process: processBellNode, setParam: setBellParam,
      getParam: getBellParam, reset: resetBellState)
  addr bellFactory

{.pop.}
