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
import clap_plugin_extensions

{.push raises: [].}

const
  ClapBackendName* = "clap"
  ## Максимум отложенных изменений параметров между вызовами flush/process.
  ## CLAP не имеет метода setValue: значения передаются событиями, поэтому
  ## `paramSet` копит их здесь, а применяет `paramFlush`/`process`.
  ClapMaxPendingParams = 32

type
  PendingParam = object
    id: uint32
    value: float64
    used: bool

  ClapSlot = object
    ## Состояние одного инстанса. POD; размещается в shared-куче.
    inst: ClapPluginInstance
    ## host-side состояние (clap.host/params|state|gui|thread-check|latency).
    hostCtx: ptr ClapHostContext
    ## plugin-side расширения (clap.params|state|latency|audio-ports).
    exts: ClapPluginExtSet
    audioThreadMarked: bool
    maxBlock: int32
    audioIn: int32
    audioOut: int32
    pendingParams: array[ClapMaxPendingParams, PendingParam]
    ## Слияние внешних событий блока с отложенными параметрами.
    mergedEvents: EventQueue

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

  # Число портов/параметров и заявленная latency доступны только у
  # инстанса плагина (расширения выдаются на plugin, а не на descriptor).
  # Enumeration — холодный путь, поэтому создаём временный инстанс,
  # опрашиваем и уничтожаем.
  var host: ClapHost
  initHost(host)
  let hostCtx = newClapHostContext()
  if not hostCtx.isNil:
    installClapHostExtensions(host, hostCtx)

  let plugin = f.createPlugin(f, addr host, desc.id)
  if not plugin.isNil:
    if plugin.init(plugin):
      let exts = fetchClapPluginExts(plugin)
      if not exts.audioPorts.isNil and not exts.audioPorts.count.isNil:
        info.audioInCount = int32(exts.audioPorts.count(plugin, true))
        info.audioOutCount = int32(exts.audioPorts.count(plugin, false))
      if not exts.params.isNil and not exts.params.count.isNil:
        info.paramCount = int32(exts.params.count(plugin))
      if not exts.latency.isNil and not exts.latency.get.isNil:
        info.reportedLatency = int32(exts.latency.get(plugin))
      info.hasState = not exts.state.isNil
    plugin.destroy(plugin)

  freeClapHostContext(hostCtx)
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
  # Кэшируем plugin-side расширения один раз (issue #49). Их может не быть —
  # тогда соответствующие методы контракта вернут пустой результат.
  slot.exts = fetchClapPluginExts(plugin)
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

  # Отложенные параметры уезжают в плагин вместе с событиями блока: в CLAP
  # значения параметров передаются событиями, а не отдельным вызовом.
  clearEvents(addr slot.mergedEvents)
  if not inEvents.isNil:
    for i in 0 ..< inEvents.count:
      discard pushEvent(addr slot.mergedEvents, inEvents.events[i])
  for i in 0 ..< ClapMaxPendingParams:
    if slot.pendingParams[i].used:
      discard pushEvent(addr slot.mergedEvents, RealtimeEvent(
        frameOffset: 0'u32, kind: evParamChange,
        data: [float32(slot.pendingParams[i].id),
               float32(slot.pendingParams[i].value), 0.0f, 0.0f]))
      slot.pendingParams[i].used = false

  var evPorts: NodeEventPorts
  evPorts.inputs[0] = addr slot.mergedEvents
  evPorts.inputCount = 1
  if not outEvents.isNil:
    evPorts.outputs[0] = outEvents
    evPorts.outputCount = 1

  statusToPlugin(processPlugin(slot.inst, ctx, audio, addr evPorts))

# ----------------------------------------------------------------------------
# Параметры (clap.params) / состояние (clap.state) / latency (clap.latency)
#
# В CLAP нет метода «установить параметр»: значения передаются СОБЫТИЯМИ
# (clap_event_param_value) через входные события `process` или через
# `clap.params.flush`. Поэтому `paramSet` копит изменения в слоте, а
# применяет их `paramFlush` (или ближайший `process`).
# ----------------------------------------------------------------------------

proc clapParamToFlags(flags: uint32): set[PluginParamFlag] {.inline.} =
  if (flags and ClapParamIsAutomatable) != 0'u32: result.incl ppfAutomatable
  if (flags and ClapParamIsModulatable) != 0'u32: result.incl ppfModulatable
  if (flags and ClapParamIsStepped) != 0'u32: result.incl ppfInteger
  if (flags and ClapParamIsEnum) != 0'u32: result.incl ppfChoice
  if (flags and ClapParamIsHidden) != 0'u32: result.incl ppfHidden

proc pendingIndexOf(slot: ptr ClapSlot; paramId: uint32): int =
  for i in 0 ..< ClapMaxPendingParams:
    if slot.pendingParams[i].used and slot.pendingParams[i].id == paramId:
      return i
  -1

proc pendingFreeIndex(slot: ptr ClapSlot): int =
  for i in 0 ..< ClapMaxPendingParams:
    if not slot.pendingParams[i].used:
      return i
  -1

proc clapParamCount(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or slot.exts.params.isNil or slot.exts.params.count.isNil:
    return 0
  int32(slot.exts.params.count(slot.inst.plugin))

proc clapParamInfo(api: ptr PluginApi; handle: PluginHandle; index: int32;
  info: var PluginParamInfo): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or index < 0:
    return false
  if slot.exts.params.isNil or slot.exts.params.getInfo.isNil:
    return false

  var raw: ClapParamInfo
  if not slot.exts.params.getInfo(slot.inst.plugin, uint32(index), addr raw):
    return false

  info.id = raw.id
  info.name = readFixedString(raw.name)
  info.flags = clapParamToFlags(raw.flags)
  info.minValue = raw.minValue
  info.maxValue = raw.maxValue
  info.defaultValue = raw.defaultValue
  # CLAP не сообщает шаг: для ступенчатых/перечислимых параметров это 1,
  # иначе шаг задаёт UI.
  info.step = (if ppfInteger in info.flags or ppfChoice in info.flags: 1.0 else: 0.0)
  true

proc clapParamGet(api: ptr PluginApi; handle: PluginHandle;
  paramId: uint32): float64 {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or slot.exts.params.isNil or slot.exts.params.getValue.isNil:
    return 0.0
  var value = 0.0
  if not slot.exts.params.getValue(slot.inst.plugin, paramId, addr value):
    return 0.0
  value

proc clapParamSet(api: ptr PluginApi; handle: PluginHandle; paramId: uint32;
  value: float64; normalized: bool): bool {.cdecl, raises: [], gcsafe.} =
  ## Плагин не имеет setValue: значение откладывается и уедет в него
  ## событием при следующем `paramFlush`/`process`.
  let slot = slotOf(handle)
  if slot.isNil or slot.exts.params.isNil:
    return false

  var v = value
  if normalized:
    # Нормировка требует min/max конкретного параметра — ищем по индексу.
    let count = if slot.exts.params.count.isNil: 0'u32
                else: slot.exts.params.count(slot.inst.plugin)
    var raw: ClapParamInfo
    var found = false
    var i = 0'u32
    while i < count:
      if slot.exts.params.getInfo(slot.inst.plugin, i, addr raw) and raw.id == paramId:
        found = true
        break
      inc i
    if not found:
      return false
    v = raw.minValue + clamp(value, 0.0, 1.0) * (raw.maxValue - raw.minValue)

  let existing = slot.pendingIndexOf(paramId)
  if existing >= 0:
    slot.pendingParams[existing].value = v
    return true

  let free = slot.pendingFreeIndex()
  if free < 0:
    return false
  slot.pendingParams[free] = PendingParam(id: paramId, value: v, used: true)
  true

proc clapParamFlush(api: ptr PluginApi; handle: PluginHandle;
  inEvents, outEvents: ptr EventQueue): bool {.cdecl, raises: [], gcsafe.} =
  ## Sample-accurate применение: отложенные `paramSet` + входные события
  ## уезжают в `clap.params.flush`, out-events плагина возвращаются в
  ## очередь Core.
  let slot = slotOf(handle)
  if slot.isNil or slot.exts.params.isNil or slot.exts.params.flush.isNil:
    return false

  # То же хранилище, что использует processPlugin: вызовы не пересекаются.
  slot.inst.inputStorage.count = 0
  slot.inst.outputStorage.count = 0

  for i in 0 ..< ClapMaxPendingParams:
    if slot.pendingParams[i].used:
      discard pushParamToClap(slot.inst.inputStorage, 0'u32,
        slot.pendingParams[i].id, slot.pendingParams[i].value)
      slot.pendingParams[i].used = false

  if not inEvents.isNil:
    for i in 0 ..< inEvents.count:
      discard convertRtEventToClap(inEvents.events[i], slot.inst.inputStorage)

  var inList = initInputEvents(addr slot.inst.inputStorage)
  var outList = initOutputEvents(addr slot.inst.outputStorage)
  slot.exts.params.flush(slot.inst.plugin, addr inList, addr outList)

  if not outEvents.isNil:
    clearEvents(outEvents)
    for i in 0 ..< slot.inst.outputStorage.count:
      let hdr = cast[ptr ClapEventHeader](addr slot.inst.outputStorage.events[i])
      discard pushEvent(outEvents, convertClapEventToRt(hdr))

  true

proc clapStateSave(api: ptr PluginApi; handle: PluginHandle;
  dst: pointer; maxLen: int): int {.cdecl, raises: [], gcsafe.} =
  ## Байтовый стрим clap.state. Контракт CLAP: `write` вернёт -1 при
  ## переполнении, тогда сохранение считается неудачным.
  let slot = slotOf(handle)
  if slot.isNil or dst.isNil or maxLen <= 0:
    return -1
  if slot.exts.state.isNil or slot.exts.state.save.isNil:
    return -1

  var cursor: BufferCursor
  var stream = initWriteStream(cursor, dst, maxLen)
  if not slot.exts.state.save(slot.inst.plugin, addr stream):
    return -1
  bytesUsed(cursor)

proc clapStateLoad(api: ptr PluginApi; handle: PluginHandle;
  src: pointer; len: int): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or src.isNil or len <= 0:
    return false
  if slot.exts.state.isNil or slot.exts.state.load.isNil:
    return false

  var cursor: BufferCursor
  var stream = initReadStream(cursor, src, len)
  slot.exts.state.load(slot.inst.plugin, addr stream)

proc clapLatencyFrames(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or slot.exts.latency.isNil or slot.exts.latency.get.isNil:
    return 0
  int32(slot.exts.latency.get(slot.inst.plugin))

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
# Состояние инстанса для проекта (issue #53)
#
# Core не знает о плагинах, поэтому склейка «состояние плагина ↔ проект»
# живёт на границе адаптера и CLI/Editor: адаптер даёт непрозрачный блоб,
# проект хранит его рядом с id узла. Снимать/ставить — control-path.
# ----------------------------------------------------------------------------

proc saveInstanceState*(api: ptr PluginApi; handle: PluginHandle): seq[byte] =
  ## Снимок состояния плагина (clap.state.save) в блоб для проекта.
  ## Начинаем с небольшого буфера и удваиваем при переполнении: контракт
  ## CLAP возвращает -1, если данные не влезли. Плагин без clap.state даёт
  ## пустой блоб — это не ошибка.
  var cap = 4096
  while cap <= (1 shl 24):
    result = newSeq[byte](cap)
    let n = pluginStateSave(api, handle, addr result[0], cap)
    if n >= 0:
      result.setLen(n)
      return
    cap = cap * 2
  result = newSeq[byte](0)

proc loadInstanceState*(api: ptr PluginApi; handle: PluginHandle;
                        blob: openArray[byte]): bool =
  ## Восстановление состояния плагина из блоба проекта (clap.state.load).
  ## Пустой блоб означает «состояния нет» — восстанавливать нечего.
  if blob.len == 0:
    return true
  pluginStateLoad(api, handle, unsafeAddr blob[0], blob.len)

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

