# nodes/builtin/effects/delay.nim
#
# Стерео-задержка на C-ядре eut_delay.c: дробное время, интерполяция
# Catmull-Rom, обратная связь с фильтром, ping-pong.
#
# Память под кольцо выделяется здесь, на холодной стороне, и размер
# определяется максимальным временем задержки: пересоздавать кольцо в
# audio thread нельзя, поэтому параметр времени меняется только в
# пределах уже выделенной ёмкости.
import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../native/eut_native

{.push raises: [].}

const
  DelayParamTimeL*     = 0'u32
  DelayParamTimeR*     = 1'u32
  DelayParamFeedback*  = 2'u32
  DelayParamMix*       = 3'u32
  DelayParamPingPong*  = 4'u32

  # 4 секунды максимума: для большинства музыкальных задержек хватает,
  # а память под кольцо (2 канала * 192000 фреймов) считается один раз.
  DelayMaxSeconds* = 4.0'f32

type
  DelayState* = object
    dly: Delay
    memory: ptr float32
    capacityFrames: int
    sampleRate: float32
    pingPong: bool

    smoothTimeL: ParamSmoother
    smoothTimeR: ParamSmoother
    smoothFeedback: ParamSmoother
    smoothMix: ParamSmoother

var
  delayDesc: NodeDesc
  delayFactory: NodeFactory
  delayReady = false

proc initDelayDesc() =
  delayDesc = NodeDesc(
    id: fixedId("euterpia.delay"),
    name: fixedName("Delay"),
    category: fixedName("effects"),
    audioInCount: 1, audioOutCount: 1,
    ctrlInCount: 1, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 5
  )

  delayDesc.params[0] = NodeParamDesc(
    id: DelayParamTimeL, name: fixedParamName("time_l"),
    minValue: 0.001f, maxValue: DelayMaxSeconds, defaultValue: 0.25f, step: 0.001f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  delayDesc.params[1] = NodeParamDesc(
    id: DelayParamTimeR, name: fixedParamName("time_r"),
    minValue: 0.001f, maxValue: DelayMaxSeconds, defaultValue: 0.25f, step: 0.001f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  delayDesc.params[2] = NodeParamDesc(
    id: DelayParamFeedback, name: fixedParamName("feedback"),
    minValue: 0.0f, maxValue: 0.95f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  delayDesc.params[3] = NodeParamDesc(
    id: DelayParamMix, name: fixedParamName("mix"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.3f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  delayDesc.params[4] = NodeParamDesc(
    id: DelayParamPingPong, name: fixedParamName("pingpong"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfChoice)
  )

proc createDelayState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not delayReady:
    initDelayDesc()
    delayReady = true
  if not abiCheck():
    return nil

  result = allocShared0(sizeof(DelayState))
  if result.isNil:
    return nil

  let st = cast[ptr DelayState](result)
  st.sampleRate = 48000.0f
  st.pingPong = false
  st.capacityFrames = int(DelayMaxSeconds) * 48000 + 8

  st.memory = cast[ptr float32](
    allocShared0(sizeof(float32) * st.capacityFrames * 2)
  )
  if st.memory.isNil:
    deallocShared(result)
    return nil

  st.dly = newDelay(st.memory, st.capacityFrames)
  if not st.dly.isReady:
    deallocShared(st.memory)
    deallocShared(result)
    return nil
  delaySet(addr st.dly, st.sampleRate, 0.25f, 0.25f, 0.35f, 0.3f, false)

  st.smoothTimeL = initSmoother(50.0f, 48000.0f, 0.25f)
  st.smoothTimeR = initSmoother(50.0f, 48000.0f, 0.25f)
  st.smoothFeedback = initSmoother(50.0f, 48000.0f, 0.35f)
  st.smoothMix = initSmoother(50.0f, 48000.0f, 0.3f)

proc destroyDelayState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr DelayState](state)
  freeDelay(addr st.dly)
  if not st.memory.isNil:
    deallocShared(st.memory)
    st.memory = nil
  deallocShared(state)

proc resetDelayState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  delayReset(addr (cast[ptr DelayState](state)).dly)

proc setDelayParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr DelayState](state)
  let raw = if normalized: delayDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of DelayParamTimeL:
    st.smoothTimeL.setTarget(clamp(raw, 0.001f, DelayMaxSeconds))
  of DelayParamTimeR:
    st.smoothTimeR.setTarget(clamp(raw, 0.001f, DelayMaxSeconds))
  of DelayParamFeedback:
    st.smoothFeedback.setTarget(clamp(raw, 0.0f, 0.95f))
  of DelayParamMix:
    st.smoothMix.setTarget(clamp(raw, 0.0f, 1.0f))
  of DelayParamPingPong:
    st.pingPong = round(raw) >= 0.5f
  else:
    discard

proc getDelayParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr DelayState](state)

  case paramId
  of DelayParamTimeL:    outValue[] = st.smoothTimeL.target
  of DelayParamTimeR:    outValue[] = st.smoothTimeR.target
  of DelayParamFeedback: outValue[] = st.smoothFeedback.target
  of DelayParamMix:      outValue[] = st.smoothMix.target
  of DelayParamPingPong: outValue[] = (if st.pingPong: 1.0f else: 0.0f)
  else: return false

  true

proc processDelayNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  let st = cast[ptr DelayState](userData)
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
  if abs(sr - st.sampleRate) > 0.01f:
    # Смена sample rate меняет требуемый размер кольца.
    # Перевыделять память в audio thread нельзя, поэтому кольцо
    # остаётся прежним, а время просто пересчитывается в кадры.
    st.sampleRate = sr

  # Пер-сэмпловое сглаживание (#386). Установившийся режим — параметры ставятся
  # раз в блок; во время перехода — на каждом сэмпле (ядро задержки принимает
  # одно значение на вызов, поэтому переход идёт вызовами по одному сэмплу).
  let settled =
    abs(st.smoothTimeL.target - st.smoothTimeL.current) <=
      snapEps(st.smoothTimeL.target) and
    abs(st.smoothTimeR.target - st.smoothTimeR.current) <=
      snapEps(st.smoothTimeR.target) and
    abs(st.smoothFeedback.target - st.smoothFeedback.current) <=
      snapEps(st.smoothFeedback.target) and
    abs(st.smoothMix.target - st.smoothMix.current) <=
      snapEps(st.smoothMix.target)
  var rampTimeL = st.smoothTimeL.beginRamp(frames)
  var rampTimeR = st.smoothTimeR.beginRamp(frames)
  var rampFb = st.smoothFeedback.beginRamp(frames)
  var rampMix = st.smoothMix.beginRamp(frames)

  let channels = channelCount(outBuf)
  let inCh = channelCount(inBuf)

  let inL = inBuf.channelPtr(0, frames)
  let inR = if inCh >= 2: inBuf.channelPtr(1, frames) else: inL
  let outL = outBuf.channelPtr(0, frames)
  let outR = if channels >= 2: outBuf.channelPtr(1, frames) else: outL

  if inL.isNil or inR.isNil or outL.isNil or outR.isNil:
    # Задержке нужен непрерывный доступ к обоим каналам; на
    # interleaved-буфере корректного звука не получить, поэтому
    # выход просто копирует вход — тише, чем «мусор с хвостом».
    forEachFrame(outBuf, frames):
      let x = inBuf.sampleAt(0, i)
      outBuf.setSampleAt(0, i, x)
      if channels >= 2:
        outBuf.setSampleAt(1, i, x)
    return

  if settled:
    delaySet(addr st.dly, sr, rampTimeL.next(), rampTimeR.next(),
             rampFb.next(), rampMix.next(), st.pingPong)
    delayProcess(addr st.dly, inL, inR, outL, outR, frames.int)
  else:
    let inLA = cast[ptr UncheckedArray[float32]](inL)
    let inRA = cast[ptr UncheckedArray[float32]](inR)
    let outLA = cast[ptr UncheckedArray[float32]](outL)
    let outRA = cast[ptr UncheckedArray[float32]](outR)
    var i: int32 = 0
    while i < frames:
      delaySet(addr st.dly, sr, rampTimeL.next(), rampTimeR.next(),
               rampFb.next(), rampMix.next(), st.pingPong)
      delayProcess(addr st.dly, addr inLA[i], addr inRA[i],
                   addr outLA[i], addr outRA[i], 1)
      inc i

  # Каналы сверх двух (7.1): копируем вход без обработки.
  if channels > 2:
    for ch in 2 ..< channels:
      let p = outBuf.channelPtr(ch, frames)
      if p.isNil:
        outBuf.fillZero(frames)
        return
      mixGain(inBuf.channelPtr(ch, frames), p, frames.int, 1.0f)

proc getDelayDesc*(): ptr NodeDesc =
  if not delayReady:
    initDelayDesc()
    delayReady = true
  addr delayDesc

proc getDelayFactory*(): ptr NodeFactory =
  if not delayReady:
    initDelayDesc()
    delayReady = true
  if delayFactory.create.isNil:
    delayFactory = NodeFactory(
      create: createDelayState, destroy: destroyDelayState,
      process: processDelayNode, setParam: setDelayParam,
      getParam: getDelayParam, reset: resetDelayState
    )
  addr delayFactory

{.pop.}
