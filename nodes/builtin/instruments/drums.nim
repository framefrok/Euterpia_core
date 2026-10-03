# nodes/builtin/instruments/drums.nim
#
# Ударные на C-ядре eut_inst.c: набор из GM-карты нот (бочка, малый,
# хэты, тарелки, томы) — каждая нота выбирает свою «деталь» установки.
#
# Нода не переводит ноты сама: карта нот→деталь живёт в ядре
# (`eut_drums_piece_for_note`), потому что от неё зависит и выбор
# огибающей, и набор шумовых генераторов. Обёртка `drumsPieceForNote`
# нужна только тестам и CLI, чтобы показать, какая нота чем звучит.
#
# Note-off здесь не пустой: закрытый хэт гасит открытый, и движение
# педали ударника воспроизводится именно событием, а не таймером.

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
  DrumsParamTune*   = 0'u32   # множитель строя установки, 0.25..4
  DrumsParamDecay*  = 1'u32   # множитель затухания, 0.1..5
  DrumsParamSnappy* = 2'u32   # уровень подструнника/шумовой части
  DrumsParamTone*   = 3'u32   # яркость, 0..1
  DrumsParamDrive*  = 4'u32   # насыщение, 0..1
  DrumsParamPan*    = 5'u32
  DrumsParamLevel*  = 6'u32   # dB

  ## 16 голосов: быстрая дробь по малому плюс одновременно звучащие
  ## бочка, хэт и тарелка — типичный максимум для одного такта.
  DrumsVoices = 16

  DrumsDefaultSampleRate = 48000.0f
  DrumsLevelMinDb = -80.0f
  DrumsLevelMaxDb = 6.0f

type
  DrumsState* = object
    g: Drums
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
      ## Временный planar-буфер для interleaved-выхода (см. InstScratchFrames).
    sampleRate: float32
    tune, decay, snappy, tone, drive, pan, levelLin: float32
    live: bool

var
  drumsDesc: NodeDesc
  drumsFactory: NodeFactory
  drumsReady = false

# ==============================================================================
# Descriptor (холодная сторона)
# ==============================================================================

proc initDrumsDesc() =
  drumsDesc = NodeDesc(
    id: fixedId("euterpia.drums"),
    name: fixedName("Drums"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0,
    maxChannels: 2,
    paramCount: 7
  )

  drumsDesc.params[0] = NodeParamDesc(
    id: DrumsParamTune, name: fixedParamName("tune"),
    minValue: 0.25f, maxValue: 4.0f, defaultValue: 1.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  drumsDesc.params[1] = NodeParamDesc(
    id: DrumsParamDecay, name: fixedParamName("decay"),
    minValue: 0.1f, maxValue: 5.0f, defaultValue: 1.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  drumsDesc.params[2] = NodeParamDesc(
    id: DrumsParamSnappy, name: fixedParamName("snappy"),
    minValue: 0.0f, maxValue: 2.0f, defaultValue: 1.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  drumsDesc.params[3] = NodeParamDesc(
    id: DrumsParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  drumsDesc.params[4] = NodeParamDesc(
    id: DrumsParamDrive, name: fixedParamName("drive"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.15f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  drumsDesc.params[5] = NodeParamDesc(
    id: DrumsParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  drumsDesc.params[6] = NodeParamDesc(
    id: DrumsParamLevel, name: fixedParamName("level"),
    minValue: DrumsLevelMinDb, maxValue: DrumsLevelMaxDb,
    defaultValue: -6.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc drumsApplyParams(st: ptr DrumsState) =
  drumsSet(addr st.g, st.tune, st.decay, st.snappy, st.tone, st.drive,
           st.pan, st.levelLin)
  st.live = false

proc createDrumsState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not drumsReady:
    initDrumsDesc()
    drumsReady = true

  result = allocShared0(sizeof(DrumsState))
  if result.isNil:
    return nil

  let st = cast[ptr DrumsState](result)
  st.sampleRate = DrumsDefaultSampleRate
  st.g = newDrums(DrumsVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil

  st.abi = drumsAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

  st.tune = drumsDesc.params[0].defaultValue
  st.decay = drumsDesc.params[1].defaultValue
  st.snappy = drumsDesc.params[2].defaultValue
  st.tone = drumsDesc.params[3].defaultValue
  st.drive = drumsDesc.params[4].defaultValue
  st.pan = drumsDesc.params[5].defaultValue
  st.levelLin = dbToLin(drumsDesc.params[6].defaultValue)
  st.live = true

proc destroyDrumsState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  freeDrums(addr (cast[ptr DrumsState](state)).g)
  deallocShared(state)

proc resetDrumsState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Паника: все детали установки глушатся, параметры остаются.
  if state.isNil:
    return
  let st = cast[ptr DrumsState](state)
  drumsReset(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.live = true


# ==============================================================================
# Параметры
# ==============================================================================

proc setDrumsParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr DrumsState](state)
  let raw = if normalized: drumsDesc.paramFromNormalized(paramId, value) else: value

  case paramId
  of DrumsParamTune:   st.tune = clamp(raw, 0.25f, 4.0f)
  of DrumsParamDecay:  st.decay = clamp(raw, 0.1f, 5.0f)
  of DrumsParamSnappy: st.snappy = clamp(raw, 0.0f, 2.0f)
  of DrumsParamTone:   st.tone = clamp(raw, 0.0f, 1.0f)
  of DrumsParamDrive:  st.drive = clamp(raw, 0.0f, 1.0f)
  of DrumsParamPan:    st.pan = clamp(raw, -1.0f, 1.0f)
  of DrumsParamLevel:  st.levelLin = dbToLin(clamp(raw, DrumsLevelMinDb, DrumsLevelMaxDb))
  else: return

  st.live = true

proc getDrumsParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr DrumsState](state)

  case paramId
  of DrumsParamTune:   outValue[] = st.tune
  of DrumsParamDecay:  outValue[] = st.decay
  of DrumsParamSnappy: outValue[] = st.snappy
  of DrumsParamTone:   outValue[] = st.tone
  of DrumsParamDrive:  outValue[] = st.drive
  of DrumsParamPan:    outValue[] = st.pan
  of DrumsParamLevel:  outValue[] = linToDb(st.levelLin)
  else: return false

  true

# ==============================================================================
# Обработка (audio thread)
# ==============================================================================

proc processDrumsNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr DrumsState](userData)
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
    # Огибающие деталей посчитаны в сэмплах под старую частоту, поэтому
    # смена частоты пересчитывает их; звучащие голоса при этом глушатся.
    if drumsInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)
      st.live = true

  if st.live:
    drumsApplyParams(st)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]

  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

# ==============================================================================
# Экспорт
# ==============================================================================

proc getDrumsDesc*(): ptr NodeDesc =
  if not drumsReady:
    initDrumsDesc()
    drumsReady = true
  addr drumsDesc

proc getDrumsFactory*(): ptr NodeFactory =
  if not drumsReady:
    initDrumsDesc()
    drumsReady = true
  if drumsFactory.create.isNil:
    drumsFactory = NodeFactory(
      create: createDrumsState,
      destroy: destroyDrumsState,
      process: processDrumsNode,
      setParam: setDrumsParam,
      getParam: getDrumsParam,
      reset: resetDrumsState
    )
  addr drumsFactory

{.pop.}
