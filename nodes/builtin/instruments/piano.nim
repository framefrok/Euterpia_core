# nodes/builtin/instruments/piano.nim
#
# Фортепиано на C-ядре eut_inst.c (модальные струны + молоточковый шум).
#
# Отличие от остальных инструментов — сустейн-педаль: CC64 у фортепиано
# снимает демпфер, а не глушит голоса, поэтому в таблице вызовов
# (`pianoAbi`) у него есть `pedal`, а у органа, гитары и ударных — нет.
# Педаль копится в `InstMidi.sustainDown` и здесь же снимается со струн
# при release: отдельной логики в ноде не требуется.
#
# `decay` и `release` — множители, а не секунды: собственное время
# затухания струны ядро считает по номеру ноты (низкие звенят дольше),
# а параметры лишь масштабируют его.

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
  PianoParamTone*    = 0'u32   # яркость, 0..1
  PianoParamDecay*   = 1'u32   # множитель времени затухания, 0.15..4
  PianoParamDetune*  = 2'u32   # расстройка струн хора, центы
  PianoParamHammer*  = 3'u32   # уровень молоточкового шума, 0..1
  PianoParamRelease* = 4'u32   # множитель сброса после note-off
  PianoParamPan*     = 5'u32
  PianoParamLevel*   = 6'u32   # dB

  ## 16 голосов: диатоническая пьеса с педалью легко держит 10-12
  ## звучащих струн, плюс запас на «хвосты» после снятия демпфера.
  PianoVoices = 16

  PianoDefaultSampleRate = 48000.0f
  PianoLevelMinDb = -80.0f
  PianoLevelMaxDb = 6.0f

type
  PianoState* = object
    g: Piano
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
      ## Временный planar-буфер для interleaved-выхода (см. InstScratchFrames).
    sampleRate: float32
    tone, decay, detune, hammer, release, pan, levelLin: float32
    live: bool

var
  pianoDesc: NodeDesc
  pianoFactory: NodeFactory
  pianoReady = false


# ==============================================================================
# Descriptor (холодная сторона)
# ==============================================================================

proc initPianoDesc() =
  pianoDesc = NodeDesc(
    id: fixedId("euterpia.piano"),
    name: fixedName("Piano"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0,
    maxChannels: 2,
    paramCount: 7
  )

  pianoDesc.params[0] = NodeParamDesc(
    id: PianoParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.55f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  pianoDesc.params[1] = NodeParamDesc(
    id: PianoParamDecay, name: fixedParamName("decay"),
    minValue: 0.15f, maxValue: 4.0f, defaultValue: 1.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  pianoDesc.params[2] = NodeParamDesc(
    id: PianoParamDetune, name: fixedParamName("detune"),
    minValue: 0.0f, maxValue: 30.0f, defaultValue: 4.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  pianoDesc.params[3] = NodeParamDesc(
    id: PianoParamHammer, name: fixedParamName("hammer"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.4f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  pianoDesc.params[4] = NodeParamDesc(
    id: PianoParamRelease, name: fixedParamName("release"),
    minValue: 0.02f, maxValue: 3.0f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  pianoDesc.params[5] = NodeParamDesc(
    id: PianoParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  pianoDesc.params[6] = NodeParamDesc(
    id: PianoParamLevel, name: fixedParamName("level"),
    minValue: PianoLevelMinDb, maxValue: PianoLevelMaxDb,
    defaultValue: -6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc pianoApplyParams(st: ptr PianoState) =
  pianoSet(addr st.g, st.tone, st.decay, st.detune, st.hammer, st.release,
           st.pan, st.levelLin)
  st.live = false

proc createPianoState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not pianoReady:
    initPianoDesc()
    pianoReady = true

  result = allocShared0(sizeof(PianoState))
  if result.isNil:
    return nil

  let st = cast[ptr PianoState](result)
  st.sampleRate = PianoDefaultSampleRate
  st.g = newPiano(PianoVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil

  st.abi = pianoAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

  st.tone = pianoDesc.params[0].defaultValue
  st.decay = pianoDesc.params[1].defaultValue
  st.detune = pianoDesc.params[2].defaultValue
  st.hammer = pianoDesc.params[3].defaultValue
  st.release = pianoDesc.params[4].defaultValue
  st.pan = pianoDesc.params[5].defaultValue
  st.levelLin = dbToLin(pianoDesc.params[6].defaultValue)
  st.live = true

proc destroyPianoState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  freePiano(addr (cast[ptr PianoState](state)).g)
  deallocShared(state)

proc resetPianoState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Паника: голоса и педаль снимаются, параметры остаются.
  if state.isNil:
    return
  let st = cast[ptr PianoState](state)
  pianoReset(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.live = true

# ==============================================================================
# Параметры
# ==============================================================================

proc setPianoParam(state: pointer; paramId: uint32; value: float32;
                  normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr PianoState](state)
  let raw = if normalized: pianoDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of PianoParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of PianoParamDecay:   st.decay = clamp(raw, 0.15f, 4.0f)
  of PianoParamDetune:  st.detune = clamp(raw, 0.0f, 30.0f)
  of PianoParamHammer:  st.hammer = clamp(raw, 0.0f, 1.0f)
  of PianoParamRelease: st.release = clamp(raw, 0.02f, 3.0f)
  of PianoParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of PianoParamLevel:   st.levelLin = dbToLin(clamp(raw, PianoLevelMinDb, PianoLevelMaxDb))
  else: return

  st.live = true

proc getPianoParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr PianoState](state)

  case paramId
  of PianoParamTone:    outValue[] = st.tone
  of PianoParamDecay:   outValue[] = st.decay
  of PianoParamDetune:  outValue[] = st.detune
  of PianoParamHammer:  outValue[] = st.hammer
  of PianoParamRelease: outValue[] = st.release
  of PianoParamPan:     outValue[] = st.pan
  of PianoParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false

  true

# ==============================================================================
# Обработка (audio thread)
# ==============================================================================

proc processPianoNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr PianoState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1:
    return

  let outBuf = audio.outputs[0]
  if outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    # Смена частоты снимает демпфер с уже звучащих струн: их время
    # затухания посчитано в сэмплах под старую частоту.
    if pianoInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)
      st.live = true

  if st.live:
    pianoApplyParams(st)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]

  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

# ==============================================================================
# Экспорт
# ==============================================================================

proc getPianoDesc*(): ptr NodeDesc =
  if not pianoReady:
    initPianoDesc()
    pianoReady = true
  addr pianoDesc

proc getPianoFactory*(): ptr NodeFactory =
  if not pianoReady:
    initPianoDesc()
    pianoReady = true
  if pianoFactory.create.isNil:
    pianoFactory = NodeFactory(
      create: createPianoState,
      destroy: destroyPianoState,
      process: processPianoNode,
      setParam: setPianoParam,
      getParam: getPianoParam,
      reset: resetPianoState
    )
  addr pianoFactory

{.pop.}
