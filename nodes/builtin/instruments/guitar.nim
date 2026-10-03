# nodes/builtin/instruments/guitar.nim
#
# Гитара на C-ядре eut_inst.c (Карплус-Стронг, струна на голос).
#
# Особенность этого инструмента — отдельная память под струны: ядро
# держит по линии задержки на голос, и её длина определяется самой
# низкой нотой (`GuitarLowestHz`). Обёртка `newGuitar` выделяет эту
# память под частоту `max(sampleRate, GuitarMaxSampleRate)`, чтобы
# смена частоты дискретизации в проекте не потребовала аллокации
# в audio thread — `guitarInitAt` только переиспользует линии.
#
# Note-off у гитары гаснет быстро (демпфер струны), пальмовый глушёный
# приём — это параметр `mute`, а не отдельное событие.

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
  GuitarParamPick*    = 0'u32   # позиция щипка по струне, 0.02..0.95
  GuitarParamDamping* = 1'u32   # поглощение в линии, 0..1
  GuitarParamTone*    = 2'u32   # яркость после фильтра, 0..1
  GuitarParamDrive*   = 3'u32   # насыщение струны, 0..1
  GuitarParamMute*    = 4'u32   # palm mute, 0..1
  GuitarParamRelease* = 5'u32   # время гашения после note-off, с
  GuitarParamPan*     = 6'u32
  GuitarParamLevel*   = 7'u32   # dB

  ## 8 голосов: шесть струн плюс две на «наложение» аппликатуры,
  ## при котором следующая нота берётся до затухания предыдущей.
  GuitarVoices = 8

  GuitarDefaultSampleRate = 48000.0f
  GuitarLevelMinDb = -80.0f
  GuitarLevelMaxDb = 6.0f

type
  GuitarState* = object
    g: Guitar
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
      ## Временный planar-буфер для interleaved-выхода (см. InstScratchFrames).
    sampleRate: float32
    pick, damping, tone, drive, mute, release, pan, levelLin: float32
    live: bool

var
  guitarDesc: NodeDesc
  guitarFactory: NodeFactory
  guitarReady = false

# ==============================================================================
# Descriptor (холодная сторона)
# ==============================================================================

proc initGuitarDesc() =
  guitarDesc = NodeDesc(
    id: fixedId("euterpia.guitar"),
    name: fixedName("Guitar"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0,
    maxChannels: 2,
    paramCount: 8
  )

  guitarDesc.params[0] = NodeParamDesc(
    id: GuitarParamPick, name: fixedParamName("pick"),
    minValue: 0.02f, maxValue: 0.95f, defaultValue: 0.5f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  guitarDesc.params[1] = NodeParamDesc(
    id: GuitarParamDamping, name: fixedParamName("damping"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.35f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  guitarDesc.params[2] = NodeParamDesc(
    id: GuitarParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.6f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  guitarDesc.params[3] = NodeParamDesc(
    id: GuitarParamDrive, name: fixedParamName("drive"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.2f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  guitarDesc.params[4] = NodeParamDesc(
    id: GuitarParamMute, name: fixedParamName("mute"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  guitarDesc.params[5] = NodeParamDesc(
    id: GuitarParamRelease, name: fixedParamName("release"),
    minValue: 0.01f, maxValue: 2.0f, defaultValue: 0.4f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  guitarDesc.params[6] = NodeParamDesc(
    id: GuitarParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  guitarDesc.params[7] = NodeParamDesc(
    id: GuitarParamLevel, name: fixedParamName("level"),
    minValue: GuitarLevelMinDb, maxValue: GuitarLevelMaxDb,
    defaultValue: -6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc guitarApplyParams(st: ptr GuitarState) =
  guitarSet(addr st.g, st.pick, st.damping, st.tone, st.drive, st.mute,
            st.release, st.pan, st.levelLin)
  st.live = false

proc createGuitarState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not guitarReady:
    initGuitarDesc()
    guitarReady = true

  result = allocShared0(sizeof(GuitarState))
  if result.isNil:
    return nil

  let st = cast[ptr GuitarState](result)
  st.sampleRate = GuitarDefaultSampleRate
  st.g = newGuitar(GuitarVoices, st.sampleRate)
  if not st.g.isReady:
    # Здесь nil означает ещё и «не хватило памяти под струны»: линии
    # задержек — самая крупная аллокация из четырёх инструментов.
    deallocShared(result)
    return nil

  st.abi = guitarAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

  st.pick = guitarDesc.params[0].defaultValue
  st.damping = guitarDesc.params[1].defaultValue
  st.tone = guitarDesc.params[2].defaultValue
  st.drive = guitarDesc.params[3].defaultValue
  st.mute = guitarDesc.params[4].defaultValue
  st.release = guitarDesc.params[5].defaultValue
  st.pan = guitarDesc.params[6].defaultValue
  st.levelLin = dbToLin(guitarDesc.params[7].defaultValue)
  st.live = true

proc destroyGuitarState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  freeGuitar(addr (cast[ptr GuitarState](state)).g)
  deallocShared(state)

proc resetGuitarState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Паника: струны глушатся вместе с памятью линий, параметры остаются.
  if state.isNil:
    return
  let st = cast[ptr GuitarState](state)
  guitarReset(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.live = true


# ==============================================================================
# Параметры
# ==============================================================================

proc setGuitarParam(state: pointer; paramId: uint32; value: float32;
                    normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr GuitarState](state)
  let raw = if normalized: guitarDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of GuitarParamPick:    st.pick = clamp(raw, 0.02f, 0.95f)
  of GuitarParamDamping: st.damping = clamp(raw, 0.0f, 1.0f)
  of GuitarParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of GuitarParamDrive:   st.drive = clamp(raw, 0.0f, 1.0f)
  of GuitarParamMute:    st.mute = clamp(raw, 0.0f, 1.0f)
  of GuitarParamRelease: st.release = clamp(raw, 0.01f, 2.0f)
  of GuitarParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of GuitarParamLevel:   st.levelLin = dbToLin(clamp(raw, GuitarLevelMinDb, GuitarLevelMaxDb))
  else: return

  st.live = true

proc getGuitarParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr GuitarState](state)

  case paramId
  of GuitarParamPick:    outValue[] = st.pick
  of GuitarParamDamping: outValue[] = st.damping
  of GuitarParamTone:    outValue[] = st.tone
  of GuitarParamDrive:   outValue[] = st.drive
  of GuitarParamMute:    outValue[] = st.mute
  of GuitarParamRelease: outValue[] = st.release
  of GuitarParamPan:     outValue[] = st.pan
  of GuitarParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false

  true

# ==============================================================================
# Обработка (audio thread)
# ==============================================================================

proc processGuitarNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr GuitarState](userData)
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
    # Линии задержек выделены под максимум из поддерживаемых частот,
    # поэтому здесь меняется только длина активной части линии.
    if guitarInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)
      st.live = true

  if st.live:
    guitarApplyParams(st)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]

  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

# ==============================================================================
# Экспорт
# ==============================================================================

proc getGuitarDesc*(): ptr NodeDesc =
  if not guitarReady:
    initGuitarDesc()
    guitarReady = true
  addr guitarDesc

proc getGuitarFactory*(): ptr NodeFactory =
  if not guitarReady:
    initGuitarDesc()
    guitarReady = true
  if guitarFactory.create.isNil:
    guitarFactory = NodeFactory(
      create: createGuitarState,
      destroy: destroyGuitarState,
      process: processGuitarNode,
      setParam: setGuitarParam,
      getParam: getGuitarParam,
      reset: resetGuitarState
    )
  addr guitarFactory

{.pop.}
