# adapters/lilv/lilv_plugin_backend.nim
#
# LV2-хостинг через Lilv за контрактом `core/plugin_api.nim` (issue #39).
#
#   Core -> plugin_api -> adapters/lilv -> liblilv (LV2)
#
# Это единственный файл дерева, который знает про LV2/Lilv (MANIFEST §8,
# §41, §42). Core видит только таблицу методов `PluginApi`.
#
# Лицензия: Lilv — ISC, совместим с проприетарным ядром (в отличие от VST3,
# MANIFEST §104). Линковка — ДИНАМИЧЕСКАЯ через `lazy_dynlib` (issue #267):
# нет liblilv — `peUnavailable`, а не падение до `main()`. Имя библиотеки
# переопределяется `EUTERPIA_LILV_LIB`.
#
# Что поддержано:
#   * перечисление плагинов бандла (`pluginCount`/`pluginInfo`);
#   * инстанс: instantiate/activate/deactivate/reset/process/destroy;
#   * аудио-порты (planar) и control-порты (float32) — параметры;
#   * latency-порт (`lv2:latency`) -> pluginLatencyFrames (идёт в PDC);
#   * paramGet/paramSet/paramFlush (control-path; в RT не аллоцирует).
#
# Что НЕ поддержано и почему честно отказывает:
#   * LV2 Atom/MIDI-порты: нужен полный LV2_URID_Map и atom-forge/sequence.
#     Такие порты не подключаются (ограничение адаптера, не Core);
#   * состояние (stateSave/stateLoad): Lilv требует LV2_URID_Map; адаптер
#     возвращает -1/false — вызывающий видит отказ, а не тихо битый блоб.
#
# MANIFEST §8, §40, §41, §42, §102.

import std/strutils

import plugin_api
import logger
import node_interface
import signal_types
import lazy_dynlib

{.push raises: [].}

const
  LilvBackendName* = "lv2"

  LilvLibDefault =
    when defined(windows): "liblilv-0.dll"
    elif defined(macosx): "liblilv-0.dylib"
    else: "liblilv-0.so"

  LilvLibEnv = "EUTERPIA_LILV_LIB"

  MaxLilvParams* = 64
  MaxLilvAudioPorts* = 8
    ## Совпадает с `MaxAudioPorts` из node_interface.

  LilvMaxPorts = 64
  LilvNoPort = high(uint32)

type
  LilvWorld = object
  LilvPlugins = object
  LilvIter = object
  LilvPlugin = object
  LilvPluginClass = object
  LilvPort = object
  LilvNode = object
  LilvInstance = object

  LilvWorldPtr* = ptr LilvWorld
  LilvPluginsPtr = ptr LilvPlugins
  LilvIterPtr = ptr LilvIter
  LilvPluginPtr = ptr LilvPlugin
  LilvPluginClassPtr = ptr LilvPluginClass
  LilvPortPtr = ptr LilvPort
  LilvNodePtr = ptr LilvNode
  LilvInstancePtr = ptr LilvInstance

  # --- C ABI liblilv (только используемые символы) ---
  NewWorldProc = proc(): LilvWorldPtr {.cdecl, raises: [], gcsafe.}
  FreeWorldProc = proc(w: LilvWorldPtr) {.cdecl, raises: [], gcsafe.}
  WorldLoadAllProc = proc(w: LilvWorldPtr) {.cdecl, raises: [], gcsafe.}
  WorldLoadBundleProc = proc(w: LilvWorldPtr; uri: LilvNodePtr)
    {.cdecl, raises: [], gcsafe.}
  WorldAllPluginsProc = proc(w: LilvWorldPtr): LilvPluginsPtr
    {.cdecl, raises: [], gcsafe.}
  NewUriProc = proc(w: LilvWorldPtr; uri: cstring): LilvNodePtr
    {.cdecl, raises: [], gcsafe.}
  NewFileUriProc = proc(w: LilvWorldPtr; host: cstring; path: cstring): LilvNodePtr
    {.cdecl, raises: [], gcsafe.}
  NodeFreeProc = proc(n: LilvNodePtr) {.cdecl, raises: [], gcsafe.}
  NodeAsStringProc = proc(n: LilvNodePtr): cstring {.cdecl, raises: [], gcsafe.}
  PluginsBeginProc = proc(p: LilvPluginsPtr): LilvIterPtr
    {.cdecl, raises: [], gcsafe.}
  PluginsGetProc = proc(p: LilvPluginsPtr; it: LilvIterPtr): LilvPluginPtr
    {.cdecl, raises: [], gcsafe.}
  PluginsNextProc = proc(p: LilvPluginsPtr; it: LilvIterPtr): LilvIterPtr
    {.cdecl, raises: [], gcsafe.}
  PluginsSizeProc = proc(p: LilvPluginsPtr): cuint
    {.cdecl, raises: [], gcsafe.}
  PluginGetUriProc = proc(p: LilvPluginPtr): LilvNodePtr
    {.cdecl, raises: [], gcsafe.}
  PluginGetNameProc = proc(p: LilvPluginPtr): LilvNodePtr
    {.cdecl, raises: [], gcsafe.}
  PluginGetAuthorProc = proc(p: LilvPluginPtr): LilvNodePtr
    {.cdecl, raises: [], gcsafe.}
  PluginGetClassProc = proc(p: LilvPluginPtr): LilvPluginClassPtr
    {.cdecl, raises: [], gcsafe.}
  PluginClassUriProc = proc(c: LilvPluginClassPtr): LilvNodePtr
    {.cdecl, raises: [], gcsafe.}
  PluginNumPortsProc = proc(p: LilvPluginPtr): uint32
    {.cdecl, raises: [], gcsafe.}
  PluginPortByIndexProc = proc(p: LilvPluginPtr; index: uint32): LilvPortPtr
    {.cdecl, raises: [], gcsafe.}
  PortGetNameProc = proc(p: LilvPluginPtr; port: LilvPortPtr): LilvNodePtr
    {.cdecl, raises: [], gcsafe.}
  PortIsAProc = proc(p: LilvPluginPtr; port: LilvPortPtr; cls: LilvNodePtr): bool
    {.cdecl, raises: [], gcsafe.}
  PortHasPropertyProc = proc(p: LilvPluginPtr; port: LilvPortPtr;
    prop: LilvNodePtr): bool {.cdecl, raises: [], gcsafe.}
  PortGetRangeProc = proc(p: LilvPluginPtr; port: LilvPortPtr;
    dflt, mn, mx: ptr float32) {.cdecl, raises: [], gcsafe.}
  PluginLatencyPortProc = proc(p: LilvPluginPtr): uint32
    {.cdecl, raises: [], gcsafe.}
  InstantiateProc = proc(p: LilvPluginPtr; sampleRate: cdouble;
    features: pointer): LilvInstancePtr {.cdecl, raises: [], gcsafe.}
  InstanceFreeProc = proc(i: LilvInstancePtr) {.cdecl, raises: [], gcsafe.}
  InstanceActivateProc = proc(i: LilvInstancePtr) {.cdecl, raises: [], gcsafe.}
  InstanceDeactivateProc = proc(i: LilvInstancePtr) {.cdecl, raises: [], gcsafe.}
  InstanceConnectProc = proc(i: LilvInstancePtr; portIndex: uint32;
    data: pointer) {.cdecl, raises: [], gcsafe.}
  InstanceRunProc = proc(i: LilvInstancePtr; frames: uint32)
    {.cdecl, raises: [], gcsafe.}

var
  lilvLib: LazyLibrary
  symWorldNew: NewWorldProc
  symWorldFree: FreeWorldProc
  symWorldLoadAll: WorldLoadAllProc
  symWorldLoadBundle: WorldLoadBundleProc
  symWorldAllPlugins: WorldAllPluginsProc
  symNewUri: NewUriProc
  symNewFileUri: NewFileUriProc
  symNodeFree: NodeFreeProc
  symNodeAsString: NodeAsStringProc
  symPluginsBegin: PluginsBeginProc
  symPluginsGet: PluginsGetProc
  symPluginsNext: PluginsNextProc
  symPluginsSize: PluginsSizeProc
  symPluginGetUri: PluginGetUriProc
  symPluginGetName: PluginGetNameProc
  symPluginGetAuthor: PluginGetAuthorProc
  symPluginGetClass: PluginGetClassProc
  symPluginClassUri: PluginClassUriProc
  symPluginNumPorts: PluginNumPortsProc
  symPluginPortByIndex: PluginPortByIndexProc
  symPortGetName: PortGetNameProc
  symPortIsA: PortIsAProc
  symPortHasProperty: PortHasPropertyProc
  symPortGetRange: PortGetRangeProc
  symPluginLatencyPort: PluginLatencyPortProc
  symInstantiate: InstantiateProc
  symInstanceFree: InstanceFreeProc
  symInstanceActivate: InstanceActivateProc
  symInstanceDeactivate: InstanceDeactivateProc
  symInstanceConnect: InstanceConnectProc
  symInstanceRun: InstanceRunProc

proc loadLilv(): bool =
  ## Control-path: загрузка и резолв символов. Повторный вызов — no-op.
  if not lilvLib.handle.isNil:
    return true
  if not openLibrary(lilvLib):
    return false
  result =
    symPtr(lilvLib, "lilv_world_new", symWorldNew) and
    symPtr(lilvLib, "lilv_world_free", symWorldFree) and
    symPtr(lilvLib, "lilv_world_load_all", symWorldLoadAll) and
    symPtr(lilvLib, "lilv_world_load_bundle", symWorldLoadBundle) and
    symPtr(lilvLib, "lilv_world_get_all_plugins", symWorldAllPlugins) and
    symPtr(lilvLib, "lilv_new_uri", symNewUri) and
    symPtr(lilvLib, "lilv_new_file_uri", symNewFileUri) and
    symPtr(lilvLib, "lilv_node_free", symNodeFree) and
    symPtr(lilvLib, "lilv_node_as_string", symNodeAsString) and
    symPtr(lilvLib, "lilv_plugins_begin", symPluginsBegin) and
    symPtr(lilvLib, "lilv_plugins_get", symPluginsGet) and
    symPtr(lilvLib, "lilv_plugins_next", symPluginsNext) and
    symPtr(lilvLib, "lilv_plugins_size", symPluginsSize) and
    symPtr(lilvLib, "lilv_plugin_get_uri", symPluginGetUri) and
    symPtr(lilvLib, "lilv_plugin_get_name", symPluginGetName) and
    symPtr(lilvLib, "lilv_plugin_get_author_name", symPluginGetAuthor) and
    symPtr(lilvLib, "lilv_plugin_get_class", symPluginGetClass) and
    symPtr(lilvLib, "lilv_plugin_class_get_uri", symPluginClassUri) and
    symPtr(lilvLib, "lilv_plugin_get_num_ports", symPluginNumPorts) and
    symPtr(lilvLib, "lilv_plugin_get_port_by_index", symPluginPortByIndex) and
    symPtr(lilvLib, "lilv_port_get_name", symPortGetName) and
    symPtr(lilvLib, "lilv_port_is_a", symPortIsA) and
    symPtr(lilvLib, "lilv_port_has_property", symPortHasProperty) and
    symPtr(lilvLib, "lilv_port_get_range", symPortGetRange) and
    symPtr(lilvLib, "lilv_plugin_get_latency_port_index", symPluginLatencyPort) and
    symPtr(lilvLib, "lilv_plugin_instantiate", symInstantiate) and
    symPtr(lilvLib, "lilv_instance_free", symInstanceFree) and
    symPtr(lilvLib, "lilv_instance_activate", symInstanceActivate) and
    symPtr(lilvLib, "lilv_instance_deactivate", symInstanceDeactivate) and
    symPtr(lilvLib, "lilv_instance_connect_port", symInstanceConnect) and
    symPtr(lilvLib, "lilv_instance_run", symInstanceRun)

# ==============================================================================
# Состояние инстанса
# ==============================================================================

const
  PortNone = 0'u8
  PortAudioIn = 1'u8
  PortAudioOut = 2'u8
  PortControlIn = 3'u8
  PortControlOut = 4'u8

type
  LilvSlot = object
    ## Состояние одного инстанса. POD: живёт в shared-куче, в audio-поток
    ## попадает указатель.
    world: LilvWorldPtr
    plugin: LilvPluginPtr
    inst: LilvInstancePtr
    active: bool
    sampleRate: float64
    portCount: uint32
    portKind: array[LilvMaxPorts, uint8]
    audioInPort: array[MaxLilvAudioPorts, uint32]
    audioOutPort: array[MaxLilvAudioPorts, uint32]
    audioInCount: int32
    audioOutCount: int32
    ctrlInPort: array[MaxLilvParams, uint32]
    ctrlOutPort: array[MaxLilvParams, uint32]
    ctrlInCount: int32
    ctrlOutCount: int32
    ctrlValue: array[MaxLilvParams, float32]
    ctrlOutValue: array[MaxLilvParams, float32]
    latencyPort: uint32
    latencyValue: float32
    scratch: array[MaxAudioChannels, array[signal_types.MaxBlockSize, float32]]
      ## Соединение аудио-портов до первого `process`: LV2 требует
      ## подключить порты ДО activate, а реальные буферы графа появляются
      ## только в блоке.

  LilvBackend = object
    log: Logger
    initialized: bool

proc implOf(api: ptr PluginApi): ptr LilvBackend {.inline.} =
  if api.isNil: nil else: cast[ptr LilvBackend](api.impl)

proc slotOf(handle: PluginHandle): ptr LilvSlot {.inline.} =
  if handle.isNil: nil else: cast[ptr LilvSlot](handle)

proc uriNode(world: LilvWorldPtr; uri: string): LilvNodePtr =
  symNewUri(world, cstring(uri))

proc strOf(node: LilvNodePtr): string =
  if node.isNil:
    return ""
  let p = symNodeAsString(node)
  if p.isNil: "" else: $p

proc categoryOf(plugin: LilvPluginPtr): PluginCategory =
  let cls = symPluginGetClass(plugin)
  if cls.isNil:
    return pcUnknown
  let uri = strOf(symPluginClassUri(cls))
  if uri.len == 0:
    return pcUnknown
  if uri.endsWith("InstrumentPlugin") or uri.endsWith("GeneratorPlugin"):
    return pcInstrument
  if uri.endsWith("AnalyserPlugin"):
    return pcAnalyzer
  if uri.endsWith("Plugin") or uri.endsWith("FilterPlugin") or
     uri.endsWith("DelayPlugin") or uri.endsWith("ReverbPlugin") or
     uri.endsWith("DistortionPlugin") or uri.endsWith("WaveshaperPlugin") or
     uri.endsWith("DynamicsPlugin") or uri.endsWith("AmplifierPlugin") or
     uri.endsWith("MixerPlugin"):
    return pcEffect
  pcUnknown

proc pluginAt(world: LilvWorldPtr; path: string; index: int32): LilvPluginPtr =
  ## Загрузить бандл в мир и вернуть плагин по индексу.
  if world.isNil or path.len == 0 or index < 0:
    return nil
  let uri = symNewFileUri(world, nil, cstring(path))
  if uri.isNil:
    return nil
  symWorldLoadBundle(world, uri)
  symNodeFree(uri)
  let plugins = symWorldAllPlugins(world)
  if plugins.isNil:
    return nil
  var it = symPluginsBegin(plugins)
  var i: int32 = 0
  while not it.isNil:
    if i == index:
      return symPluginsGet(plugins, it)
    it = symPluginsNext(plugins, it)
    inc i
  nil

# ==============================================================================
# Таблица методов
# ==============================================================================

proc lilvInit(api: ptr PluginApi; log: ptr Logger): PluginError
    {.cdecl, raises: [], gcsafe.} =
  let b = implOf(api)
  if b.isNil:
    return peUnavailable
  if not log.isNil:
    b.log = log[]
  if b.initialized:
    return peOk
  if not loadLilv():
    logError(addr b.log, "lv2: " & libraryError(lilvLib))
    return peUnavailable
  b.initialized = true
  peOk

proc lilvShutdown(api: ptr PluginApi) {.cdecl, raises: [], gcsafe.} =
  let b = implOf(api)
  if b.isNil:
    return
  b.initialized = false

proc lilvPluginCount(api: ptr PluginApi; path: cstring): int32
    {.cdecl, raises: [], gcsafe.} =
  let b = implOf(api)
  if b.isNil or not b.initialized or path.isNil:
    return -1
  let world = symWorldNew()
  if world.isNil:
    return -1
  defer: symWorldFree(world)
  let uri = symNewFileUri(world, nil, path)
  if uri.isNil:
    return -1
  symWorldLoadBundle(world, uri)
  symNodeFree(uri)
  let plugins = symWorldAllPlugins(world)
  if plugins.isNil:
    return 0
  int32(symPluginsSize(plugins))

proc fillPortMap(slot: ptr LilvSlot) =
  ## Разложить порты плагина по видам. Atom/MIDI-порты остаются `PortNone`:
  ## им нужен URID/atom-forge, который адаптер не обещает.
  if slot.isNil or slot.plugin.isNil:
    return
  let audioPort = uriNode(slot.world, "http://lv2plug.in/ns/lv2core#AudioPort")
  let controlPort = uriNode(slot.world, "http://lv2plug.in/ns/lv2core#ControlPort")
  let inputPort = uriNode(slot.world, "http://lv2plug.in/ns/lv2core#InputPort")
  let outputPort = uriNode(slot.world, "http://lv2plug.in/ns/lv2core#OutputPort")
  defer:
    for n in [audioPort, controlPort, inputPort, outputPort]:
      if not n.isNil:
        symNodeFree(n)

  var i: uint32 = 0
  while i < slot.portCount and i < uint32(LilvMaxPorts):
    let port = symPluginPortByIndex(slot.plugin, i)
    if not port.isNil:
      let isInput = symPortIsA(slot.plugin, port, inputPort)
      let isOutput = symPortIsA(slot.plugin, port, outputPort)
      if symPortIsA(slot.plugin, port, audioPort):
        if isInput and slot.audioInCount < int32(MaxLilvAudioPorts):
          slot.portKind[i] = PortAudioIn
          slot.audioInPort[slot.audioInCount] = i
          inc slot.audioInCount
        elif isOutput and slot.audioOutCount < int32(MaxLilvAudioPorts):
          slot.portKind[i] = PortAudioOut
          slot.audioOutPort[slot.audioOutCount] = i
          inc slot.audioOutCount
      elif symPortIsA(slot.plugin, port, controlPort):
        if isInput and slot.ctrlInCount < int32(MaxLilvParams):
          slot.portKind[i] = PortControlIn
          slot.ctrlInPort[slot.ctrlInCount] = i
          var dflt = 0.0'f32
          var mn = 0.0'f32
          var mx = 1.0'f32
          symPortGetRange(slot.plugin, port, addr dflt, addr mn, addr mx)
          slot.ctrlValue[slot.ctrlInCount] = dflt
          inc slot.ctrlInCount
        elif isOutput and slot.ctrlOutCount < int32(MaxLilvParams):
          slot.portKind[i] = PortControlOut
          slot.ctrlOutPort[slot.ctrlOutCount] = i
          inc slot.ctrlOutCount
    inc i

  let lat = symPluginLatencyPort(slot.plugin)
  slot.latencyPort = if lat < slot.portCount: lat else: LilvNoPort

proc connectPorts(slot: ptr LilvSlot) =
  ## Подключить порты к стабильным адресам слота. Аудио-порты затем
  ## переподключаются в `process` (буферы графа меняются).
  if slot.isNil or slot.inst.isNil:
    return
  for i in 0 ..< int(slot.audioInCount):
    symInstanceConnect(slot.inst, slot.audioInPort[i],
      addr slot.scratch[i mod MaxAudioChannels][0])
  for i in 0 ..< int(slot.ctrlInCount):
    symInstanceConnect(slot.inst, slot.ctrlInPort[i], addr slot.ctrlValue[i])
  for i in 0 ..< int(slot.ctrlOutCount):
    symInstanceConnect(slot.inst, slot.ctrlOutPort[i], addr slot.ctrlOutValue[i])
  if slot.latencyPort != LilvNoPort:
    symInstanceConnect(slot.inst, slot.latencyPort, addr slot.latencyValue)

proc lilvPluginInfo(
  api: ptr PluginApi;
  path: cstring;
  index: int32;
  info: var PluginInfo
): bool {.cdecl, raises: [], gcsafe.} =
  let b = implOf(api)
  if b.isNil or not b.initialized or path.isNil:
    return false
  let world = symWorldNew()
  if world.isNil:
    return false
  defer: symWorldFree(world)
  let plugin = pluginAt(world, $path, index)
  if plugin.isNil:
    return false

  info = PluginInfo()
  info.id = strOf(symPluginGetUri(plugin))
  info.name = strOf(symPluginGetName(plugin))
  info.vendor = strOf(symPluginGetAuthor(plugin))
  info.version = ""
  info.category = categoryOf(plugin)
  info.hasState = false   # LV2-состояние требует LV2_URID_Map (см. шапку)
  info.hasGui = false
  info.reportedLatency = 0

  var probe = LilvSlot(world: world, plugin: plugin,
                       portCount: symPluginNumPorts(plugin))
  fillPortMap(addr probe)
  info.audioInCount = probe.audioInCount
  info.audioOutCount = probe.audioOutCount
  info.paramCount = probe.ctrlInCount
  true

proc lilvInstantiate(
  api: ptr PluginApi;
  path: cstring;
  index: int32
): PluginHandle {.cdecl, raises: [], gcsafe.} =
  let b = implOf(api)
  if b.isNil or not b.initialized or path.isNil:
    return nil
  let slot = cast[ptr LilvSlot](allocShared0(sizeof(LilvSlot)))
  if slot.isNil:
    return nil
  slot.world = symWorldNew()
  if slot.world.isNil:
    deallocShared(cast[pointer](slot))
    return nil
  slot.plugin = pluginAt(slot.world, $path, index)
  if slot.plugin.isNil:
    symWorldFree(slot.world)
    deallocShared(cast[pointer](slot))
    return nil
  slot.portCount = symPluginNumPorts(slot.plugin)
  slot.latencyPort = LilvNoPort
  fillPortMap(slot)
  slot.inst = symInstantiate(slot.plugin, 48000.0, nil)
  if slot.inst.isNil:
    symWorldFree(slot.world)
    deallocShared(cast[pointer](slot))
    return nil
  cast[PluginHandle](slot)

proc lilvDestroy(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return
  if slot.active and not slot.inst.isNil:
    symInstanceDeactivate(slot.inst)
  if not slot.inst.isNil:
    symInstanceFree(slot.inst)
  if not slot.world.isNil:
    symWorldFree(slot.world)
  deallocShared(cast[pointer](slot))

proc lilvActivate(
  api: ptr PluginApi;
  handle: PluginHandle;
  sampleRate: float64;
  maxBlock: int32;
  audioIn: int32;
  audioOut: int32
): PluginError {.cdecl, raises: [], gcsafe.} =
  discard maxBlock
  discard audioIn
  discard audioOut
  let slot = slotOf(handle)
  if slot.isNil or slot.inst.isNil:
    return peNotActive
  slot.sampleRate = sampleRate
  # Порты подключаются до activate: этого требует LV2-спецификация.
  connectPorts(slot)
  symInstanceActivate(slot.inst)
  slot.active = true
  peOk

proc lilvDeactivate(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or slot.inst.isNil or not slot.active:
    return
  symInstanceDeactivate(slot.inst)
  slot.active = false

proc lilvReset(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  ## Сброс = deactivate + activate: отдельного reset в LV2 нет.
  let slot = slotOf(handle)
  if slot.isNil or slot.inst.isNil:
    return
  if slot.active:
    symInstanceDeactivate(slot.inst)
  symInstanceActivate(slot.inst)
  slot.active = true

proc lilvProcess(
  api: ptr PluginApi;
  handle: PluginHandle;
  ctx: ptr NodeProcessContext;
  audio: ptr NodeAudioPorts;
  inEvents: ptr EventQueue;
  outEvents: ptr EventQueue
): PluginProcessStatus {.cdecl, raises: [], gcsafe.} =
  ## Realtime-path: без аллокаций, локов и исключений. Atom/MIDI-события
  ## не передаются (см. ограничения в шапке).
  discard inEvents
  discard outEvents
  let slot = slotOf(handle)
  if slot.isNil or slot.inst.isNil or not slot.active or ctx.isNil:
    return ppsError
  let frames = if ctx.blockSize > 0: ctx.blockSize else: 1

  # Аудио-порты: буферы графа меняются от блока к блоку (мастер пишется
  # напрямую в драйвер), поэтому переподключаем их здесь.
  if not audio.isNil:
    for i in 0 ..< int(slot.audioInCount):
      var data: pointer = addr slot.scratch[i mod MaxAudioChannels][0]
      if i < audio.inputCount and not audio.inputs[i].isNil and
         not audio.inputs[i].data.isNil:
        data = cast[pointer](addr audio.inputs[i].data[0])
      symInstanceConnect(slot.inst, slot.audioInPort[i], data)
    for i in 0 ..< int(slot.audioOutCount):
      var data: pointer = addr slot.scratch[i mod MaxAudioChannels][0]
      if i < audio.outputCount and not audio.outputs[i].isNil and
         not audio.outputs[i].data.isNil:
        data = cast[pointer](addr audio.outputs[i].data[0])
      symInstanceConnect(slot.inst, slot.audioOutPort[i], data)

  symInstanceRun(slot.inst, uint32(frames))
  ppsContinue

proc lilvParamCount(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return 0
  slot.ctrlInCount

proc lilvParamInfo(api: ptr PluginApi; handle: PluginHandle; index: int32;
                   info: var PluginParamInfo): bool
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or index < 0 or index >= slot.ctrlInCount:
    return false
  let portIdx = slot.ctrlInPort[index]
  let port = symPluginPortByIndex(slot.plugin, portIdx)
  if port.isNil:
    return false
  info = PluginParamInfo(id: portIdx, flags: {ppfAutomatable})
  info.name = strOf(symPortGetName(slot.plugin, port))
  var dflt = 0.0'f32
  var mn = 0.0'f32
  var mx = 1.0'f32
  symPortGetRange(slot.plugin, port, addr dflt, addr mn, addr mx)
  info.defaultValue = float64(dflt)
  info.minValue = float64(mn)
  info.maxValue = float64(mx)
  info.step = 0.0

  # Дискретные/целочисленные порты помечаются флагами — по ним UI и
  # автоматизация выбирают шаг.
  let integer = uriNode(slot.world, "http://lv2plug.in/ns/lv2core#integer")
  let toggled = uriNode(slot.world, "http://lv2plug.in/ns/lv2core#toggled")
  let enumeration = uriNode(slot.world,
    "http://lv2plug.in/ns/lv2core#enumeration")
  defer:
    for n in [integer, toggled, enumeration]:
      if not n.isNil:
        symNodeFree(n)
  if not toggled.isNil and symPortHasProperty(slot.plugin, port, toggled):
    info.flags.incl(ppfInteger)
    info.flags.incl(ppfChoice)
    info.step = 1.0
  elif not enumeration.isNil and
       symPortHasProperty(slot.plugin, port, enumeration):
    info.flags.incl(ppfChoice)
    info.step = 1.0
  elif not integer.isNil and symPortHasProperty(slot.plugin, port, integer):
    info.flags.incl(ppfInteger)
    info.step = 1.0
  true

proc lilvParamGet(api: ptr PluginApi; handle: PluginHandle;
                  paramId: uint32): float64 {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return 0.0
  for i in 0 ..< int(slot.ctrlInCount):
    if slot.ctrlInPort[i] == paramId:
      return float64(slot.ctrlValue[i])
  0.0

proc lilvParamSet(api: ptr PluginApi; handle: PluginHandle; paramId: uint32;
                  value: float64; normalized: bool): bool
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return false
  for i in 0 ..< int(slot.ctrlInCount):
    if slot.ctrlInPort[i] == paramId:
      let port = symPluginPortByIndex(slot.plugin, paramId)
      var dflt = 0.0'f32
      var mn = 0.0'f32
      var mx = 1.0'f32
      if not port.isNil:
        symPortGetRange(slot.plugin, port, addr dflt, addr mn, addr mx)
      var v = float32(value)
      if normalized:
        v = mn + (mx - mn) * float32(value)
      if v < mn: v = mn
      if v > mx: v = mx
      slot.ctrlValue[i] = v
      return true
  false

proc lilvParamFlush(api: ptr PluginApi; handle: PluginHandle;
                    inEvents: ptr EventQueue;
                    outEvents: ptr EventQueue): bool
    {.cdecl, raises: [], gcsafe.} =
  ## Управляющие значения LV2 читаются плагином из подключённых портов на
  ## каждом `run` — отдельного flush в протоколе нет.
  discard inEvents
  discard outEvents
  slotOf(handle) != nil

proc lilvStateSave(api: ptr PluginApi; handle: PluginHandle;
                   dst: pointer; maxLen: int): int
    {.cdecl, raises: [], gcsafe.} =
  ## LV2-состояние требует LV2_URID_Map: честный отказ, а не пустой блоб.
  discard dst
  discard maxLen
  -1

proc lilvStateLoad(api: ptr PluginApi; handle: PluginHandle;
                   src: pointer; len: int): bool
    {.cdecl, raises: [], gcsafe.} =
  discard src
  discard len
  false

proc lilvLatency(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or slot.latencyPort == LilvNoPort:
    return 0
  let v = slot.latencyValue
  if v != v or v < 0.0f:
    return 0
  int32(v + 0.5f)

proc lilvOnMainThread(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  discard

# ==============================================================================
# Создание / уничтожение (control-path)
# ==============================================================================

proc createLilvPluginApi*(log: Logger = silentLogger()): ptr PluginApi =
  ## Собрать адаптер в shared-куче. Нет liblilv — `pluginInit` вернёт
  ## `peUnavailable`, процесс жив (issue #267).
  let api = cast[ptr PluginApi](allocShared0(sizeof(PluginApi)))
  if api.isNil:
    return nil
  let b = cast[ptr LilvBackend](allocShared0(sizeof(LilvBackend)))
  if b.isNil:
    deallocShared(cast[pointer](api))
    return nil
  b.log = log
  b.initialized = false
  lilvLib.setLibraryName(resolveLibraryName(LilvLibEnv, LilvLibDefault))

  api.backendName = cstring(LilvBackendName)
  api.impl = cast[pointer](b)
  api.init = lilvInit
  api.shutdown = lilvShutdown
  api.pluginCount = lilvPluginCount
  api.pluginInfo = lilvPluginInfo
  api.instantiate = lilvInstantiate
  api.destroy = lilvDestroy
  api.activate = lilvActivate
  api.deactivate = lilvDeactivate
  api.reset = lilvReset
  api.process = lilvProcess
  api.countParams = lilvParamCount
  api.paramInfo = lilvParamInfo
  api.paramGet = lilvParamGet
  api.paramSet = lilvParamSet
  api.paramFlush = lilvParamFlush
  api.stateSave = lilvStateSave
  api.stateLoad = lilvStateLoad
  api.latencyFrames = lilvLatency
  api.onMainThread = lilvOnMainThread
  api

proc destroyLilvPluginApi*(api: ptr PluginApi) =
  if api.isNil:
    return
  pluginShutdown(api)
  let b = implOf(api)
  if not b.isNil:
    api.impl = nil
    deallocShared(cast[pointer](b))
  deallocShared(cast[pointer](api))

{.pop.}
