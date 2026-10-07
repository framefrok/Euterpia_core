# nodes/builtin/dynamics/compressor.nim
#
# Feed-forward компрессор на C-ядре eut_comp.c.
#
# Stereo link реализован здесь, а не в C: детектор считается по максимуму
# каналов, поэтому оба канала получают одинаковую кривую gain и образ
# не «разъезжается». Решение о линке принимает хост — это политика,
# а не математика.
#
# Gain reduction публикуется на control-порту 0: на него вешается
# индикатор в UI. В process() это единственная запись в ctrl.
import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../native/eut_native

{.push raises: [].}

const
  CompParamThreshold* = 0'u32
  CompParamRatio*     = 1'u32
  CompParamKnee*      = 2'u32
  CompParamAttack*    = 3'u32
  CompParamRelease*   = 4'u32
  CompParamMakeup*    = 5'u32
  CompParamLink*      = 6'u32

type
  CompressorState* = object
    comp: Compressor
    channels: int32
    stereoLink: bool

    ## Scratch для детектора stereo link.
    ##
    ## Выделяется один раз при создании ноды: в audio thread нельзя
    ## ни аллоцировать, ни использовать буфер входа ноды как промежуточный
    ## (входной буфер может быть общим для нескольких потребителей —
    ##  запись в него из компрессора испортила бы соседние ветки графа).
    detectorScratch: ptr float32

    # Параметры, влияющие на коэффициенты, пересчитываются в C;
    # их нужно передавать туда одним вызовом, поэтому хранятся здесь.
    pThreshold: float32
    pRatio: float32
    pKnee: float32
    pAttack: float32
    pRelease: float32
    pMakeup: float32

    smoothThreshold: ParamSmoother
    smoothRatio: ParamSmoother
    smoothMakeup: ParamSmoother

var
  compDesc: NodeDesc
  compFactory: NodeFactory
  compReady = false

proc initCompDesc() =
  compDesc = NodeDesc(
    id: fixedId("euterpia.compressor"),
    name: fixedName("Compressor"),
    category: fixedName("dynamics"),
    audioInCount: 1, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 1,   # out 0 — gain reduction в dB
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 7
  )

  compDesc.params[0] = NodeParamDesc(
    id: CompParamThreshold, name: fixedParamName("threshold"),
    minValue: -60.0f, maxValue: 0.0f, defaultValue: -18.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  compDesc.params[1] = NodeParamDesc(
    id: CompParamRatio, name: fixedParamName("ratio"),
    minValue: 1.0f, maxValue: 20.0f, defaultValue: 4.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  compDesc.params[2] = NodeParamDesc(
    id: CompParamKnee, name: fixedParamName("knee"),
    minValue: 0.0f, maxValue: 24.0f, defaultValue: 6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  compDesc.params[3] = NodeParamDesc(
    id: CompParamAttack, name: fixedParamName("attack"),
    minValue: 0.0001f, maxValue: 2.0f, defaultValue: 0.01f, step: 0.0001f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  compDesc.params[4] = NodeParamDesc(
    id: CompParamRelease, name: fixedParamName("release"),
    minValue: 0.0001f, maxValue: 4.0f, defaultValue: 0.1f, step: 0.0001f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  compDesc.params[5] = NodeParamDesc(
    id: CompParamMakeup, name: fixedParamName("makeup"),
    minValue: -24.0f, maxValue: 24.0f, defaultValue: 0.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  compDesc.params[6] = NodeParamDesc(
    id: CompParamLink, name: fixedParamName("link"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 1.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfChoice)
  )

proc createCompState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not compReady:
    initCompDesc()
    compReady = true
  if not abiCheck():
    return nil

  result = allocShared0(sizeof(CompressorState))
  if result.isNil:
    return nil

  let st = cast[ptr CompressorState](result)
  st.channels = 2
  st.stereoLink = true
  st.detectorScratch = cast[ptr float32](
    allocShared0(sizeof(float32) * int(MaxBlockSize))
  )
  if st.detectorScratch.isNil:
    deallocShared(result)
    return nil
  st.pThreshold = -18.0f
  st.pRatio = 4.0f
  st.pKnee = 6.0f
  st.pAttack = 0.01f
  st.pRelease = 0.1f
  st.pMakeup = 0.0f

  st.comp = newCompressor(2, EutCompPeak, 48000.0f)
  if not st.comp.isReady:
    deallocShared(result)
    return nil
  compSetParams(addr st.comp, st.pThreshold, st.pRatio, st.pKnee,
                st.pAttack, st.pRelease, st.pMakeup)

  st.smoothThreshold = initSmoother(50.0f, 48000.0f, -18.0f)
  st.smoothRatio = initSmoother(50.0f, 48000.0f, 4.0f)
  st.smoothMakeup = initSmoother(50.0f, 48000.0f, 0.0f)

proc destroyCompState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr CompressorState](state)
  freeCompressor(addr st.comp)
  if not st.detectorScratch.isNil:
    deallocShared(st.detectorScratch)
    st.detectorScratch = nil
  deallocShared(state)

proc resetCompState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  compReset(addr (cast[ptr CompressorState](state)).comp)

proc setCompParam(state: pointer; paramId: uint32; value: float32;
                  normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr CompressorState](state)
  let raw = if normalized: compDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of CompParamThreshold: st.smoothThreshold.setTarget(clamp(raw, -60.0f, 0.0f))
  of CompParamRatio:     st.smoothRatio.setTarget(clamp(raw, 1.0f, 20.0f))
  of CompParamKnee:      st.pKnee = clamp(raw, 0.0f, 24.0f)
  of CompParamAttack:    st.pAttack = clamp(raw, 0.0001f, 2.0f)
  of CompParamRelease:   st.pRelease = clamp(raw, 0.0001f, 4.0f)
  of CompParamMakeup:    st.smoothMakeup.setTarget(clamp(raw, -24.0f, 24.0f))
  of CompParamLink:      st.stereoLink = round(raw) >= 0.5f
  else: discard

proc getCompParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr CompressorState](state)

  case paramId
  of CompParamThreshold: outValue[] = st.smoothThreshold.target
  of CompParamRatio:     outValue[] = st.smoothRatio.target
  of CompParamKnee:      outValue[] = st.pKnee
  of CompParamAttack:    outValue[] = st.pAttack
  of CompParamRelease:   outValue[] = st.pRelease
  of CompParamMakeup:    outValue[] = st.smoothMakeup.target
  of CompParamLink:      outValue[] = (if st.stereoLink: 1.0f else: 0.0f)
  else: return false

  true

proc processCompNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard events
  let st = cast[ptr CompressorState](userData)
  if st.isNil or audio.isNil or audio.inputCount < 1 or audio.outputCount < 1:
    return

  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf.isNil or outBuf.isNil:
    return

  # Кривая gain в C-состоянии рассчитана максимум на EutCompMaxBlock
  # сэмплов (он же — предел блока в Core). Клампим явно: без этого
  # применение кривой читало бы память за границей массива (issue #64).
  let frames = min(processFrames(ctx, outBuf), EutCompMaxBlock.int32)
  if frames <= 0:
    return

  let channels = min(channelCount(outBuf), 2'i32)
  let scale = 1.0f / sqrt(0.5f)

  # Пер-сэмпловое сглаживание (#386). Порог/ratio/makeup двигают кривую gain:
  # установившийся режим считает её раз в блок, переход — по сэмплу через
  # `compSetParams`+`compDetect(1)` (одно значение на позицию).
  let settled =
    abs(st.smoothThreshold.target - st.smoothThreshold.current) <=
      snapEps(st.smoothThreshold.target) and
    abs(st.smoothRatio.target - st.smoothRatio.current) <=
      snapEps(st.smoothRatio.target) and
    abs(st.smoothMakeup.target - st.smoothMakeup.current) <=
      snapEps(st.smoothMakeup.target)
  var rampThr = st.smoothThreshold.beginRamp(frames)
  var rampRatio = st.smoothRatio.beginRamp(frames)
  var rampMakeup = st.smoothMakeup.beginRamp(frames)

  let stereoLink =
    st.stereoLink and channels >= 2 and not st.detectorScratch.isNil

  if settled:
    st.pThreshold = rampThr.next()
    st.pRatio = rampRatio.next()
    st.pMakeup = rampMakeup.next()
    compSetParams(addr st.comp, st.pThreshold, st.pRatio, st.pKnee,
                  st.pAttack, st.pRelease, st.pMakeup)

    # --- Детектор (блок) -------------------------------------------------
    #
    # При линке детектор считается по максимуму каналов, нормированному
    # так, чтобы сумма моно-сигналов не читалась как +3 dB.
    # Детектор НИКОГДА не пишет во входной буфер: вход может быть общим
    # для нескольких нод графа.
    var detectorInput: ptr float32 = nil
    if st.stereoLink and channels >= 2:
      let l = inBuf.channelPtr(0, frames)
      let r = inBuf.channelPtr(1, frames)
      if not l.isNil and not r.isNil and not st.detectorScratch.isNil:
        let la = cast[ptr UncheckedArray[float32]](l)
        let ra = cast[ptr UncheckedArray[float32]](r)
        let scratch = cast[ptr UncheckedArray[float32]](st.detectorScratch)
        for i in 0 ..< frames.int:
          let a = abs(la[i])
          let b = abs(ra[i])
          scratch[i] = (if a > b: a else: b) * scale
        detectorInput = st.detectorScratch
    else:
      detectorInput = inBuf.channelPtr(0, frames)
    if not detectorInput.isNil:
      compDetect(addr st.comp, detectorInput, frames.int)

    # --- Применение (блок) ----------------------------------------------
    for ch in 0 ..< max(channels, 1'i32):
      let pin = inBuf.channelPtr(ch, frames)
      let pout = outBuf.channelPtr(ch, frames)

      if pin.isNil or pout.isNil:
        # Interleaved-раскладка (выход прямо в драйвер): непрерывного
        # указателя на канал нет, поэтому gain берётся по сэмплам.
        forEachFrame(outBuf, frames):
          let x = inBuf.sampleAt(ch, i)
          outBuf.setSampleAt(ch, i, x * compGainAt(addr st.comp, i))
      else:
        compApply(addr st.comp, pin, pout, frames.int)
  else:
    # --- Переход: порог/ratio/makeup и обработка — по сэмплу ------------
    var i: int32 = 0
    while i < frames:
      compSetParams(addr st.comp, rampThr.next(), rampRatio.next(), st.pKnee,
                    st.pAttack, st.pRelease, rampMakeup.next())
      var det: float32
      if stereoLink:
        let a = abs(inBuf.sampleAt(0, i))
        let b = abs(inBuf.sampleAt(1, i))
        det = (if a > b: a else: b) * scale
      else:
        det = inBuf.sampleAt(0, i)
      compDetect(addr st.comp, addr det, 1)
      let g = compGainAt(addr st.comp, 0)
      for ch in 0 ..< max(channels, 1'i32):
        outBuf.setSampleAt(ch, i, inBuf.sampleAt(ch, i) * g)
      inc i

  # --- Метрика ------------------------------------------------------------
  if not ctrl.isNil and ctrl.outputCount > 0 and not ctrl.outputs[0].isNil:
    ctrl.outputs[0][] = compGainDb(addr st.comp)

proc getCompDesc*(): ptr NodeDesc =
  if not compReady:
    initCompDesc()
    compReady = true
  addr compDesc

proc getCompFactory*(): ptr NodeFactory =
  if not compReady:
    initCompDesc()
    compReady = true
  if compFactory.create.isNil:
    compFactory = NodeFactory(
      create: createCompState, destroy: destroyCompState,
      process: processCompNode, setParam: setCompParam,
      getParam: getCompParam, reset: resetCompState
    )
  addr compFactory

{.pop.}
