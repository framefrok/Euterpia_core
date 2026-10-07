# nodes/builtin/io/input.nim
#
# Вход устройства в граф (issue #3).
#
# Нода — источник: у неё нет аудио-входов, а выход берётся из
# `ctx.input`, то есть из planar-арены драйверного входа, которую
# AudioEngine публикует каждый блок.
#
# Раскладка входа:
#   - channels == 1 -> моно: канал 0 дублируется в оба выхода;
#   - channels == 2 -> стерео: канал-в-канал;
#   - channels == 0 -> входа нет: выход зануляется (тишина).
#
# Нода НЕ трогает кольца, файлы и аллокации: только чтение ctx.input и
# запись в выходной порт. Усиление (gain) сглаживается, как в gain-ноде,
# чтобы автоматизация входа не щёлкала.
import
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../../sdk/dsp_units

{.push raises: [].}

const
  InputParamGain* = 0'u32

type
  InputState* = object
    ## Состояние input-ноды. POD, без строк и владения памятью.
    smoothDb: ParamSmoother

var
  inputDesc: NodeDesc
  inputFactory: NodeFactory
  inputReady = false

proc initInputDesc() =
  inputDesc = NodeDesc(
    id: fixedId("euterpia.input"),
    name: fixedName("Input"),
    category: fixedName("io"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 1
  )

  inputDesc.params[0] = NodeParamDesc(
    id: InputParamGain, name: fixedParamName("gain"),
    minValue: -80.0f, maxValue: 12.0f, defaultValue: 0.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

proc createInputState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not inputReady:
    initInputDesc()
    inputReady = true

  result = allocShared0(sizeof(InputState))
  if result.isNil:
    return nil

  let st = cast[ptr InputState](result)
  # Дефолт — 0 dB (unity): вход по умолчанию не окрашивает сигнал.
  st.smoothDb = initSmoother(15.0f, 48000.0f, 0.0f)

proc destroyInputState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  deallocShared(state)

proc resetInputState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  discard

proc setInputParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil or paramId != InputParamGain:
    return
  let st = cast[ptr InputState](state)
  let raw = if normalized: inputDesc.paramFromNormalized(paramId, value) else: value
  st.smoothDb.setTarget(clamp(raw, -80.0f, 12.0f))

proc getInputParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil or paramId != InputParamGain:
    return false
  outValue[] = (cast[ptr InputState](state)).smoothDb.target
  true

proc processInputNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events

  let st = cast[ptr InputState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1:
    return

  let outBuf = audio.outputs[0]
  if outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  let src = if ctx.isNil: nil else: ctx.input
  if src.isNil or src.data.isNil or src.channels <= 0:
    # Входа нет: молчим, а не отдаём мусор прошлого блока.
    outBuf.fillZero(frames)
    return

  let inChans = src.channels
  let outChans = max(channelCount(outBuf), 1'i32)

  # Пер-сэмпловое сглаживание (#386): усиление входа применяется по сэмплу,
  # а не одним значением конца блока — иначе переход «прыгает» на границе.
  var ramp = st.smoothDb.beginRamp(frames)

  var i: int32 = 0
  while i < frames:
    let g = dbToLin(ramp.next())
    for ch in 0 ..< outChans:
      # Моно-вход разводится в оба выхода; стерео — канал-в-канал.
      let srcCh =
        if inChans == 1: 0'i32
        elif ch < inChans: ch
        else: inChans - 1'i32
      outBuf.setSampleAt(ch, i, src.sampleAt(srcCh, i) * g)
    inc i

proc getInputDesc*(): ptr NodeDesc =
  if not inputReady:
    initInputDesc()
    inputReady = true
  addr inputDesc

proc getInputFactory*(): ptr NodeFactory =
  if not inputReady:
    initInputDesc()
    inputReady = true
  if inputFactory.create.isNil:
    inputFactory = NodeFactory(
      create: createInputState, destroy: destroyInputState,
      process: processInputNode, setParam: setInputParam,
      getParam: getInputParam, reset: resetInputState
    )
  addr inputFactory

{.pop.}
