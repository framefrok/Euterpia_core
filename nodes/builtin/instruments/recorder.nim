# nodes/builtin/instruments/recorder.nim
#
# Свирель/блокфлейта на C-ядре eut_inst.c: деревянный духовой — как флейта,
# но спектр «деревянный» (заметны чётные гармоники), атака слышнее. Моно.
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
  RecorderParamTone*    = 0'u32   # яркость, 0..1
  RecorderParamBreath*  = 1'u32   # дыхание (шум), 0..1
  RecorderParamVibrato* = 2'u32   # глубина вибрато, центы
  RecorderParamPan*     = 3'u32
  RecorderParamLevel*   = 4'u32   # dB

  RecorderVoices = 8
  RecorderDefaultSampleRate = 48000.0f
  RecorderLevelMinDb = -80.0f
  RecorderLevelMaxDb = 6.0f

type
  RecorderState* = object
    g: Recorder
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    tone, breath, vibrato, pan, levelLin: float32

var
  recorderDesc: NodeDesc
  recorderFactory: NodeFactory
  recorderReady = false

proc initRecorderDesc() =
  recorderDesc = NodeDesc(
    id: fixedId("euterpia.recorder"),
    name: fixedName("Recorder"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5)
  recorderDesc.params[0] = NodeParamDesc(
    id: RecorderParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.6f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  recorderDesc.params[1] = NodeParamDesc(
    id: RecorderParamBreath, name: fixedParamName("breath"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.30f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  recorderDesc.params[2] = NodeParamDesc(
    id: RecorderParamVibrato, name: fixedParamName("vibrato"),
    minValue: 0.0f, maxValue: 60.0f, defaultValue: 5.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  recorderDesc.params[3] = NodeParamDesc(
    id: RecorderParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  recorderDesc.params[4] = NodeParamDesc(
    id: RecorderParamLevel, name: fixedParamName("level"),
    minValue: RecorderLevelMinDb, maxValue: RecorderLevelMaxDb,
    defaultValue: -6.0f, step: 0.1f, flags: uint32(npfAutomatable))

proc createRecorderState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not recorderReady:
    initRecorderDesc()
    recorderReady = true
  result = allocShared0(sizeof(RecorderState))
  if result.isNil:
    return nil
  let st = cast[ptr RecorderState](result)
  st.sampleRate = RecorderDefaultSampleRate
  st.g = newRecorder(RecorderVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = recorderAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tone = 0.6f; st.breath = 0.30f; st.vibrato = 5.0f
  st.pan = 0.0f; st.levelLin = dbToLin(-6.0f)

proc destroyRecorderState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeRecorder(addr (cast[ptr RecorderState](state)).g)
  deallocShared(state)

proc resetRecorderState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr RecorderState](state)
  recorderAllOff(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setRecorderParam(state: pointer; paramId: uint32; value: float32;
                      normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr RecorderState](state)
  let raw = if normalized: recorderDesc.paramFromNormalized(paramId, value)
            else: value
  case paramId
  of RecorderParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of RecorderParamBreath:  st.breath = clamp(raw, 0.0f, 1.0f)
  of RecorderParamVibrato: st.vibrato = clamp(raw, 0.0f, 60.0f)
  of RecorderParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of RecorderParamLevel:   st.levelLin = dbToLin(clamp(raw, RecorderLevelMinDb,
                                                       RecorderLevelMaxDb))
  else: return

proc getRecorderParam(state: pointer; paramId: uint32;
                      outValue: ptr float32): bool {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr RecorderState](state)
  case paramId
  of RecorderParamTone:    outValue[] = st.tone
  of RecorderParamBreath:  outValue[] = st.breath
  of RecorderParamVibrato: outValue[] = st.vibrato
  of RecorderParamPan:     outValue[] = st.pan
  of RecorderParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processRecorderNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                         ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                         userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr RecorderState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if recorderInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  recorderSet(addr st.g, st.tone, st.breath, st.vibrato, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getRecorderDesc*(): ptr NodeDesc =
  if not recorderReady:
    initRecorderDesc()
    recorderReady = true
  addr recorderDesc

proc getRecorderFactory*(): ptr NodeFactory =
  if not recorderReady:
    initRecorderDesc()
    recorderReady = true
  if recorderFactory.create.isNil:
    recorderFactory = NodeFactory(
      create: createRecorderState, destroy: destroyRecorderState,
      process: processRecorderNode, setParam: setRecorderParam,
      getParam: getRecorderParam, reset: resetRecorderState)
  addr recorderFactory

{.pop.}

