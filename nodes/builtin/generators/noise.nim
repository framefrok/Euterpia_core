# nodes/builtin/generators/noise.nim
#
# Генератор шума на C-ядре eut_noise.c: белый, розовый (-3 dB/окт),
# коричневый (-6 dB/окт).
#
# Генератор детерминирован по сиду: один и тот же сид даёт один и тот же
# шум. Это нужно и офлайн-рендеру (проект обязан звучать одинаково при
# повторном открытии), и тестам.
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
  NoiseParamColor* = 0'u32
  NoiseParamLevel* = 1'u32

type
  NoiseState* = object
    nz: Noise
    color: cint

    smoothLevel: ParamSmoother

var
  noiseDesc: NodeDesc
  noiseFactory: NodeFactory
  noiseReady = false

proc initNoiseDesc() =
  noiseDesc = NodeDesc(
    id: fixedId("euterpia.noise"),
    name: fixedName("Noise"),
    category: fixedName("generator"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 2
  )

  noiseDesc.params[0] = NodeParamDesc(
    id: NoiseParamColor, name: fixedParamName("color"),
    minValue: 0.0f, maxValue: 2.0f, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfChoice)
  )
  noiseDesc.params[1] = NodeParamDesc(
    id: NoiseParamLevel, name: fixedParamName("level"),
    minValue: -80.0f, maxValue: 6.0f, defaultValue: -20.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

proc createNoiseState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not noiseReady:
    initNoiseDesc()
    noiseReady = true
  if not abiCheck():
    return nil

  result = allocShared0(sizeof(NoiseState))
  if result.isNil:
    return nil

  let st = cast[ptr NoiseState](result)
  st.color = EutNoiseWhite
  # Сид фиксирован: одинаковый шум при каждом запуске проекта.
  st.nz = newNoise(0x9E3779B9'u32)
  if not st.nz.isReady:
    deallocShared(result)
    return nil
  st.smoothLevel = initSmoother(10.0f, 48000.0f, dbToLin(-20.0f))

proc destroyNoiseState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  freeNoise(addr (cast[ptr NoiseState](state)).nz)
  deallocShared(state)

proc resetNoiseState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr NoiseState](state)
  freeNoise(addr st.nz)
  st.nz = newNoise(0x9E3779B9'u32)

proc setNoiseParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr NoiseState](state)
  let raw = if normalized: noiseDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of NoiseParamColor:
    st.color = cint(clamp(round(raw), 0.0'f32, 2.0'f32))
  of NoiseParamLevel:
    st.smoothLevel.setTarget(dbToLin(clamp(raw, -80.0f, 6.0f)))
  else:
    discard

proc getNoiseParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr NoiseState](state)

  case paramId
  of NoiseParamColor: outValue[] = float32(st.color)
  of NoiseParamLevel: outValue[] = linToDb(st.smoothLevel.target)
  else: return false

  true

proc processNoiseNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  let st = cast[ptr NoiseState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1:
    return

  let outBuf = audio.outputs[0]
  if outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  let level = st.smoothLevel.advance(frames)

  let channels = channelCount(outBuf)
  for ch in 0 ..< max(channels, 1'i32):
    let p = outBuf.channelPtr(ch, frames)
    if p.isNil:
      outBuf.fillZero(frames)
      return
    # Левый и правый получают РАЗНЫЕ отсчёты: общий шум в двух каналах
    # слышен как узкий моно-сигнал и «схлопывает» стерео-сцену.
    if ch == 0:
      noiseRender(addr st.nz, st.color, p, frames.int, level)
    else:
      noiseRender(addr st.nz, st.color, p, frames.int, level)

proc getNoiseDesc*(): ptr NodeDesc =
  if not noiseReady:
    initNoiseDesc()
    noiseReady = true
  addr noiseDesc

proc getNoiseFactory*(): ptr NodeFactory =
  if not noiseReady:
    initNoiseDesc()
    noiseReady = true
  if noiseFactory.create.isNil:
    noiseFactory = NodeFactory(
      create: createNoiseState, destroy: destroyNoiseState,
      process: processNoiseNode, setParam: setNoiseParam,
      getParam: getNoiseParam, reset: resetNoiseState
    )
  addr noiseFactory

{.pop.}
