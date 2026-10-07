# nodes/builtin/filters/svf.nim
#
# SVF-фильтр (state variable, TPT-формулировка) на C-ядре eut_svf.c.
#
# Отличие от biquad: SVF даёт 12 dB/окт на обоих полюсах, устойчив
# почти до всей полосы и не «схлопывается» при низком Q. Минус — только
# 12 dB, поэтому глубокую фильтрацию делают каскадом из двух SVF.
#
# Resonance задаётся как 1/Q: 1.0 — нейтрально, меньше — резче.
import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../native/eut_native

{.push raises: [].}

const
  SvfParamType*      = 0'u32
  SvfParamCutoff*    = 1'u32
  SvfParamResonance* = 2'u32

type
  SvfState* = object
    filters: array[2, Svf]
    sampleRate: float32
    kind: cint

    smoothCutoff: ParamSmoother
    smoothReso: ParamSmoother

var
  svfDesc: NodeDesc
  svfFactory: NodeFactory
  svfReady = false

proc initSvfDesc() =
  svfDesc = NodeDesc(
    id: fixedId("euterpia.svf"),
    name: fixedName("SVF"),
    category: fixedName("filter"),
    audioInCount: 1, audioOutCount: 1,
    ctrlInCount: 1, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 3
  )

  svfDesc.params[0] = NodeParamDesc(
    id: SvfParamType, name: fixedParamName("type"),
    minValue: 0.0f, maxValue: 3.0f, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfChoice)
  )
  svfDesc.params[1] = NodeParamDesc(
    id: SvfParamCutoff, name: fixedParamName("cutoff"),
    minValue: 10.0f, maxValue: 20000.0f, defaultValue: 1000.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  svfDesc.params[2] = NodeParamDesc(
    id: SvfParamResonance, name: fixedParamName("reso"),
    minValue: 0.05f, maxValue: 4.0f, defaultValue: 1.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

proc createSvfState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not svfReady:
    initSvfDesc()
    svfReady = true
  if not abiCheck():
    return nil

  result = allocShared0(sizeof(SvfState))
  if result.isNil:
    return nil

  let st = cast[ptr SvfState](result)
  for ch in 0 ..< 2:
    st.filters[ch] = newSvf()
    if not st.filters[ch].isReady:
      return nil

  st.sampleRate = 48000.0f
  st.kind = EutSvfLowpass
  st.smoothCutoff = initSmoother(20.0f, 48000.0f, 1000.0f)
  st.smoothReso = initSmoother(20.0f, 48000.0f, 1.0f)

  for ch in 0 ..< 2:
    svfDesign(addr st.filters[ch], st.kind, st.sampleRate, 1000.0f, 1.0f)

proc destroySvfState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr SvfState](state)
  for ch in 0 ..< 2:
    freeSvf(addr st.filters[ch])
  deallocShared(state)

proc resetSvfState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr SvfState](state)
  for ch in 0 ..< 2:
    svfReset(addr st.filters[ch])

proc setSvfParam(state: pointer; paramId: uint32; value: float32;
                 normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr SvfState](state)
  let raw = if normalized: svfDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of SvfParamType:
    st.kind = cint(clamp(round(raw), 0.0'f32, 3.0'f32))
  of SvfParamCutoff:
    st.smoothCutoff.setTarget(clamp(raw, 10.0f, 20000.0f))
  of SvfParamResonance:
    st.smoothReso.setTarget(clamp(raw, 0.05f, 4.0f))
  else:
    discard

proc getSvfParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr SvfState](state)

  case paramId
  of SvfParamType:      outValue[] = float32(st.kind)
  of SvfParamCutoff:    outValue[] = st.smoothCutoff.target
  of SvfParamResonance: outValue[] = st.smoothReso.target
  else: return false

  true

proc processSvfNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  let st = cast[ptr SvfState](userData)
  if st.isNil or audio.isNil or audio.inputCount < 1 or audio.outputCount < 1:
    return

  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf.isNil or outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate

  # Пер-сэмпловое сглаживание (#386). Установившийся режим — коэффициенты
  # считаются раз в блок (быстро); во время перехода — на КАЖДОМ сэмпле, чтобы
  # форма перехода не зависела от blockSize. Ядро SVF принимает одно значение
  # на вызов, поэтому per-sample переход идёт через `svfProcessOne`.
  let settled =
    abs(st.smoothCutoff.target - st.smoothCutoff.current) <=
      snapEps(st.smoothCutoff.target) and
    abs(st.smoothReso.target - st.smoothReso.current) <=
      snapEps(st.smoothReso.target)
  var rampCut = st.smoothCutoff.beginRamp(frames)
  var rampReso = st.smoothReso.beginRamp(frames)

  if abs(sr - st.sampleRate) > 0.01f:
    st.sampleRate = sr
    st.smoothCutoff = initSmoother(20.0f, sr, st.smoothCutoff.current)
    st.smoothReso = initSmoother(20.0f, sr, st.smoothReso.current)

  let channels = min(channelCount(outBuf), 2'i32)

  if settled:
    let cutoff = rampCut.next()
    let reso = rampReso.next()
    for ch in 0 ..< channels:
      svfDesign(addr st.filters[ch], st.kind, sr, cutoff, reso)

      let pin = inBuf.channelPtr(ch, frames)
      let pout = outBuf.channelPtr(ch, frames)
      if pin.isNil or pout.isNil:
        forEachFrame(outBuf, frames):
          outBuf.setSampleAt(ch, i,
            svfProcessOne(addr st.filters[ch], st.kind, inBuf.sampleAt(ch, i)))
      else:
        svfProcess(addr st.filters[ch], st.kind, pin, pout, frames.int)
  else:
    # Переход: коэффициенты и обработка — по сэмплу (одно значение на позицию,
    # общее для всех каналов).
    var i: int32 = 0
    while i < frames:
      let cutoff = rampCut.next()
      let reso = rampReso.next()
      for ch in 0 ..< channels:
        svfDesign(addr st.filters[ch], st.kind, sr, cutoff, reso)
        outBuf.setSampleAt(ch, i,
          svfProcessOne(addr st.filters[ch], st.kind, inBuf.sampleAt(ch, i)))
      inc i

proc getSvfDesc*(): ptr NodeDesc =
  if not svfReady:
    initSvfDesc()
    svfReady = true
  addr svfDesc

proc getSvfFactory*(): ptr NodeFactory =
  if not svfReady:
    initSvfDesc()
    svfReady = true
  if svfFactory.create.isNil:
    svfFactory = NodeFactory(
      create: createSvfState, destroy: destroySvfState,
      process: processSvfNode, setParam: setSvfParam,
      getParam: getSvfParam, reset: resetSvfState
    )
  addr svfFactory

{.pop.}
