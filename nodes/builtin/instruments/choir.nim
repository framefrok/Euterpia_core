# nodes/builtin/instruments/choir.nim
#
# Хор на C-ядре eut_inst.c: источник-«голосовая щель» плюс три форманты гласной
# («а» → «о» → «и» по параметру `vowel`, коэффициенты пересчитываются каждый
# блок, поэтому гласную можно вести автоматизацией). Нода — источник;
# render-путь общий — instrument_common.nim.

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
  ChoirParamVowel*   = 0'u32   # 0 — «а», 0.5 — «о», 1 — «и»
  ChoirParamTone*    = 1'u32   # яркость источника, 0..1
  ChoirParamVibrato* = 2'u32   # глубина вибрато, центы
  ChoirParamPan*     = 3'u32
  ChoirParamLevel*   = 4'u32   # dB

  ChoirVoices = 12
  ChoirDefaultSampleRate = 48000.0f
  ChoirLevelMinDb = -80.0f
  ChoirLevelMaxDb = 6.0f

type
  ChoirState* = object
    g: Choir
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    vowel, tone, vibrato, pan, levelLin: float32

var
  choirDesc: NodeDesc
  choirFactory: NodeFactory
  choirReady = false

proc initChoirDesc() =
  choirDesc = NodeDesc(
    id: fixedId("euterpia.choir"),
    name: fixedName("Choir"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5)
  choirDesc.params[0] = NodeParamDesc(
    id: ChoirParamVowel, name: fixedParamName("vowel"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  choirDesc.params[1] = NodeParamDesc(
    id: ChoirParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  choirDesc.params[2] = NodeParamDesc(
    id: ChoirParamVibrato, name: fixedParamName("vibrato"),
    minValue: 0.0f, maxValue: 60.0f, defaultValue: 9.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  choirDesc.params[3] = NodeParamDesc(
    id: ChoirParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  choirDesc.params[4] = NodeParamDesc(
    id: ChoirParamLevel, name: fixedParamName("level"),
    minValue: ChoirLevelMinDb, maxValue: ChoirLevelMaxDb,
    defaultValue: -8.0f, step: 0.1f, flags: uint32(npfAutomatable))

proc createChoirState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not choirReady:
    initChoirDesc()
    choirReady = true
  result = allocShared0(sizeof(ChoirState))
  if result.isNil:
    return nil
  let st = cast[ptr ChoirState](result)
  st.sampleRate = ChoirDefaultSampleRate
  st.g = newChoir(ChoirVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = choirAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.vowel = 0.0f; st.tone = 0.5f; st.vibrato = 9.0f
  st.pan = 0.0f; st.levelLin = dbToLin(-8.0f)

proc destroyChoirState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeChoir(addr (cast[ptr ChoirState](state)).g)
  deallocShared(state)

proc resetChoirState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr ChoirState](state)
  choirReset(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setChoirParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr ChoirState](state)
  let raw = if normalized: choirDesc.paramFromNormalized(paramId, value)
            else: value
  case paramId
  of ChoirParamVowel:   st.vowel = clamp(raw, 0.0f, 1.0f)
  of ChoirParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of ChoirParamVibrato: st.vibrato = clamp(raw, 0.0f, 60.0f)
  of ChoirParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of ChoirParamLevel:   st.levelLin = dbToLin(clamp(raw, ChoirLevelMinDb,
                                                    ChoirLevelMaxDb))
  else: return

proc getChoirParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr ChoirState](state)
  case paramId
  of ChoirParamVowel:   outValue[] = st.vowel
  of ChoirParamTone:    outValue[] = st.tone
  of ChoirParamVibrato: outValue[] = st.vibrato
  of ChoirParamPan:     outValue[] = st.pan
  of ChoirParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processChoirNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                      ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                      userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr ChoirState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if choirInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  choirSet(addr st.g, st.vowel, st.tone, st.vibrato, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getChoirDesc*(): ptr NodeDesc =
  if not choirReady:
    initChoirDesc()
    choirReady = true
  addr choirDesc

proc getChoirFactory*(): ptr NodeFactory =
  if not choirReady:
    initChoirDesc()
    choirReady = true
  if choirFactory.create.isNil:
    choirFactory = NodeFactory(
      create: createChoirState, destroy: destroyChoirState,
      process: processChoirNode, setParam: setChoirParam,
      getParam: getChoirParam, reset: resetChoirState)
  addr choirFactory

{.pop.}

