# cli/plugin_host.nim
#
# Хостинг внешних плагинов в графе (issue #95).
#
# Зачем это в CLI, а не в Core/Nodes:
#   * Nodes не знают форматов плагинов (§27), Core — тоже (§40-§42);
#   * но пользовательский путь «добавить `.clap` в проект и отрендерить»
#     обязан существовать. Место стыка — CLI: он регистрирует в реестре нод
#     тип-обёртку `plugin:<id>` с фабрикой, которая вызывает ТОЛЬКО
#     `core/plugin_api`.
#
# Модель владения:
#   * `PluginHostSpec` (путь + api + индекс) живёт в shared-куче до конца
#     процесса CLI: на него ссылается дескриптор типа (`NodeDesc.pluginHost`);
#   * `PluginNodeState` — состояние одного инстанса, его освобождает
#     `destroy`, вызванный сценой;
#   * `PluginApi` один на процесс: инстансы разных нод используют одну таблицу.
#
# Realtime: `process` вызывает `pluginProcess` без аллокаций; activate —
# строго до audio-потока (хук `prepare`).

import std/[os, strutils]

import plugin_api
import logger
import signal_types
import sdk/node_api
import sdk/node_registry
import project
import control/document
import control/query
import control/error_frame
import type_registry
import clap_plugin_backend
import builtin/scene_loader

export type_registry

const
  PluginPathMax = 1024
  PluginIdMax = 128

type
  PluginHostSpec = object
    ## POD-описание типа-обёртки. `path` — фиксированный буфер: объект
    ## читается из `{.gcsafe.}`-фабрики, где обращение к GC-памяти запрещено.
    api: ptr PluginApi
    index: int32
    path: array[PluginPathMax, char]

  PluginNodeState = object
    api: ptr PluginApi
    handle: PluginHandle
    active: bool
    audioIn: int32
    audioOut: int32

var
  gDebugCalls, gDebugActive, gDebugActivateErr: int

var gDebugInPeak, gDebugOutPeak: float32

proc pluginHostDebug*(): tuple[calls, active, err: int] =
  (gDebugCalls, gDebugActive, gDebugActivateErr)

proc pluginHostPeaks*(): tuple[inp, outp: float32] =
  (gDebugInPeak, gDebugOutPeak)

var
  gPluginApi: ptr PluginApi
  gPluginApiTried = false
  gPluginKeepAlive: seq[pointer]
    ## Спеки, дескрипторы и фабрики типов. Живут до выхода процесса: реестр
    ## и сцена держат на них указатели.

proc setFixedPath(dst: var array[PluginPathMax, char]; value: string) =
  let n = min(value.len, PluginPathMax - 1)
  for i in 0 ..< n:
    dst[i] = value[i]
  dst[n] = '\0'

proc pathOf(spec: ptr PluginHostSpec): cstring {.inline.} =
  cast[cstring](addr spec.path[0])

proc pluginHostApi*(): ptr PluginApi =
  ## Одна таблица методов CLAP на процесс. `nil` — библиотека недоступна.
  if gPluginApiTried:
    return gPluginApi
  gPluginApiTried = true
  let api = newClapPluginApi()
  if api.isNil:
    return nil
  var log = silentLogger()
  if pluginInit(api, addr log) != peOk:
    freeClapPluginApi(api)
    return nil
  gPluginApi = api
  api

proc stateOf(state: pointer): ptr PluginNodeState {.inline.} =
  cast[ptr PluginNodeState](state)

proc nodeCreate(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil or desc.pluginHost.isNil:
    return nil
  let spec = cast[ptr PluginHostSpec](desc.pluginHost)
  let handle = pluginInstantiate(spec.api, pathOf(spec), spec.index)
  if handle.isNil:
    return nil
  let st = cast[ptr PluginNodeState](allocShared0(sizeof(PluginNodeState)))
  if st.isNil:
    pluginDestroy(spec.api, handle)
    return nil
  st.api = spec.api
  st.handle = handle
  st.audioIn = desc.audioInCount
  st.audioOut = desc.audioOutCount
  cast[pointer](st)

proc nodeDestroy(state: pointer) {.cdecl, raises: [], gcsafe.} =
  let st = stateOf(state)
  if st.isNil:
    return
  if st.active:
    pluginDeactivate(st.api, st.handle)
  pluginDestroy(st.api, st.handle)
  deallocShared(cast[pointer](st))

proc nodeProcess(
  ctx: ptr NodeProcessContext;
  audio: ptr NodeAudioPorts;
  ctrl: ptr NodeControlPorts;
  events: ptr NodeEventPorts;
  userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  let st = stateOf(userData)
  if st.isNil or not st.active or ctx.isNil:
    return
  var inQ: ptr EventQueue = nil
  var outQ: ptr EventQueue = nil
  if not events.isNil:
    if events.inputCount > 0:
      inQ = events.inputs[0]
    if events.outputCount > 0:
      outQ = events.outputs[0]
  discard pluginProcess(st.api, st.handle, ctx, audio, inQ, outQ)

proc nodeSetParam(state: pointer; paramId: uint32; value: float32;
                  normalized: bool) {.cdecl, raises: [], gcsafe.} =
  let st = stateOf(state)
  if st.isNil:
    return
  discard pluginParamSet(st.api, st.handle, paramId, float64(value),
                         normalized)

proc nodeGetParam(state: pointer; paramId: uint32;
                  outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  let st = stateOf(state)
  if st.isNil or outValue.isNil:
    return false
  outValue[] = float32(pluginParamGet(st.api, st.handle, paramId))
  true

proc nodeReset(state: pointer) {.cdecl, raises: [], gcsafe.} =
  let st = stateOf(state)
  if st.isNil:
    return
  pluginReset(st.api, st.handle)

proc nodePrepare(state: pointer; sampleRate: float32)
    {.cdecl, raises: [], gcsafe.} =
  ## Активация строго на холодной стороне (#393): audio-поток не должен
  ## видеть неактивированный плагин.
  let st = stateOf(state)
  if st.isNil or st.active or sampleRate <= 0.0f:
    return
  let err = pluginActivate(st.api, st.handle, float64(sampleRate),
                           int32(MaxBlockSize), st.audioIn, st.audioOut)
  st.active = err == peOk

# ==============================================================================
# Регистрация типа в реестре и в control-слое
# ==============================================================================

proc paramStep(p: PluginParamInfo): float32 =
  ## Шаг параметра. Плагин вправе не сообщать step (0) — Node API требует
  ## step > 0, поэтому берём 1/1000 диапазона (для integer/choice — 1).
  if p.step > 0.0:
    return float32(p.step)
  if ppfInteger in p.flags or ppfChoice in p.flags:
    return 1.0'f32
  let span = p.maxValue - p.minValue
  if span > 0.0:
    float32(span / 1000.0)
  else:
    0.001'f32

proc paramFlagsOf(p: PluginParamInfo): uint32 =
  var flags: uint32 = 0
  if ppfAutomatable in p.flags: flags = flags or uint32(npfAutomatable)
  if ppfModulatable in p.flags: flags = flags or uint32(npfModulatable)
  if ppfInteger in p.flags: flags = flags or uint32(npfInteger)
  if ppfChoice in p.flags: flags = flags or uint32(npfChoice)
  if ppfHidden in p.flags: flags = flags or uint32(npfHidden)
  flags

proc registerPluginNodeType*(
  reg: var NodeRegistry;
  nodeType, path: string;
  index: int32;
  info: PluginInfo;
  controlSpec: var NodeTypeSpec;
  err: var string
): bool =
  ## Зарегистрировать `plugin:<id>` в реестре нод и заполнить описатель для
  ## control-слоя. Повторная регистрация того же типа — успех (идемпотентно).
  err = ""
  if reg.findNodeType(nodeType) != nil:
    return true
  let api = pluginHostApi()
  if api.isNil:
    err = "CLAP-адаптер недоступен: plugin scan/info тоже не работают"
    return false
  if path.len == 0:
    err = "у ноды " & nodeType & " нет пути к плагину"
    return false

  # Параметры знает только инстанс: дескриптор типа строится по пробному
  # инстансу, который сразу уничтожается (control-path).
  let probe = pluginInstantiate(api, cstring(path), index)
  var paramDescs: array[NodeMaxParams, NodeParamDesc]
  var paramSpecs: seq[ParamSpec] = @[]
  var paramCount = 0
  if not probe.isNil:
    let total = pluginParamCount(api, probe)
    var i = 0'i32
    while i < total and paramCount < int32(NodeMaxParams):
      var pi: PluginParamInfo
      if pluginParamInfo(api, probe, i, pi):
        paramDescs[paramCount] = NodeParamDesc(
          id: pi.id,
          name: fixedParamName(pi.name),
          flags: paramFlagsOf(pi),
          minValue: float32(pi.minValue),
          maxValue: float32(pi.maxValue),
          defaultValue: float32(pi.defaultValue),
          step: paramStep(pi))
        paramSpecs.add ParamSpec(
          name: pi.name,
          minValue: float32(pi.minValue), maxValue: float32(pi.maxValue),
          defaultValue: float32(pi.defaultValue),
          step: paramStep(pi),
          integerLike: ppfInteger in pi.flags or ppfChoice in pi.flags,
          automatable: ppfAutomatable in pi.flags,
          modulatable: ppfModulatable in pi.flags,
          hidden: ppfHidden in pi.flags)
        inc paramCount
      inc i
    pluginDestroy(api, probe)

  let spec = cast[ptr PluginHostSpec](allocShared0(sizeof(PluginHostSpec)))
  let desc = cast[ptr NodeDesc](allocShared0(sizeof(NodeDesc)))
  let factory = cast[ptr NodeFactory](allocShared0(sizeof(NodeFactory)))
  if spec.isNil or desc.isNil or factory.isNil:
    if not spec.isNil: deallocShared(cast[pointer](spec))
    if not desc.isNil: deallocShared(cast[pointer](desc))
    if not factory.isNil: deallocShared(cast[pointer](factory))
    err = "не хватило памяти под описание типа плагина"
    return false
  spec.api = api
  spec.index = index
  setFixedPath(spec.path, path)

  let audioIn = min(info.audioInCount, int32(signal_types.MaxAudioChannels))
  let audioOut = min(info.audioOutCount, int32(signal_types.MaxAudioChannels))
  desc.id = fixedId(nodeType)
  desc.name = fixedName(if info.name.len > 0: info.name else: nodeType)
  desc.category = fixedName("plugin")
  desc.audioInCount = audioIn
  desc.audioOutCount = audioOut
  desc.ctrlInCount = 0
  desc.ctrlOutCount = 0
  desc.eventInCount = (if info.category == pcInstrument or info.noteInCount > 0:
                         1'i32 else: 0'i32)
  desc.eventOutCount = 0
  desc.latencyFrames = info.reportedLatency
  desc.maxChannels = int32(signal_types.MaxAudioChannels)
  desc.pluginHost = cast[pointer](spec)
  desc.paramCount = int32(paramCount)
  for i in 0 ..< paramCount:
    desc.params[i] = paramDescs[i]

  factory.create = nodeCreate
  factory.destroy = nodeDestroy
  factory.process = nodeProcess
  factory.setParam = nodeSetParam
  factory.getParam = nodeGetParam
  factory.reset = nodeReset
  factory.prepare = nodePrepare

  if not reg.registerNodeType(desc, factory, err):
    deallocShared(cast[pointer](spec))
    deallocShared(cast[pointer](desc))
    deallocShared(cast[pointer](factory))
    return false
  gPluginKeepAlive.add cast[pointer](spec)
  gPluginKeepAlive.add cast[pointer](desc)
  gPluginKeepAlive.add cast[pointer](factory)

  controlSpec = NodeTypeSpec(
    id: nodeType, name: desc.name.readFixed,
    audioIn: int(audioIn), audioOut: int(audioOut),
    ctrlIn: 0, ctrlOut: 0,
    eventIn: int(desc.eventInCount), eventOut: 0,
    latencyFrames: int(desc.latencyFrames))
  for p in paramSpecs:
    controlSpec.params.add p
  true

# ==============================================================================
# Проект: какие плагины нужно поднять
# ==============================================================================

proc findPluginIndex*(api: ptr PluginApi; path, wantedId: string): int32 =
  ## Индекс плагина в библиотеке по его id. `-1` — не найден.
  if api.isNil or path.len == 0:
    return -1
  let count = pluginCount(api, cstring(path))
  var i = 0'i32
  while i < count:
    var info: PluginInfo
    if pluginInfo(api, cstring(path), i, info) and info.id == wantedId:
      return i
    inc i
  -1

proc registerProjectPlugins*(reg: var NodeRegistry; doc: Document;
                             err: var string): int =
  ## Поднять типы всех плагинов проекта до загрузки сцены.
  ##
  ## Без этого `render`/`play`/`record` отвергли бы проект словами «тип ноды
  ## не зарегистрирован» — то есть плагин был бы в файле, но не в звуке.
  err = ""
  let nodes = queryNodes(doc)
  if not nodes.frame.isOk():
    err = nodes.frame.message
    return 0
  let api = pluginHostApi()
  if api.isNil:
    # Проект без плагинов не должен зависеть от CLAP-адаптера.
    for node in nodes.nodes:
      if node.nodeType.startsWith("plugin:"):
        err = "CLAP-адаптер недоступен, а в проекте есть плагины"
        return 0
    return 0

  var seen: seq[string] = @[]
  for node in nodes.nodes:
    if not node.nodeType.startsWith("plugin:") or node.nodeType in seen:
      continue
    seen.add node.nodeType
    if node.pluginPath.len == 0:
      err = "нода #" & $node.id & " (" & node.nodeType &
            ") без пути к плагину"
      return result
    let wanted = node.nodeType["plugin:".len .. ^1]
    let index = findPluginIndex(api, node.pluginPath, wanted)
    if index < 0:
      err = "плагин " & wanted & " не найден в " & node.pluginPath
      return result
    var info: PluginInfo
    if not pluginInfo(api, cstring(node.pluginPath), index, info):
      err = "не удалось прочитать плагин " & node.pluginPath
      return result
    var spec: NodeTypeSpec
    if not registerPluginNodeType(reg, node.nodeType, node.pluginPath,
                                  index, info, spec, err):
      return result
    registerControlTypeSpec(spec)
    inc result

proc pluginStateHookFor*(doc: Document): PluginStateHook =
  ## Хук загрузки сцены: применить сохранённые состояния плагинов.
  ##
  ## Байты берутся через Query API (`pluginStateBytes`): CLI не читает
  ## `ProjectFormat` руками (§63).
  result = proc(nodeId: int; nodeType: string; state: pointer) =
    discard nodeType
    if state.isNil:
      return
    let st = stateOf(state)
    let bytes = pluginStateBytes(doc, nodeId)
    if bytes.len == 0:
      return
    discard pluginStateLoad(st.api, st.handle, unsafeAddr bytes[0],
                            bytes.len)

proc pluginStateBytesOf*(doc: Document; nodeId: int): seq[byte] =
  ## Состояние плагина узла (для `plugin save` и отчётов).
  pluginStateBytes(doc, nodeId)


# ==============================================================================
# Контекст проекта: описатели типов для control-слоя
# ==============================================================================

proc registerContextTypes(proj: ProjectFormat) =
  ## Вызывается `openDocument`: до разбора команд типы `plugin:<id>` уже
  ## описаны, иначе `connect`/`param set` не знали бы их порты.
  let nodes = pluginNodes(proj)
  if nodes.len == 0:
    return
  let api = pluginHostApi()
  if api.isNil:
    return
  for node in nodes:
    if node.pluginPath.len == 0:
      continue
    var existing: NodeTypeSpec
    if lookupControlTypeSpec(node.nodeType, existing):
      continue
    let wanted = node.nodeType["plugin:".len .. ^1]
    let index = findPluginIndex(api, node.pluginPath, wanted)
    if index < 0:
      continue
    var info: PluginInfo
    if not pluginInfo(api, cstring(node.pluginPath), index, info):
      continue
    var scratch = initNodeRegistry()
    var spec: NodeTypeSpec
    var err = ""
    if registerPluginNodeType(scratch, node.nodeType, node.pluginPath,
                              index, info, spec, err):
      registerControlTypeSpec(spec)
    else:
      discard err

setContextRegistrar(registerContextTypes)
