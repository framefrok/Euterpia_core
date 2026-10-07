# nodes/builtin/generators/oscillator.nim
#
# Генератор на C-ядре eut_osc.c (polyBLEP, без алиасинга).
#
# Разделение по MANIFEST §47:
#   OscillatorDesc  — только метаданные: порты, параметры, latency 0
#   OscillatorState — только DSP: фаза, сглаженные параметры, состояние C
#
# В process() нет ни строк, ни таблиц, ни аллокаций: всё состояние
# создаётся в createOscState() на холодной стороне.

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
  # Идентификаторы параметров числовые и стабильные: проект,
  # автоматизация и CLI ссылаются на них, а не на названия.
  OscParamWaveform* = 0'u32
  OscParamFrequency* = 1'u32
  OscParamLevel* = 2'u32
  OscParamDetune* = 3'u32
  OscParamPulseWidth* = 4'u32

type
  OscillatorState* = object
    osc: Osc
    sampleRate: float32

    # Целевые значения и их сглаженные копии.
    #
    # Сглаживание обязательно: параметр обновляется раз в 128 сэмплов
    # (control rate), и без него автоматизация частоты слышна как
    # ступенчатое «заикание» на каждом блоке.
    smoothFreq: ParamSmoother
    smoothLevel: ParamSmoother
    smoothDetune: ParamSmoother
    smoothPulse: ParamSmoother

    waveform: cint

var
  oscDesc: NodeDesc
  oscFactory: NodeFactory
  oscReady = false

# ==============================================================================
# Descriptor (холодная сторона)
# ==============================================================================

proc initOscDesc() =
  oscDesc = NodeDesc(
    id: fixedId("euterpia.osc"),
    name: fixedName("Oscillator"),
    category: fixedName("generator"),
    audioInCount: 0,
    audioOutCount: 1,
    ctrlInCount: 0,
    ctrlOutCount: 0,
    eventInCount: 1,      # MIDI-подписка на ноты
    eventOutCount: 0,
    latencyFrames: 0,
    maxChannels: 2,
    paramCount: 5
  )

  oscDesc.params[0] = NodeParamDesc(
    id: OscParamWaveform,
    name: fixedParamName("waveform"),
    minValue: 0.0f, maxValue: 3.0f, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfChoice)
  )
  oscDesc.params[1] = NodeParamDesc(
    id: OscParamFrequency,
    name: fixedParamName("freq"),
    minValue: 0.01f, maxValue: 20000.0f, defaultValue: 440.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  oscDesc.params[2] = NodeParamDesc(
    id: OscParamLevel,
    name: fixedParamName("level"),
    minValue: -80.0f, maxValue: 6.0f, defaultValue: -6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  oscDesc.params[3] = NodeParamDesc(
    id: OscParamDetune,
    name: fixedParamName("detune"),
    minValue: -50.0f, maxValue: 50.0f, defaultValue: 0.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  oscDesc.params[4] = NodeParamDesc(
    id: OscParamPulseWidth,
    name: fixedParamName("width"),
    minValue: 0.05f, maxValue: 0.95f, defaultValue: 0.5f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc createOscState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not oscReady:
    initOscDesc()
    oscReady = true

  result = allocShared0(sizeof(OscillatorState))
  if result.isNil:
    return nil

  let st = cast[ptr OscillatorState](result)
  st.sampleRate = 48000.0f
  st.osc = newOsc(st.sampleRate, 440.0f)
  if not st.osc.isReady:
    deallocShared(result)
    return nil
  st.waveform = EutOscSaw

  # Время сглаживания 20 мс — компромисс: заметно мягче «ступенек»
  # и при этом неслышимо при игре на клавиатуре.
  st.smoothFreq = initSmoother(20.0f, 48000.0f, 440.0f)
  st.smoothLevel = initSmoother(10.0f, 48000.0f, dbToLin(-6.0f))
  st.smoothDetune = initSmoother(20.0f, 48000.0f, 0.0f)
  st.smoothPulse = initSmoother(10.0f, 48000.0f, 0.5f)

proc destroyOscState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  freeOsc(addr (cast[ptr OscillatorState](state)).osc)
  deallocShared(state)

proc resetOscState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  oscReset(addr (cast[ptr OscillatorState](state)).osc)

# ==============================================================================
# Параметры
#
# setParam может вызываться и из control plane, и из audio thread
# (команда cmdSetParam). Поэтому здесь только запись целевого значения
# в поле состояния: это атомарно в пределах float32 и не требует
# синхронизации — настоящее изменение звука происходит в process().
# ==============================================================================

proc setOscParam(state: pointer; paramId: uint32; value: float32;
                 normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr OscillatorState](state)
  let raw = if normalized: oscDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of OscParamWaveform:
    st.waveform = cint(clamp(round(raw), 0.0'f32, 3.0'f32))
  of OscParamFrequency:
    st.smoothFreq.setTarget(clamp(raw, 0.01f, 20000.0f))
  of OscParamLevel:
    st.smoothLevel.setTarget(dbToLin(clamp(raw, -80.0f, 6.0f)))
  of OscParamDetune:
    st.smoothDetune.setTarget(clamp(raw, -50.0f, 50.0f))
  of OscParamPulseWidth:
    st.smoothPulse.setTarget(clamp(raw, 0.05f, 0.95f))
  else:
    discard

proc getOscParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr OscillatorState](state)

  case paramId
  of OscParamWaveform:   outValue[] = float32(st.waveform)
  of OscParamFrequency:  outValue[] = st.smoothFreq.target
  of OscParamLevel:      outValue[] = linToDb(st.smoothLevel.target)
  of OscParamDetune:     outValue[] = st.smoothDetune.target
  of OscParamPulseWidth: outValue[] = st.smoothPulse.target
  else: return false

  true

# ==============================================================================
# Обработка (audio thread)
# ==============================================================================

proc oscChanPtr(a: ptr float32; i: int32): ptr float32 {.inline.} =
  ## Указатель на сэмпл `i` канала: `channelPtr` даёт на канал, а ядру осциллятора
  ## нужен указатель на конкретный сэмпл (пер-сэмпловый переход, #386).
  cast[ptr float32](addr cast[ptr UncheckedArray[float32]](a)[int(i)])

proc processOscNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr OscillatorState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1:
    return

  let outBuf = audio.outputs[0]
  if outBuf.isNil:
    return

  # --- MIDI: нота меняет частоту --------------------------------------------
  if not events.isNil and events.inputCount > 0:
    let q = events.inputs[0]
    if not q.isNil:
      for i in 0 ..< q.count:
        let ev = q.events[i]
        if ev.kind == evNoteOn or ev.kind == evNoteOff:
          if ev.data[0] >= 0.0f:
            st.smoothFreq.setTarget(
              clamp(midiNoteToFreq(ev.data[0]), 0.01f, 20000.0f)
            )

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  # --- Сглаживание параметров ------------------------------------------------
  # Уровень — всегда по сэмплу (#386). freq/detune/pulse двигают состояние ядра
  # (фазовый инкремент и ширину импульса): в установившемся режиме ставятся раз
  # в блок, в переходе — на каждом сэмпле (рендер по одному сэмплу).
  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    # Смена sample rate пересоздаёт сглаживатели с новым шагом,
    # но сохраняет текущие значения: иначе параметр «прыгает».
    st.sampleRate = sr
    st.smoothFreq = initSmoother(20.0f, sr, st.smoothFreq.current)
    st.smoothLevel = initSmoother(10.0f, sr, st.smoothLevel.current)
    st.smoothDetune = initSmoother(20.0f, sr, st.smoothDetune.current)
    st.smoothPulse = initSmoother(10.0f, sr, st.smoothPulse.current)

  let settledOsc =
    abs(st.smoothFreq.target - st.smoothFreq.current) <=
      snapEps(st.smoothFreq.target) and
    abs(st.smoothDetune.target - st.smoothDetune.current) <=
      snapEps(st.smoothDetune.target) and
    abs(st.smoothPulse.target - st.smoothPulse.current) <=
      snapEps(st.smoothPulse.target)
  var rampFreq = st.smoothFreq.beginRamp(frames)
  var rampDetune = st.smoothDetune.beginRamp(frames)
  var rampPulse = st.smoothPulse.beginRamp(frames)
  var levelRamp = st.smoothLevel.beginRamp(frames)

  let channels = channelCount(outBuf)
  let kind = st.waveform

  if settledOsc:
    let freq = rampFreq.next()
    let detune = rampDetune.next()
    let pulse = rampPulse.next()
    oscSetFreq(addr st.osc, sr, freq)
    oscSetPulseWidth(addr st.osc, pulse)

    let n = frames.cint
    if channels <= 1:
      let p = outBuf.channelPtr(0, frames)
      if p.isNil:
        outBuf.fillZero(frames)
      else:
        oscRender(addr st.osc, kind, p, n, 1.0f)
    elif abs(detune) < 0.001f:
      # Без расстройки оба канала получают один и тот же инкремент фазы:
      # так они когерентны, как у настоящего моно-генератора.
      for ch in 0 ..< channels:
        let p = outBuf.channelPtr(ch, frames)
        if p.isNil:
          outBuf.fillZero(frames)
          return
        oscRender(addr st.osc, kind, p, n, 1.0f)
    else:
      let pl = outBuf.channelPtr(0, frames)
      let pr = outBuf.channelPtr(1, frames)
      if pl.isNil or pr.isNil:
        outBuf.fillZero(frames)
      else:
        oscRenderStereo(addr st.osc, kind, pl, pr, n, 1.0f, detune)

    # Уровень: одно значение на позицию сэмпла, ко всем каналам (#386).
    var i: int32 = 0
    while i < frames:
      let g = levelRamp.next()
      for ch in 0 ..< channels:
        outBuf.setSampleAt(ch, i, outBuf.sampleAt(ch, i) * g)
      inc i
  else:
    # Переход: freq/detune/pulse/level — на каждом сэмпле. Каналы заранее
    # сводятся к указателям: рендер идёт по одному сэмплу.
    var chanPtr: array[8, ptr float32]
    let nch = min(channels, 8'i32)
    for ch in 0 ..< nch:
      chanPtr[int(ch)] = outBuf.channelPtr(ch, frames)
      if chanPtr[int(ch)].isNil:
        outBuf.fillZero(frames)
        return
    var i: int32 = 0
    while i < frames:
      let f = rampFreq.next()
      let d = rampDetune.next()
      let p = rampPulse.next()
      let g = levelRamp.next()
      oscSetFreq(addr st.osc, sr, f)
      oscSetPulseWidth(addr st.osc, p)
      if nch <= 1:
        oscRender(addr st.osc, kind, oscChanPtr(chanPtr[0], i), 1, g)
      elif abs(d) < 0.001f:
        for ch in 0 ..< nch:
          oscRender(addr st.osc, kind, oscChanPtr(chanPtr[int(ch)], i), 1, g)
      else:
        oscRenderStereo(addr st.osc, kind, oscChanPtr(chanPtr[0], i),
                        oscChanPtr(chanPtr[1], i), 1, g, d)
      inc i

# ==============================================================================
# Экспорт
# ==============================================================================

proc getOscillatorDesc*(): ptr NodeDesc =
  if not oscReady:
    initOscDesc()
    oscReady = true
  addr oscDesc

proc getOscillatorFactory*(): ptr NodeFactory =
  if not oscReady:
    initOscDesc()
    oscReady = true
  if oscFactory.create.isNil:
    oscFactory = NodeFactory(
      create: createOscState,
      destroy: destroyOscState,
      process: processOscNode,
      setParam: setOscParam,
      getParam: getOscParam,
      reset: resetOscState
    )
  addr oscFactory

{.pop.}
