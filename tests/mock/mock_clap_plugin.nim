# tests/mock/mock_clap_plugin.nim
#
# Mock CLAP-плагин для сквозного теста хостинга (issue #53).
#
# Собирается в РАЗДЕЛЯЕМУЮ библиотеку (`nim c --app:lib`) и экспортирует
# ровно тот символ, который ищет загрузчик CLAP-адаптера — `clap_entry`.
# Бинарных `.clap` в дереве нет: плагин живёт в `tests/mock/` и собирается
# самой задачей `nimble clapMock`.
#
# Что реализует плагин (минимум для сквозного пути
# load → instantiate → activate → process → params → state):
#   * clap.plugin-factory — один дескриптор;
#   * clap.audio-ports    — 1 вход / 1 выход, 2 канала, тип "audio";
#   * clap.params         — 2 параметра (Gain, Bypass), get/set через события;
#   * clap.state          — save/load 16 байт (два float64), байт-в-байт;
#   * clap.latency        — ненулевая (8 кадров), чтобы проверить PDC-поле;
#   * host.request_callback + on_main_thread — обратный вызов хоста.
#
# ВАЖНО: `process` и `flush` — realtime-путь: без аллокаций, локов, IO и
# исключений (все callback'и помечены `raises: []`).

import clap_host
import clap_host_extensions
import clap_plugin_extensions

const
  MockPluginId* = "com.euterpia.mock.gain"
  MockLatencyFrames* = 8'u32
  MockChannels* = 2'u32

  ParamGainId* = 0'u32
  ParamBypassId* = 1'u32

  MockStateBytes = 16

type
  MockInstance = object
    ## Первое поле — ABI-совместимая `clap_plugin`; адрес совпадает с
    ## адресом объекта, поэтому `cast[ptr MockInstance](plugin)` корректен.
    plugin: ClapPlugin
    host: ptr ClapHost
    sampleRate: float64
    gain: float64
    bypass: float64
    active: bool
    started: bool
    callbackRequested: bool
    mainThreadCalls: int32

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

proc instanceOf(plugin: ptr ClapPlugin): ptr MockInstance {.inline.} =
  cast[ptr MockInstance](plugin)

proc setFixedPtr(dst: pointer; cap: int; v: string) =
  if dst.isNil or cap <= 0:
    return
  let n = min(v.len, cap - 1)
  if n > 0:
    copyMem(dst, unsafeAddr v[0], n)
  cast[ptr UncheckedArray[char]](dst)[n] = '\0'

proc setFixed(dst: var openArray[char]; v: string) =
  setFixedPtr(addr dst[0], dst.len, v)

proc cstreq(a, b: cstring): bool {.inline.} =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  $a == $b

proc applyParam(inst: ptr MockInstance; paramId: uint32; value: float64) =
  case paramId
  of ParamGainId:
    if value < 0.0: inst.gain = 0.0
    elif value > 2.0: inst.gain = 2.0
    else: inst.gain = value
  of ParamBypassId:
    inst.bypass = (if value >= 0.5: 1.0 else: 0.0)
  else:
    discard

proc applyParamEvents(inst: ptr MockInstance; list: ptr ClapInputEvents) =
  ## Разбирает clap_event_param_value из входного списка. Общий код для
  ## `process` и `clap.params.flush`.
  if inst.isNil or list.isNil or list.get.isNil or list.size.isNil:
    return
  let n = list.size(list)
  var i = 0'u32
  while i < n:
    let hdr = list.get(list, i)
    if not hdr.isNil and hdr.eventType == ClapEvtParamVal:
      let ev = cast[ptr ClapEventParamVal](hdr)
      applyParam(inst, ev.paramId, ev.value)
    inc i

# ----------------------------------------------------------------------------
# clap.params (plugin-side)
# ----------------------------------------------------------------------------

proc mockParamCount(plugin: ptr ClapPlugin): uint32 {.cdecl, raises: [], gcsafe.} =
  2'u32

proc fillParamInfo(info: ptr ClapParamInfo; id: uint32; name: string;
                   flags: uint32; minV, maxV, defV: float64) =
  info.id = id
  info.flags = flags
  info.cookie = nil
  setFixed(info.name, name)
  setFixed(info.module, "")
  info.minValue = minV
  info.maxValue = maxV
  info.defaultValue = defV

proc mockParamGetInfo(plugin: ptr ClapPlugin; index: uint32;
                      info: ptr ClapParamInfo): bool {.cdecl, raises: [], gcsafe.} =
  if info.isNil: return false
  case index
  of 0:
    fillParamInfo(info, ParamGainId, "Gain",
      ClapParamIsAutomatable, 0.0, 2.0, 1.0)
  of 1:
    fillParamInfo(info, ParamBypassId, "Bypass",
      ClapParamIsAutomatable or ClapParamIsStepped, 0.0, 1.0, 0.0)
  else:
    return false
  true

proc mockParamGetValue(plugin: ptr ClapPlugin; paramId: uint32;
                       value: ptr float64): bool {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil or value.isNil: return false
  case paramId
  of ParamGainId:   value[] = inst.gain
  of ParamBypassId: value[] = inst.bypass
  else: return false
  true

proc mockParamValueToText(plugin: ptr ClapPlugin; paramId: uint32;
                          value: float64; display: cstring;
                          size: uint32): bool {.cdecl, raises: [], gcsafe.} =
  ## Текстовое представление не нужно тесту: показываем только «что-то».
  if display.isNil or size == 0: return false
  let txt = if paramId == ParamBypassId: (if value >= 0.5: "on" else: "off")
            else: "value"
  setFixedPtr(cast[pointer](display), int(size), txt)
  true

proc mockParamTextToValue(plugin: ptr ClapPlugin; paramId: uint32;
                          display: cstring; value: ptr float64): bool
    {.cdecl, raises: [], gcsafe.} =
  if display.isNil or value.isNil: return false
  if paramId == ParamBypassId:
    let s = $display
    if s == "on":
      value[] = 1.0
      return true
    if s == "off":
      value[] = 0.0
      return true
    return false
  true

proc mockParamFlush(plugin: ptr ClapPlugin; input: ptr ClapInputEvents;
                    output: ptr ClapOutputEvents) {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil: return
  applyParamEvents(inst, input)

# ----------------------------------------------------------------------------
# clap.state (plugin-side)
# ----------------------------------------------------------------------------

proc mockStateSave(plugin: ptr ClapPlugin; stream: ptr ClapOStream): bool
    {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil or stream.isNil or stream.write.isNil: return false
  var buf: array[MockStateBytes, byte]
  var gain = inst.gain
  var bypass = inst.bypass
  copyMem(addr buf[0], addr gain, sizeof(float64))
  copyMem(addr buf[8], addr bypass, sizeof(float64))
  stream.write(stream, addr buf[0], uint64(MockStateBytes)) == int64(MockStateBytes)

proc mockStateLoad(plugin: ptr ClapPlugin; stream: ptr ClapIStream): bool
    {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil or stream.isNil or stream.read.isNil: return false
  var buf: array[MockStateBytes, byte]
  if stream.read(stream, addr buf[0], uint64(MockStateBytes)) != int64(MockStateBytes):
    return false
  var gain = 0.0
  var bypass = 0.0
  copyMem(addr gain, addr buf[0], sizeof(float64))
  copyMem(addr bypass, addr buf[8], sizeof(float64))
  applyParam(inst, ParamGainId, gain)
  applyParam(inst, ParamBypassId, bypass)
  true

# ----------------------------------------------------------------------------
# clap.latency / clap.audio-ports (plugin-side)
# ----------------------------------------------------------------------------

proc mockLatencyGet(plugin: ptr ClapPlugin): uint32 {.cdecl, raises: [], gcsafe.} =
  MockLatencyFrames

proc mockAudioPortsCount(plugin: ptr ClapPlugin; isInput: bool): uint32
    {.cdecl, raises: [], gcsafe.} =
  1'u32

proc mockAudioPortsGet(plugin: ptr ClapPlugin; index: uint32; isInput: bool;
                       info: ptr ClapAudioPortInfo): bool
    {.cdecl, raises: [], gcsafe.} =
  if info.isNil or index != 0: return false
  info.id = (if isInput: 0'u32 else: 1'u32)
  setFixed(info.name, if isInput: "Input" else: "Output")
  info.flags = 0'u32
  info.channelCount = MockChannels
  info.portType = cstring"audio"
  info.inPlacePair = 0'u32
  true


# ----------------------------------------------------------------------------
# Статические таблицы расширений и фабрика
#
# Живут весь срок жизни библиотеки: CLAP требует, чтобы указатели,
# выданные `get_extension`, были стабильны.
# ----------------------------------------------------------------------------

var
  gParams: ClapPluginParams
  gState: ClapPluginState
  gLatency: ClapPluginLatency
  gAudioPorts: ClapPluginAudioPorts
  gDescriptor: ClapPluginDescriptor
  gFactory: ClapPluginFactory



# ----------------------------------------------------------------------------
# Жизненный цикл clap_plugin
# ----------------------------------------------------------------------------

proc mockInit(plugin: ptr ClapPlugin): bool {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil: return false
  inst.gain = 1.0
  inst.bypass = 0.0
  true

proc mockDestroy(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.} =
  if plugin.isNil: return
  deallocShared(cast[pointer](plugin))

proc mockActivate(plugin: ptr ClapPlugin; sampleRate: float64;
                  minFrames, maxFrames: uint32): bool {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil: return false
  inst.sampleRate = sampleRate
  inst.active = true
  true

proc mockDeactivate(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if not inst.isNil: inst.active = false

proc mockStartProcessing(plugin: ptr ClapPlugin): bool {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil: return false
  inst.started = true
  true

proc mockStopProcessing(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if not inst.isNil: inst.started = false

proc mockReset(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil: return
  inst.gain = 1.0
  inst.bypass = 0.0

proc copyChannelGo(src, dst: pointer; frames: int; g: float64) =
  if src.isNil or dst.isNil: return
  let s = cast[ptr UncheckedArray[float32]](src)
  let d = cast[ptr UncheckedArray[float32]](dst)
  var i = 0
  while i < frames:
    d[i] = float32(float64(s[i]) * g)
    inc i

proc silenceChannel(dst: pointer; frames: int) =
  if dst.isNil: return
  let d = cast[ptr UncheckedArray[float32]](dst)
  var i = 0
  while i < frames:
    d[i] = 0.0'f32
    inc i

proc mockProcess(plugin: ptr ClapPlugin; process: ptr ClapProcess): int32
    {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if inst.isNil or process.isNil or not inst.started:
    return ClapProcessError

  # Значения параметров уезжают событиями (в CLAP нет setValue).
  applyParamEvents(inst, process.inEvents)

  # Обратный вызов хоста ровно один раз: проверяет request_callback →
  # on_main_thread и заодно thread-check со стороны плагина.
  if not inst.callbackRequested and not inst.host.isNil:
    if not inst.host.requestCallback.isNil:
      inst.host.requestCallback(inst.host)
    inst.callbackRequested = true

  let frames = int(process.framesCount)
  if frames <= 0:
    return ClapProcessContinue

  let gain = if inst.bypass >= 0.5: 1.0 else: inst.gain
  let ins = cast[ptr UncheckedArray[ClapAudioBuffer]](process.audioInputs)
  let outs = cast[ptr UncheckedArray[ClapAudioBuffer]](process.audioOutputs)

  var p = 0'u32
  while p < process.audioOutputsCount:
    let outBuf = addr outs[p]
    if outBuf.data32.isNil:
      inc p
      continue
    let hasIn = (p < process.audioInputsCount) and (not process.audioInputs.isNil) and
                (not ins[p].data32.isNil)
    let chans = int(outBuf.channelCount)
    var c = 0
    while c < chans:
      if hasIn and c < int(ins[p].channelCount):
        copyChannelGo(ins[p].data32[c], outBuf.data32[c], frames, gain)
      else:
        silenceChannel(outBuf.data32[c], frames)
      inc c
    inc p

  ClapProcessContinue

proc mockOnMainThread(plugin: ptr ClapPlugin) {.cdecl, raises: [], gcsafe.} =
  let inst = instanceOf(plugin)
  if not inst.isNil: inc inst.mainThreadCalls

proc mockGetExtension(plugin: ptr ClapPlugin; id: cstring): pointer
    {.cdecl, raises: [], gcsafe.} =
  if id.isNil: return nil
  if cstreq(id, ClapExtParams):
    return cast[pointer](addr gParams)
  if cstreq(id, ClapExtState):
    return cast[pointer](addr gState)
  if cstreq(id, ClapExtLatency):
    return cast[pointer](addr gLatency)
  if cstreq(id, ClapExtAudioPorts):
    return cast[pointer](addr gAudioPorts)
  nil


# ----------------------------------------------------------------------------
# clap.plugin-factory
# ----------------------------------------------------------------------------

proc mockFactoryGetCount(factory: ptr ClapPluginFactory): uint32
    {.cdecl, raises: [], gcsafe.} =
  1'u32

proc mockFactoryGetDescriptor(factory: ptr ClapPluginFactory; index: uint32):
    ptr ClapPluginDescriptor {.cdecl, raises: [], gcsafe.} =
  if index != 0: return nil
  addr gDescriptor

proc mockCreatePlugin(factory: ptr ClapPluginFactory; host: ptr ClapHost;
                      pluginId: cstring): ptr ClapPlugin
    {.cdecl, raises: [], gcsafe.} =
  if pluginId.isNil or $pluginId != MockPluginId:
    return nil
  let inst = cast[ptr MockInstance](allocShared0(sizeof(MockInstance)))
  if inst.isNil:
    return nil
  inst.host = host
  inst.gain = 1.0
  inst.bypass = 0.0
  inst.plugin.desc = addr gDescriptor
  inst.plugin.pluginData = nil
  inst.plugin.init = mockInit
  inst.plugin.destroy = mockDestroy
  inst.plugin.activate = mockActivate
  inst.plugin.deactivate = mockDeactivate
  inst.plugin.startProcessing = mockStartProcessing
  inst.plugin.stopProcessing = mockStopProcessing
  inst.plugin.reset = mockReset
  inst.plugin.process = mockProcess
  inst.plugin.getExtension = mockGetExtension
  inst.plugin.onMainThread = mockOnMainThread
  cast[ptr ClapPlugin](inst)

# ----------------------------------------------------------------------------
# clap_entry — точка входа библиотеки
# ----------------------------------------------------------------------------

proc mockEntryInit(pluginPath: cstring): bool {.cdecl, raises: [], gcsafe.} =
  true

proc mockEntryDeinit() {.cdecl, raises: [], gcsafe.} =
  discard

proc mockEntryGetFactory(factoryId: cstring): pointer {.cdecl, raises: [], gcsafe.} =
  if factoryId.isNil: return nil
  if cstreq(factoryId, ClapPluginFactoryId):
    return cast[pointer](addr gFactory)
  nil

proc setupMockPlugin() =
  ## Заполняет статические таблицы. Вызывается инициализацией модуля,
  ## которая исполняется загрузчиком при `dlopen` (`--app:lib`).
  gParams.count = mockParamCount
  gParams.getInfo = mockParamGetInfo
  gParams.getValue = mockParamGetValue
  gParams.valueToText = mockParamValueToText
  gParams.textToValue = mockParamTextToValue
  gParams.flush = mockParamFlush

  gState.save = mockStateSave
  gState.load = mockStateLoad

  gLatency.get = mockLatencyGet

  gAudioPorts.count = mockAudioPortsCount
  gAudioPorts.get = mockAudioPortsGet

  gDescriptor.clapVersion.major = ClapVersionMajor
  gDescriptor.clapVersion.minor = ClapVersionMinor
  gDescriptor.clapVersion.revision = ClapVersionRevision
  gDescriptor.id = cstring(MockPluginId)
  gDescriptor.name = cstring"EUTERPIA Mock Gain"
  gDescriptor.vendor = cstring"EUTERPIA"
  gDescriptor.url = cstring""
  gDescriptor.manualUrl = cstring""
  gDescriptor.supportUrl = cstring""
  gDescriptor.version = cstring"1.0.0"
  gDescriptor.description = cstring"Mock gain plugin for host integration tests"
  gDescriptor.features = nil

  gFactory.getPluginCount = mockFactoryGetCount
  gFactory.getPluginDescriptor = mockFactoryGetDescriptor
  gFactory.createPlugin = mockCreatePlugin

proc buildClapEntry(): ClapPluginEntry =
  result.clapVersion.major = ClapVersionMajor
  result.clapVersion.minor = ClapVersionMinor
  result.clapVersion.revision = ClapVersionRevision
  result.init = mockEntryInit
  result.deinit = mockEntryDeinit
  result.getFactory = mockEntryGetFactory

# Инициализация таблиц обязана произойти ДО того, как загрузчик прочитает
# `clap_entry`: переменная экспортируется отдельным от Nim-идентификатора
# именем, а таблицы заполняются в инициализации модуля (`--app:lib`
# исполняет её через конструктор при `dlopen`).
var mockClapEntry* {.exportc: "clap_entry", dynlib.}: ClapPluginEntry

setupMockPlugin()
mockClapEntry = buildClapEntry()

