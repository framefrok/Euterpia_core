# nodes/builtin/instruments/timpani.nim
#
# Литавры на C-ядре eut_inst.c: настраиваемый барабан со СТРОЕМ (моды 1:1.504:
# 2:2.61 затухают с разной скоростью) плюс короткий шумовой удар. Нотой не
# глушится — звенит до конца. Нода — источник; render-путь — instrument_common.

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
  TimpaniParamTune*  = 0'u32   # строй, множитель
  TimpaniParamDecay* = 1'u32   # длина звона, множитель
  TimpaniParamTone*  = 2'u32   # яркость и шум атаки, 0..1
  TimpaniParamPan*   = 3'u32
  TimpaniParamLevel* = 4'u32   # dB

  TimpaniVoices = 6
  TimpaniDefaultSampleRate = 48000.0f
  TimpaniLevelMinDb = -80.0f
  TimpaniLevelMaxDb = 6.0f

type
  TimpaniState* = object
    g: Timpani
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    tune, decay, tone, pan, levelLin: float32

var
  timpaniDesc: NodeDesc
  timpaniFactory: NodeFactory
  timpaniReady = false

proc initTimpaniDesc() =
  timpaniDesc = NodeDesc(
    id: fixedId("euterpia.timpani"),
    name: fixedName("Timpani"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5)
  timpaniDesc.params[0] = NodeParamDesc(
    id: TimpaniParamTune, name: fixedParamName("tune"),
    minValue: 0.25f, maxValue: 4.0f, defaultValue: 1.0f, step: 0.001f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  timpaniDesc.params[1] = NodeParamDesc(
    id: TimpaniParamDecay, name: fixedParamName("decay"),
    minValue: 0.1f, maxValue: 8.0f, defaultValue: 1.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  timpaniDesc.params[2] = NodeParamDesc(
    id: TimpaniParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  timpaniDesc.params[3] = NodeParamDesc(
    id: TimpaniParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  timpaniDesc.params[4] = NodeParamDesc(
    id: TimpaniParamLevel, name: fixedParamName("level"),
    minValue: TimpaniLevelMinDb, maxValue: TimpaniLevelMaxDb,
    defaultValue: -6.0f, step: 0.1f, flags: uint32(npfAutomatable))

proc createTimpaniState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not timpaniReady:
    initTimpaniDesc()
    timpaniReady = true
  result = allocShared0(sizeof(TimpaniState))
  if result.isNil:
    return nil
  let st = cast[ptr TimpaniState](result)
  st.sampleRate = TimpaniDefaultSampleRate
  st.g = newTimpani(TimpaniVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = timpaniAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tune = 1.0f; st.decay = 1.0f; st.tone = 0.5f
  st.pan = 0.0f; st.levelLin = dbToLin(-6.0f)

proc destroyTimpaniState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeTimpani(addr (cast[ptr TimpaniState](state)).g)
  deallocShared(state)

proc resetTimpaniState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr TimpaniState](state)
  timpaniAllOff(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setTimpaniParam(state: pointer; paramId: uint32; value: float32;
                     normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr TimpaniState](state)
  let raw = if normalized: timpaniDesc.paramFromNormalized(paramId, value)
            else: value
  case paramId
  of TimpaniParamTune:  st.tune = clamp(raw, 0.25f, 4.0f)
  of TimpaniParamDecay: st.decay = clamp(raw, 0.1f, 8.0f)
  of TimpaniParamTone:  st.tone = clamp(raw, 0.0f, 1.0f)
  of TimpaniParamPan:   st.pan = clamp(raw, -1.0f, 1.0f)
  of TimpaniParamLevel: st.levelLin = dbToLin(clamp(raw, TimpaniLevelMinDb,
                                                    TimpaniLevelMaxDb))
  else: return

proc getTimpaniParam(state: pointer; paramId: uint32;
                     outValue: ptr float32): bool {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr TimpaniState](state)
  case paramId
  of TimpaniParamTune:  outValue[] = st.tune
  of TimpaniParamDecay: outValue[] = st.decay
  of TimpaniParamTone:  outValue[] = st.tone
  of TimpaniParamPan:   outValue[] = st.pan
  of TimpaniParamLevel: outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processTimpaniNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                        ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                        userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr TimpaniState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if timpaniInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  timpaniSet(addr st.g, st.tune, st.decay, st.tone, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getTimpaniDesc*(): ptr NodeDesc =
  if not timpaniReady:
    initTimpaniDesc()
    timpaniReady = true
  addr timpaniDesc

proc getTimpaniFactory*(): ptr NodeFactory =
  if not timpaniReady:
    initTimpaniDesc()
    timpaniReady = true
  if timpaniFactory.create.isNil:
    timpaniFactory = NodeFactory(
      create: createTimpaniState, destroy: destroyTimpaniState,
      process: processTimpaniNode, setParam: setTimpaniParam,
      getParam: getTimpaniParam, reset: resetTimpaniState)
  addr timpaniFactory

{.pop.}

