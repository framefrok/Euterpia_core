# nodes/builtin/mixing/pan.nim
#
# Стерео-панорама с постоянной мощностью.
#
# Почему constant power, а не «линейный закон»: при линейном законе
# суммарная энергия в центре падает на 3 dB, и моно-сведение звучит
# тише, чем ожидает микшер. Здесь gl^2 + gr^2 = 2 всегда (усиления
# нормированы на sqrt(2): в центре gl = gr = 1), поэтому мощность
# в центре такая же, как у края.
import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../native/eut_native

{.push raises: [].}

const
  PanParamPan* = 0'u32

type
  PanState* = object
    smoothPan: ParamSmoother

var
  panDesc: NodeDesc
  panFactory: NodeFactory
  panReady = false

proc initPanDesc() =
  panDesc = NodeDesc(
    id: fixedId("euterpia.pan"),
    name: fixedName("Pan"),
    category: fixedName("mixing"),
    audioInCount: 1, audioOutCount: 1,
    ctrlInCount: 1, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 1
  )

  panDesc.params[0] = NodeParamDesc(
    id: PanParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

proc createPanState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not panReady:
    initPanDesc()
    panReady = true

  result = allocShared0(sizeof(PanState))
  if result.isNil:
    return nil

  let st = cast[ptr PanState](result)
  st.smoothPan = initSmoother(15.0f, 48000.0f, 0.0f)

proc destroyPanState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  deallocShared(state)

proc resetPanState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  discard

proc setPanParam(state: pointer; paramId: uint32; value: float32;
                 normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil or paramId != PanParamPan:
    return
  let st = cast[ptr PanState](state)
  let raw = if normalized: panDesc.paramFromNormalized(paramId, value) else: value
  st.smoothPan.setTarget(clamp(raw, -1.0f, 1.0f))

proc getPanParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil or paramId != PanParamPan:
    return false
  outValue[] = (cast[ptr PanState](state)).smoothPan.target
  true

proc processPanNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  let st = cast[ptr PanState](userData)
  if st.isNil or audio.isNil or audio.inputCount < 1 or audio.outputCount < 1:
    return

  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf.isNil or outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  # Пер-сэмпловое сглаживание панорамы (#386): коэффициенты L/R считаются
  # на каждом сэмпле, поэтому переход не зависит от blockSize.
  var ramp = st.smoothPan.beginRamp(frames)

  let channels = channelCount(outBuf)
  let inCh = channelCount(inBuf)

  if channels >= 2 and inCh >= 2:
    var i: int32 = 0
    while i < frames:
      var gl, gr: float32
      mixPanGains(ramp.next(), gl, gr)
      outBuf.setSampleAt(0, i, inBuf.sampleAt(0, i) * gl)
      outBuf.setSampleAt(1, i, inBuf.sampleAt(1, i) * gr)
      inc i
    # Каналы сверх двух (7.1 и т.п.) копируются без панорамы:
    # на них нет закона «слева-справа».
    for ch in 2 ..< channels:
      let p = outBuf.channelPtr(ch, frames)
      if p.isNil:
        outBuf.fillZero(frames)
        return
      mixGain(inBuf.channelPtr(ch, frames), p, frames.int, 1.0f)
  else:
    # Моно-вход: панорама сводится к простому балансу.
    let nch = max(channels, 1'i32)
    var i: int32 = 0
    while i < frames:
      var gl, gr: float32
      mixPanGains(ramp.next(), gl, gr)
      for ch in 0 ..< nch:
        outBuf.setSampleAt(ch, i, inBuf.sampleAt(0, i) * (if ch == 0: gl else: gr))
      inc i

proc getPanDesc*(): ptr NodeDesc =
  if not panReady:
    initPanDesc()
    panReady = true
  addr panDesc

proc getPanFactory*(): ptr NodeFactory =
  if not panReady:
    initPanDesc()
    panReady = true
  if panFactory.create.isNil:
    panFactory = NodeFactory(
      create: createPanState, destroy: destroyPanState,
      process: processPanNode, setParam: setPanParam,
      getParam: getPanParam, reset: resetPanState
    )
  addr panFactory

{.pop.}
