# nodes/builtin/instruments/strings.nim
#
# Смычковые (струнный ансамбль) на C-ядре eut_inst.c: пила через корпусный
# ФНЧ, задержанное вибрато, лёгкая микрорасстройка голосов. Один инструмент
# покрывает скрипку/альт/виолончель — тембром управляют `tone` и регистр
# ноты. Нода — источник; render-путь общий — instrument_common.nim.

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
  StringsParamTone*     = 0'u32   # яркость (срез ФНЧ), 0..1
  StringsParamVibrato*  = 1'u32   # глубина вибрато, центы
  StringsParamEnsemble* = 2'u32   # разброс расстройки (ансамбль), центы
  StringsParamPan*      = 3'u32
  StringsParamLevel*    = 4'u32   # dB

  StringsVoices = 8
  StringsDefaultSampleRate = 48000.0f
  StringsLevelMinDb = -80.0f
  StringsLevelMaxDb = 6.0f

type
  StringsState* = object
    g: Strings
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    tone, vibrato, ensemble, pan, levelLin: float32

var
  stringsDesc: NodeDesc
  stringsFactory: NodeFactory
  stringsReady = false

proc initStringsDesc() =
  stringsDesc = NodeDesc(
    id: fixedId("euterpia.strings"),
    name: fixedName("Strings"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 5
  )
  stringsDesc.params[0] = NodeParamDesc(
    id: StringsParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  stringsDesc.params[1] = NodeParamDesc(
    id: StringsParamVibrato, name: fixedParamName("vibrato"),
    minValue: 0.0f, maxValue: 60.0f, defaultValue: 10.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  stringsDesc.params[2] = NodeParamDesc(
    id: StringsParamEnsemble, name: fixedParamName("ensemble"),
    minValue: 0.0f, maxValue: 30.0f, defaultValue: 7.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  stringsDesc.params[3] = NodeParamDesc(
    id: StringsParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  stringsDesc.params[4] = NodeParamDesc(
    id: StringsParamLevel, name: fixedParamName("level"),
    minValue: StringsLevelMinDb, maxValue: StringsLevelMaxDb, defaultValue: -8.0f,
    step: 0.1f, flags: uint32(npfAutomatable))

proc createStringsState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not stringsReady:
    initStringsDesc()
    stringsReady = true
  result = allocShared0(sizeof(StringsState))
  if result.isNil:
    return nil
  let st = cast[ptr StringsState](result)
  st.sampleRate = StringsDefaultSampleRate
  st.g = newStrings(StringsVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = stringsAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tone = 0.5f; st.vibrato = 10.0f; st.ensemble = 7.0f
  st.pan = 0.0f; st.levelLin = dbToLin(-8.0f)

proc destroyStringsState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeStrings(addr (cast[ptr StringsState](state)).g)
  deallocShared(state)

proc resetStringsState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr StringsState](state)
  stringsAllOff(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setStringsParam(state: pointer; paramId: uint32; value: float32;
                     normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr StringsState](state)
  let raw = if normalized: stringsDesc.paramFromNormalized(paramId, value) else: value
  case paramId
  of StringsParamTone:     st.tone = clamp(raw, 0.0f, 1.0f)
  of StringsParamVibrato:  st.vibrato = clamp(raw, 0.0f, 60.0f)
  of StringsParamEnsemble: st.ensemble = clamp(raw, 0.0f, 30.0f)
  of StringsParamPan:      st.pan = clamp(raw, -1.0f, 1.0f)
  of StringsParamLevel:    st.levelLin = dbToLin(clamp(raw, StringsLevelMinDb, StringsLevelMaxDb))
  else: return

proc getStringsParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr StringsState](state)
  case paramId
  of StringsParamTone:     outValue[] = st.tone
  of StringsParamVibrato:  outValue[] = st.vibrato
  of StringsParamEnsemble: outValue[] = st.ensemble
  of StringsParamPan:      outValue[] = st.pan
  of StringsParamLevel:    outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processStringsNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                        ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                        userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr StringsState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if stringsInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  # Параметры применяются раз в блок: движок хранит их, а нода — цели.
  stringsSet(addr st.g, st.tone, st.vibrato, st.ensemble, st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc getStringsDesc*(): ptr NodeDesc =
  if not stringsReady:
    initStringsDesc()
    stringsReady = true
  addr stringsDesc

proc getStringsFactory*(): ptr NodeFactory =
  if not stringsReady:
    initStringsDesc()
    stringsReady = true
  if stringsFactory.create.isNil:
    stringsFactory = NodeFactory(
      create: createStringsState, destroy: destroyStringsState,
      process: processStringsNode, setParam: setStringsParam,
      getParam: getStringsParam, reset: resetStringsState)
  addr stringsFactory

{.pop.}
