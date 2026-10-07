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
    integerLike*, automatable*, modulatable*, hidden*: bool
      ## Свойства параметра фактами, а не флагами реестра: Core не знает
      ## `NodeParamFlag` (§54) — перевод делает хозяин описаний.

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

proc typeSpec*(doc: Document; nodeType: string;
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

proc applyRestoreNodeState(doc: var Document;
                           cmd: ControlCommand): ErrorFrame =
  ## Вернуть то, что удаление ноды унесло с собой: дорожки автоматизации и
  ## состояния плагинов. Операция отката, но живёт в общем контракте команд —
  ## иначе отмена была бы «магией», которую нельзя ни показать, ни записать в
  ## историю.
  let found = doc.requireNode(cmd.nodeId, "восстановление состояния ноды")
  if not found.ok:
    return found.frame
  for lane in cmd.lanes:
    var known = false
    for existing in doc.proj.sequencer.automationLanes:
      if existing.nodeId == lane.nodeId and existing.paramId == lane.paramId:
        known = true
        break
    if not known:
      doc.proj.sequencer.automationLanes.add lane
  for state in cmd.states:
    var known = false
    for existing in doc.proj.pluginStates:
      if existing.nodeId == state.nodeId and existing.pluginId == state.pluginId:
        known = true
        break
    if not known:
      doc.proj.pluginStates.add state
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applySetProjectInfo(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## Запись метаданных проекта (issue #373). Проверки границ переехали сюда из
  ## CLI: одно правило для CLI, Editor и скриптов. Меняются только поля из
  ## `projectMask` — иначе «не задано» не отличить от «поставить ноль».
  if (cmd.projectMask and ProjectFieldSampleRate) != 0:
    if not (cmd.projectSampleRate > 0.0f and
            cmd.projectSampleRate <= 1_000_000.0f):
      return errFrame(ecOutOfRange,
        "sample-rate = " & $cmd.projectSampleRate & " вне диапазона 0…1000000",
        "частота дискретизации должна быть положительной")
  if (cmd.projectMask and ProjectFieldTempo) != 0:
    if not (cmd.projectTempo > 0.0f and cmd.projectTempo <= 1000.0f):
      return errFrame(ecOutOfRange,
        "tempo = " & $cmd.projectTempo & " вне диапазона 0…1000",
        "темп должен быть положительным")
  if (cmd.projectMask and ProjectFieldTimeSignature) != 0:
    if cmd.tsNum < 1:
      return errFrame(ecOutOfRange, "числитель размера < 1",
        "размер вида N/M, N ≥ 1")
    if cmd.tsDen notin [1'i32, 2'i32, 4'i32, 8'i32, 16'i32, 32'i32]:
      return errFrame(ecOutOfRange,
        "знаменатель размера " & $cmd.tsDen & " не степень двойки",
        "допустимо: 1, 2, 4, 8, 16, 32")

  if (cmd.projectMask and ProjectFieldName) != 0:
    doc.proj.metadata.name = cmd.projectName
  if (cmd.projectMask and ProjectFieldAuthor) != 0:
    doc.proj.metadata.author = cmd.projectAuthor
  if (cmd.projectMask and ProjectFieldSampleRate) != 0:
    doc.proj.metadata.sampleRate = cmd.projectSampleRate
  if (cmd.projectMask and ProjectFieldTempo) != 0:
    doc.proj.metadata.tempo = cmd.projectTempo
  if (cmd.projectMask and ProjectFieldTimeSignature) != 0:
    doc.proj.metadata.timeSignature = TimeSignatureFormat(
      numerator: cmd.tsNum, denominator: cmd.tsDen)
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc nextTrackId(tracks: seq[TrackFormat]): int32 =
  ## «Максимум + 1» (issue #373): после удаления дорожки счётчик длины выдал бы
  ## повтор id, и две дорожки стали бы неразличимы для автоматизации.
  for track in tracks:
    if track.id + 1 > result:
      result = track.id + 1
  if result < 1:
    result = 1

proc nextClipId(clips: seq[ClipFormat]): int32 =
  for clip in clips:
    if clip.id + 1 > result:
      result = clip.id + 1
  if result < 1:
    result = 1

proc applyAddTrack(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## Добавить дорожку в конец (issue #373). Умолчания формата — здесь, а не в
  ## клиенте: один источник для CLI, Editor и скриптов.
  let id = nextTrackId(doc.proj.sequencer.tracks)
  let name = if cmd.trackName.len > 0: cmd.trackName else: "Track " & $id
  doc.proj.sequencer.tracks.add TrackFormat(
    id: id, name: name, trackType: int(cmd.trackType),
    volume: 1.0'f32, pan: 0.0'f32, inputChannel: 0, outputBus: 0)
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyRemoveTrack(doc: var Document; cmd: ControlCommand): ErrorFrame =
  let t = int(cmd.removeTrackIndex)
  if t < 0 or t >= doc.proj.sequencer.tracks.len:
    return errFrame(ecNotFound, "нет дорожки #" & $t,
                    "дорожки проекта показывает: euterpia project show")
  doc.proj.sequencer.tracks.delete(t)
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyAddClip(doc: var Document; cmd: ControlCommand): ErrorFrame =
  let t = int(cmd.addClipTrackIndex)
  if t < 0 or t >= doc.proj.sequencer.tracks.len:
    return errFrame(ecNotFound, "нет дорожки #" & $t, "")
  let id = nextClipId(doc.proj.sequencer.tracks[t].clips)
  let name = if cmd.addClipName.len > 0: cmd.addClipName else: "Clip " & $id
  doc.proj.sequencer.tracks[t].clips.add ClipFormat(
    id: id, clipType: int(cmd.addClipType), name: name,
    startTick: cmd.addClipStartTick, lengthTicks: cmd.addClipLengthTicks,
    loopEnabled: cmd.addClipLoopEnabled, audioBufferId: -1, resourceId: -1,
    offsetFrames: 0, color: cmd.addClipColor)
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyDeleteClip(doc: var Document; cmd: ControlCommand): ErrorFrame =
  let t = int(cmd.delClipTrackIndex)
  if t < 0 or t >= doc.proj.sequencer.tracks.len:
    return errFrame(ecNotFound, "нет дорожки #" & $t, "")
  let c = int(cmd.delClipIndex)
  if c < 0 or c >= doc.proj.sequencer.tracks[t].clips.len:
    return errFrame(ecNotFound, "нет клипа #" & $c, "")
  doc.proj.sequencer.tracks[t].clips.delete(c)
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applySetClip(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## SetClip content wholesale (issue #373): notes, length, loop, optionally name.
  let t = int(cmd.setClipTrackIndex)
  if t < 0 or t >= doc.proj.sequencer.tracks.len:
    return errFrame(ecNotFound, "нет дорожки #" & $t, "")
  let c = int(cmd.setClipIndex)
  if c < 0 or c >= doc.proj.sequencer.tracks[t].clips.len:
    return errFrame(ecNotFound, "нет клипа #" & $c, "")
  let clip = addr doc.proj.sequencer.tracks[t].clips[c]
  clip[].notes = cmd.setClipNotes
  clip[].lengthTicks = cmd.setClipLengthTicks
  clip[].loopEnabled = cmd.setClipLoopEnabled
  if cmd.setClipNameSpecified:
    clip[].name = cmd.setClipName
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyRestoreTrack(doc: var Document; cmd: ControlCommand): ErrorFrame =
  ## Вставить дорожку на её прежнее место (issue #373).
  let t = int(cmd.restoreTrackIndex)
  if t < 0 or t > doc.proj.sequencer.tracks.len:
    return errFrame(ecInvalidArgument, "позиция восстановления дорожки вне диапазона",
                    "")
  doc.proj.sequencer.tracks.insert(cmd.restoreTrackData, t)
  doc.stampModified()
  doc.refreshHandles()
  okFrame()

proc applyRestoreClip(doc: var Document; cmd: ControlCommand): ErrorFrame =
  let t = int(cmd.restoreClipTrackIndex)
  if t < 0 or t >= doc.proj.sequencer.tracks.len:
    return errFrame(ecNotFound, "нет дорожки #" & $t, "")
  let c = int(cmd.restoreClipIndex)
  if c < 0 or c > doc.proj.sequencer.tracks[t].clips.len:
    return errFrame(ecInvalidArgument, "позиция восстановления клипа вне диапазона",
                    "")
  doc.proj.sequencer.tracks[t].clips.insert(cmd.restoreClipData, c)
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
  of ccRestoreNodeState: doc.applyRestoreNodeState(cmd)
  of ccSetProjectInfo: doc.applySetProjectInfo(cmd)
  of ccAddTrack: doc.applyAddTrack(cmd)
  of ccRemoveTrack: doc.applyRemoveTrack(cmd)
  of ccAddClip: doc.applyAddClip(cmd)
  of ccDeleteClip: doc.applyDeleteClip(cmd)
  of ccSetClip: doc.applySetClip(cmd)
  of ccRestoreTrack: doc.applyRestoreTrack(cmd)
  of ccRestoreClip: doc.applyRestoreClip(cmd)
  else:
    errFrame(ecUnsupportedCommand,
             "команда " & commandName(cmd.kind) & " объявлена, но ещё не реализована",
             "реализованные команды: node.create, node.delete, graph.connect, " &
             "graph.disconnect, param.set")

# =============================================================================
# Обратные команды и транзакции
# =============================================================================
#
# Откат строится из ОБРАТНЫХ КОМАНД, а не из снимка модели: снимок прощает
# «приблизительно», обратная команда — нет, и её видно в истории. Пустая
# последовательность обратных команд означает «откат невозможен», и транзакция
# такую операцию не примет (код `ecNotInvertible`), а не сделает вид, что
# отменить можно.

type
  NodeSnapshot* = object
    ## Что удаление ноды уносит с собой: сама нода плюс то, что на неё ссылалось.
    node*: NodeFormat
    lanes*: seq[AutomationLaneFormat]
    states*: seq[PluginStateFormat]
    conns*: seq[ControlCommand]

type
  TransactionPlan* = object
    ## Результат предпроверки: что делаем (redo), чем отменяем (undo) и почему
    ## отказали, если отказали.
    frame*: ErrorFrame
    undo*: seq[ControlCommand]
    redo*: seq[ControlCommand]
    description*: string

proc snapshotNode*(doc: Document; nodeId: int32):
    tuple[ok: bool, snapshot: NodeSnapshot] =
  ## Снимок ДО удаления. Пусто означает «такой ноды нет» — тогда и удалять нечего.
  let index = doc.nodeIndexOf(nodeId)
  if index < 0:
    return (false, NodeSnapshot())
  var lanes: seq[AutomationLaneFormat] = @[]
  for lane in doc.proj.sequencer.automationLanes:
    if lane.nodeId == nodeId:
      lanes.add lane
  var states: seq[PluginStateFormat] = @[]
  for st in doc.proj.pluginStates:
    if st.nodeId == int(nodeId):
      states.add st
  var conns: seq[ControlCommand] = @[]
  for conn in doc.proj.graph.connections:
    if conn.srcNodeId == nodeId or conn.dstNodeId == nodeId:
      conns.add connect(
        port(int32(conn.srcNodeId), ControlPortKind(conn.sigType),
             int32(conn.srcPortIdx)),
        port(int32(conn.dstNodeId), ControlPortKind(conn.sigType),
             int32(conn.dstPortIdx)))
  (true, NodeSnapshot(node: doc.proj.graph.nodes[index], lanes: lanes,
                      states: states, conns: conns))

proc restoreSnapshot*(snap: NodeSnapshot): seq[ControlCommand] =
  ## Обратные команды для удаления: нода с её id и значениями, её связи и всё,
  ## что было привязано. Порядок важен: сначала нода, потом связи (иначе
  ## откат упрётся в «нет такой ноды»).
  result = @[
    createNode(snap.node.nodeType, snap.node.name, int32(snap.node.id))
  ]
  for conn in snap.conns:
    result.add conn
  if snap.lanes.len > 0 or snap.states.len > 0:
    result.add restoreNodeState(int32(snap.node.id), snap.lanes, snap.states)

proc applyCommandRecording*(doc: var Document; cmd: ControlCommand):
    tuple[frame: ErrorFrame, inverse: seq[ControlCommand]] =
  ## Команда вместе с обратными к ней. Обратные вычисляются из состояния ДО
  ## правки: поэтому откат — точное зеркало, а не «примерно то же».
  case cmd.kind
  of ccCreateNode:
    let before = doc.proj.graph.nodes.len
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    let newId = (if doc.proj.graph.nodes.len > before:
                   int32(doc.proj.graph.nodes[before].id) else: 0'i32)
    (frame, @[deleteNode(newId)])
  of ccDeleteNode:
    let snap = doc.snapshotNode(cmd.nodeId)
    let frame = doc.applyCommand(cmd)
    if not frame.isOk() or not snap.ok:
      return (frame, @[])
    (frame, snap.snapshot.restoreSnapshot())
  of ccConnect:
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[disconnect(cmd.src, cmd.dst)])
  of ccDisconnect:
    let snap = doc.snapshotNode(cmd.src.nodeId)
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, snap.snapshot.restoreSnapshot())
  of ccSetParameter:
    # Прежнее значение параметра — единственное, что нужно для отката.
    let index = doc.nodeIndexOf(cmd.nodeId)
    if index < 0:
      let frame = doc.applyCommand(cmd)     # вернёт «нет такой ноды»
      return (frame, @[])
    var spec: NodeTypeSpec
    if doc.typeSpec(doc.proj.graph.nodes[index].nodeType, spec).isOk() and
       spec.params.len > 0:
      let paramIdx = spec.paramIndexOf(cmd.paramName, cmd.paramIndex)
      if paramIdx >= 0:
        let old = doc.proj.graph.nodes[index].parameters[spec.params[paramIdx].name]
        let frame = doc.applyCommand(cmd)
        if not frame.isOk():
          return (frame, @[])
        return (frame, @[setParameter(cmd.nodeId, old, cmd.paramName, cmd.paramIndex)])
    (doc.applyCommand(cmd), @[])
  of ccSetProjectInfo:
    # Обратная команда — те же поля с прежними значениями (issue #373).
    let m = doc.proj.metadata
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[setProjectInfo(cmd.projectMask, m.name, m.author,
                             m.sampleRate, m.tempo,
                             m.timeSignature.numerator,
                             m.timeSignature.denominator)])
  of ccAddTrack:
    let indexBefore = doc.proj.sequencer.tracks.len
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[removeTrack(int32(indexBefore))])
  of ccAddClip:
    let trackIndex = int(cmd.addClipTrackIndex)
    if trackIndex < 0 or trackIndex >= doc.proj.sequencer.tracks.len:
      return (doc.applyCommand(cmd), @[])
    let clipIndexBefore = doc.proj.sequencer.tracks[trackIndex].clips.len
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[deleteClip(int32(trackIndex), int32(clipIndexBefore))])
  of ccSetClip:
    let t = int(cmd.setClipTrackIndex)
    let c = int(cmd.setClipIndex)
    if t < 0 or t >= doc.proj.sequencer.tracks.len or
       c < 0 or c >= doc.proj.sequencer.tracks[t].clips.len:
      return (doc.applyCommand(cmd), @[])
    let prev = doc.proj.sequencer.tracks[t].clips[c]
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[setClip(int32(t), int32(c), prev.notes, prev.lengthTicks,
                      prev.loopEnabled, prev.name, true)])
  of ccRemoveTrack:
    # Снимок ДО удаления — им восстанавливается дорожка со всеми клипами.
    let t = int(cmd.removeTrackIndex)
    if t < 0 or t >= doc.proj.sequencer.tracks.len:
      return (doc.applyCommand(cmd), @[])
    let snap = doc.proj.sequencer.tracks[t]
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[restoreTrack(int32(t), snap)])
  of ccDeleteClip:
    let t = int(cmd.delClipTrackIndex)
    let c = int(cmd.delClipIndex)
    if t < 0 or t >= doc.proj.sequencer.tracks.len or
       c < 0 or c >= doc.proj.sequencer.tracks[t].clips.len:
      return (doc.applyCommand(cmd), @[])
    let snap = doc.proj.sequencer.tracks[t].clips[c]
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[restoreClip(int32(t), int32(c), snap)])
  of ccRestoreTrack:
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[removeTrack(cmd.restoreTrackIndex)])
  of ccRestoreClip:
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      return (frame, @[])
    (frame, @[deleteClip(cmd.restoreClipTrackIndex, cmd.restoreClipIndex)])
  else:
    # Команда не реализована или её откат не определён: применяем как обычно,
    # но откат не обещаем.
    let frame = doc.applyCommand(cmd)
    (frame, @[])

proc applyCommands*(doc: var Document; commands: seq[ControlCommand];
                    description: string = ""): ErrorFrame =
  ## Атомарное применение ГОТОВОГО набора команд — без вычисления обратных.
  ## Так применяются отмена и повтор: набор уже записан в истории, и «как его
  ## отменить» знать не нужно. Требование «у каждой команды есть обратная»
  ## относится только к записи новой операции (`planTransaction`).
  result = errFrame(ecInvalidArgument, "пустой набор команд",
                    "нечего применять")
  if commands.len == 0:
    return
  var probe = doc
  for cmd in commands:
    let frame = probe.applyCommand(cmd)
    if not frame.isOk():
      result = errFrame(frame.code,
                        "набор «" & description & "» отменен: " & frame.message,
                        if frame.hint.len > 0:
                          frame.hint & " (ни одна команда не применена)"
                        else: "ни одна команда не применена")
      return
  for cmd in commands:
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      result = errFrame(ecInternal,
                        "команда прошла пробу, но не выполнилась: " & frame.message,
                        "внутренняя ошибка ядра")
      return
  result = okFrame()

proc planTransaction*(doc: Document; commands: seq[ControlCommand];
                      description: string = ""): TransactionPlan =
  ## План составной операции БЕЗ побочных эффектов: команды прогоняются на
  ## копии документа, и возвращаются обратные команды для отката.
  ##
  ## План — это и есть «pre-check → откат» (#127) целиком: документ ещё цел,
  ## поэтому откатывать нечего. Разделение плана и применения нужно ещё и
  ## истории: она должна записать шаг с обратными командами, а применить — через
  ## общий исполнитель, иначе две дороги исполнения снова разойдутся.
  result.description = description
  if commands.len == 0:
    result.frame = errFrame(ecInvalidArgument, "транзакция без команд",
                            "составная операция должна что-то делать")
    return

  var probe = doc
  var inverses: seq[seq[ControlCommand]] = @[]
  for cmd in commands:
    let outcome = probe.applyCommandRecording(cmd)
    if not outcome.frame.isOk():
      result.frame = errFrame(outcome.frame.code,
                              "транзакция «" & description & "» отменена: " &
                              outcome.frame.message,
                              if outcome.frame.hint.len > 0:
                                outcome.frame.hint & " (ни одна команда не применена)"
                              else: "ни одна команда не применена")
      return
    if outcome.inverse.len == 0:
      result.frame = errFrame(ecNotInvertible,
                              "откат для «" & commandName(cmd.kind) &
                              "» не определён",
                              "история не примет операцию, которую нельзя отменить")
      return
    inverses.add outcome.inverse

  # Отмена идёт в ОБРАТНОМ порядке команд — сначала отменяется последняя. Внутри
  # одной команды её обратные команды идут в своём порядке: удалённая нода
  # сначала появляется, потом к ней подключаются связи, потом возвращаются
  # дорожки автоматизации и состояния плагинов.
  var i = inverses.len - 1
  while i >= 0:
    for inverse in inverses[i]:
      result.undo.add inverse
    dec i
  result.redo = commands
  result.frame = okFrame()

proc applyTransaction*(doc: var Document; commands: seq[ControlCommand];
                       description: string = ""): TransactionPlan =
  ## Составная операция: план на копии, затем те же команды по-настоящему.
  ## Отказ не оставляет НИКАКИХ изменений — откатывать нечего, потому что до
  ## второй фазы документ не трогали.
  result = doc.planTransaction(commands, description)
  if not result.frame.isOk():
    return
  for cmd in commands:
    let frame = doc.applyCommand(cmd)
    if not frame.isOk():
      # Проба прошла, значит это невозможно — но код должен быть честным.
      result.frame = errFrame(ecInternal,
                              "транзакция прошла пробу, но не выполнилась: " &
                              frame.message,
                              "внутренняя ошибка ядра")
      return
  result.frame = okFrame()
