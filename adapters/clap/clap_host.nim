# clap_host.nim
import ../../core/signal_types 
import ../../core/node_interface
import std/dynlib

{.push raises: [].}

# ==============================================================================
# CLAP ABI Constants
# ==============================================================================

const
  ClapVersionMajor* = 1'u32
  ClapVersionMinor* = 2'u32
  ClapVersionRevision* = 0'u32

  ClapPluginFactoryId* = "clap.plugin-factory"

  # Event type IDs (uint16 to match header.eventType)
  ClapEvtNoteOn*: uint16 = 0
  ClapEvtNoteOff*: uint16 = 1
  ClapEvtNoteChoke*: uint16 = 2
  ClapEvtNoteExpr*: uint16 = 3
  ClapEvtParamVal*: uint16 = 4
  ClapEvtParamMod*: uint16 = 5
  ClapEvtTransport*: uint16 = 6
  ClapEvtMidi*: uint16 = 7
  ClapEvtMidiSysex*: uint16 = 8
  ClapEvtMidi2*: uint16 = 9

  # Event flags
  ClapEvtIsLive*: uint32 = 1'u32 shl 0
  ClapEvtDontRecord*: uint32 = 1'u32 shl 1

  # Transport flags
  ClapTransportHasTempo*: uint32 = 1'u32 shl 0
  ClapTransportHasBeatsTimeline*: uint32 = 1'u32 shl 1
  ClapTransportHasSecondsTimeline*: uint32 = 1'u32 shl 2
  ClapTransportHasTimeSig*: uint32 = 1'u32 shl 3
  ClapTransportIsPlaying*: uint32 = 1'u32 shl 4
  ClapTransportIsRecording*: uint32 = 1'u32 shl 5
  ClapTransportIsLoopActive*: uint32 = 1'u32 shl 6

  # Process status
  ClapProcessError*: int32 = 0
  ClapProcessContinue*: int32 = 1
  ClapProcessTail*: int32 = 2
  ClapProcessSleep*: int32 = 3

  # Internal storage
  MaxClapRawEventSize* = 128

# ==============================================================================
# CLAP ABI Types
# ==============================================================================

type
  ClapVersion* {.bycopy.} = object
    major*: uint32
    minor*: uint32
    revision*: uint32

  ClapEventHeader* {.bycopy.} = object
    size*: uint32
    time*: uint32
    spaceId*: uint16
    eventType*: uint16
    flags*: uint32

  ClapEventNote* {.bycopy.} = object
    header*: ClapEventHeader
    noteId*: int32
    portIndex*: int16
    channel*: int16
    key*: int16
    velocity*: float64

  ClapEventMidi* {.bycopy.} = object
    header*: ClapEventHeader
    portIndex*: int16
    data*: array[3, uint8]

  ClapEventParamVal* {.bycopy.} = object
    header*: ClapEventHeader
    paramId*: uint32
    cookie*: pointer
    noteId*: int32
    portIndex*: int16
    channel*: int16
    key*: int16
    value*: float64

  ClapEventTransport* {.bycopy.} = object
    header*: ClapEventHeader
    flags*: uint32
    songPosBeats*: int64
    songPosSeconds*: int64
    tempo*: float64
    tempoInc*: float64
    loopStartBeats*: int64
    loopEndBeats*: int64
    loopStartSeconds*: int64
    loopEndSeconds*: int64
    barStart*: int64
    barNumber*: int32
    timeSigNumerator*: uint16
    timeSigDenominator*: uint16

  ClapInputEvents* {.bycopy.} = object
    ctx*: pointer
    size*: proc(list: ptr ClapInputEvents): uint32 {.cdecl, raises: [], gcsafe.}
    get*: proc(list: ptr ClapInputEvents, index: uint32): ptr ClapEventHeader {.cdecl, raises: [], gcsafe.}

  ClapOutputEvents* {.bycopy.} = object
    ctx*: pointer
    tryPush*: proc(list: ptr ClapOutputEvents, event: ptr ClapEventHeader): bool {.cdecl, raises: [], gcsafe.}
    tryFlush*: proc(list: ptr ClapOutputEvents): bool {.cdecl, raises: [], gcsafe.}

  ClapAudioBuffer* {.bycopy.} = object
    data32*: ptr UncheckedArray[ptr float32]
    data64*: ptr UncheckedArray[ptr float64]
    channelCount*: uint32
    latency*: uint32
    constantMask*: uint64

  ClapProcess* {.bycopy.} = object
    steadyTime*: int64
    framesCount*: uint32
    transport*: ptr ClapEventTransport
    audioInputs*: ptr ClapAudioBuffer
    audioOutputs*: ptr ClapAudioBuffer
    audioInputsCount*: uint32
    audioOutputsCount*: uint32
    inEvents*: ptr ClapInputEvents
    outEvents*: ptr ClapOutputEvents

  ClapHost* {.bycopy.} = object
    clapVersion*: ClapVersion
    hostData*: pointer
    name*: cstring
    vendor*: cstring
    url*: cstring
    version*: cstring
    getExtension*: proc(host: ptr ClapHost, extensionId: cstring): pointer {.cdecl, raises: [], gcsafe.}
    requestRestart*: proc(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.}
    requestProcess*: proc(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.}
    requestCallback*: proc(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.}

  ClapPluginDescriptor* {.bycopy.} = object
    clapVersion*: ClapVersion
    id*: cstring
    name*: cstring
    vendor*: cstring
    url*: cstring
    manualUrl*: cstring
    supportUrl*: cstring
    version*: cstring
    description*: cstring
    features*: ptr UncheckedArray[cstring]

  ClapPlugin* {.bycopy.} = object
    desc*: ptr ClapPluginDescriptor
    pluginData*: pointer
    init*: proc(plugin: ptr ClapPlugin): bool {.cdecl, raises: [], gcsafe.}
    destroy*: proc(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.}
    activate*: proc(plugin: ptr ClapPlugin, sampleRate: float64,
                    minFrames: uint32, maxFrames: uint32): bool {.cdecl, raises: [], gcsafe.}
    deactivate*: proc(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.}
    startProcessing*: proc(plugin: ptr ClapPlugin): bool {.cdecl, raises: [], gcsafe.}
    stopProcessing*: proc(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.}
    reset*: proc(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.}
    process*: proc(plugin: ptr ClapPlugin, process: ptr ClapProcess): int32 {.cdecl, raises: [], gcsafe.}
    getExtension*: proc(plugin: ptr ClapPlugin, id: cstring): pointer {.cdecl, raises: [], gcsafe.}
    # `on_main_thread` — последнее поле clap_plugin_t (проверено по
    # include/clap/plugin.h), поэтому порядок ABI соблюдён.
    onMainThread*: proc(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.}

  ClapPluginFactory* {.bycopy.} = object
    getPluginCount*: proc(factory: ptr ClapPluginFactory): uint32 {.cdecl, raises: [], gcsafe.}
    getPluginDescriptor*: proc(factory: ptr ClapPluginFactory,
                               index: uint32): ptr ClapPluginDescriptor {.cdecl, raises: [], gcsafe.}
    createPlugin*: proc(factory: ptr ClapPluginFactory, host: ptr ClapHost,
                        pluginId: cstring): ptr ClapPlugin {.cdecl, raises: [], gcsafe.}

  ClapPluginEntry* {.bycopy.} = object
    clapVersion*: ClapVersion
    init*: proc(pluginPath: cstring): bool {.cdecl, raises: [], gcsafe.}
    deinit*: proc() {.cdecl, raises: [], gcsafe.}
    getFactory*: proc(factoryId: cstring): pointer {.cdecl, raises: [], gcsafe.}

# ==============================================================================
# Internal Types
# ==============================================================================

type
  # Raw event storage — fixed-size byte slots, cast to specific types on access.
  # Mirrors how CLAP actually stores variable-size events in a flat buffer.
  ClapRawEvent* = array[MaxClapRawEventSize, byte]

  ClapEventStorage* = object
    events*: array[MaxBlockEvents, ClapRawEvent]
    count*: int32

  # Per-channel pointer arrays for bridging AudioBuffer → CLAP float**
  ChannelPtrs* = array[MaxAudioPorts, ptr float32]

  ClapPluginInstance* = object
    plugin*: ptr ClapPlugin
    lib*: LibHandle
    host*: ClapHost
    isActive*: bool
    isProcessing*: bool
    sampleRate*: float64
    inputStorage*: ClapEventStorage
    outputStorage*: ClapEventStorage
    inChannelPtrs*: array[MaxAudioPorts, ChannelPtrs]
    outChannelPtrs*: array[MaxAudioPorts, ChannelPtrs]

# ==============================================================================
# Host Callbacks (minimal implementation)
# ==============================================================================

proc hostGetExtension(host: ptr ClapHost, extensionId: cstring): pointer {.cdecl, gcsafe.} =
  # No extensions supported yet
  return nil

proc hostRequestRestart(host: ptr ClapHost) {.cdecl, gcsafe.} =
  discard

proc hostRequestProcess(host: ptr ClapHost) {.cdecl, gcsafe.} =
  discard

proc hostRequestCallback(host: ptr ClapHost) {.cdecl, gcsafe.} =
  discard

# ==============================================================================
# Event List Callbacks for CLAP
# ==============================================================================

proc inputEventsSize(list: ptr ClapInputEvents): uint32 {.cdecl, gcsafe.} =
  let storage = cast[ptr ClapEventStorage](list.ctx)
  return storage.count.uint32

proc inputEventsGet(list: ptr ClapInputEvents, index: uint32): ptr ClapEventHeader {.cdecl, gcsafe.} =
  let storage = cast[ptr ClapEventStorage](list.ctx)
  if index < storage.count.uint32:
    return cast[ptr ClapEventHeader](addr storage.events[index])
  return nil

proc outputEventsTryPush(list: ptr ClapOutputEvents, event: ptr ClapEventHeader): bool {.cdecl, gcsafe.} =
  let storage = cast[ptr ClapEventStorage](list.ctx)
  if storage.count >= MaxBlockEvents:
    return false
  let sz = event.size.int
  if sz <= 0 or sz > MaxClapRawEventSize:
    return false
  copyMem(addr storage.events[storage.count], event, sz)
  inc storage.count
  return true

proc outputEventsTryFlush(list: ptr ClapOutputEvents): bool {.cdecl, gcsafe.} =
  return true

proc initInputEvents*(storage: ptr ClapEventStorage): ClapInputEvents =
  ## Собирает clap_input_events поверх нашего хранилища. Нужно тем, кто
  ## зовёт не `process`, а другие методы с событиями (например
  ## `clap.params.flush`, issue #49).
  result.ctx = cast[pointer](storage)
  result.size = inputEventsSize
  result.get = inputEventsGet

proc initOutputEvents*(storage: ptr ClapEventStorage): ClapOutputEvents =
  ## Парная обёртка для clap_output_events.
  result.ctx = cast[pointer](storage)
  result.tryPush = outputEventsTryPush
  result.tryFlush = outputEventsTryFlush

# ==============================================================================
# Event Conversion: Internal ↔ CLAP
# ==============================================================================

proc pushNoteToClap*(storage: var ClapEventStorage,
                     evType: uint16,
                     frameOffset: uint32,
                     portIdx: int16,
                     channel: int16,
                     key: int16,
                     velocity: float64): bool =
  ## Push a note event into raw CLAP storage.
  if storage.count >= MaxBlockEvents:
    return false
  var ev: ClapEventNote
  ev.header.size = uint32(sizeof(ClapEventNote))
  ev.header.time = frameOffset
  ev.header.spaceId = 0
  ev.header.eventType = evType
  ev.header.flags = ClapEvtIsLive
  ev.noteId = -1
  ev.portIndex = portIdx
  ev.channel = channel
  ev.key = key
  ev.velocity = velocity
  copyMem(addr storage.events[storage.count], addr ev, sizeof(ClapEventNote))
  inc storage.count
  return true

proc pushParamToClap*(storage: var ClapEventStorage,
                      frameOffset: uint32,
                      paramId: uint32,
                      value: float64): bool =
  ## Push a parameter value event into raw CLAP storage.
  if storage.count >= MaxBlockEvents:
    return false
  var ev: ClapEventParamVal
  ev.header.size = uint32(sizeof(ClapEventParamVal))
  ev.header.time = frameOffset
  ev.header.spaceId = 0
  ev.header.eventType = ClapEvtParamVal
  ev.header.flags = ClapEvtIsLive
  ev.paramId = paramId
  ev.cookie = nil
  ev.noteId = -1
  ev.portIndex = -1
  ev.channel = -1
  ev.key = -1
  ev.value = value
  copyMem(addr storage.events[storage.count], addr ev, sizeof(ClapEventParamVal))
  inc storage.count
  return true

proc midiStatus(base: uint8; channel: uint8): uint8 {.inline.} =
  ## Статус-байт MIDI: тип сообщения | номер канала (4 бита).
  base or (channel and 0x0F'u8)

proc to7BitRaw(v: float32): uint8 {.inline.} =
  ## Значение уже в единицах MIDI (0..127) -> 7 бит без нормировки.
  if v <= 0.0f: 0'u8
  elif v >= 127.0f: 127'u8
  else: uint8(v + 0.5f)

proc to7BitNorm(v: float32): uint8 {.inline.} =
  ## Нормированное значение (0..1) -> 7 бит.
  if v <= 0.0f: 0'u8
  elif v >= 1.0f: 127'u8
  else: uint8(v * 127.0f + 0.5f)

proc pitchBend14(v: float32): int32 {.inline.} =
  ## [-1, 1] -> 14-битное значение с центром 8192 (0..16383).
  var bend = int32(v * 8192.0f) + 8192
  if bend < 0: bend = 0
  if bend > 16383: bend = 16383
  bend

proc pushMidiToClap*(storage: var ClapEventStorage,
                     frameOffset: uint32,
                     status, d1, d2: uint8): bool =
  ## 3-байтное MIDI-сообщение в CLAP (`clap_event_midi`).
  ##
  ## Это штатный «запасной выход» CLAP: отдельные типы событий есть только у
  ## нот и параметров, всё остальное (CC, pitch bend, aftertouch, program
  ## change) ходит как MIDI-байты.
  if storage.count >= MaxBlockEvents:
    return false
  var ev: ClapEventMidi
  ev.header.size = uint32(sizeof(ClapEventMidi))
  ev.header.time = frameOffset
  ev.header.spaceId = 0
  ev.header.eventType = ClapEvtMidi
  ev.header.flags = ClapEvtIsLive
  ev.portIndex = 0
  ev.data[0] = status
  ev.data[1] = d1
  ev.data[2] = d2
  copyMem(addr storage.events[storage.count], addr ev, sizeof(ClapEventMidi))
  inc storage.count
  true

proc convertRtEventToClap*(ev: RealtimeEvent, storage: var ClapEventStorage): bool =
  ## Convert internal RealtimeEvent → CLAP raw storage.
  ##
  ## Для CC / pitch bend / aftertouch / program change в CLAP нет отдельных
  ## типов событий: они уезжают как `clap_event_midi` (3 байта). Раньше эти
  ## виды событий молча терялись — плагин не получал ни CC, ни pitch bend
  ## с клавиатуры (issue #7).
  case ev.kind
  of evNoteOn:
    return pushNoteToClap(storage, ClapEvtNoteOn, ev.frameOffset,
                          ev.port.int16, ev.channel.int16,
                          ev.data[0].int16, ev.data[1].float64)
  of evNoteOff:
    return pushNoteToClap(storage, ClapEvtNoteOff, ev.frameOffset,
                          ev.port.int16, ev.channel.int16,
                          ev.data[0].int16, ev.data[1].float64)
  of evParamChange:
    return pushParamToClap(storage, ev.frameOffset,
                           ev.data[0].uint32, ev.data[1].float64)
  of evCC:
    # data[0] — номер контроллера (0..127), data[1] — нормированное значение.
    return pushMidiToClap(storage, ev.frameOffset,
                          midiStatus(0xB0'u8, ev.channel),
                          to7BitRaw(ev.data[0]), to7BitNorm(ev.data[1]))
  of evPitchBend:
    # data[0] — [-1, 1] -> 14-битное значение вокруг центра 8192.
    let bend = pitchBend14(ev.data[0])
    return pushMidiToClap(storage, ev.frameOffset,
                          midiStatus(0xE0'u8, ev.channel),
                          uint8(bend and 0x7F'i32),
                          uint8((bend shr 7) and 0x7F'i32))
  of evAftertouch:
    return pushMidiToClap(storage, ev.frameOffset,
                          midiStatus(0xD0'u8, ev.channel),
                          to7BitNorm(ev.data[0]), 0'u8)
  of evProgramChange:
    return pushMidiToClap(storage, ev.frameOffset,
                          midiStatus(0xC0'u8, ev.channel),
                          to7BitRaw(ev.data[0]), 0'u8)
  else:
    return false

proc convertClapEventToRt*(header: ptr ClapEventHeader): RealtimeEvent =
  ## Convert CLAP event header → internal RealtimeEvent.
  result.frameOffset = header.time
  result.subFrame = 0.0f
  result.port = 0
  result.channel = 0

  case header.eventType
  of ClapEvtNoteOn:
    let note = cast[ptr ClapEventNote](header)
    result.kind = evNoteOn
    result.channel = note.channel.uint8
    result.data[0] = note.key.float32
    result.data[1] = note.velocity.float32

  of ClapEvtNoteOff:
    let note = cast[ptr ClapEventNote](header)
    result.kind = evNoteOff
    result.channel = note.channel.uint8
    result.data[0] = note.key.float32
    result.data[1] = note.velocity.float32

  of ClapEvtParamVal:
    let param = cast[ptr ClapEventParamVal](header)
    result.kind = evParamChange
    result.data[0] = param.paramId.float32
    result.data[1] = param.value.float32

  of ClapEvtMidi:
    # Симметрично convertRtEventToClap: разбираем статус-байт, чтобы out-event
    # вернулся в Core тем же типом, каким ушёл бы вход (issue #7). Раньше
    # всё сводилось к evCC, и MIDI-out плагина терял тип сообщения.
    let midi = cast[ptr ClapEventMidi](header)
    let status = midi.data[0] and 0xF0'u8
    result.channel = midi.data[0] and 0x0F'u8
    case status
    of 0x90'u8:                       # Note On (velocity 0 == Note Off)
      if midi.data[2] == 0'u8:
        result.kind = evNoteOff
        result.data[0] = float32(midi.data[1])
        result.data[1] = 0.0f
      else:
        result.kind = evNoteOn
        result.data[0] = float32(midi.data[1])
        result.data[1] = float32(midi.data[2]) / 127.0f
    of 0x80'u8:                       # Note Off
      result.kind = evNoteOff
      result.data[0] = float32(midi.data[1])
      result.data[1] = 0.0f
    of 0xB0'u8:                       # Control Change
      result.kind = evCC
      result.data[0] = float32(midi.data[1])
      result.data[1] = float32(midi.data[2]) / 127.0f
    of 0xE0'u8:                       # Pitch Bend
      let bend = (int32(midi.data[2]) shl 7) or int32(midi.data[1])
      result.kind = evPitchBend
      result.data[0] = float32(bend - 8192) / 8192.0f
    of 0xD0'u8:                       # Channel Aftertouch
      result.kind = evAftertouch
      result.data[0] = float32(midi.data[1]) / 127.0f
    of 0xC0'u8:                       # Program Change
      result.kind = evProgramChange
      result.data[0] = float32(midi.data[1])
    else:
      result.kind = evTrigger
      result.data[0] = float32(midi.data[0])
      result.data[1] = float32(midi.data[1])
      result.data[2] = float32(midi.data[2])

  else:
    result.kind = evTrigger

# ==============================================================================
# Audio Buffer Bridging
# ==============================================================================

proc setupClapAudioBuffer*(buf: PAudioBuffer,
                           channelPtrs: var ChannelPtrs,
                           clapBuf: var ClapAudioBuffer) =
  ## Bridge our AudioBuffer → CLAP's float** layout.
  if buf.isNil or buf.data.isNil:
    clapBuf.data32 = nil
    clapBuf.data64 = nil
    clapBuf.channelCount = 0
    return

  # Клампим число каналов: `channelPtrs` — фиксированный array[MaxAudioPorts].
  # Без клампа буфер с большим числом каналов писал бы ЗА массив, а плагину
  # сообщался бы `channelCount` больше, чем реально есть указателей (он читал
  # бы мусор за границей). Конфигурации 1/1, 2/2, 2/4 обязаны оставаться в
  # границах (issue #7).
  let ch = min(buf.channels.int, MaxAudioPorts)
  let stride = buf.stride.int
  for c in 0 ..< ch:
    if stride == buf.frames.int:
      # Planar layout: channel c starts at data[c * frames]
      channelPtrs[c] = addr buf.data[c * stride]
    else:
      # Interleaved or single-channel
      channelPtrs[c] = addr buf.data[c]

  clapBuf.data32 = cast[ptr UncheckedArray[ptr float32]](addr channelPtrs)
  clapBuf.data64 = nil
  clapBuf.channelCount = ch.uint32
  clapBuf.latency = 0
  clapBuf.constantMask = 0

# ==============================================================================
# Transport Bridging
# ==============================================================================

proc buildClapTransport*(ctx: ptr NodeProcessContext): ClapEventTransport =
  ## Build a CLAP transport event from our NodeProcessContext.
  result.header.size = uint32(sizeof(ClapEventTransport))
  result.header.time = 0
  result.header.spaceId = 0
  result.header.eventType = ClapEvtTransport
  result.header.flags = 0

  var flags: uint32 = 0
  flags = flags or ClapTransportHasTempo
  flags = flags or ClapTransportHasBeatsTimeline
  flags = flags or ClapTransportHasSecondsTimeline
  flags = flags or ClapTransportHasTimeSig

  if pfTransportPlaying in ctx.flags:
    flags = flags or ClapTransportIsPlaying

  result.flags = flags
  result.tempo = ctx.transport.tempo
  result.timeSigNumerator = ctx.transport.timeSigNum.uint16
  result.timeSigDenominator = ctx.transport.timeSigDen.uint16
  result.songPosBeats = (ctx.transport.beatPosition * 1e9).int64  # CLAP uses fixed-point
  result.songPosSeconds = (ctx.timeInSeconds * 1e9).int64
  result.barStart = (ctx.transport.barPosition * 1e9).int64
  result.barNumber = ctx.transport.barPosition.int32
  result.loopStartBeats = (ctx.transport.cycleStart * 1e9).int64
  result.loopEndBeats = (ctx.transport.cycleEnd * 1e9).int64

# ==============================================================================
# Plugin Lifecycle
# ==============================================================================

proc initHost*(host: var ClapHost) =
  ## Initialize the host interface with default callbacks.
  host.clapVersion.major = ClapVersionMajor
  host.clapVersion.minor = ClapVersionMinor
  host.clapVersion.revision = ClapVersionRevision
  host.hostData = nil
  host.name = "Euterpia"
  host.vendor = "Euterpia"
  host.url = ""
  host.version = "0.1.0"
  host.getExtension = hostGetExtension
  host.requestRestart = hostRequestRestart
  host.requestProcess = hostRequestProcess
  host.requestCallback = hostRequestCallback

proc loadClapPlugin*(path: string): ClapPluginInstance =
  ## Load a CLAP plugin from a .clap shared library.
  result.lib = loadLib(path)
  if result.lib.isNil:
    return

  # clap_entry is a global pointer variable in the shared library
  let entrySym = symAddr(result.lib, "clap_entry")
  if entrySym.isNil:
    unloadLib(result.lib)
    result.lib = nil
    return

  let entry = cast[ptr ClapPluginEntry](entrySym)
  if entry.clapVersion.major != ClapVersionMajor:
    unloadLib(result.lib)
    result.lib = nil
    return

  # Initialize the plugin entry
  if not entry.init(path.cstring):
    unloadLib(result.lib)
    result.lib = nil
    return

  # Get the plugin factory
  let factoryPtr = entry.getFactory(ClapPluginFactoryId)
  if factoryPtr.isNil:
    entry.deinit()
    unloadLib(result.lib)
    result.lib = nil
    return

  let factory = cast[ptr ClapPluginFactory](factoryPtr)
  let pluginCount = factory.getPluginCount(factory)
  if pluginCount == 0:
    entry.deinit()
    unloadLib(result.lib)
    result.lib = nil
    return

  # Initialize host interface
  initHost(result.host)

  # Create the first available plugin
  let desc = factory.getPluginDescriptor(factory, 0)
  if desc.isNil:
    entry.deinit()
    unloadLib(result.lib)
    result.lib = nil
    return

  result.plugin = factory.createPlugin(factory, addr result.host, desc.id)
  if result.plugin.isNil:
    entry.deinit()
    unloadLib(result.lib)
    result.lib = nil
    return

  if not result.plugin.init(result.plugin):
    result.plugin.destroy(result.plugin)
    result.plugin = nil
    entry.deinit()
    unloadLib(result.lib)
    result.lib = nil
    return

proc activatePlugin*(inst: var ClapPluginInstance,
                     sampleRate: float64,
                     minFrames, maxFrames: uint32): bool =
  if inst.plugin.isNil or inst.isActive:
    return false
  if not inst.plugin.activate(inst.plugin, sampleRate, minFrames, maxFrames):
    return false
  inst.isActive = true
  inst.sampleRate = sampleRate
  return true

proc deactivatePlugin*(inst: var ClapPluginInstance) =
  if inst.plugin.isNil or not inst.isActive:
    return
  if inst.isProcessing:
    inst.plugin.stopProcessing(inst.plugin)
    inst.isProcessing = false
  inst.plugin.deactivate(inst.plugin)
  inst.isActive = false

proc startProcessing*(inst: var ClapPluginInstance): bool =
  if inst.plugin.isNil or not inst.isActive or inst.isProcessing:
    return false
  if not inst.plugin.startProcessing(inst.plugin):
    return false
  inst.isProcessing = true
  return true

proc stopProcessing*(inst: var ClapPluginInstance) =
  if inst.plugin.isNil or not inst.isProcessing:
    return
  inst.plugin.stopProcessing(inst.plugin)
  inst.isProcessing = false

proc processPlugin*(inst: var ClapPluginInstance,
                    ctx: ptr NodeProcessContext,
                    audio: ptr NodeAudioPorts,
                    events: ptr NodeEventPorts): int32 =
  ## Process one audio block through the CLAP plugin.
  if inst.plugin.isNil or not inst.isProcessing:
    return ClapProcessError

  # Clear event storages
  inst.inputStorage.count = 0
  inst.outputStorage.count = 0

  # Convert input events from our format → CLAP
  if not events.isNil and events.inputCount > 0 and events.inputs[0] != nil:
    let inQ = events.inputs[0]
    for i in 0 ..< inQ.count:
      discard convertRtEventToClap(inQ.events[i], inst.inputStorage)

  # Build transport
  var transport = buildClapTransport(ctx)

  # Setup audio buffers
  var clapAudioIns: array[MaxAudioPorts, ClapAudioBuffer]
  var clapAudioOuts: array[MaxAudioPorts, ClapAudioBuffer]

  # Число портов клампим к MaxAudioPorts: и массивы буферов, и per-port
  # указатели на каналы имеют фиксированную длину. Граф Core тоже ограничен
  # MaxAudioPorts, но адаптер не должен полагаться на это (issue #7).
  let inPorts = if audio.isNil: 0 else: min(audio.inputCount.int, MaxAudioPorts)
  let outPorts = if audio.isNil: 0 else: min(audio.outputCount.int, MaxAudioPorts)

  if not audio.isNil:
    for i in 0 ..< inPorts:
      setupClapAudioBuffer(audio.inputs[i], inst.inChannelPtrs[i], clapAudioIns[i])
    for i in 0 ..< outPorts:
      setupClapAudioBuffer(audio.outputs[i], inst.outChannelPtrs[i], clapAudioOuts[i])

  # Setup event list interfaces
  var inEvtList: ClapInputEvents
  inEvtList.ctx = addr inst.inputStorage
  inEvtList.size = inputEventsSize
  inEvtList.get = inputEventsGet

  var outEvtList: ClapOutputEvents
  outEvtList.ctx = addr inst.outputStorage
  outEvtList.tryPush = outputEventsTryPush
  outEvtList.tryFlush = outputEventsTryFlush

  # Build process struct
  var clapProc: ClapProcess
  clapProc.steadyTime = ctx.samplePosition
  clapProc.framesCount = ctx.blockSize.uint32
  clapProc.transport = addr transport
  clapProc.audioInputsCount = inPorts.uint32
  clapProc.audioOutputsCount = outPorts.uint32
  clapProc.audioInputs = cast[ptr ClapAudioBuffer](addr clapAudioIns)
  clapProc.audioOutputs = cast[ptr ClapAudioBuffer](addr clapAudioOuts)
  clapProc.inEvents = addr inEvtList
  clapProc.outEvents = addr outEvtList

  # Call the plugin's process
  let status = inst.plugin.process(inst.plugin, addr clapProc)

  # Convert output events from CLAP → our format
  if not events.isNil and events.outputCount > 0 and events.outputs[0] != nil:
    let outQ = events.outputs[0]
    clearEvents(outQ)
    for i in 0 ..< inst.outputStorage.count:
      let hdr = cast[ptr ClapEventHeader](addr inst.outputStorage.events[i])
      let rtEv = convertClapEventToRt(hdr)
      discard pushEvent(outQ, rtEv)

  return status

proc unloadClapPlugin*(inst: var ClapPluginInstance) =
  ## Fully unload plugin and release all resources.
  if inst.plugin != nil:
    if inst.isProcessing:
      stopProcessing(inst)
    if inst.isActive:
      deactivatePlugin(inst)
    inst.plugin.destroy(inst.plugin)
    inst.plugin = nil

  if inst.lib != nil:
    # Call entry.deinit() before unloading
    let entrySym = symAddr(inst.lib, "clap_entry")
    if entrySym != nil:
      let entry = cast[ptr ClapPluginEntry](entrySym)
      entry.deinit()
    unloadLib(inst.lib)
    inst.lib = nil

{.pop.}