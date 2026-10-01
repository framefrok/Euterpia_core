# adapters/clap/clap_plugin_backend.nim
#
# CLAP-адаптер за контрактом `core/plugin_api.nim` (issue #29).
#
#   Core -> plugin_api -> adapters/clap -> clap_host.nim (CLAP 1.2 ABI)
#
# Здесь живёт ВСЁ, что знает про CLAP: загрузка `.clap`, ABI-структуры,
# конвертация `EventQueue` <-> CLAP-события. Core об этом не знает.
#
# Реализация построена на низкоуровневом `clap_host.nim` и держит
# состояние инстанса в POD-объекте (`ClapPluginInstance`), поэтому слот
# можно размещать в shared-куче: в audio-поток попадает указатель,
# которым владеет адаптер, без GC-полей.
#
# Границы объёма:
#   * базовая жизнь плагина (load / enumerate / instantiate / activate /
#     process / deactivate / destroy) — здесь;
#   * host-side расширения CLAP (clap.host/params|state|gui|thread-check),
#     т.е. то, что плагин ВЫЗЫВАЕТ у хоста, — issue #6;
#   * доступ к параметрам плагина через `clap.params` появится вместе с
#     host-расширениями (методы param* сейчас возвращают пустой список).
#
# MANIFEST §8, §40, §41, §42.

import std/dynlib
import plugin_api
import signal_types
import node_interface
import clap_host
import clap_host_extensions

{.push raises: [].}

const
  ClapBackendName* = "clap"

type
  ClapSlot = object
    ## Состояние одного инстанса. POD; размещается в shared-куче.
    inst: ClapPluginInstance
    ## host-side состояние (clap.host/params|state|gui|thread-check|latency).
    hostCtx: ptr ClapHostContext
    audioThreadMarked: bool
    maxBlock: int32
    audioIn: int32
    audioOut: int32

  ClapBackendImpl = object
    initCalls: int32

proc implOf(api: ptr PluginApi): ptr ClapBackendImpl {.inline.} =
  if api.isNil: nil else: cast[ptr ClapBackendImpl](api.impl)

proc slotOf(handle: PluginHandle): ptr ClapSlot {.inline.} =
  cast[ptr ClapSlot](handle)

proc statusToPlugin(status: int32): PluginProcessStatus {.inline.} =
  case status
  of ClapProcessContinue: ppsContinue
  of ClapProcessTail:     ppsTail
  of ClapProcessSleep:    ppsSleep
  else:                   ppsError

proc safeStr(s: cstring): string {.inline.} =
  if s.isNil: "" else: $s

# ----------------------------------------------------------------------------
# Загрузка модуля и фабрика (control-path)
# ----------------------------------------------------------------------------

type OpenedModule = object
  lib: LibHandle
  entry: ptr ClapPluginEntry

proc openModule(path: cstring): OpenedModule =
  ## Открывает .clap и вызывает entry.init(). Владелец — вызывающий;
  ## закрывать через `closeModule`.
  result.lib = loadLib($path)
  if result.lib.isNil:
    return
  let sym = symAddr(result.lib, "clap_entry")
  if sym.isNil:
    unloadLib(result.lib)
    result.lib = nil
    return
  result.entry = cast[ptr ClapPluginEntry](sym)
  if result.entry.clapVersion.major != ClapVersionMajor:
    unloadLib(result.lib)
    result.lib = nil
    return
  if not result.entry.init(path):
    unloadLib(result.lib)
    result.lib = nil
    return

proc closeModule(m: var OpenedModule) =
  if not m.lib.isNil:
    if not m.entry.isNil:
      m.entry.deinit()
    unloadLib(m.lib)
  m.lib = nil
  m.entry = nil

proc factoryOf(m: OpenedModule): ptr ClapPluginFactory =
  if m.entry.isNil:
    return nil
  let f = m.entry.getFactory(ClapPluginFactoryId)
  if f.isNil: nil else: cast[ptr ClapPluginFactory](f)

# ----------------------------------------------------------------------------
# Таблица методов PluginApi
# ----------------------------------------------------------------------------

proc clapInit(api: ptr PluginApi; log: ptr Logger): PluginError
    {.cdecl, raises: [], gcsafe.} =
  let impl = implOf(api)
  if impl.isNil:
    return peUnavailable
  impl.initCalls = 0
  peOk

proc clapShutdown(api: ptr PluginApi) {.cdecl, raises: [], gcsafe.} =
  discard

proc clapPluginCount(api: ptr PluginApi; path: cstring): int32
    {.cdecl, raises: [], gcsafe.} =
  if implOf(api).isNil or path.isNil:
    return -1
  var m = openModule(path)
  if m.lib.isNil:
    return 0
  let f = factoryOf(m)
  let n = if f.isNil: 0'i32 else: int32(f.getPluginCount(f))
  m.closeModule()
  n

proc clapPluginInfo(
  api: ptr PluginApi;
  path: cstring;
  index: int32;
  info: var PluginInfo
): bool {.cdecl, raises: [], gcsafe.} =
  if implOf(api).isNil or path.isNil or index < 0:
    return false
  var m = openModule(path)
  if m.lib.isNil:
    return false
  defer: m.closeModule()
  let f = factoryOf(m)
  if f.isNil:
    return false
  let desc = f.getPluginDescriptor(f, uint32(index))
  if desc.isNil:
    return false
  info.id = safeStr(desc.id)
  info.name = safeStr(desc.name)
  info.vendor = safeStr(desc.vendor)
  info.version = safeStr(desc.version)
  info.category = pcUnknown
  info.audioInCount = 0
  info.audioOutCount = 0
  info.noteInCount = 0
  info.noteOutCount = 0
  info.paramCount = 0
  info.hasState = false
  info.hasGui = false
  info.reportedLatency = 0
  true

proc clapInstantiate(
  api: ptr PluginApi;
  path: cstring;
  index: int32
): PluginHandle {.cdecl, raises: [], gcsafe.} =
  if implOf(api).isNil or path.isNil or index < 0:
    return nil

  var m = openModule(path)
  if m.lib.isNil:
    return nil
  let f = factoryOf(m)
  if f.isNil:
    m.closeModule()
    return nil
  let desc = f.getPluginDescriptor(f, uint32(index))
  if desc.isNil:
    m.closeModule()
    return nil

  let slot = cast[ptr ClapSlot](allocShared0(sizeof(ClapSlot)))
  if slot.isNil:
    m.closeModule()
    return nil

  # Хост-интерфейс плагина: базовые поля + host-расширения (#6).
  initHost(slot.inst.host)
  slot.hostCtx = newClapHostContext()
  if slot.hostCtx.isNil:
    deallocShared(slot)
    m.closeModule()
    return nil
  installClapHostExtensions(slot.inst.host, slot.hostCtx)

  let plugin = f.createPlugin(f, addr slot.inst.host, desc.id)
  if plugin.isNil:
    deallocShared(slot)
    m.closeModule()
    return nil
  if not plugin.init(plugin):
    plugin.destroy(plugin)
    deallocShared(slot)
    m.closeModule()
    return nil

  slot.inst.lib = m.lib
  slot.inst.plugin = plugin
  slot.maxBlock = 0
  slot.audioIn = 0
  slot.audioOut = 0

  # Владение библиотекой перешло слоту: не закрываем модуль.
  result = cast[PluginHandle](slot)

proc clapDestroy(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return
  unloadClapPlugin(slot.inst)
  freeClapHostContext(slot.hostCtx)
  deallocShared(slot)

proc clapActivate(
  api: ptr PluginApi;
  handle: PluginHandle;
  sampleRate: float64;
  maxBlock: int32;
  audioIn: int32;
  audioOut: int32
): PluginError {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return peNoSuchPlugin
  if sampleRate <= 0.0 or maxBlock <= 0 or slot.inst.plugin.isNil:
    return peInstantiateFailed
  if not activatePlugin(slot.inst, sampleRate, 1'u32, uint32(maxBlock)):
    return peInstantiateFailed
  if not startProcessing(slot.inst):
    deactivatePlugin(slot.inst)
    return peInstantiateFailed
  slot.maxBlock = maxBlock
  slot.audioIn = audioIn
  slot.audioOut = audioOut
  peOk

proc clapDeactivate(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return
  deactivatePlugin(slot.inst)

proc clapReset(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or slot.inst.plugin.isNil:
    return
  if not slot.inst.plugin.reset.isNil:
    slot.inst.plugin.reset(slot.inst.plugin)

proc clapProcess(
  api: ptr PluginApi;
  handle: PluginHandle;
  ctx: ptr NodeProcessContext;
  audio: ptr NodeAudioPorts;
  inEvents: ptr EventQueue;
  outEvents: ptr EventQueue
): PluginProcessStatus {.cdecl, raises: [], gcsafe.} =
  ## Realtime: конвертация событий и вызов плагина идут через
  ## `processPlugin` без аллокаций.
  let slot = slotOf(handle)
  if slot.isNil or ctx.isNil:
    return ppsError

  # Первый вызов process — единственное место, где достоверно известно,
  # какой поток является аудио-потоком (clap.thread-check).
  if not slot.audioThreadMarked:
    markAudioThread(slot.hostCtx)
    slot.audioThreadMarked = true

  var evPorts: NodeEventPorts
  if not inEvents.isNil:
    evPorts.inputs[0] = inEvents
    evPorts.inputCount = 1
  if not outEvents.isNil:
    evPorts.outputs[0] = outEvents
    evPorts.outputCount = 1

  statusToPlugin(processPlugin(slot.inst, ctx, audio, addr evPorts))

# ----------------------------------------------------------------------------
# Параметры / состояние / latency / main-thread
#
# Доступ к `clap.params`, `clap.state`, `clap.latency` и `onMainThread`
# идёт через плагинные расширения, а их обвязка (host-side extensions,
# которые вызывает плагин) — предмет issue #6. Пока методы возвращают
# пустой результат: контракт остаётся полным, а корректный «пустой»
# ответ не ломает граф.
# ----------------------------------------------------------------------------

proc clapParamCount(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  0

proc clapParamInfo(api: ptr PluginApi; handle: PluginHandle; index: int32;
  info: var PluginParamInfo): bool {.cdecl, raises: [], gcsafe.} =
  false

proc clapParamGet(api: ptr PluginApi; handle: PluginHandle;
  paramId: uint32): float64 {.cdecl, raises: [], gcsafe.} =
  0.0

proc clapParamSet(api: ptr PluginApi; handle: PluginHandle; paramId: uint32;
  value: float64; normalized: bool): bool {.cdecl, raises: [], gcsafe.} =
  false

proc clapParamFlush(api: ptr PluginApi; handle: PluginHandle;
  inEvents, outEvents: ptr EventQueue): bool {.cdecl, raises: [], gcsafe.} =
  false

proc clapStateSave(api: ptr PluginApi; handle: PluginHandle;
  dst: pointer; maxLen: int): int {.cdecl, raises: [], gcsafe.} =
  -1

proc clapStateLoad(api: ptr PluginApi; handle: PluginHandle;
  src: pointer; len: int): bool {.cdecl, raises: [], gcsafe.} =
  false

proc clapLatencyFrames(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  0

proc clapOnMainThread(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  ## Плагин звал `request_callback` — main-loop зовёт `on_main_thread`
  ## столько раз, сколько запросов накопилось с прошлого раза.
  let slot = slotOf(handle)
  if slot.isNil or slot.inst.plugin.isNil:
    return

  let n = takeCallbackRequests(slot.hostCtx)
  if n <= 0:
    return

  let callback = slot.inst.plugin.onMainThread
  if callback.isNil:
    return

  var i = 0
  while i < n:
    callback(slot.inst.plugin)
    inc i

proc clapHostContextOf*(api: ptr PluginApi; handle: PluginHandle): ptr ClapHostContext =
  ## Host-side состояние инстанса: флаги `rescan`/`state.markDirty`/
  ## `latency.changed`/`request_restart`/`request_process`/`gui.*`.
  ## Main-loop забирает их через `take*` из clap_host_extensions.
  ##
  ## Владелец указателя — адаптер; он валиден, пока жив инстанс.
  let slot = slotOf(handle)
  if slot.isNil: nil else: slot.hostCtx

# ----------------------------------------------------------------------------
# Фабрика адаптера
# ----------------------------------------------------------------------------

proc newClapPluginApi*(): ptr PluginApi =
  ## Таблица методов CLAP-адаптера в shared-куче.
  let impl = createShared(ClapBackendImpl)
  if impl.isNil:
    return nil
  result = createShared(PluginApi)
  if result.isNil:
    deallocShared(impl)
    return nil
  result.backendName = ClapBackendName
  result.impl = cast[pointer](impl)
  result.init = clapInit
  result.shutdown = clapShutdown
  result.pluginCount = clapPluginCount
  result.pluginInfo = clapPluginInfo
  result.instantiate = clapInstantiate
  result.destroy = clapDestroy
  result.activate = clapActivate
  result.deactivate = clapDeactivate
  result.reset = clapReset
  result.process = clapProcess
  result.countParams = clapParamCount
  result.paramInfo = clapParamInfo
  result.paramGet = clapParamGet
  result.paramSet = clapParamSet
  result.paramFlush = clapParamFlush
  result.stateSave = clapStateSave
  result.stateLoad = clapStateLoad
  result.latencyFrames = clapLatencyFrames
  result.onMainThread = clapOnMainThread

proc freeClapPluginApi*(api: ptr PluginApi) =
  if api.isNil:
    return
  if not api.impl.isNil:
    deallocShared(cast[ptr ClapBackendImpl](api.impl))
  deallocShared(api)

{.pop.}

