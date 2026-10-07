# nodes/builtin/filters/biquad.nim
#
# Классический biquad (TDF-II, RBJ) на C-ядре eut_biquad.c.
#
# Семь типов: lowpass, highpass, bandpass, notch, peak, lowshelf, highshelf.
# Коэффициенты пересчитываются раз в блок по сглаженным параметрам:
# считать их на каждом сэмпле незачем, а раз в блок — как в любом
# уважающем себя плагине, и ухо разницы не слышит.

import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../native/eut_native

{.push raises: [].}

const
  BiquadParamType*   = 0'u32
  BiquadParamCutoff* = 1'u32
  BiquadParamQ*      = 2'u32
  BiquadParamGain*   = 3'u32

type
  BiquadState* = object
    ## Состояние на канал: C считает их независимо, поэтому стерео
    ## фильтр не «смешивает» каналы даже при разной громкости входа.
    filters: array[2, Biquad]

    sampleRate: float32
    kind: cint

    smoothCutoff: ParamSmoother
    smoothQ: ParamSmoother
    smoothGain: ParamSmoother

var
  biquadDesc: NodeDesc
  biquadFactory: NodeFactory
  biquadReady = false

proc initBiquadDesc() =
  biquadDesc = NodeDesc(
    id: fixedId("euterpia.biquad"),
    name: fixedName("Biquad"),
    category: fixedName("filter"),
    audioInCount: 1,
    audioOutCount: 1,
    ctrlInCount: 1,
    ctrlOutCount: 0,
    eventInCount: 0,
    eventOutCount: 0,
    latencyFrames: 0,
    maxChannels: 2,
    paramCount: 4
  )

  biquadDesc.params[0] = NodeParamDesc(
    id: BiquadParamType, name: fixedParamName("type"),
    minValue: 0.0f, maxValue: 6.0f, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfChoice)
  )
  biquadDesc.params[1] = NodeParamDesc(
    id: BiquadParamCutoff, name: fixedParamName("cutoff"),
    minValue: 10.0f, maxValue: 20000.0f, defaultValue: 1000.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  biquadDesc.params[2] = NodeParamDesc(
    id: BiquadParamQ, name: fixedParamName("q"),
    minValue: 0.05f, maxValue: 20.0f, defaultValue: 0.707f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  biquadDesc.params[3] = NodeParamDesc(
    id: BiquadParamGain, name: fixedParamName("gain"),
    minValue: -24.0f, maxValue: 24.0f, defaultValue: 0.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

proc createBiquadState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not biquadReady:
    initBiquadDesc()
    biquadReady = true

  result = allocShared0(sizeof(BiquadState))
  if result.isNil:
    return nil

  let st = cast[ptr BiquadState](result)
  for ch in 0 ..< 2:
    st.filters[ch] = newBiquad()
    if not st.filters[ch].isReady:
      return nil

  st.sampleRate = 48000.0f
  st.kind = EutBiquadLowpass
  st.smoothCutoff = initSmoother(20.0f, 48000.0f, 1000.0f)
  st.smoothQ = initSmoother(20.0f, 48000.0f, 0.707f)
  st.smoothGain = initSmoother(20.0f, 48000.0f, 0.0f)

  for ch in 0 ..< 2:
    biquadDesign(addr st.filters[ch], st.kind, st.sampleRate, 1000.0f,
                 0.707f, 0.0f)

proc destroyBiquadState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr BiquadState](state)
  for ch in 0 ..< 2:
    freeBiquad(addr st.filters[ch])
  deallocShared(state)

proc resetBiquadState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr BiquadState](state)
  for ch in 0 ..< 2:
    biquadReset(addr st.filters[ch])

proc setBiquadParam(state: pointer; paramId: uint32; value: float32;
                    normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr BiquadState](state)
  let raw = if normalized: biquadDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of BiquadParamType:
    st.kind = cint(clamp(round(raw), 0.0'f32, 6.0'f32))
  of BiquadParamCutoff:
    st.smoothCutoff.setTarget(clamp(raw, 10.0f, 20000.0f))
  of BiquadParamQ:
    st.smoothQ.setTarget(clamp(raw, 0.05f, 20.0f))
  of BiquadParamGain:
    st.smoothGain.setTarget(clamp(raw, -24.0f, 24.0f))
  else:
    discard

proc getBiquadParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr BiquadState](state)

  case paramId
  of BiquadParamType:   outValue[] = float32(st.kind)
  of BiquadParamCutoff: outValue[] = st.smoothCutoff.target
  of BiquadParamQ:      outValue[] = st.smoothQ.target
  of BiquadParamGain:   outValue[] = st.smoothGain.target
  else: return false

  true

proc processBiquadNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  let st = cast[ptr BiquadState](userData)
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
  # считаются раз в блок (синусы/косинусы не на каждом сэмпле); во время
  # перехода — на каждом сэмпле, чтобы переход не зависел от blockSize.
  let settled =
    abs(st.smoothCutoff.target - st.smoothCutoff.current) <=
      snapEps(st.smoothCutoff.target) and
    abs(st.smoothQ.target - st.smoothQ.current) <=
      snapEps(st.smoothQ.target) and
    abs(st.smoothGain.target - st.smoothGain.current) <=
      snapEps(st.smoothGain.target)
  var rampCut = st.smoothCutoff.beginRamp(frames)
  var rampQ = st.smoothQ.beginRamp(frames)
  var rampGain = st.smoothGain.beginRamp(frames)

  if abs(sr - st.sampleRate) > 0.01f:
    st.sampleRate = sr
    st.smoothCutoff = initSmoother(20.0f, sr, st.smoothCutoff.current)
    st.smoothQ = initSmoother(20.0f, sr, st.smoothQ.current)
    st.smoothGain = initSmoother(20.0f, sr, st.smoothGain.current)

  let channels = min(channelCount(outBuf), 2'i32)

  if settled:
    let cutoff = rampCut.next()
    let q = rampQ.next()
    let gain = rampGain.next()
    for ch in 0 ..< channels:
      biquadDesign(addr st.filters[ch], st.kind, sr, cutoff, q, gain)

      let pin = inBuf.channelPtr(ch, frames)
      let pout = outBuf.channelPtr(ch, frames)
      if pin.isNil or pout.isNil:
        # Interleaved-раскладка (таков выход в драйвер): непрерывного
        # указателя на канал нет, поэтому фильтруем по одному сэмплу.
        forEachFrame(outBuf, frames):
          let x = inBuf.sampleAt(ch, i)
          outBuf.setSampleAt(ch, i, biquadProcessOne(addr st.filters[ch], x))
      else:
        # in == out допустимо: TDF-II читает x до записи результата.
        biquadProcess(addr st.filters[ch], pin, pout, frames.int)
  else:
    # Переход: пересчёт коэффициентов и обработка — по сэмплу.
    var i: int32 = 0
    while i < frames:
      let cutoff = rampCut.next()
      let q = rampQ.next()
      let gain = rampGain.next()
      for ch in 0 ..< channels:
        biquadDesign(addr st.filters[ch], st.kind, sr, cutoff, q, gain)
        let x = inBuf.sampleAt(ch, i)
        outBuf.setSampleAt(ch, i, biquadProcessOne(addr st.filters[ch], x))
      inc i

proc getBiquadDesc*(): ptr NodeDesc =
  if not biquadReady:
    initBiquadDesc()
    biquadReady = true
  addr biquadDesc

proc getBiquadFactory*(): ptr NodeFactory =
  if not biquadReady:
    initBiquadDesc()
    biquadReady = true
  if biquadFactory.create.isNil:
    biquadFactory = NodeFactory(
      create: createBiquadState,
      destroy: destroyBiquadState,
      process: processBiquadNode,
      setParam: setBiquadParam,
      getParam: getBiquadParam,
      reset: resetBiquadState
    )
  addr biquadFactory

{.pop.}
