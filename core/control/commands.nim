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
