# nodes/builtin/instruments/plucked.nim
#
# Щипковые на C-ядре eut_inst.c (Карплус-Стронг): арфа и клавесин — ОДИН
# движок `EutPluck` с разными характерами. Это не «два похожих файла»: у
# инструментов общий контракт голосов и общий путь событий/рендера, различаются
# только умолчания и корпус — поэтому здесь одна реализация и четыре точки
# входа (`getHarpDesc`/`getHarpFactory`/`getHarpsichordDesc`/...).
#
# Разница характеров:
#   * арфа — длинный тёплый звон, мягкий щипок, низкий корпус;
#   * клавесин — короткий яркий «перьевой» щипок, высокий корпус-дека.
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
  PluckParamTone*    = 0'u32   # яркость струны 0..1
  PluckParamDamping* = 1'u32   # длина звона (0 — короткий щипок, 1 — длинный)
  PluckParamPluck*   = 2'u32   # резкость щипка 0..1
  PluckParamBody*    = 3'u32   # глубина резонатора корпуса 0..1
  PluckParamPan*     = 4'u32
  PluckParamLevel*   = 5'u32   # dB

  PluckVoices = 12
  PluckDefaultSampleRate = 48000.0f
  PluckLevelMinDb = -80.0f
  PluckLevelMaxDb = 6.0f

type
  PluckKind = enum
    pkHarp, pkHarpsichord

  PluckState = object
    g: Pluck
    abi: InstAbi
    midi: InstMidi
    scratch: array[2 * InstScratchFrames, float32]
    sampleRate: float32
    kind: PluckKind
    bodyHz: float32
    tone, damping, pluck, body, pan, levelLin: float32

var
  harpDesc: NodeDesc
  harpFactory: NodeFactory
  harpsiDesc: NodeDesc
  harpsiFactory: NodeFactory
  pluckReady = false

proc kindDefaults(kind: PluckKind):
    tuple[tone, damping, pluck, body, bodyHz, levelDb: float32] =
  ## Характер инструмента: всё, чем арфа отличается от клавесина.
  case kind
  of pkHarp:
    (0.55f, 0.78f, 0.35f, 0.45f, 180.0f, -8.0f)
  of pkHarpsichord:
    (0.85f, 0.42f, 0.78f, 0.28f, 420.0f, -9.0f)

proc descFor(kind: PluckKind): ptr NodeDesc {.inline.} =
  if kind == pkHarp: addr harpDesc else: addr harpsiDesc

proc factoryFor(kind: PluckKind): ptr NodeFactory {.inline.} =
  if kind == pkHarp: addr harpFactory else: addr harpsiFactory

proc initDesc(kind: PluckKind) =
  let d = kindDefaults(kind)
  var desc = NodeDesc(
    id: fixedId(if kind == pkHarp: "euterpia.harp" else: "euterpia.harpsichord"),
    name: fixedName(if kind == pkHarp: "Harp" else: "Harpsichord"),
    category: fixedName("instrument"),
    audioInCount: 0, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 1, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2, paramCount: 6
  )
  desc.params[0] = NodeParamDesc(
    id: PluckParamTone, name: fixedParamName("tone"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: d.tone, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[1] = NodeParamDesc(
    id: PluckParamDamping, name: fixedParamName("damping"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: d.damping, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[2] = NodeParamDesc(
    id: PluckParamPluck, name: fixedParamName("pluck"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: d.pluck, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[3] = NodeParamDesc(
    id: PluckParamBody, name: fixedParamName("body"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: d.body, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[4] = NodeParamDesc(
    id: PluckParamPan, name: fixedParamName("pan"),
    minValue: -1.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable))
  desc.params[5] = NodeParamDesc(
    id: PluckParamLevel, name: fixedParamName("level"),
    minValue: PluckLevelMinDb, maxValue: PluckLevelMaxDb,
    defaultValue: d.levelDb, step: 0.1f, flags: uint32(npfAutomatable))

  if kind == pkHarp:
    harpDesc = desc
  else:
    harpsiDesc = desc

proc initPluckDesc() =
  initDesc(pkHarp)
  initDesc(pkHarpsichord)

proc createPluckState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not pluckReady:
    initPluckDesc()
    pluckReady = true
  # Какой инструмент просят, видно по описателю: у арфы и клавесина он свой.
  let kind = if desc == addr harpDesc: pkHarp else: pkHarpsichord
  let d = kindDefaults(kind)
  result = allocShared0(sizeof(PluckState))
  if result.isNil:
    return nil
  let st = cast[ptr PluckState](result)
  st.sampleRate = PluckDefaultSampleRate
  st.kind = kind
  st.bodyHz = d.bodyHz
  st.g = newPluck(PluckVoices, st.sampleRate)
  if not st.g.isReady:
    deallocShared(result)
    return nil
  st.abi = pluckAbi(addr st.g)
  st.midi = initInstMidi(st.sampleRate)
  st.tone = d.tone
  st.damping = d.damping
  st.pluck = d.pluck
  st.body = d.body
  st.pan = 0.0f
  st.levelLin = dbToLin(d.levelDb)

proc destroyPluckState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  freePluck(addr (cast[ptr PluckState](state)).g)
  deallocShared(state)

proc resetPluckState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr PluckState](state)
  pluckAllOff(addr st.g)
  st.midi = initInstMidi(st.sampleRate)

proc setPluckParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil: return
  let st = cast[ptr PluckState](state)
  let raw = if normalized:
              descFor(st.kind)[].paramFromNormalized(paramId, value)
            else: value
  case paramId
  of PluckParamTone:    st.tone = clamp(raw, 0.0f, 1.0f)
  of PluckParamDamping: st.damping = clamp(raw, 0.0f, 1.0f)
  of PluckParamPluck:   st.pluck = clamp(raw, 0.0f, 1.0f)
  of PluckParamBody:    st.body = clamp(raw, 0.0f, 1.0f)
  of PluckParamPan:     st.pan = clamp(raw, -1.0f, 1.0f)
  of PluckParamLevel:   st.levelLin = dbToLin(clamp(raw, PluckLevelMinDb,
                                                    PluckLevelMaxDb))
  else: return

proc getPluckParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil: return false
  let st = cast[ptr PluckState](state)
  case paramId
  of PluckParamTone:    outValue[] = st.tone
  of PluckParamDamping: outValue[] = st.damping
  of PluckParamPluck:   outValue[] = st.pluck
  of PluckParamBody:    outValue[] = st.body
  of PluckParamPan:     outValue[] = st.pan
  of PluckParamLevel:   outValue[] = linToDb(st.levelLin)
  else: return false
  true

proc processPluckNode(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                      ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                      userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = cast[ptr PluckState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1: return
  let outBuf = audio.outputs[0]
  if outBuf.isNil: return
  let frames = processFrames(ctx, outBuf)
  if frames <= 0: return

  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: st.sampleRate
  if abs(sr - st.sampleRate) > 0.01f:
    if pluckInitAt(addr st.g, sr):
      st.sampleRate = sr
      instSetSampleRate(st.midi, sr)

  pluckSet(addr st.g, st.tone, st.damping, st.pluck, st.body, st.bodyHz,
           st.pan, st.levelLin)

  var q: ptr EventQueue = nil
  if not events.isNil and events.inputCount > 0:
    q = events.inputs[0]
  instRender(st.abi, st.midi, outBuf, frames, q, addr st.scratch[0])

proc pluckNode(kind: PluckKind): tuple[desc: ptr NodeDesc;
                                       factory: ptr NodeFactory] =
  if not pluckReady:
    initPluckDesc()
    pluckReady = true
  let f = factoryFor(kind)
  if f.create.isNil:
    f[] = NodeFactory(
      create: createPluckState, destroy: destroyPluckState,
      process: processPluckNode, setParam: setPluckParam,
      getParam: getPluckParam, reset: resetPluckState)
  (descFor(kind), f)

proc getHarpDesc*(): ptr NodeDesc = pluckNode(pkHarp).desc
proc getHarpFactory*(): ptr NodeFactory = pluckNode(pkHarp).factory
proc getHarpsichordDesc*(): ptr NodeDesc = pluckNode(pkHarpsichord).desc
proc getHarpsichordFactory*(): ptr NodeFactory = pluckNode(pkHarpsichord).factory

{.pop.}

