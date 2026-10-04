# core/control/document.nim
#
# Документ и единственный путь исполнения команд (issue #139, MANIFEST §65,
# §66: Control Core рядом с Realtime Core).
#
# Что здесь и чего здесь быть не должно:
#   ЗДЕСЬ — операции над моделью: проверки по описателю типа, правила графа,
#   каскадные удаления, отметка изменения. Один код для CLI и Editor.
#   НЕ ЗДЕСЬ — файлы, stdout, JSON-конверты, разбор аргументов, коды возврата.
#   Это работа клиента (§20): Core не знает, кто его зовёт.
#
# Core не знает типов нод (§54): описатели приходят от хозяина документа через
# `NodeTypeProvider`. Такой поворот — Core ничего не импортирует из Nodes, но
# всё равно знает, сколько у типа портов и какие у параметра границы.
#
# Правило отказа: команда сначала ПРОВЕРЯЕТСЯ целиком и только потом меняет
# документ. Поэтому отказ не оставляет половины изменений (критерий #127 на
# текущем подэтапе): транзакции с откатом — следующий подэтап, но и сейчас
# составных частичных операций в командах нет.

import std/[math, strutils, tables]

import project
import handles
import commands
import error_frame

type
  ParamSpec* = object
    ## Параметр типа НОДЫ в том виде, в котором Core готов его проверить.
    ## `integerLike` — перевод флагов типа в один факт: Core не знает
    ## `NodeParamFlag` (§54), но обязан знать, что параметр не дробный.
    name*: string
    minValue*, maxValue*, defaultValue*, step*: float32
    integerLike*: bool

  NodeTypeSpec* = object
    ## Описатель типа ноды для control-слоя. Хозяин переводит в него
    ## дескриптор реестра (Nodes); Core не видит ни реестра, ни типов.
    id*: string
    name*: string
      ## Человеческое имя типа («Oscillator»); пусто — использовать `id`.
    audioIn*, audioOut*, ctrlIn*, ctrlOut*, eventIn*, eventOut*: int
    latencyFrames*: int
    params*: seq[ParamSpec]

  NodeTypeProvider* = proc(nodeType: string; spec: var NodeTypeSpec): bool
    ## Отвечает, знает ли хозяин такой тип и каков он. `false` — тип неизвестен
    ## хозяину (не ошибка ядра).

  Clock* = proc(): string
    ## Отметка времени для `metadata.modified`. Внедряется, а не берётся из
    ## системных часов: иначе два клиента, выполнившие одну команду, дали бы
    ## разные документы и их нельзя было бы сравнить (критерий #139).

  Document* = object
    ## Владелец модели проекта. Сессия держит ровно один такой объект и
    ## отдаёт наружу только значения (DTO/JSON), но не внутренние указатели
    ## (§63).
    proj*: ProjectFormat
      ## Модель документа. Хост читает её, чтобы записать файл или показать
      ## отчёт; менять её в обход `applyCommand` нельзя — тогда адреса и
      ## правила разойдутся.
    handles*: HandleTable
      ## Адреса сущностей (#143). Пересобираются после каждой команды: это
      ## дёшево для размеров проекта и зато не может разойтись с моделью.
    docId*: uint32
    types*: NodeTypeProvider
      ## Хозяин описателей; `nil` — хозяин не дал (все команды о типах
      ## отвечают `ecNoDescriptor`).
    clock*: Clock
      ## Отметка изменения; `nil` — не проставляется.

proc refreshHandles*(doc: var Document): void =
  ## Пересобрать адреса под текущую модель (#143). Просто и не может
  ## «забыться»: единственный способ изменить модель — команда, а она
  ## пересобрает адреса в конце.
  var tbl: HandleTable
  discard initHandleTable(tbl, doc.docId)
  discard openProjectHandles(tbl, doc.proj)
  doc.handles = tbl

proc initDocument*(doc: var Document; proj: ProjectFormat; docId: uint32;
                   types: NodeTypeProvider = nil;
                   clock: Clock = nil): void =
  ## Документ из загруженного проекта. Адреса строятся сразу: команды и
  ## отчёты работают с ними без отдельного шага «построить».
  doc.proj = proj
  doc.docId = docId
  doc.types = types
  doc.clock = clock
  refreshHandles(doc)

proc stampModified*(doc: var Document) =
  if doc.clock != nil:
    doc.proj.metadata.modified = doc.clock()

# =============================================================================
# Проверки (всё ДО изменения документа)
# =============================================================================

proc typeSpec(doc: Document; nodeType: string;
              spec: var NodeTypeSpec): ErrorFrame =
  ## Описатель типа от хозяина. Отказ здесь — либо «Core не знает типов»,
  ## либо «хозяин не знает этого типа»: разные коды, потому что лечатся они
  ## по-разному.
  if doc.types == nil:
    return errFrame(ecNoDescriptor,
                    "тип ноды " & nodeType & " не проверить: хозяин документа " &
                    "не дал описатели типов",
                    "документ должен получить NodeTypeProvider при открытии")
  if not doc.types(nodeType, spec):
    return errFrame(ecUnknownNodeType, "тип ноды не зарегистрирован: " & nodeType,
                    "доступные типы печатает: euterpia node types")
  okFrame()

proc nodeIndexOf*(doc: Document; nodeId: int32): int =
  ## Индекс ноды в файле или -1. Позиция в файле — часть данных: команды не
  ## пересортировывают ноды.
  for i in 0 ..< doc.proj.graph.nodes.len:
    if doc.proj.graph.nodes[i].id == nodeId:
      return i
  -1

proc requireNode*(doc: Document; nodeId: int32;
                  what: string): tuple[ok: bool, index: int; frame: ErrorFrame] =
  let index = doc.nodeIndexOf(nodeId)
  if index < 0:
    return (false, -1,
            errFrame(ecNotFound, what & ": ноды #" & $nodeId & " нет в проекте",
                     "список нод: euterpia node list"))
  (true, index, okFrame())

proc paramIndexOf*(info: NodeTypeSpec; paramName: string;
                   paramIndex: int32): int =
  ## Параметр по имени или по номеру в описателе. Номер устойчив к
  ## переименованию, имя — привычнее человеку; оба адреса нужны (CLI даёт имя,
  ## скрипт — номер).
  if paramIndex >= 0:
    if paramIndex < info.params.len:
      return int(paramIndex)
    return -1
  for i, p in info.params:
    if p.name == paramName:
      return i
  -1

proc nextNodeId*(doc: Document): int32 =
  ## Следующий свободный id: максимум + 1. Детерминированно и без
  ## переиспользования дырок: занятый ранее id не должен «оживать» в связях,
  ## автоматизации и состояниях плагинов.
  var maxId = 0
  for node in doc.proj.graph.nodes:
    if node.id > maxId:
      maxId = node.id
  int32(maxId + 1)

# =============================================================================
# Команды
# =============================================================================

proc applyCreateNode(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## Создание ноды по описателю типа: порты, задержка и умолчания берёт
  ## хозяин описаний, а не клиент (§54).
  if cmd.nodeType.len == 0:
    return errFrame(ecInvalidArgument, "не указан тип ноды",
                    "например: euterpia node add oscillator")
  var spec: NodeTypeSpec
  let frame = doc.typeSpec(cmd.nodeType, spec)
  if not frame.isOk():
    return frame

  var newId = cmd.newNodeId
  if newId == 0:
    newId = doc.nextNodeId()
  elif newId < 0:
    return errFrame(ecInvalidArgument,
                    "id ноды должен быть положительным, получено: " & $newId,
                    "id ноды — целое, начиная с 1")
  elif doc.nodeIndexOf(newId) >= 0:
    return errFrame(ecAlreadyExists, "нода с id " & $newId & " уже есть",
                    "без --id нода получит следующий свободный id")

  var node = NodeFormat(
    id: int(newId),
    nodeType: spec.id,
    name: (if cmd.name.len > 0: cmd.name
           elif spec.name.len > 0: spec.name
           else: spec.id),
    audioInCount: spec.audioIn, audioOutCount: spec.audioOut,
    ctrlInCount: spec.ctrlIn, ctrlOutCount: spec.ctrlOut,
    eventInCount: spec.eventIn, eventOutCount: spec.eventOut,
    latencyReported: uint32(max(0, spec.latencyFrames)),
    latencyIntrinsic: 0,
    isSubgraph: false,
    parameters: initTable[string, float32]()
  )
  for p in spec.params:
    node.parameters[p.name] = p.defaultValue

  # Всё проверено — только теперь меняем документ.
  doc.proj.graph.nodes.add node
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyDeleteNode(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## Удаление ЦЕЛОЙ ноды: связи, дорожки автоматизации и состояния плагинов,
  ## которые на неё ссылались. Оставить их — значит создать ссылки в никуда.
  let found = doc.requireNode(cmd.nodeId, "удаление ноды")
  if not found.ok:
    return found.frame

  var conns: seq[ConnectionFormat] = @[]
  for conn in doc.proj.graph.connections:
    if not (conn.srcNodeId == cmd.nodeId or conn.dstNodeId == cmd.nodeId):
      conns.add conn
  var lanes: seq[AutomationLaneFormat] = @[]
  for lane in doc.proj.sequencer.automationLanes:
    if lane.nodeId != cmd.nodeId:
      lanes.add lane
  var states: seq[PluginStateFormat] = @[]
  for state in doc.proj.pluginStates:
    if state.nodeId != int(cmd.nodeId):
      states.add state

  doc.proj.graph.nodes.delete(found.index)
  doc.proj.graph.connections = conns
  doc.proj.sequencer.automationLanes = lanes
  doc.proj.pluginStates = states
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc portCount*(spec: NodeTypeSpec; kind: ControlPortKind;
                 isSource: bool): int =
  case kind
  of cpkAudio: (if isSource: spec.audioOut else: spec.audioIn)
  of cpkControl: (if isSource: spec.ctrlOut else: spec.ctrlIn)
  of cpkEvent: (if isSource: spec.eventOut else: spec.eventIn)

proc checkPort*(doc: Document; sel: PortSelector; isSource: bool;
                what: string): ErrorFrame =
  ## Порт существует, у ноды есть такой вид и такой номер. Проверка по
  ## описателю хозяина: без него нельзя отличить «порт 2 есть» от «порта 2
  ## нет», а молча соединить что-то не то — худший вид ошибки.
  if sel.index < 0:
    return errFrame(ecInvalidArgument,
                    what & ": номер порта отрицательный (" & $sel.index & ")",
                    "номер порта — целое, начиная с 0")
  let found = doc.requireNode(sel.nodeId, what)
  if not found.ok:
    return found.frame
  var spec: NodeTypeSpec
  let frame = doc.typeSpec(doc.proj.graph.nodes[found.index].nodeType, spec)
  if not frame.isOk():
    return frame
  let available = spec.portCount(sel.kind, isSource)
  if sel.index >= available:
    return errFrame(ecPortNotAvailable,
                    "у ноды #" & $sel.nodeId & " нет порта " & $sel.kind &
                    (if isSource: "-out" else: "-in") & " с номером " &
                    $sel.index & ": доступно " & $available,
                    "порты ноды показывает: euterpia node show " & $sel.nodeId)
  okFrame()

proc applyConnect(doc: var Document; cmd: ControlCommand): ErrorFrame =
  if cmd.src.kind != cmd.dst.kind:
    return errFrame(ecPortKindMismatch,
                    "виды портов не совпадают: " & $cmd.src.kind & " — " &
                    $cmd.dst.kind,
                    "соединять можно одноимённые виды: audio, ctrl, event")
  let srcFrame = doc.checkPort(cmd.src, true, "источник")
  if not srcFrame.isOk():
    return srcFrame
  let dstFrame = doc.checkPort(cmd.dst, false, "приёмник")
  if not dstFrame.isOk():
    return dstFrame

  for conn in doc.proj.graph.connections:
    if conn.srcNodeId == cmd.src.nodeId and conn.dstNodeId == cmd.dst.nodeId and
       conn.srcPortIdx == cmd.src.index and conn.dstPortIdx == cmd.dst.index and
       conn.sigType == ord(cmd.src.kind):
      return errFrame(ecDuplicateConnection,
                      "такая связь уже есть: #" & $cmd.src.nodeId & " → #" &
                      $cmd.dst.nodeId,
                      "повторная связь между теми же портами не создаётся")

  doc.proj.graph.connections.add ConnectionFormat(
    srcNodeId: cmd.src.nodeId, srcPortIdx: cmd.src.index,
    dstNodeId: cmd.dst.nodeId, dstPortIdx: cmd.dst.index,
    sigType: ord(cmd.src.kind))
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyDisconnect(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## Разрыв по портам или всех связей между парой нод — как в CLI.
  if cmd.portSpecified:
    let srcFrame = doc.checkPort(cmd.src, true, "источник")
    if not srcFrame.isOk():
      return srcFrame
    let dstFrame = doc.checkPort(cmd.dst, false, "приёмник")
    if not dstFrame.isOk():
      return dstFrame
  else:
    # `disconnect A B` говорит о НОДАХ, а не о портах: нода без аудиопортов
    # (например, нода нот) обязана расцениваться как «разорвать всё, что между
    # ними», а не как «у неё нет порта 0».
    let srcFrame = doc.requireNode(cmd.src.nodeId, "источник")
    if not srcFrame.ok:
      return srcFrame.frame
    let dstFrame = doc.requireNode(cmd.dst.nodeId, "приёмник")
    if not dstFrame.ok:
      return dstFrame.frame

  var kept: seq[ConnectionFormat] = @[]
  var removed = 0
  for conn in doc.proj.graph.connections:
    let samePair = conn.srcNodeId == cmd.src.nodeId and
                   conn.dstNodeId == cmd.dst.nodeId
    let sameKind = conn.sigType == ord(cmd.src.kind)
    if samePair and (not cmd.portSpecified or
                     (sameKind and conn.srcPortIdx == cmd.src.index and
                      conn.dstPortIdx == cmd.dst.index)):
      inc removed
    else:
      kept.add conn
  if removed == 0:
    return errFrame(ecConnectionNotFound,
                    "такой связи нет: #" & $cmd.src.nodeId & " → #" &
                    $cmd.dst.nodeId,
                    "связи проекта показывает: euterpia node list")

  doc.proj.graph.connections = kept
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applySetParameter(doc: var Document; cmd: ControlCommand): ErrorFrame =
  let found = doc.requireNode(cmd.nodeId, "параметр")
  if not found.ok:
    return found.frame
  var spec: NodeTypeSpec
  let frame = doc.typeSpec(doc.proj.graph.nodes[found.index].nodeType, spec)
  if not frame.isOk():
    return frame

  let paramIdx = spec.paramIndexOf(cmd.paramName, cmd.paramIndex)
  if paramIdx < 0:
    var names: seq[string] = @[]
    for p in spec.params:
      names.add p.name
    return errFrame(ecUnknownParameter,
                    "у ноды #" & $cmd.nodeId & " нет параметра " &
                    (if cmd.paramName.len > 0: cmd.paramName else: $cmd.paramIndex),
                    "параметры: " & names.join(", "))
  let p = spec.params[paramIdx]

  if cmd.value < p.minValue or cmd.value > p.maxValue:
    return errFrame(ecOutOfRange,
                    p.name & " = " & $cmd.value & " вне диапазона " &
                    $p.minValue & "…" & $p.maxValue,
                    "диапазон объявлен типом ноды: " & spec.id)
  if p.integerLike:
    let rounded = round(cmd.value)
    if abs(cmd.value - rounded) > 1e-6:
      return errFrame(ecOutOfRange,
                      p.name & " — целочисленный параметр, получено " &
                      $cmd.value,
                      "ближайшее целое: " & $int(rounded))

  doc.proj.graph.nodes[found.index].parameters[p.name] = cmd.value
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyCommand*(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## ЕДИНАЯ точка исполнения операций над документом (§65): её зовут CLI,
  ## Editor, тесты и скрипты — и все получают один и тот же результат.
  ##
  ## Отказ не оставляет частичных изменений: команда сначала проверяет всё и
  ## только потом меняет документ.
  if cmd.apiVersion != 0'u16 and cmd.apiVersion != ControlApiVersion:
    return errFrame(ecApiVersionMismatch,
                    "команда версии API " & $cmd.apiVersion &
                    ", control-слой знает версию " & $ControlApiVersion,
                    "клиент и ядро должны говорить на одной версии (§58)")

  case cmd.kind
  of ccCreateNode: doc.applyCreateNode(cmd)
  of ccDeleteNode: doc.applyDeleteNode(cmd)
  of ccConnect: doc.applyConnect(cmd)
  of ccDisconnect: doc.applyDisconnect(cmd)
  of ccSetParameter: doc.applySetParameter(cmd)
  else:
    errFrame(ecUnsupportedCommand,
             "команда " & commandName(cmd.kind) & " объявлена, но ещё не реализована",
             "реализованные команды: node.create, node.delete, graph.connect, " &
             "graph.disconnect, param.set")
