# nodes/builtin/mixing/gain.nim
#
# Усиление в dB. Самая частая нода в любом проекте и самая частая причина
# клика при автоматизации — поэтому gain всегда сглаживается.
#
# Нода умеет писать и в interleaved-буфер (выход прямо в драйвер):
# для planar используется векторное C-ядро, для interleaved — скалярный
# путь по одному сэмплу.
import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../../sdk/dsp_units,
  ../native/eut_native

{.push raises: [].}

const
  GainParamGain* = 0'u32

type
  GainState* = object
    smoothDb: ParamSmoother

var
  gainDesc: NodeDesc
  gainFactory: NodeFactory
  gainReady = false

proc initGainDesc() =
  gainDesc = NodeDesc(
    id: fixedId("euterpia.gain"),
    name: fixedName("Gain"),
    category: fixedName("mixing"),
    audioInCount: 1, audioOutCount: 1,
    ctrlInCount: 1, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 1
  )

  gainDesc.params[0] = NodeParamDesc(
    id: GainParamGain, name: fixedParamName("gain"),
    minValue: -80.0f, maxValue: 12.0f, defaultValue: 0.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

proc createGainState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not gainReady:
    initGainDesc()
    gainReady = true

  result = allocShared0(sizeof(GainState))
  if result.isNil:
    return nil

  let st = cast[ptr GainState](result)
  st.smoothDb = initSmoother(15.0f, 48000.0f, 0.0f)

proc destroyGainState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  deallocShared(state)

proc resetGainState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  discard

proc setGainParam(state: pointer; paramId: uint32; value: float32;
                  normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil or paramId != GainParamGain:
    return
  let st = cast[ptr GainState](state)
  let raw = if normalized: gainDesc.paramFromNormalized(paramId, value) else: value
  st.smoothDb.setTarget(clamp(raw, -80.0f, 12.0f))

proc getGainParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil or paramId != GainParamGain:
    return false
  outValue[] = (cast[ptr GainState](state)).smoothDb.target
  true

proc processGainNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  let st = cast[ptr GainState](userData)
  if st.isNil or audio.isNil or audio.inputCount < 1 or audio.outputCount < 1:
    return

  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf.isNil or outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  let channels = channelCount(outBuf)

  # Пер-сэмпловое сглаживание (#386): нода больше не применяет одно значение
  # конца блока ко всему блоку, поэтому переход параметра не зависит от blockSize.
  let settled = abs(st.smoothDb.target - st.smoothDb.current) <=
    snapEps(st.smoothDb.target)
  var ramp = st.smoothDb.beginRamp(frames)

  if settled:
    # Установившийся режим: усиление постоянно — оставляем быстрый SIMD-путь.
    let lin = dbToLin(ramp.next())
    for ch in 0 ..< max(channels, 1'i32):
      let pin = inBuf.channelPtr(ch, frames)
      let pout = outBuf.channelPtr(ch, frames)
      if pin.isNil or pout.isNil:
        forEachFrame(outBuf, frames):
          outBuf.setSampleAt(ch, i, inBuf.sampleAt(ch, i) * lin)
      else:
        mixGain(pin, pout, frames.int, lin)
  else:
    # Переход: усиление считается и применяется ПО СЭМПЛУ.
    var i: int32 = 0
    while i < frames:
      let g = dbToLin(ramp.next())
      for ch in 0 ..< channels:
        outBuf.setSampleAt(ch, i, inBuf.sampleAt(ch, i) * g)
      inc i

proc getGainDesc*(): ptr NodeDesc =
  if not gainReady:
    initGainDesc()
    gainReady = true
  addr gainDesc

proc getGainFactory*(): ptr NodeFactory =
  if not gainReady:
    initGainDesc()
    gainReady = true
  if gainFactory.create.isNil:
    gainFactory = NodeFactory(
      create: createGainState, destroy: destroyGainState,
      process: processGainNode, setParam: setGainParam,
      getParam: getGainParam, reset: resetGainState
    )
  addr gainFactory

{.pop.}
