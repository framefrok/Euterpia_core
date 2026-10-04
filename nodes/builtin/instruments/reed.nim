# nodes/builtin/instruments/reed.nim
#
# Свободноязычковые на C-ядре eut_inst.c: баян (аккордеон) и губная гармошка —
# ОДИН движок `EutReed` с разными характерами, как арфа и клавесин у щипковых.
#
# Почему один движок на два инструмента: у обоих звук делает не «спектр ноты»,
# а язычок в камере — их роднит и разлив (несколько расстроенных язычков на
# ноту), и шум воздуха (мех или дыхание), и посадка строя после атаки.
# Различаются ровно два числа:
#   * баян — разлив 12 центов (язычки врозь) и низкая камера ~1.4 кГц;
#   * гармошка — язычок на ноту один (разлив 0) и высокая камера ~2.6 кГц.
#
# Нода — источник; render-путь общий — instrument_common.nim.

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
  ReedParamTone*    = 0'u32   # яркость: верх и «гнусавость» 0..1
  ReedParamDetune*  = 1'u32   # разлив между язычками, центы (0 — сухой строй)
  ReedParamNoise*   = 2'u32   # воздух: мех/дыхание 0..1
  ReedParamAttack*  = 3'u32   # время речи язычка, секунды
  ReedParamPan*     = 4'u32
  ReedParamLevel*   = 5'u32   # dB

  ReedVoices = 12
  ReedDefaultSampleRate = 48000.0f
  ReedLevelMinDb = -80.0f
  ReedLevelMaxDb = 6.0f

type
  ReedKind = enum
    rkAccordion, rkHarmonica

  ReedState = object
    g: Reed
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    kind: ReedKind
    formantHz: float32
    tone, detune, noise, attack, pan, levelLin: float32

var
  accordionDesc: NodeDesc
  harmonicaDesc: NodeDesc
  accordionFactory: NodeFactory
  harmonicaFactory: NodeFactory
  reedReady = false

proc kindDefaults(kind: ReedKind):
    tuple[tone, detune, noise, attack, formantHz, levelDb: float32] =
  ## Характер инструмента: всё, чем баян отличается от гармошки.
  case kind
  of rkAccordion:
    (0.50f, 12.0f, 0.28f, 0.050f, 1400.0f, -8.0f)
  of rkHarmonica:
    (0.72f,  0.0f, 0.20f, 0.018f, 2600.0f, -9.0f)

proc descFor(kind: ReedKind): ptr NodeDesc {.inline.} =
  if kind == rkAccordion: addr accordionDesc else: addr harmonicaDesc

proc factoryFor(kind: ReedKind): ptr NodeFactory {.inline.} =
  if kind == rkAccordion: addr accordionFactory else: addr harmonicaFactory

proc initReedDesc(kind: ReedKind) =
  let d = kindDefaults(kind)
  var desc = NodeDesc(
    id: fixedId(if kind == rkAccordion: "euterpia.accordion"
                else: "euterpia.harmonica"),
    name: fixedName(if kind == rkAccordion: "Accordion" else: "Harmonica"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 6
  )
  desc.params[0] = NodeParamDesc(
    id: ReedParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: d.tone, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[1] = NodeParamDesc(
    id: ReedParamDetune, name: fixedParamName("detune"),
    minValue: 0.0f, maxValue: 40.0f, defaultValue: d.detune, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[2] = NodeParamDesc(
    id: ReedParamNoise, name: fixedParamName("noise"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: d.noise, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[3] = NodeParamDesc(
    id: ReedParamAttack, name: fixedParamName("attack"),
    minValue: 0.002f, maxValue: 0.5f, defaultValue: d.attack, step: 0.001f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[4] = NodeParamDesc(
    id: ReedParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[5] = NodeParamDesc(
    id: ReedParamLevel, name: fixedParamName("level"),
    minValue: ReedLevelMinDb, maxValue: ReedLevelMaxDb,
    defaultValue: d.levelDb, step: 0.1f, flags: uint32(npfAutomatable))
  if kind == rkAccordion: accordionDesc = desc else: harmonicaDesc = desc

proc initReedDesc() =
  initReedDesc(rkAccordion)
  initReedDesc(rkHarmonica)

proc createReedState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not reedReady:
    initReedDesc()
    reedReady = true
  # Какой инструмент просят, видно по описателю: у баяна и гармошки он свой.
  let kind = if desc == addr accordionDesc: rkAccordion else: rkHarmonica
  let d = kindDefaults(kind)
  result = allocShared0(sizeof(ReedState))
  if result.isNil:
    return nil
  let st = cast[ptr ReedState](result)
  st.sampleRate = ReedDefaultSampleRate
  st.kind = kind
  st.formantHz = d.formantHz
  st.g = newReed(ReedVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = reedAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tone = d.tone
  st.detune = d.detune
  st.noise = d.noise
  st.attack = d.attack
  st.pan = 0.0f
  st.levelLin = dbToLin(d.levelDb)

proc destroyReedState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freeReed(addr (cast[ptr ReedState](state)).g)
  deallocShared(state)

proc resetReedState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr ReedState](state)
  reedReset(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setReedParam(state: pointer; paramId: uint32; value: float32;
                  normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr ReedState](state)
  let raw = if normalized:
              descFor(st.kind)[].paramFromNormalized(paramId, value)
            else: value
  case paramId
  of ReedParamTone:   st.tone = clamp(raw, 0.0f, 1.0f)
  of ReedParamDetune: st.detune = clamp(raw, 0.0f, 40.0f)
  of ReedParamNoise:  st.noise = clamp(raw, 0.0f, 1.0f)
  of ReedParamAttack: st.attack = clamp(raw, 0.002f, 0.5f)
  of ReedParamPan:    st.pan = clamp(raw, -1.0f, 1.0f)
  of ReedParamLevel:  st.levelLin = dbToLin(clamp(raw, ReedLevelMinDb,
                                                  ReedLevelMaxDb))
  else: return

proc getReedParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr ReedState](state)
  case paramId
  of ReedParamTone:   outValue[] = st.tone
  of ReedParamDetune: outValue[] = st.detune
  of ReedParamNoise:  outValue[] = st.noise
  of ReedParamAttack: outValue[] = st.attack
  of ReedParamPan:    outValue[] = st.pan
  of ReedParamLevel:  outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processReedNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                     ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                     userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr ReedState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if reedInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  reedSet(addr st.g, st.tone, st.detune, st.noise, st.attack, st.formantHz,
          st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc reedNode(kind: ReedKind): tuple[desc: ptr NodeDesc;
                                     factory: ptr NodeFactory] =
  if not reedReady:
    initReedDesc()
    reedReady = true
  let f = factoryFor(kind)
  if f.create.isNil:
    f[] = NodeFactory(
      create: createReedState, destroy: destroyReedState,
      process: processReedNode, setParam: setReedParam,
      getParam: getReedParam, reset: resetReedState)
  (descFor(kind), f)

proc getAccordionDesc*(): ptr NodeDesc = reedNode(rkAccordion).desc
proc getAccordionFactory*(): ptr NodeFactory = reedNode(rkAccordion).factory
proc getHarmonicaDesc*(): ptr NodeDesc = reedNode(rkHarmonica).desc
proc getHarmonicaFactory*(): ptr NodeFactory = reedNode(rkHarmonica).factory

{.pop.}
