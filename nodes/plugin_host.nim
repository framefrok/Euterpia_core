# ============================================================
# EUTERPIA CLAP Host — plugin_host.nim
# ============================================================
#
# Architecture:
#   Official CLAP C ABI  →  thin Nim bindings  →  ClapNodeAdapter  →  PipelineStep
#
# Thread model:
#   Main thread  : load, instantiate, activate, deactivate, destroy,
#                  params, state, GUI, extension queries
#   Audio thread : processClapPluginNode, event I/O callbacks
#
# Realtime guarantees (audio thread):
#   ✗ allocation   ✗ lock   ✗ I/O   ✗ exception
#   All buffers pre-allocated in ClapNodeAdapter at compile time.
#
# ABI note:
#   Struct layouts match CLAP 1.2.0 C headers field-by-field.
#   Nim identifier equivalence (case/underscore-insensitive) is
#   handled by using CLAP_EVT_* prefix for event-type constants,
#   avoiding collision with ClapEvent* type names.
# ============================================================

import std/dynlib
import ../core/node_interface

# ============================================================
# CLAP Constants
# ============================================================

const
  CLAP_VERSION_MAJOR*    = 1'u32
  CLAP_VERSION_MINOR*    = 2'u32
  CLAP_VERSION_REVISION* = 0'u32

  CLAP_PLUGIN_ENTRY_SYMBOL* = "clap_entry"

  # clap_process_status
  CLAP_PROCESS_ERROR*                  = -1'i32
  CLAP_PROCESS_CONTINUE*               =  0'i32
  CLAP_PROCESS_CONTINUE_IF_NOT_QUIET*  =  1'i32
  CLAP_PROCESS_TAIL*                   =  2'i32
  CLAP_PROCESS_SLEEP*                  =  3'i32

  # Event space
  CLAP_CORE_EVENT_SPACE_ID* = 0'u16

  # Event types  (CLAP_EVT_* to avoid Nim collision with ClapEvent* types)
  CLAP_EVT_NOTE_ON*           = 0'u16
  CLAP_EVT_NOTE_OFF*          = 1'u16
  CLAP_EVT_NOTE_CHOKE*        = 2'u16
  CLAP_EVT_NOTE_END*          = 3'u16
  CLAP_EVT_NOTE_EXPRESSION*   = 4'u16
  CLAP_EVT_PARAM_VALUE*       = 5'u16
  CLAP_EVT_PARAM_MOD*         = 6'u16
  CLAP_EVT_PARAM_GESTURE_BEGIN* = 7'u16
  CLAP_EVT_PARAM_GESTURE_END*   = 8'u16
  CLAP_EVT_TRANSPORT*         = 9'u16
  CLAP_EVT_MIDI*              = 10'u16
  CLAP_EVT_MIDI_SYSEX*        = 11'u16
  CLAP_EVT_MIDI2*             = 12'u16

  # Transport flags
  CLAP_TRANSPORT_HAS_TEMPO*          = 1'u32 shl 0
  CLAP_TRANSPORT_HAS_BEATTIME*       = 1'u32 shl 1
  CLAP_TRANSPORT_HAS_SECONDS*        = 1'u32 shl 2
  CLAP_TRANSPORT_HAS_TIME_SIGNATURE* = 1'u32 shl 3
  CLAP_TRANSPORT_IS_PLAYING*         = 1'u32 shl 4
  CLAP_TRANSPORT_IS_RECORDING*       = 1'u32 shl 5
  CLAP_TRANSPORT_IS_LOOP_ACTIVE*     = 1'u32 shl 6
  CLAP_TRANSPORT_IS_WITHIN_PRE_ROLL* = 1'u32 shl 7

  # Extension IDs
  CLAP_EXT_AUDIO_PORTS* = "clap.audio-ports"
  CLAP_EXT_NOTE_PORTS*  = "clap.note-ports"
  CLAP_EXT_PARAMS*      = "clap.params"
  CLAP_EXT_STATE*       = "clap.state"
  CLAP_EXT_GUI*         = "clap.gui"
  CLAP_EXT_LATENCY*     = "clap.latency"
  CLAP_EXT_TAIL*        = "clap.tail"

  # Realtime buffer limits
  MaxEventsPerBlock*  = 1024
  MaxEventByteBudget* = MaxEventsPerBlock * 128

  # CLAP fixed-point denominator for beats / seconds (2^31)
  ClapFixedPointScale* = 2147483648.0

# ============================================================
# CLAP Core Types  (ABI-exact, field order = C struct order)
# ============================================================

type
  ClapId* = uint32

  ClapVersion* {.bycopy.} = object
    major*:    uint32
    minor*:    uint32
    revision*: uint32

  ClapPluginDescriptor* {.bycopy.} = object
    id*:          cstring
    name*:        cstring
    vendor*:      cstring
    url*:         cstring
    manualUrl*:   cstring
    supportUrl*:  cstring
    version*:     cstring
    description*: cstring
    features*:    ptr UncheckedArray[cstring]

  ClapHost* {.bycopy.} = object
    clapVersion*: ClapVersion
    hostData*:    pointer
    name*:        cstring
    vendor*:      cstring
    url*:         cstring
    version*:     cstring
    getExtension*:    proc (host: ptr ClapHost; id: cstring): pointer
                        {.cdecl, raises: [], gcsafe.}
    requestRestart*:  proc (host: ptr ClapHost)
                        {.cdecl, raises: [], gcsafe.}
    requestProcess*:  proc (host: ptr ClapHost)
                        {.cdecl, raises: [], gcsafe.}
    requestCallback*: proc (host: ptr ClapHost)
                        {.cdecl, raises: [], gcsafe.}

  ClapPlugin* {.bycopy.} = object
    desc*:         ptr ClapPluginDescriptor
    pluginData*:   pointer
    init*:           proc (plugin: ptr ClapPlugin): bool
                       {.cdecl, raises: [], gcsafe.}
    destroy*:        proc (plugin: ptr ClapPlugin)
                       {.cdecl, raises: [], gcsafe.}
    activate*:       proc (plugin: ptr ClapPlugin;
                           sampleRate: cdouble;
                           minFrames, maxFrames: uint32): bool
                       {.cdecl, raises: [], gcsafe.}
    deactivate*:     proc (plugin: ptr ClapPlugin)
                       {.cdecl, raises: [], gcsafe.}
    startProcessing*: proc (plugin: ptr ClapPlugin): bool
                       {.cdecl, raises: [], gcsafe.}
    stopProcessing*: proc (plugin: ptr ClapPlugin)
                       {.cdecl, raises: [], gcsafe.}
    reset*:          proc (plugin: ptr ClapPlugin)
                       {.cdecl, raises: [], gcsafe.}
    process*:        proc (plugin: ptr ClapPlugin;
                           p: ptr ClapProcess): int32
                       {.cdecl, raises: [], gcsafe.}
    getExtension*:   proc (plugin: ptr ClapPlugin; id: cstring): pointer
                       {.cdecl, raises: [], gcsafe.}
    onMainThread*:   proc (plugin: ptr ClapPlugin)
                       {.cdecl, raises: [], gcsafe.}

  ClapEntry* {.bycopy.} = object
    clapVersion*:       ClapVersion
    init*:              proc (pluginPath: cstring): bool
                          {.cdecl, raises: [], gcsafe.}
    deinit*:            proc ()
                          {.cdecl, raises: [], gcsafe.}
    getPluginCount*:    proc (): uint32
                          {.cdecl, raises: [], gcsafe.}
    getPluginDescriptor*: proc (index: uint32): ptr ClapPluginDescriptor
                          {.cdecl, raises: [], gcsafe.}
    createPlugin*:      proc (host: ptr ClapHost;
                              pluginId: cstring): ptr ClapPlugin
                          {.cdecl, raises: [], gcsafe.}

# ============================================================
# CLAP Event Types
# ============================================================

  ClapEventHeader* {.bycopy.} = object
    size*:    uint32
    time*:    uint32
    spaceId*: uint16
    `type`*:  uint16
    flags*:   uint32

  ClapEventTransport* {.bycopy.} = object
    header*:           ClapEventHeader
    transportFlags*:   uint32
    songPosBeats*:     int64
    songPosSeconds*:   int64
    tempo*:            cdouble
    tempoInc*:         cdouble
    loopStartBeats*:   int64
    loopEndBeats*:     int64
    loopStartSeconds*: int64
    loopEndSeconds*:   int64
    barStart*:         int64
    barNumber*:        int32
    tsigNum*:          uint16
    tsigDen*:          uint16

  ClapEventNote* {.bycopy.} = object
    header*:   ClapEventHeader
    noteId*:   int32
    portIndex*: int16
    channel*:  int16
    key*:      int16
    velocity*: cdouble

  ClapEventParamValue* {.bycopy.} = object
    header*:   ClapEventHeader
    paramId*:  ClapId
    cookie*:   pointer
    noteId*:   int32
    portIndex*: int16
    channel*:  int16
    key*:      int16
    value*:    cdouble

# ============================================================
# CLAP Audio Types
# ============================================================

  ClapAudioBuffer* {.bycopy.} = object
    data32*:       ptr ptr float32
    data64*:       ptr ptr float64
    channelCount*: uint32
    latency*:      uint32
    constantMask*: uint64

# ============================================================
# CLAP Event I/O Interfaces
# ============================================================

  ClapInputEvents* {.bycopy.} = object
    ctx*:  pointer
    size*: proc (list: ptr ClapInputEvents): uint32
             {.cdecl, raises: [], gcsafe.}
    get*:  proc (list: ptr ClapInputEvents; index: uint32): ptr ClapEventHeader
             {.cdecl, raises: [], gcsafe.}

  ClapOutputEvents* {.bycopy.} = object
    ctx*:     pointer
    tryPush*: proc (list: ptr ClapOutputEvents;
                    event: ptr ClapEventHeader): bool
                {.cdecl, raises: [], gcsafe.}

# ============================================================
# CLAP Process Struct  (ABI-exact, matches clap/process.h)
# ============================================================

  ClapProcess* {.bycopy.} = object
    steadyTime*:       int64
    framesCount*:      uint32
    transport*:        ptr ClapEventTransport
    audioInputs*:      ptr ClapAudioBuffer
    audioOutputs*:     ptr ClapAudioBuffer
    audioInputsCount*: uint32
    audioOutputsCount*: uint32
    inEvents*:         ptr ClapInputEvents
    outEvents*:        ptr ClapOutputEvents

# ============================================================
# CLAP Extension Interfaces
# ============================================================

  # --- clap.ext/audio-ports ---

  ClapAudioPortInfo* {.bycopy.} = object
    id*:            ClapId
    name*:          array[256, char]
    channelCount*:  uint32
    flags*:         uint32
    inPlacePair*:   ClapId

  ClapPluginAudioPorts* {.bycopy.} = object
    count*: proc (plugin: ptr ClapPlugin; isInput: bool): uint32
              {.cdecl, raises: [], gcsafe.}
    get*:   proc (plugin: ptr ClapPlugin; index: uint32;
                  isInput: bool; info: ptr ClapAudioPortInfo): bool
              {.cdecl, raises: [], gcsafe.}

  # --- clap.ext/note-ports ---

  ClapNotePortInfo* {.bycopy.} = object
    id*:                ClapId
    name*:              array[256, char]
    supportedDialects*: uint32
    preferredDialect*:  uint32

  ClapPluginNotePorts* {.bycopy.} = object
    count*: proc (plugin: ptr ClapPlugin; isInput: bool): uint32
              {.cdecl, raises: [], gcsafe.}
    get*:   proc (plugin: ptr ClapPlugin; index: uint32;
                  isInput: bool; info: ptr ClapNotePortInfo): bool
              {.cdecl, raises: [], gcsafe.}

  # --- clap.ext/params ---

  ClapParamInfo* {.bycopy.} = object
    id*:           ClapId
    flags*:        uint32
    cookie*:       pointer
    name*:         array[256, char]
    module*:       array[1024, char]
    minValue*:     cdouble
    maxValue*:     cdouble
    defaultValue*: cdouble

  ClapPluginParams* {.bycopy.} = object
    count*:       proc (plugin: ptr ClapPlugin): uint32
                    {.cdecl, raises: [], gcsafe.}
    getInfo*:     proc (plugin: ptr ClapPlugin; paramIndex: uint32;
                        info: ptr ClapParamInfo): bool
                    {.cdecl, raises: [], gcsafe.}
    getValue*:    proc (plugin: ptr ClapPlugin; paramId: ClapId;
                        value: ptr cdouble): bool
                    {.cdecl, raises: [], gcsafe.}
    valueToText*: proc (plugin: ptr ClapPlugin; paramId: ClapId;
                        value: cdouble; display: cstring; size: uint32): bool
                    {.cdecl, raises: [], gcsafe.}
    textToValue*: proc (plugin: ptr ClapPlugin; paramId: ClapId;
                        display: cstring; value: ptr cdouble): bool
                    {.cdecl, raises: [], gcsafe.}
    flush*:       proc (plugin: ptr ClapPlugin;
                        inEvents: ptr ClapInputEvents;
                        outEvents: ptr ClapOutputEvents)
                    {.cdecl, raises: [], gcsafe.}

  # --- clap.ext/state ---

  ClapStream* {.bycopy.} = object
    ctx*:   pointer
    write*: proc (stream: ptr ClapStream;
                  buffer: pointer; size: uint64): int64
              {.cdecl, raises: [], gcsafe.}
    read*:  proc (stream: ptr ClapStream;
                  buffer: pointer; size: uint64): int64
              {.cdecl, raises: [], gcsafe.}

  ClapPluginState* {.bycopy.} = object
    save*: proc (plugin: ptr ClapPlugin; stream: ptr ClapStream): bool
             {.cdecl, raises: [], gcsafe.}
    load*: proc (plugin: ptr ClapPlugin; stream: ptr ClapStream): bool
             {.cdecl, raises: [], gcsafe.}

  # --- clap.ext/gui ---

  ClapWindow* {.union, bycopy.} = object
    pos*:   tuple[x: cint, y: cint]
    x11*:   culong
    cocoa*: pointer
    win32*: pointer

  ClapGuiResizeHints* {.bycopy.} = object
    canResizeHorizontally*:   bool
    canResizeVertically*:     bool
    preserveAspectRatio*:     bool
    aspectRatioWidth*:        uint32
    aspectRatioHeight*:       uint32

  ClapPluginGui* {.bycopy.} = object
    isApiSupported*:  proc (plugin: ptr ClapPlugin;
                            api: cstring; isFloating: bool): bool
                        {.cdecl, raises: [], gcsafe.}
    getPreferredApi*: proc (plugin: ptr ClapPlugin;
                            api: ptr cstring; isFloating: ptr bool): bool
                        {.cdecl, raises: [], gcsafe.}
    create*:          proc (plugin: ptr ClapPlugin;
                            api: cstring; isFloating: bool): bool
                        {.cdecl, raises: [], gcsafe.}
    destroy*:         proc (plugin: ptr ClapPlugin)
                        {.cdecl, raises: [], gcsafe.}
    setScale*:        proc (plugin: ptr ClapPlugin; scale: cdouble): bool
                        {.cdecl, raises: [], gcsafe.}
    getSize*:         proc (plugin: ptr ClapPlugin;
                            width, height: ptr uint32): bool
                        {.cdecl, raises: [], gcsafe.}
    canResize*:       proc (plugin: ptr ClapPlugin): bool
                        {.cdecl, raises: [], gcsafe.}
    getResizeHints*:  proc (plugin: ptr ClapPlugin;
                            hints: ptr ClapGuiResizeHints): bool
                        {.cdecl, raises: [], gcsafe.}
    adjustSize*:      proc (plugin: ptr ClapPlugin;
                            width, height: ptr uint32): bool
                        {.cdecl, raises: [], gcsafe.}
    setSize*:         proc (plugin: ptr ClapPlugin;
                            width, height: uint32): bool
                        {.cdecl, raises: [], gcsafe.}
    setParent*:       proc (plugin: ptr ClapPlugin;
                            window: ptr ClapWindow): bool
                        {.cdecl, raises: [], gcsafe.}
    setTransient*:    proc (plugin: ptr ClapPlugin;
                            window: ptr ClapWindow): bool
                        {.cdecl, raises: [], gcsafe.}
    suggestTitle*:    proc (plugin: ptr ClapPlugin; title: cstring)
                        {.cdecl, raises: [], gcsafe.}
    show*:            proc (plugin: ptr ClapPlugin): bool
                        {.cdecl, raises: [], gcsafe.}
    hide*:            proc (plugin: ptr ClapPlugin): bool
                        {.cdecl, raises: [], gcsafe.}

  # --- clap.ext/latency ---

  ClapPluginLatency* {.bycopy.} = object
    get*: proc (plugin: ptr ClapPlugin): uint32
            {.cdecl, raises: [], gcsafe.}

  # --- clap.ext/tail ---

  ClapPluginTail* {.bycopy.} = object
    get*: proc (plugin: ptr ClapPlugin): uint32
            {.cdecl, raises: [], gcsafe.}

# ============================================================
# EUTERPIA Host Types
# ============================================================

  PluginInstance* = object
    library*:    LibHandle
    entry*:      ptr ClapEntry
    plugin*:     ptr ClapPlugin
    descriptor*: ptr ClapPluginDescriptor
    isActive*:   bool
    isProcessing*: bool
    sampleRate*: float64
    maxBlockSize*: uint32
    # Cached extension pointers (queried once at instantiate)
    audioPortsExt*: ptr ClapPluginAudioPorts
    notePortsExt*:  ptr ClapPluginNotePorts
    paramsExt*:     ptr ClapPluginParams
    stateExt*:      ptr ClapPluginState
    guiExt*:        ptr ClapPluginGui
    latencyExt*:    ptr ClapPluginLatency
    tailExt*:       ptr ClapPluginTail

  PluginHost* = object
    plugins*: seq[PluginInstance]
    hostApi*: ClapHost

# ============================================================
# EUTERPIA Adapter  (pre-allocated, realtime-safe)
# ============================================================
# Created at graph compile time.  All buffers are fixed-size
# arrays so the audio thread never allocates.

  ClapNodeAdapter* = object
    plugin*: ptr ClapPlugin

    # Cached extension pointers (copied from PluginInstance)
    audioPortsExt*: ptr ClapPluginAudioPorts
    notePortsExt*:  ptr ClapPluginNotePorts
    paramsExt*:     ptr ClapPluginParams
    stateExt*:      ptr ClapPluginState
    guiExt*:        ptr ClapPluginGui
    latencyExt*:    ptr ClapPluginLatency
    tailExt*:       ptr ClapPluginTail

    # Pre-built process struct
    processStruct*:    ClapProcess
    inEventsImpl*:     ClapInputEvents
    outEventsImpl*:    ClapOutputEvents
    transportEvent*:   ClapEventTransport

    # Audio port mapping (mono per EUTERPIA buffer)
    audioInBuffers*:       array[MaxAudioPorts, ClapAudioBuffer]
    audioOutBuffers*:      array[MaxAudioPorts, ClapAudioBuffer]
    audioInChannelPtrs*:   array[MaxAudioPorts, array[2, ptr float32]]
    audioOutChannelPtrs*:  array[MaxAudioPorts, array[2, ptr float32]]

    # Flat event ring buffers (no heap, no seq)
    inEventBuf*:       array[MaxEventByteBudget, byte]
    inEventOffsets*:   array[MaxEventsPerBlock, uint32]
    inEventCount*:     uint32
    inEventWritePos*:  uint32

    outEventBuf*:      array[MaxEventByteBudget, byte]
    outEventOffsets*:  array[MaxEventsPerBlock, uint32]
    outEventCount*:    uint32
    outEventWritePos*: uint32

# ============================================================
# Host Callbacks  (called by plugin on main thread)
# ============================================================

proc hostGetExtension(host: ptr ClapHost; id: cstring): pointer
    {.cdecl, raises: [], gcsafe.} =
  # TODO: provide host extensions (clap.host/params, clap.host/gui, etc.)
  result = nil

proc hostRequestRestart(host: ptr ClapHost)
    {.cdecl, raises: [], gcsafe.} =
  # TODO: signal main-thread loop to rebuild compiled pipeline
  discard

proc hostRequestProcess(host: ptr ClapHost)
    {.cdecl, raises: [], gcsafe.} =
  # TODO: wake audio thread if suspended
  discard

proc hostRequestCallback(host: ptr ClapHost)
    {.cdecl, raises: [], gcsafe.} =
  # TODO: schedule plugin.onMainThread() on main loop
  discard

# ============================================================
# Event I/O Callbacks  (audio thread — realtime safe)
# ============================================================

proc inEventsSize(list: ptr ClapInputEvents): uint32
    {.cdecl, raises: [], gcsafe.} =
  let a = cast[ptr ClapNodeAdapter](list.ctx)
  if a == nil: return 0
  result = a.inEventCount

proc inEventsGet(list: ptr ClapInputEvents; index: uint32): ptr ClapEventHeader
    {.cdecl, raises: [], gcsafe.} =
  let a = cast[ptr ClapNodeAdapter](list.ctx)
  if a == nil or index >= a.inEventCount: return nil
  result = cast[ptr ClapEventHeader](addr a.inEventBuf[a.inEventOffsets[index]])

proc outEventsTryPush(list: ptr ClapOutputEvents;
                      event: ptr ClapEventHeader): bool
    {.cdecl, raises: [], gcsafe.} =
  let a = cast[ptr ClapNodeAdapter](list.ctx)
  if a == nil: return false
  if a.outEventCount >= MaxEventsPerBlock: return false
  if event.size == 0 or event.size > 128: return false
  if a.outEventWritePos + event.size > MaxEventByteBudget: return false

  copyMem(addr a.outEventBuf[a.outEventWritePos],
          cast[pointer](event),
          event.size)

  a.outEventOffsets[a.outEventCount] = a.outEventWritePos
  inc a.outEventCount
  a.outEventWritePos += event.size
  result = true

# ============================================================
# Host Lifecycle  (main thread)
# ============================================================

proc initPluginHost*(): PluginHost =
  result.plugins = @[]
  result.hostApi = ClapHost(
    clapVersion: ClapVersion(
      major:    CLAP_VERSION_MAJOR,
      minor:    CLAP_VERSION_MINOR,
      revision: CLAP_VERSION_REVISION),
    hostData:        nil,
    name:            "Euterpia DAW",
    vendor:          "Euterpia",
    url:             "https://euterpia.dev",
    version:         "1.0.0",
    getExtension:    hostGetExtension,
    requestRestart:  hostRequestRestart,
    requestProcess:  hostRequestProcess,
    requestCallback: hostRequestCallback)

proc loadPlugin*(host: var PluginHost; path: string): int32 =
  ## Load a .clap / .so / .dll and run entry.init().
  ## Returns plugin-slot index or -1 on failure.
  let lib = loadLib(path)
  if lib == nil:
    echo "[ClapHost] failed to load library: ", path
    return -1

  # clap_entry is a **global struct**, not a function.
  let symAddr = lib.symAddr(CLAP_PLUGIN_ENTRY_SYMBOL)
  if symAddr == nil:
    echo "[ClapHost] symbol '", CLAP_PLUGIN_ENTRY_SYMBOL, "' not found in: ", path
    unloadLib(lib)
    return -1

  let entry = cast[ptr ClapEntry](symAddr)

  # entry.init() receives the plugin path (C string), NOT the host API.
  if not entry.init(cstring(path)):
    echo "[ClapHost] entry.init() failed for: ", path
    unloadLib(lib)
    return -1

  let count = entry.getPluginCount()
  echo "[ClapHost] loaded '", path, "' — ", count, " plugin(s)"

  host.plugins.add(PluginInstance(
    library:      lib,
    entry:        entry,
    plugin:       nil,
    descriptor:   nil,
    isActive:     false,
    isProcessing: false,
    sampleRate:   48000.0,
    maxBlockSize: 256))

  result = int32(host.plugins.len - 1)

proc queryExtensions(inst: ptr PluginInstance) =
  ## Cache all extension pointers (call once after createPlugin + init).
  let p = inst.plugin
  if p == nil: return
  inst.audioPortsExt = cast[ptr ClapPluginAudioPorts](
    p.getExtension(p, CLAP_EXT_AUDIO_PORTS))
  inst.notePortsExt = cast[ptr ClapPluginNotePorts](
    p.getExtension(p, CLAP_EXT_NOTE_PORTS))
  inst.paramsExt = cast[ptr ClapPluginParams](
    p.getExtension(p, CLAP_EXT_PARAMS))
  inst.stateExt = cast[ptr ClapPluginState](
    p.getExtension(p, CLAP_EXT_STATE))
  inst.guiExt = cast[ptr ClapPluginGui](
    p.getExtension(p, CLAP_EXT_GUI))
  inst.latencyExt = cast[ptr ClapPluginLatency](
    p.getExtension(p, CLAP_EXT_LATENCY))
  inst.tailExt = cast[ptr ClapPluginTail](
    p.getExtension(p, CLAP_EXT_TAIL))

proc instantiatePlugin*(host: var PluginHost;
                        pluginIdx: int32;
                        descriptorIdx: uint32 = 0): bool =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return false
  let inst = addr host.plugins[pluginIdx]

  let desc = inst.entry.getPluginDescriptor(descriptorIdx)
  if desc == nil: return false

  let plugin = inst.entry.createPlugin(addr host.hostApi, desc.id)
  if plugin == nil: return false

  if not plugin.init(plugin):
    plugin.destroy(plugin)
    return false

  inst.plugin     = plugin
  inst.descriptor = desc
  
  # Теперь inst (ptr PluginInstance) корректно передается в queryExtensions
  inst.queryExtensions()

  echo "[ClapHost] instantiated: ", desc.name
  result = true

proc activatePlugin*(host: var PluginHost;
                     pluginIdx: int32;
                     sampleRate: float64;
                     maxBlockSize: uint32): bool =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return false
  let inst = addr host.plugins[pluginIdx]
  if inst.plugin == nil or inst.isActive: return false

  if not inst.plugin.activate(inst.plugin, sampleRate, 1, maxBlockSize):
    return false
  if not inst.plugin.startProcessing(inst.plugin):
    inst.plugin.deactivate(inst.plugin)
    return false

  inst.isActive     = true
  inst.isProcessing = true
  inst.sampleRate   = sampleRate
  inst.maxBlockSize = maxBlockSize
  result = true

proc deactivatePlugin*(host: var PluginHost; pluginIdx: int32) =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return
  let inst = addr host.plugins[pluginIdx]
  if inst.plugin == nil or not inst.isActive: return

  if inst.isProcessing:
    inst.plugin.stopProcessing(inst.plugin)
    inst.isProcessing = false
  inst.plugin.deactivate(inst.plugin)
  inst.isActive = false

proc unloadPlugin*(host: var PluginHost; pluginIdx: int32) =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return
  let inst = addr host.plugins[pluginIdx]

  if inst.plugin != nil:
    if inst.isProcessing:
      inst.plugin.stopProcessing(inst.plugin)
    if inst.isActive:
      inst.plugin.deactivate(inst.plugin)
    inst.plugin.destroy(inst.plugin)
    inst.plugin = nil

  if inst.library != nil:
    if inst.entry != nil and inst.entry.deinit != nil:
      inst.entry.deinit()
    unloadLib(inst.library)
    inst.library = nil

  host.plugins.delete(pluginIdx)

proc destroyPluginHost*(host: var PluginHost) =
  for i in countdown(host.plugins.len - 1, 0):
    host.unloadPlugin(int32(i))
  host.plugins = @[]

# ============================================================
# Extension Accessors  (main thread, convenience)
# ============================================================

proc getParamCount*(host: var PluginHost; pluginIdx: int32): uint32 =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return 0
  let ext = host.plugins[pluginIdx].paramsExt
  if ext == nil or ext.count == nil: return 0
  result = ext.count(host.plugins[pluginIdx].plugin)

proc getParamInfo*(host: var PluginHost; pluginIdx: int32;
                   paramIndex: uint32; info: var ClapParamInfo): bool =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return false
  let ext = host.plugins[pluginIdx].paramsExt
  if ext == nil or ext.getInfo == nil: return false
  result = ext.getInfo(host.plugins[pluginIdx].plugin, paramIndex, addr info)

proc getParamValue*(host: var PluginHost; pluginIdx: int32;
                    paramId: ClapId; value: var cdouble): bool =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return false
  let ext = host.plugins[pluginIdx].paramsExt
  if ext == nil or ext.getValue == nil: return false
  result = ext.getValue(host.plugins[pluginIdx].plugin, paramId, addr value)

proc getLatency*(host: var PluginHost; pluginIdx: int32): uint32 =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return 0
  let ext = host.plugins[pluginIdx].latencyExt
  if ext == nil or ext.get == nil: return 0
  result = ext.get(host.plugins[pluginIdx].plugin)

proc getTail*(host: var PluginHost; pluginIdx: int32): uint32 =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return 0
  let ext = host.plugins[pluginIdx].tailExt
  if ext == nil or ext.get == nil: return 0
  result = ext.get(host.plugins[pluginIdx].plugin)

proc saveState*(host: var PluginHost; pluginIdx: int32;
                stream: ptr ClapStream): bool =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return false
  let ext = host.plugins[pluginIdx].stateExt
  if ext == nil or ext.save == nil: return false
  result = ext.save(host.plugins[pluginIdx].plugin, stream)

proc loadState*(host: var PluginHost; pluginIdx: int32;
                stream: ptr ClapStream): bool =
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return false
  let ext = host.plugins[pluginIdx].stateExt
  if ext == nil or ext.load == nil: return false
  result = ext.load(host.plugins[pluginIdx].plugin, stream)

# ============================================================
# Adapter Lifecycle  (graph compile time — NOT audio thread)
# ============================================================

proc createClapAdapter*(host: var PluginHost;
                        pluginIdx: int32): ptr ClapNodeAdapter =
  ## Pre-allocate and wire a realtime-safe adapter.
  ## Called during Graph → Compile → CompiledPipeline.
  if pluginIdx < 0 or pluginIdx >= int32(host.plugins.len): return nil
  let inst = addr host.plugins[pluginIdx]
  if inst.plugin == nil: return nil

  let a = cast[ptr ClapNodeAdapter](allocShared0(sizeof(ClapNodeAdapter)))

  a.plugin        = inst.plugin
  a.audioPortsExt = inst.audioPortsExt
  a.notePortsExt  = inst.notePortsExt
  a.paramsExt     = inst.paramsExt
  a.stateExt      = inst.stateExt
  a.guiExt        = inst.guiExt
  a.latencyExt    = inst.latencyExt
  a.tailExt       = inst.tailExt

  # Wire event I/O vtables
  a.inEventsImpl  = ClapInputEvents(
    ctx:  a,
    size: inEventsSize,
    get:  inEventsGet)

  a.outEventsImpl = ClapOutputEvents(
    ctx:     a,
    tryPush: outEventsTryPush)

  result = a

proc destroyClapAdapter*(a: ptr ClapNodeAdapter) =
  if a != nil:
    deallocShared(a)

# ============================================================
# Pipeline Process  (audio thread — realtime safe)
# ============================================================
# Signature matches ProcessProc from node_interface.nim exactly.
# No allocation, no lock, no I/O, no exception.

proc processClapPluginNode*(ctx:   ptr NodeProcessContext;
                            audio: ptr NodeAudioPorts;
                            ctrl:  ptr NodeControlPorts;
                            events: ptr NodeEventPorts;
                            userData: pointer)
    {.cdecl, raises: [], gcsafe.} =

  let a = cast[ptr ClapNodeAdapter](userData)
  if a == nil or a.plugin == nil: return

  # ----------------------------------------------------------
  # 1. Map EUTERPIA audio buffers → CLAP audio buffers
  # ----------------------------------------------------------
  # PAudioBuffer is a pointer to channel data (see signal_types).
  # Each EUTERPIA buffer = 1 mono CLAP port.
  # TODO: group into stereo ports based on plugin audio-port config.

  let inCount  = min(audio.inputCount.int,  MaxAudioPorts)
  let outCount = min(audio.outputCount.int, MaxAudioPorts)

  for i in 0 ..< inCount:
    a.audioInChannelPtrs[i][0] = cast[ptr float32](audio.inputs[i])
    a.audioInBuffers[i] = ClapAudioBuffer(
      data32:       cast[ptr ptr float32](addr a.audioInChannelPtrs[i][0]),
      data64:       nil,
      channelCount: 1,
      latency:      0,
      constantMask: 0)

  for i in 0 ..< outCount:
    a.audioOutChannelPtrs[i][0] = cast[ptr float32](audio.outputs[i])
    a.audioOutBuffers[i] = ClapAudioBuffer(
      data32:       cast[ptr ptr float32](addr a.audioOutChannelPtrs[i][0]),
      data64:       nil,
      channelCount: 1,
      latency:      0,
      constantMask: 0)

  # ----------------------------------------------------------
  # 2. Reset event buffers for this block
  # ----------------------------------------------------------
  a.inEventCount    = 0
  a.inEventWritePos = 0
  a.outEventCount   = 0
  a.outEventWritePos = 0

  # TODO: translate EUTERPIA EventQueue → a.inEventBuf
  # for each event in events.inputs[0]:
  #   copy ABI-compatible struct into flat buffer, record offset

  # ----------------------------------------------------------
  # 3. Build CLAP transport event
  # ----------------------------------------------------------
  var tf: uint32 = 0

  a.transportEvent.header.size    = uint32(sizeof(ClapEventTransport))
  a.transportEvent.header.time    = 0
  a.transportEvent.header.spaceId = CLAP_CORE_EVENT_SPACE_ID
  a.transportEvent.header.`type`  = CLAP_EVT_TRANSPORT
  a.transportEvent.header.flags   = 0

  if pfTransportPlaying in ctx.flags:
    tf = tf or CLAP_TRANSPORT_IS_PLAYING

  a.transportEvent.songPosBeats   = int64(ctx.transport.beatPosition * ClapFixedPointScale)
  a.transportEvent.songPosSeconds = int64(ctx.timeInSeconds * ClapFixedPointScale)
  tf = tf or CLAP_TRANSPORT_HAS_BEATTIME or CLAP_TRANSPORT_HAS_SECONDS

  a.transportEvent.tempo   = ctx.transport.tempo
  a.transportEvent.tempoInc = 0.0
  tf = tf or CLAP_TRANSPORT_HAS_TEMPO

  a.transportEvent.tsigNum = uint16(ctx.transport.timeSigNum)
  a.transportEvent.tsigDen = uint16(ctx.transport.timeSigDen)
  tf = tf or CLAP_TRANSPORT_HAS_TIME_SIGNATURE

  if ctx.transport.cycleStart != ctx.transport.cycleEnd:
    tf = tf or CLAP_TRANSPORT_IS_LOOP_ACTIVE
    a.transportEvent.loopStartBeats   = int64(ctx.transport.cycleStart * ClapFixedPointScale)
    a.transportEvent.loopEndBeats     = int64(ctx.transport.cycleEnd   * ClapFixedPointScale)
    a.transportEvent.loopStartSeconds = 0
    a.transportEvent.loopEndSeconds   = 0

  a.transportEvent.barStart  = 0
  a.transportEvent.barNumber = 0
  a.transportEvent.transportFlags = tf

  # ----------------------------------------------------------
  # 4. Fill clap_process_t
  # ----------------------------------------------------------
  a.processStruct.steadyTime       = ctx.samplePosition
  a.processStruct.framesCount      = uint32(ctx.blockSize)
  a.processStruct.transport        = addr a.transportEvent
  a.processStruct.audioInputs      = if inCount  > 0: addr a.audioInBuffers[0]  else: nil
  a.processStruct.audioOutputs     = if outCount > 0: addr a.audioOutBuffers[0] else: nil
  a.processStruct.audioInputsCount  = uint32(inCount)
  a.processStruct.audioOutputsCount = uint32(outCount)
  a.processStruct.inEvents         = addr a.inEventsImpl
  a.processStruct.outEvents        = addr a.outEventsImpl

  # ----------------------------------------------------------
  # 5. Call CLAP plugin.process()
  # ----------------------------------------------------------
  let status = a.plugin.process(a.plugin, addr a.processStruct)

  # ----------------------------------------------------------
  # 6. Translate output events back to EUTERPIA
  # ----------------------------------------------------------
  # TODO: iterate a.outEventBuf via outEventOffsets
  # and push into events.outputs[0]

  discard status