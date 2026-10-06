# core/control/commands.nim
#
# Типы команд над документом (issue #139, MANIFEST §65).
#
# Зачем отдельный слой, если уже есть `core/ipc_bus.nim`:
#   `EngineCommand` — это POD для пути control → audio: маленькая структура без
#   строк, кладётся в кольцо без блокировок и не имеет права трогать модель
#   документа. Команда «создать ноду» туда не годится: она меняет проект.
#   Здесь — операция над документом; результат доезжает до realtime существующим
#   путём `postGraphUpdate` (§10), без новых операций в блоке.
#
# Конверт (по контракту issue):
#   id         — идентификатор команды: по нему история (#109) и повтор
#                («сделай ещё раз вот это») не различают одинаковые команды;
#   apiVersion — версия API команды (§58: версии не смешиваются; клиент и ядро
#                обязаны говорить на одном);
#   kind+данные — сама операция.
#
# Про значения: команда работает в единицах типа (`freq = 220`, а не `0..1`).
# Нормализованные значения — отдельный путь автоматизации, и смешивать их в
# одной команде значило бы прятать в команде выбор шкалы.
#
# Строки здесь допустимы: это control-path, а не audio-путь. В audio-кольцо
# эти команды не кладутся никогда.

import std/[json]

import project

const
  ControlApiVersion* = 1'u16
    ## Версия control-API. Повышается, только если меняется смысл полей
    ## команды; получатель с другой версией отказывает, а не гадает.

type
  ControlCommandKind* = enum
    ## Перечень операций документа (MANIFEST §65). Значения стабильны: по ним
    ## скрипты и Editor узнают контракт. Часть команд объявлена, но ещё не
    ## реализована и отвечает `ecUnsupportedCommand` — это честнее, чем
    ## прятать их до появления CLI-команд.
    ccCreateNode = 0
    ccDeleteNode
    ccConnect
    ccDisconnect
    ccSetParameter
    ccAddTrack
    ccRemoveTrack
    ccAddClip
    ccDeleteClip
    ccAddNote
    ccDeleteNote
    ccSetTransport
    ccLoadResource
    ccRestoreNodeState
      ## Вернуть автодорожки и состояния плагинов, которые унесло с собой
      ## удаление ноды. В обычном редакторе не вызывается: это операция
      ## ОТКАТА (`deleteNode` в обратную сторону), и она объявлена в том же
      ## контракте, что и остальные, — иначе откат был бы «магией», которую
      ## нельзя ни показать, ни записать в историю.

  ControlPortKind* = enum
    ## Вид сигнала в команде. Порядковые значения совпадают с `SignalType`
    ## (`core/signal_types.nim`): это один и тот же смысл, а не два.
    ## Имя с префиксом — в одном модуле с описателями живут и другие виды
    ## портов, и одинаковое имя в двух слоях сделало бы каждый вызов
    ## двусмысленным.
    cpkAudio = 0
    cpkControl = 1
    cpkEvent = 2

  PortSelector* = object
    ## Порт ноды: `nodeId + вид + номер`. Адрес ноды — постоянный id проекта,
    ## а не handle (#143): handle живёт в сессии, id — в документе, и команда
    ## должна переживать перезапуск сессии.
    nodeId*: int32
    kind*: ControlPortKind
    index*: int32

  ControlCommand* = object
    ## Конверт команды. Общее поле — нода-цель, частные — объединены в
    ## вариант: у каждой команды ровно те данные, которые ей нужны.
    id*: uint32
    apiVersion*: uint16
    nodeId*: int32
      ## Нода-цель (удалить, задать параметр); 0 — команда не про ноду.
    case kind*: ControlCommandKind
    of ccCreateNode:
      nodeType*: string
      name*: string
        ## Пустое имя — имя типа (как в `node add osc`).
      newNodeId*: int32
        ## Желаемый id новой ноды; 0 — назначает документ сам (максимум + 1).
    of ccConnect, ccDisconnect:
      src*: PortSelector
      dst*: PortSelector
      portSpecified*: bool
        ## Для `ccDisconnect`: снимать связь по портам или все связи между
        ## парой нод.
    of ccSetParameter:
      paramName*: string
        ## Пусто — параметр адресован номером (см. `paramIndex`).
      paramIndex*: int32
        ## -1 — параметр ищется по имени.
      value*: float32
    of ccRestoreNodeState:
      lanes*: seq[AutomationLaneFormat]
      states*: seq[PluginStateFormat]
        ## Что было привязано к ноде до удаления.
    else:
      discard

proc commandName*(kind: ControlCommandKind): string =
  ## Имя команды для отчётов. Стабильное: агенты и логи ссылаются на него.
  case kind
  of ccCreateNode: "node.create"
  of ccDeleteNode: "node.delete"
  of ccConnect: "graph.connect"
  of ccDisconnect: "graph.disconnect"
  of ccSetParameter: "param.set"
  of ccAddTrack: "track.add"
  of ccRemoveTrack: "track.delete"
  of ccAddClip: "clip.add"
  of ccDeleteClip: "clip.delete"
  of ccAddNote: "note.add"
  of ccDeleteNote: "note.delete"
  of ccSetTransport: "transport.set"
  of ccLoadResource: "resource.load"
  of ccRestoreNodeState: "node.restoreState"

proc isImplemented*(kind: ControlCommandKind): bool {.inline.} =
  ## Реализована ли команда в этом подэтапе. Клиент может спросить заранее,
  ## вместо того чтобы отправлять команду и получать отказ.
  case kind
  of ccCreateNode, ccDeleteNode, ccConnect, ccDisconnect, ccSetParameter: true
  else: false

# =============================================================================
# Конструкторы: клиент не собирает вариант руками
# =============================================================================

proc newCommand*(kind: ControlCommandKind; id: uint32 = 0'u32): ControlCommand =
  ## Общий каркас: идентификатор, версия API, вид. Идентификатор нужен
  ## истории (#109) и повтору команды; 0 — «не задано».
  result = ControlCommand(id: id, apiVersion: ControlApiVersion, kind: kind)

proc createNode*(nodeType: string; name: string = "";
                 newNodeId: int32 = 0; id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccCreateNode, id)
  result.nodeType = nodeType
  result.name = name
  result.newNodeId = newNodeId

proc deleteNode*(nodeId: int32; id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccDeleteNode, id)
  result.nodeId = nodeId

proc port*(nodeId: int32; kind: ControlPortKind;
            index: int32): PortSelector {.inline.} =
  PortSelector(nodeId: nodeId, kind: kind, index: index)

proc connect*(src, dst: PortSelector; id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccConnect, id)
  result.src = src
  result.dst = dst
  result.portSpecified = true

proc disconnect*(src, dst: PortSelector; portSpecified: bool = true;
                 id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccDisconnect, id)
  result.src = src
  result.dst = dst
  result.portSpecified = portSpecified

proc setParameter*(nodeId: int32; value: float32; paramName: string = "";
                   paramIndex: int32 = -1; id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccSetParameter, id)
  result.nodeId = nodeId
  result.value = value
  result.paramName = paramName
  result.paramIndex = paramIndex

proc restoreNodeState*(nodeId: int32; lanes: seq[AutomationLaneFormat];
                       states: seq[PluginStateFormat];
                       id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccRestoreNodeState, id)
  result.nodeId = nodeId
  result.lanes = lanes
  result.states = states

# =============================================================================
# Контракт на проводе: команда в JSON
# =============================================================================
#
# Зачем: команда попадает в историю (`commons/undo_redo`, #109) и в сценарии
# (#148 «GUI-действие = команда»), а значит должна пережить перезапуск. Формат
# версионируется полем `api` вместе с `ControlApiVersion` (§58: версии не
# смешиваются), а разбор строгий: неизвестный вид команды — отказ, а не «пропустим
# и посмотрим».

proc field(node: JsonNode; key: string; default: JsonNode): JsonNode {.inline.} =
  ## Поле объекта или значение по умолчанию: разбор команды не должен падать на
  ## отсутствующем ключе — он решает, понятна ли команда вообще.
  if node.kind == JObject and node.hasKey(key): node[key] else: default

proc toJson*(cmd: ControlCommand): JsonNode =
  ## Команда в машинном виде. Всегда есть `kind` и `api`; поля операции — рядом,
  ## без вложенности (как в конверте CLI, §21).
  result = newJObject()
  result["kind"] = %commandName(cmd.kind)
  result["api"] = %cmd.apiVersion
  if cmd.id != 0'u32:
    result["id"] = %cmd.id
  case cmd.kind
  of ccCreateNode:
    result["nodeType"] = %cmd.nodeType
    if cmd.name.len > 0: result["name"] = %cmd.name
    if cmd.newNodeId != 0: result["newNodeId"] = %cmd.newNodeId
  of ccDeleteNode:
    result["nodeId"] = %cmd.nodeId
  of ccConnect, ccDisconnect:
    result["src"] = %*{"nodeId": cmd.src.nodeId, "kind": ord(cmd.src.kind),
                       "index": cmd.src.index}
    result["dst"] = %*{"nodeId": cmd.dst.nodeId, "kind": ord(cmd.dst.kind),
                       "index": cmd.dst.index}
    if not cmd.portSpecified: result["portSpecified"] = %false
  of ccSetParameter:
    result["nodeId"] = %cmd.nodeId
    if cmd.paramName.len > 0: result["paramName"] = %cmd.paramName
    if cmd.paramIndex >= 0: result["paramIndex"] = %cmd.paramIndex
    result["value"] = %cmd.value
  of ccRestoreNodeState:
    result["nodeId"] = %cmd.nodeId
    var lanes = newJArray()
    for lane in cmd.lanes:
      lanes.add %*{"nodeId": lane.nodeId, "paramId": lane.paramId}
    result["lanes"] = lanes
    var states = newJArray()
    for st in cmd.states:
      states.add %*{"nodeId": st.nodeId, "pluginId": st.pluginId}
    result["states"] = states
  else:
    discard

proc kindFromName*(name: string; kind: var ControlCommandKind): bool =
  for candidate in ControlCommandKind:
    if commandName(candidate) == name:
      kind = candidate
      return true
  false

proc portFromJson(node: JsonNode; sel: var PortSelector): bool =
  if node.kind != JObject or not node.hasKey("nodeId"):
    return false
  sel = PortSelector(nodeId: int32(node["nodeId"].getInt),
                     kind: ControlPortKind(node["kind"].getInt),
                     index: int32(node["index"].getInt))
  true

proc fromJson*(node: JsonNode; cmd: var ControlCommand): bool =
  ## Разбор команды. `false` — форма не наша: неизвестный вид, чужая версия
  ## или недостающее поле. Молча чинить нельзя — история и скрипт должны
  ## сказать, что не поняли команду.
  if node.kind != JObject:
    return false
  var kind: ControlCommandKind
  if not kindFromName(field(node, "kind", newJString("")).getStr, kind):
    return false
  let api = uint16(field(node, "api", newJInt(int(ControlApiVersion))).getInt)
  if api > ControlApiVersion:
    return false
  var id = 0'u32
  if node.hasKey("id"):
    id = uint32(node["id"].getInt)


  case kind
  of ccCreateNode:
    cmd = createNode(field(node, "nodeType", newJString("")).getStr,
                     field(node, "name", newJString("")).getStr,
                     int32(field(node, "newNodeId", newJInt(0)).getInt), id)
  of ccDeleteNode:
    cmd = deleteNode(int32(node["nodeId"].getInt), id)
  of ccSetParameter:
    cmd = setParameter(int32(node["nodeId"].getInt),
                       float32(field(node, "value", newJFloat(0.0)).getFloat),
                       field(node, "paramName", newJString("")).getStr,
                       int32(field(node, "paramIndex", newJInt(-1)).getInt),
                       id)
  of ccConnect, ccDisconnect:
    if not node.hasKey("src") or not node.hasKey("dst"):
      return false
    var src, dst: PortSelector
    if not portFromJson(node["src"], src) or not portFromJson(node["dst"], dst):
      return false
    let byPort = field(node, "portSpecified", newJBool(true)).getBool
    cmd = if kind == ccConnect: connect(src, dst, id)
          else: disconnect(src, dst, byPort, id)
  of ccRestoreNodeState:
    var lanes: seq[AutomationLaneFormat] = @[]
    if node.hasKey("lanes"):
      for lane in node["lanes"].items:
        lanes.add AutomationLaneFormat(
          nodeId: int32(field(lane, "nodeId", newJInt(0)).getInt),
          paramId: uint32(field(lane, "paramId", newJInt(0)).getInt))
    var states: seq[PluginStateFormat] = @[]
    if node.hasKey("states"):
      for st in node["states"].items:
        states.add PluginStateFormat(
          nodeId: int(field(st, "nodeId", newJInt(0)).getInt),
          pluginId: field(st, "pluginId", newJString("")).getStr)
    cmd = restoreNodeState(int32(node["nodeId"].getInt), lanes, states, id)
  else:
    return false
  cmd.apiVersion = api
  true
