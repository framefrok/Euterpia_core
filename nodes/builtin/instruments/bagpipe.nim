# nodes/builtin/instruments/bagpipe.nim
#
# Волынка на C-ядре eut_inst.c: бурдон (постоянные тоны, звучат пока держится
# нота) + шантир («тростниковая» мелодия из нечётных гармоник). Legato —
# между нотами нет пауз, бурдон их связывает.

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
  BagpipeParamTone*       = 0'u32   # яркость шантира, 0..1
  BagpipeParamDroneLevel* = 1'u32   # уровень бурдона, 0..1
  BagpipeParamDroneFreq*  = 2'u32   # частота бурдона, Гц
  BagpipeParamPan*        = 3'u32
  BagpipeParamLevel*      = 4'u32   # dB

  BagpipeVoices = 4
  BagpipeDefaultSampleRate = 48000.0f
  BagpipeLevelMinDb = -80.0f
  BagpipeLevelMaxDb = 6.0f

type
  BagpipeState* = object
    g: Bagpipe
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    tone, droneLevel, droneFreq, pan, levelLin: float32

var
  bagpipeDesc: NodeDesc
  bagpipeFactory: NodeFactory
  bagpipeReady = false

proc initBagpipeDesc() =
  bagpipeDesc = NodeDesc(
    id: fixedId("euterpia.bagpipe"),
    name: fixedName("Bagpipe"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5
  )
  bagpipeDesc.params[0] = NodeParamDesc(
    id: BagpipeParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.6f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bagpipeDesc.params[1] = NodeParamDesc(
    id: BagpipeParamDroneLevel, name: fixedParamName("drone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bagpipeDesc.params[2] = NodeParamDesc(
    id: BagpipeParamDroneFreq, name: fixedParamName("droneFreq"),
    minValue: 20.0f, maxValue: 500.0f, defaultValue: 110.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bagpipeDesc.params[3] = NodeParamDesc(
    id: BagpipeParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  bagpipeDesc.params[4] = NodeParamDesc(
    id: BagpipeParamLevel, name: fixedParamName("level"),
    minValue: BagpipeLevelMinDb, maxValue: BagpipeLevelMaxDb,
    defaultValue: -6.0f, step: 0.1f, flags: uint32(npfAutomatable))

proc createBagpipeState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not bagpipeReady:
    initBagpipeDesc()
    bagpipeReady = true
  result = allocShared0(sizeof(BagpipeState))
  if result.isNil:
    return nil
  let st = cast[ptr BagpipeState](result)
  st.sampleRate = BagpipeDefaultSampleRate
  st.g = newBagpipe(BagpipeVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = bagpipeAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tone = 0.6f; st.droneLevel = 0.35f; st.droneFreq = 110.0f
  st.pan = 0.0f; st.levelLin = dbToLin(-6.0f)

proc destroyBagpipeState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeBagpipe(addr (cast[ptr BagpipeState](state)).g)
  deallocShared(state)

proc resetBagpipeState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr BagpipeState](state)
  bagpipeAllOff(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setBagpipeParam(state: pointer; paramId: uint32; value: float32;
                     normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr BagpipeState](state)
  let raw = if normalized: bagpipeDesc.paramFromNormalized(paramId, value) else: value
  case paramId
  of BagpipeParamTone:       st.tone = clamp(raw, 0.0f, 1.0f)
  of BagpipeParamDroneLevel: st.droneLevel = clamp(raw, 0.0f, 1.0f)
  of BagpipeParamDroneFreq:  st.droneFreq = clamp(raw, 20.0f, 500.0f)
  of BagpipeParamPan:        st.pan = clamp(raw, -1.0f, 1.0f)
  of BagpipeParamLevel:      st.levelLin = dbToLin(clamp(raw, BagpipeLevelMinDb, BagpipeLevelMaxDb))
  else: return

proc getBagpipeParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr BagpipeState](state)
  case paramId
  of BagpipeParamTone:       outValue[] = st.tone
  of BagpipeParamDroneLevel: outValue[] = st.droneLevel
  of BagpipeParamDroneFreq:  outValue[] = st.droneFreq
  of BagpipeParamPan:        outValue[] = st.pan
  of BagpipeParamLevel:      outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processBagpipeNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                        ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                        userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr BagpipeState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if bagpipeInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  bagpipeSet(addr st.g, st.tone, st.droneLevel, st.droneFreq, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getBagpipeDesc*(): ptr NodeDesc =
  if not bagpipeReady:
    initBagpipeDesc()
    bagpipeReady = true
  addr bagpipeDesc

proc getBagpipeFactory*(): ptr NodeFactory =
  if not bagpipeReady:
    initBagpipeDesc()
    bagpipeReady = true
  if bagpipeFactory.create.isNil:
    bagpipeFactory = NodeFactory(
      create: createBagpipeState, destroy: destroyBagpipeState,
      process: processBagpipeNode, setParam: setBagpipeParam,
      getParam: getBagpipeParam, reset: resetBagpipeState)
  addr bagpipeFactory

{.pop.}

