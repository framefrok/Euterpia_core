# adapters/eut/eut_plugin_backend.nim
#
# EUT-адаптер за контрактом `core/plugin_api.nim` (issue #29).
#
#   Core -> plugin_api -> adapters/eut -> eut_plugin.nim (EUT ABI v1)
#
# EUT — собственный ABI EUTERPIA. В отличие от CLAP он отдаёт дескрипторы
# портов и параметров напрямую, поэтому контракт заполняется целиком,
# включая параметры (они передаются плагину через `EutProcessContext`).
#
# Состояние инстанса — POD, размещается в shared-куче; в audio-поток
# попадает только указатель, которым владеет адаптер.
#
# MANIFEST §8, §40, §41, §42, §56/§57.

import plugin_api
import signal_types
import node_interface
import eut_plugin

{.push raises: [].}

const
  EutBackendName* = "eut"
  EutMaxParams = 64

type
  EutSlot = object
    ## Состояние одного инстанса. POD; размещается в shared-куче.
    module: EutPluginModule
    instance: pointer
    active: bool
    sampleRate: float64
    maxBlock: int32
    audioIn: int32
    audioOut: int32
    paramCount: int32
    paramValues: array[EutMaxParams, cdouble]

  EutBackendImpl = object
    initCalls: int32

proc implOf(api: ptr PluginApi): ptr EutBackendImpl {.inline.} =
  if api.isNil: nil else: cast[ptr EutBackendImpl](api.impl)

proc slotOf(handle: PluginHandle): ptr EutSlot {.inline.} =
  cast[ptr EutSlot](handle)

proc safeLoad(path: string): EutPluginModule =
  ## `loadEutPlugin` бросает исключения; контракт их не пропускает.
  try:
    result = loadEutPlugin(path)
  except CatchableError:
    result = EutPluginModule()

proc statusToPlugin(status: uint32): PluginProcessStatus {.inline.} =
  if (status and EUT_PROCESS_ERROR) != 0'u32:
    ppsError
  elif (status and EUT_PROCESS_TAIL_CHANGED) != 0'u32:
    ppsTail
  else:
    ppsContinue

proc flagsToPlugin(flags: uint32): set[PluginParamFlag] {.inline.} =
  if (flags and EUT_PARAM_F_AUTOMATABLE) != 0'u32: result.incl ppfAutomatable
  if (flags and EUT_PARAM_F_MODULATABLE) != 0'u32: result.incl ppfModulatable
  if (flags and EUT_PARAM_F_INTEGER) != 0'u32: result.incl ppfInteger
  if (flags and EUT_PARAM_F_HIDDEN) != 0'u32: result.incl ppfHidden

# ----------------------------------------------------------------------------
# Конвертация событий EventQueue <-> EUT
# ----------------------------------------------------------------------------

proc pushEventToEut(q: ptr EutEventQueue; ev: RealtimeEvent) {.inline.} =
  if q.isNil or q.count >= q.capacity:
    return
  var e = EutEvent(eventType: EUT_EVENT_NONE, timeFrames: ev.frameOffset)
  case ev.kind
  of evNoteOn:
    e.eventType = EUT_EVENT_NOTE_ON
    e.payload.note = EutNotePayload(
      channel: ev.channel.uint16, key: int16(ev.data[0]),
      noteId: 0'u32, velocity: ev.data[1].float64, pressure: 0.0)
  of evNoteOff:
    e.eventType = EUT_EVENT_NOTE_OFF
    e.payload.note = EutNotePayload(
      channel: ev.channel.uint16, key: int16(ev.data[0]),
      noteId: 0'u32, velocity: ev.data[1].float64, pressure: 0.0)
  of evParamChange:
    e.eventType = EUT_EVENT_PARAM_SET
    e.payload.param = EutParamPayload(
      paramId: ev.data[0].uint32, flags: 0'u32, value: ev.data[1].float64)
  of evCC:
    e.eventType = EUT_EVENT_CONTROL
    e.payload.control = EutControlPayload(
      channel: ev.channel.uint16, controlId: uint16(ev.data[0]),
      value: ev.data[1].float64)
  else:
    return
  discard push(q, e)

proc eutEventToRt(e: EutEvent): RealtimeEvent {.inline.} =
  result.frameOffset = e.timeFrames
  case e.eventType
  of EUT_EVENT_NOTE_ON:
    result.kind = evNoteOn
    result.channel = e.payload.note.channel.uint8
    result.data[0] = e.payload.note.key.float32
    result.data[1] = e.payload.note.velocity.float32
  of EUT_EVENT_NOTE_OFF:
    result.kind = evNoteOff
    result.channel = e.payload.note.channel.uint8
    result.data[0] = e.payload.note.key.float32
    result.data[1] = e.payload.note.velocity.float32
  of EUT_EVENT_PARAM_SET:
    result.kind = evParamChange
    result.data[0] = e.payload.param.paramId.float32
    result.data[1] = e.payload.param.value.float32
  of EUT_EVENT_CONTROL:
    result.kind = evCC
    result.channel = e.payload.control.channel.uint8
    result.data[0] = e.payload.control.controlId.float32
    result.data[1] = e.payload.control.value.float32
  else:
    result.kind = evTrigger

# ----------------------------------------------------------------------------
# Таблица методов PluginApi — жизнь плагина
# ----------------------------------------------------------------------------

proc eutInit(api: ptr PluginApi; log: ptr Logger): PluginError
    {.cdecl, raises: [], gcsafe.} =
  let impl = implOf(api)
  if impl.isNil:
    return peUnavailable
  impl.initCalls = 0
  peOk

proc eutShutdown(api: ptr PluginApi) {.cdecl, raises: [], gcsafe.} =
  discard

proc eutPluginCount(api: ptr PluginApi; path: cstring): int32
    {.cdecl, raises: [], gcsafe.} =
  ## EUT: один плагин на библиотеку (дескриптор — единичный).
  if implOf(api).isNil or path.isNil:
    return -1
  var m = safeLoad($path)
  if m.isValid():
    m.unload()
    1
  else:
    0

proc fillInfoFromDescriptor(desc: ptr EutPluginDescriptor; info: var PluginInfo) =
  info.id = toString(desc.id)
  info.name = toString(desc.name)
  info.vendor = toString(desc.vendor)
  info.version = toString(desc.version)
  info.category =
    if (desc.features and EUT_FEAT_SYNTH) != 0'u32: pcInstrument
    elif (desc.features and EUT_FEAT_EFFECT) != 0'u32: pcEffect
    elif (desc.features and EUT_FEAT_CONTROL) != 0'u32: pcAnalyzer
    else: pcUnknown
  info.paramCount = int32(desc.paramCount)
  info.hasState = false
  info.hasGui = false
  info.reportedLatency = 0
  for i in 0 ..< int(desc.portCount):
    let p = addr desc.ports[i]
    if p.mediaType == EUT_MEDIA_AUDIO_F32:
      if p.direction == EUT_PORT_INPUT: inc info.audioInCount
      else: inc info.audioOutCount
    elif p.mediaType == EUT_MEDIA_EVENT:
      if p.direction == EUT_PORT_INPUT: inc info.noteInCount
      else: inc info.noteOutCount

proc eutPluginInfo(
  api: ptr PluginApi;
  path: cstring;
  index: int32;
  info: var PluginInfo
): bool {.cdecl, raises: [], gcsafe.} =
  if implOf(api).isNil or path.isNil or index != 0:
    return false
  var m = safeLoad($path)
  if not m.isValid():
    return false
  defer: m.unload()
  fillInfoFromDescriptor(m.descriptor, info)
  true

proc eutInstantiate(
  api: ptr PluginApi;
  path: cstring;
  index: int32
): PluginHandle {.cdecl, raises: [], gcsafe.} =
  if implOf(api).isNil or path.isNil or index != 0:
    return nil
  var m = safeLoad($path)
  if not m.isValid():
    return nil

  let instance = m.createInstance()
  if instance.isNil:
    m.unload()
    return nil

  let slot = cast[ptr EutSlot](allocShared0(sizeof(EutSlot)))
  if slot.isNil:
    m.destroyInstance(instance)
    m.unload()
    return nil

  slot.module = m
  slot.instance = instance
  slot.paramCount = int32(min(int(m.descriptor.paramCount), EutMaxParams))
  for i in 0 ..< int(slot.paramCount):
    slot.paramValues[i] = m.descriptor.params[i].defaultValue
  result = cast[PluginHandle](slot)

proc eutDestroy(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return
  if slot.active:
    slot.module.deactivate(slot.instance)
    slot.active = false
  slot.module.destroyInstance(slot.instance)
  slot.module.unload()
  deallocShared(slot)

proc eutActivate(
  api: ptr PluginApi;
  handle: PluginHandle;
  sampleRate: float64;
  maxBlock: int32;
  audioIn: int32;
  audioOut: int32
): PluginError {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or slot.instance.isNil:
    return peNoSuchPlugin
  if sampleRate <= 0.0 or maxBlock <= 0:
    return peInstantiateFailed
  let st = slot.module.activate(slot.instance, sampleRate, uint32(maxBlock))
  if (st and EUT_PROCESS_ERROR) != 0'u32:
    return peInstantiateFailed
  slot.active = true
  slot.sampleRate = sampleRate
  slot.maxBlock = maxBlock
  slot.audioIn = audioIn
  slot.audioOut = audioOut
  peOk

proc eutDeactivate(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or not slot.active:
    return
  slot.module.deactivate(slot.instance)
  slot.active = false

proc eutReset(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return
  slot.module.reset(slot.instance)
  for i in 0 ..< int(slot.paramCount):
    slot.paramValues[i] = slot.module.descriptor.params[i].defaultValue

proc eutProcess(
  api: ptr PluginApi;
  handle: PluginHandle;
  ctx: ptr NodeProcessContext;
  audio: ptr NodeAudioPorts;
  inEvents: ptr EventQueue;
  outEvents: ptr EventQueue
): PluginProcessStatus {.cdecl, raises: [], gcsafe.} =
  ## Realtime: только стек и предвыделенные буферы, без аллокаций.
  let slot = slotOf(handle)
  if slot.isNil or ctx.isNil or not slot.active or slot.instance.isNil:
    return ppsError

  var audioIns: array[MaxAudioPorts, EutAudioBuffer]
  var audioOuts: array[MaxAudioPorts, EutAudioBuffer]
  var inChans: array[MaxAudioPorts, array[2, ptr cfloat]]
  var outChans: array[MaxAudioPorts, array[2, ptr cfloat]]
  var inCount = 0
  var outCount = 0

  if not audio.isNil:
    inCount = min(int(audio.inputCount), MaxAudioPorts)
    outCount = min(int(audio.outputCount), MaxAudioPorts)
    for i in 0 ..< inCount:
      let b = audio.inputs[i]
      if not b.isNil and not b.data.isNil:
        inChans[i][0] = cast[ptr cfloat](b.data)
      audioIns[i] = EutAudioBuffer(
        structSize: csize_t(sizeof(EutAudioBuffer)),
        portIndex: uint32(i), channelCount: 1,
        data: cast[ptr UncheckedArray[ptr cfloat]](addr inChans[i][0]))
    for i in 0 ..< outCount:
      let b = audio.outputs[i]
      if not b.isNil and not b.data.isNil:
        outChans[i][0] = cast[ptr cfloat](b.data)
      audioOuts[i] = EutAudioBuffer(
        structSize: csize_t(sizeof(EutAudioBuffer)),
        portIndex: uint32(i), channelCount: 1,
        data: cast[ptr UncheckedArray[ptr cfloat]](addr outChans[i][0]))

  var inBuf: array[MaxBlockEvents, EutEvent]
  var outBuf: array[MaxBlockEvents, EutEvent]
  var inQ = EutEventQueue(
    structSize: csize_t(sizeof(EutEventQueue)),
    capacity: uint32(MaxBlockEvents), count: 0'u32,
    events: cast[ptr UncheckedArray[EutEvent]](addr inBuf[0]))
  var outQ = EutEventQueue(
    structSize: csize_t(sizeof(EutEventQueue)),
    capacity: uint32(MaxBlockEvents), count: 0'u32,
    events: cast[ptr UncheckedArray[EutEvent]](addr outBuf[0]))

  if not inEvents.isNil:
    for i in 0 ..< inEvents.count:
      pushEventToEut(addr inQ, inEvents.events[i])

  const EvPorts = 1
  var evtIns: array[EvPorts, EutEventPortBuffers]
  var evtOuts: array[EvPorts, EutEventPortBuffers]
  evtIns[0] = EutEventPortBuffers(
    structSize: csize_t(sizeof(EutEventPortBuffers)),
    portIndex: 0'u32, queue: addr inQ)
  evtOuts[0] = EutEventPortBuffers(
    structSize: csize_t(sizeof(EutEventPortBuffers)),
    portIndex: 0'u32, queue: addr outQ)

  var ectx = EutProcessContext(
    structSize: csize_t(sizeof(EutProcessContext)),
    frames: uint32(ctx.blockSize),
    audioInputCount: uint32(inCount),
    audioOutputCount: uint32(outCount),
    eventInputCount: (if inEvents.isNil: 0'u32 else: 1'u32),
    eventOutputCount: (if outEvents.isNil: 0'u32 else: 1'u32),
    paramCount: uint32(slot.paramCount),
    sampleRate: slot.sampleRate,
    audioInputs: cast[ptr UncheckedArray[EutAudioBuffer]](addr audioIns[0]),
    audioOutputs: cast[ptr UncheckedArray[EutAudioBuffer]](addr audioOuts[0]),
    eventInputs: cast[ptr UncheckedArray[EutEventPortBuffers]](addr evtIns[0]),
    eventOutputs: cast[ptr UncheckedArray[EutEventPortBuffers]](addr evtOuts[0]),
    paramValues: cast[ptr UncheckedArray[cdouble]](addr slot.paramValues[0]))

  let status = eut_plugin.process(slot.module, slot.instance, addr ectx)

  if not outEvents.isNil:
    clearEvents(outEvents)
    for i in 0 ..< int(outQ.count):
      discard pushEvent(outEvents, eutEventToRt(outBuf[i]))

  statusToPlugin(status)

# ----------------------------------------------------------------------------
# Параметры (значения передаются плагину через EutProcessContext)
# ----------------------------------------------------------------------------

proc paramIndexOf(desc: ptr EutPluginDescriptor; paramId: uint32): int =
  for i in 0 ..< int(desc.paramCount):
    if desc.params[i].id == paramId:
      return i
  -1

proc eutParamCount(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil: 0 else: slot.paramCount

proc eutParamInfo(api: ptr PluginApi; handle: PluginHandle; index: int32;
  info: var PluginParamInfo): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or index < 0 or index >= slot.paramCount:
    return false
  let p = addr slot.module.descriptor.params[index]
  info.id = p.id
  info.name = toString(p.name)
  info.flags = flagsToPlugin(p.flags)
  info.minValue = p.minValue
  info.maxValue = p.maxValue
  info.defaultValue = p.defaultValue
  info.step = (if ppfInteger in info.flags: 1.0 else: 0.0)
  true

proc eutParamGet(api: ptr PluginApi; handle: PluginHandle;
  paramId: uint32): float64 {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return 0.0
  let idx = paramIndexOf(slot.module.descriptor, paramId)
  if idx < 0:
    return 0.0
  slot.paramValues[idx]

proc eutParamSet(api: ptr PluginApi; handle: PluginHandle; paramId: uint32;
  value: float64; normalized: bool): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return false
  let idx = paramIndexOf(slot.module.descriptor, paramId)
  if idx < 0:
    return false
  var v = value
  if normalized:
    let p = addr slot.module.descriptor.params[idx]
    let n = clamp(value, 0.0, 1.0)
    v = p.minValue + n * (p.maxValue - p.minValue)
  slot.paramValues[idx] = v
  true

proc eutParamFlush(api: ptr PluginApi; handle: PluginHandle;
  inEvents, outEvents: ptr EventQueue): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return false
  if not outEvents.isNil:
    clearEvents(outEvents)
  if inEvents.isNil:
    return false
  for i in 0 ..< inEvents.count:
    let ev = inEvents.events[i]
    if ev.kind != evParamChange:
      continue
    let paramId = uint32(max(0.0f, ev.data[0]))
    let idx = paramIndexOf(slot.module.descriptor, paramId)
    if idx < 0:
      continue
    slot.paramValues[idx] = ev.data[1].float64
    if not outEvents.isNil and outEvents.count < MaxBlockEvents:
      outEvents.events[outEvents.count] = RealtimeEvent(
        frameOffset: ev.frameOffset, kind: evParamChange,
        port: ev.port, channel: ev.channel,
        data: [ev.data[0], ev.data[1], 0.0f, 0.0f])
      inc outEvents.count
  true

# ----------------------------------------------------------------------------
# Состояние / latency / main-thread
#
# EUT ABI v1 не описывает сериализацию состояния плагина: пока это
# возвращает «пусто». Когда появится `EUT_ext_state`, метод будет заполнен
# в адаптере, не трогая Core.
# ----------------------------------------------------------------------------

proc eutStateSave(api: ptr PluginApi; handle: PluginHandle;
  dst: pointer; maxLen: int): int {.cdecl, raises: [], gcsafe.} =
  -1

proc eutStateLoad(api: ptr PluginApi; handle: PluginHandle;
  src: pointer; len: int): bool {.cdecl, raises: [], gcsafe.} =
  false

proc eutLatencyFrames(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil: 0 else: slot.module.latency(slot.instance)

proc eutOnMainThread(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  discard

# ----------------------------------------------------------------------------
# Фабрика адаптера
# ----------------------------------------------------------------------------

proc newEutPluginApi*(): ptr PluginApi =
  let impl = createShared(EutBackendImpl)
  if impl.isNil:
    return nil
  result = createShared(PluginApi)
  if result.isNil:
    deallocShared(impl)
    return nil
  result.backendName = EutBackendName
  result.impl = cast[pointer](impl)
  result.init = eutInit
  result.shutdown = eutShutdown
  result.pluginCount = eutPluginCount
  result.pluginInfo = eutPluginInfo
  result.instantiate = eutInstantiate
  result.destroy = eutDestroy
  result.activate = eutActivate
  result.deactivate = eutDeactivate
  result.reset = eutReset
  result.process = eutProcess
  result.countParams = eutParamCount
  result.paramInfo = eutParamInfo
  result.paramGet = eutParamGet
  result.paramSet = eutParamSet
  result.paramFlush = eutParamFlush
  result.stateSave = eutStateSave
  result.stateLoad = eutStateLoad
  result.latencyFrames = eutLatencyFrames
  result.onMainThread = eutOnMainThread

proc freeEutPluginApi*(api: ptr PluginApi) =
  if api.isNil:
    return
  if not api.impl.isNil:
    deallocShared(cast[ptr EutBackendImpl](api.impl))
  deallocShared(api)

{.pop.}
