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

  # Битмаск полей `ccSetProjectInfo` (issue #373): какие метаданные менять.
  ProjectFieldName* = 1'u32
  ProjectFieldAuthor* = 2'u32
  ProjectFieldSampleRate* = 4'u32
  ProjectFieldTempo* = 8'u32
  ProjectFieldTimeSignature* = 16'u32

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
    ccSetProjectInfo
      ## Запись метаданных проекта (issue #373): имя, автор, sample rate,
      ## темп и размер. Раньше эти поля писал сам CLI (`setField`), из-за чего
      ## отметка `metadata.modified` и проверки границ жили в клиенте и
      ## повторялись бы в Editor. Теперь это операция документа (как `param.set`),
      ## отменяемая через историю. Значения по умолчанию (0/пусто) означают
      ## «не задано» и данное поле не трогается.
    ccSetClip
      ## Содержимое клипа целиком (issue #373): ноты, длина, повтор, имя. Импорт
      ## партитуры задаёт клип ЦЕЛИКОМ (идемпотентность), поэтому это одна
      ## операция «заменить содержимое», а не поток `note.add` с риском
      ## накопить дубликаты при повторном импорте.
    ccRestoreTrack
      ## Вставить дорожку обратно (issue #373). Операция ОТКАТА (`removeTrack` в
      ## обратную сторону): несёт весь снимок дорожки с её клипами, поэтому
      ## отмена удаления точна. В обычном редакторе не вызывается — как
      ## `ccRestoreNodeState`.
    ccRestoreClip
      ## Вставить клип обратно (issue #373) — обратная к `deleteClip`.

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
    of ccSetProjectInfo:
      projectMask*: uint32
        ## Битмаск «какие поля менять» (см. `ProjectField*`): позволяет
        ## явно поставить и пустое имя, и числовой ноль — «не задано» через
        ## значение не отличишь от «поставить 0».
      projectName*: string
      projectAuthor*: string
      projectSampleRate*: float32
      projectTempo*: float32
      tsNum*: int32
      tsDen*: int32
    of ccAddTrack:
      trackName*: string
        ## Пусто — «Track <id>».
      trackType*: int32
    of ccRemoveTrack:
      removeTrackIndex*: int32
    of ccAddClip:
      addClipTrackIndex*: int32
      addClipType*: int32
      addClipName*: string
      addClipStartTick*: int32
      addClipLengthTicks*: int32
      addClipLoopEnabled*: bool
      addClipColor*: uint32
    of ccDeleteClip:
      delClipTrackIndex*: int32
      delClipIndex*: int32
    of ccSetClip:
      setClipTrackIndex*: int32
      setClipIndex*: int32
      setClipNotes*: seq[NoteFormat]
      setClipLengthTicks*: int32
      setClipLoopEnabled*: bool
      setClipName*: string
      setClipNameSpecified*: bool
    of ccRestoreTrack:
      restoreTrackIndex*: int32
      restoreTrackData*: TrackFormat
    of ccRestoreClip:
      restoreClipTrackIndex*: int32
      restoreClipIndex*: int32
      restoreClipData*: ClipFormat
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
  of ccSetProjectInfo: "project.set-info"
  of ccSetClip: "clip.set"
  of ccRestoreTrack: "track.restore"
  of ccRestoreClip: "clip.restore"

proc isImplemented*(kind: ControlCommandKind): bool {.inline.} =
  ## Реализована ли команда в этом подэтапе. Клиент может спросить заранее,
  ## вместо того чтобы отправлять команду и получать отказ.
  case kind
  of ccCreateNode, ccDeleteNode, ccConnect, ccDisconnect, ccSetParameter: true
  of ccSetProjectInfo: true
  of ccAddTrack, ccRemoveTrack, ccAddClip, ccDeleteClip, ccSetClip: true
  of ccRestoreTrack, ccRestoreClip: true
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

proc setProjectInfo*(mask: uint32; name: string = ""; author: string = "";
                     sampleRate: float32 = 0.0f; tempo: float32 = 0.0f;
                     tsNum: int32 = 0; tsDen: int32 = 0;
                     id: uint32 = 0'u32): ControlCommand =
  ## Запись метаданных проекта (issue #373). `mask` — какие поля менять
  ## (`ProjectField*`); остальные игнорируются. Явный битмаск нужен, чтобы
  ## отличать «не задано» от «поставить ноль/пусто».
  result = newCommand(ccSetProjectInfo, id)
  result.projectMask = mask
  result.projectName = name
  result.projectAuthor = author
  result.projectSampleRate = sampleRate
  result.projectTempo = tempo
  result.tsNum = tsNum
  result.tsDen = tsDen

proc addTrack*(name: string = ""; trackType: int32 = 0;
               id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccAddTrack, id)
  result.trackName = name
  result.trackType = trackType

proc removeTrack*(trackIndex: int32; id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccRemoveTrack, id)
  result.removeTrackIndex = trackIndex

proc addClip*(trackIndex: int32; clipType: int32 = 0; name: string = "";
              startTick: int32 = 0; lengthTicks: int32 = 0;
              loopEnabled: bool = false; color: uint32 = 0'u32;
              id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccAddClip, id)
  result.addClipTrackIndex = trackIndex
  result.addClipType = clipType
  result.addClipName = name
  result.addClipStartTick = startTick
  result.addClipLengthTicks = lengthTicks
  result.addClipLoopEnabled = loopEnabled
  result.addClipColor = color

proc deleteClip*(trackIndex, clipIndex: int32;
                 id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccDeleteClip, id)
  result.delClipTrackIndex = trackIndex
  result.delClipIndex = clipIndex

proc setClip*(trackIndex, clipIndex: int32; notes: seq[NoteFormat];
              lengthTicks: int32; loopEnabled: bool;
              name: string = ""; nameSpecified: bool = false;
              id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccSetClip, id)
  result.setClipTrackIndex = trackIndex
  result.setClipIndex = clipIndex
  result.setClipNotes = notes
  result.setClipLengthTicks = lengthTicks
  result.setClipLoopEnabled = loopEnabled
  result.setClipName = name
  result.setClipNameSpecified = nameSpecified

proc restoreTrack*(index: int32; data: TrackFormat;
                   id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccRestoreTrack, id)
  result.restoreTrackIndex = index
  result.restoreTrackData = data

proc restoreClip*(trackIndex, clipIndex: int32; data: ClipFormat;
                  id: uint32 = 0'u32): ControlCommand =
  result = newCommand(ccRestoreClip, id)
  result.restoreClipTrackIndex = trackIndex
  result.restoreClipIndex = clipIndex
  result.restoreClipData = data

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

# Клип/дорожка целиком — для команд восстановления (issue #373). История
# сериализуется в JSON, поэтому снимок отката тоже обязан пережить round-trip.

proc clipToJson(c: ClipFormat): JsonNode =
  result = newJObject()
  result["id"] = %c.id
  result["clipType"] = %c.clipType
  result["name"] = %c.name
  result["startTick"] = %c.startTick
  result["lengthTicks"] = %c.lengthTicks
  result["loopEnabled"] = %c.loopEnabled
  result["audioBufferId"] = %c.audioBufferId
  result["resourceId"] = %c.resourceId
  result["offsetFrames"] = %c.offsetFrames
  result["color"] = %int(c.color)
  var notes = newJArray()
  for n in c.notes:
    notes.add %*{"startTick": n.startTick, "duration": n.duration,
                 "pitch": int(n.pitch), "velocity": int(n.velocity),
                 "channel": int(n.channel)}
  result["notes"] = notes

proc trackToJson(t: TrackFormat): JsonNode =
  result = newJObject()
  result["id"] = %t.id
  result["name"] = %t.name
  result["trackType"] = %t.trackType
  result["volume"] = %t.volume
  result["pan"] = %t.pan
  result["mute"] = %t.mute
  result["solo"] = %t.solo
  result["armed"] = %t.armed
  result["inputChannel"] = %t.inputChannel
  result["outputBus"] = %t.outputBus
  var clips = newJArray()
  for c in t.clips:
    clips.add clipToJson(c)
  result["clips"] = clips

proc clipFromJson(n: JsonNode): ClipFormat =
  result.id = int32(field(n, "id", newJInt(0)).getInt)
  result.clipType = int(field(n, "clipType", newJInt(0)).getInt)
  result.name = field(n, "name", newJString("")).getStr
  result.startTick = int32(field(n, "startTick", newJInt(0)).getInt)
  result.lengthTicks = int32(field(n, "lengthTicks", newJInt(0)).getInt)
  result.loopEnabled = field(n, "loopEnabled", newJBool(false)).getBool
  result.audioBufferId = int32(field(n, "audioBufferId", newJInt(-1)).getInt)
  result.resourceId = int32(field(n, "resourceId", newJInt(-1)).getInt)
  result.offsetFrames = field(n, "offsetFrames", newJInt(0)).getInt
  result.color = uint32(field(n, "color", newJInt(0)).getInt)
  if n.hasKey("notes"):
    for nn in n["notes"].items:
      result.notes.add NoteFormat(
        startTick: int32(field(nn, "startTick", newJInt(0)).getInt),
        duration: int32(field(nn, "duration", newJInt(0)).getInt),
        pitch: uint8(field(nn, "pitch", newJInt(0)).getInt),
        velocity: uint8(field(nn, "velocity", newJInt(0)).getInt),
        channel: uint8(field(nn, "channel", newJInt(0)).getInt))

proc trackFromJson(n: JsonNode): TrackFormat =
  result.id = int32(field(n, "id", newJInt(0)).getInt)
  result.name = field(n, "name", newJString("")).getStr
  result.trackType = int(field(n, "trackType", newJInt(0)).getInt)
  result.volume = float32(field(n, "volume", newJFloat(1.0)).getFloat)
  result.pan = float32(field(n, "pan", newJFloat(0.0)).getFloat)
  result.mute = field(n, "mute", newJBool(false)).getBool
  result.solo = field(n, "solo", newJBool(false)).getBool
  result.armed = field(n, "armed", newJBool(false)).getBool
  result.inputChannel = int32(field(n, "inputChannel", newJInt(0)).getInt)
  result.outputBus = int32(field(n, "outputBus", newJInt(0)).getInt)
  if n.hasKey("clips"):
    for c in n["clips"].items:
      result.clips.add clipFromJson(c)

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
  of ccSetProjectInfo:
    result["mask"] = %cmd.projectMask
    if (cmd.projectMask and ProjectFieldName) != 0:
      result["name"] = %cmd.projectName
    if (cmd.projectMask and ProjectFieldAuthor) != 0:
      result["author"] = %cmd.projectAuthor
    if (cmd.projectMask and ProjectFieldSampleRate) != 0:
      result["sampleRate"] = %cmd.projectSampleRate
    if (cmd.projectMask and ProjectFieldTempo) != 0:
      result["tempo"] = %cmd.projectTempo
    if (cmd.projectMask and ProjectFieldTimeSignature) != 0:
      result["tsNum"] = %cmd.tsNum
      result["tsDen"] = %cmd.tsDen
  of ccAddTrack:
    if cmd.trackName.len > 0: result["name"] = %cmd.trackName
    result["trackType"] = %cmd.trackType
  of ccRemoveTrack:
    result["trackIndex"] = %cmd.removeTrackIndex
  of ccAddClip:
    result["trackIndex"] = %cmd.addClipTrackIndex
    result["clipType"] = %cmd.addClipType
    if cmd.addClipName.len > 0: result["name"] = %cmd.addClipName
    result["startTick"] = %cmd.addClipStartTick
    result["lengthTicks"] = %cmd.addClipLengthTicks
    result["loopEnabled"] = %cmd.addClipLoopEnabled
    result["color"] = %cmd.addClipColor
  of ccDeleteClip:
    result["trackIndex"] = %cmd.delClipTrackIndex
    result["clipIndex"] = %cmd.delClipIndex
  of ccSetClip:
    result["trackIndex"] = %cmd.setClipTrackIndex
    result["clipIndex"] = %cmd.setClipIndex
    var notes = newJArray()
    for n in cmd.setClipNotes:
      notes.add %*{"startTick": n.startTick, "duration": n.duration,
                   "pitch": int(n.pitch), "velocity": int(n.velocity),
                   "channel": int(n.channel)}
    result["notes"] = notes
    result["lengthTicks"] = %cmd.setClipLengthTicks
    result["loopEnabled"] = %cmd.setClipLoopEnabled
    if cmd.setClipNameSpecified:
      result["name"] = %cmd.setClipName
  of ccRestoreTrack:
    result["trackIndex"] = %cmd.restoreTrackIndex
    result["track"] = trackToJson(cmd.restoreTrackData)
  of ccRestoreClip:
    result["trackIndex"] = %cmd.restoreClipTrackIndex
    result["clipIndex"] = %cmd.restoreClipIndex
    result["clip"] = clipToJson(cmd.restoreClipData)
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
  of ccSetProjectInfo:
    cmd = setProjectInfo(
      uint32(field(node, "mask", newJInt(0)).getInt),
      field(node, "name", newJString("")).getStr,
      field(node, "author", newJString("")).getStr,
      float32(field(node, "sampleRate", newJFloat(0.0)).getFloat),
      float32(field(node, "tempo", newJFloat(0.0)).getFloat),
      int32(field(node, "tsNum", newJInt(0)).getInt),
      int32(field(node, "tsDen", newJInt(0)).getInt),
      id)
  of ccAddTrack:
    cmd = addTrack(field(node, "name", newJString("")).getStr,
                   int32(field(node, "trackType", newJInt(0)).getInt), id)
  of ccRemoveTrack:
    cmd = removeTrack(int32(node["trackIndex"].getInt), id)
  of ccAddClip:
    cmd = addClip(
      int32(node["trackIndex"].getInt),
      int32(field(node, "clipType", newJInt(0)).getInt),
      field(node, "name", newJString("")).getStr,
      int32(field(node, "startTick", newJInt(0)).getInt),
      int32(field(node, "lengthTicks", newJInt(0)).getInt),
      field(node, "loopEnabled", newJBool(false)).getBool,
      uint32(field(node, "color", newJInt(0)).getInt),
      id)
  of ccDeleteClip:
    cmd = deleteClip(int32(node["trackIndex"].getInt),
                     int32(node["clipIndex"].getInt), id)
  of ccSetClip:
    var notes: seq[NoteFormat] = @[]
    if node.hasKey("notes"):
      for n in node["notes"].items:
        notes.add NoteFormat(
          startTick: int32(field(n, "startTick", newJInt(0)).getInt),
          duration: int32(field(n, "duration", newJInt(0)).getInt),
          pitch: uint8(field(n, "pitch", newJInt(0)).getInt),
          velocity: uint8(field(n, "velocity", newJInt(0)).getInt),
          channel: uint8(field(n, "channel", newJInt(0)).getInt))
    cmd = setClip(
      int32(node["trackIndex"].getInt),
      int32(node["clipIndex"].getInt),
      notes,
      int32(field(node, "lengthTicks", newJInt(0)).getInt),
      field(node, "loopEnabled", newJBool(false)).getBool,
      field(node, "name", newJString("")).getStr,
      node.hasKey("name"),
      id)
  of ccRestoreTrack:
    cmd = restoreTrack(int32(node["trackIndex"].getInt),
                       trackFromJson(field(node, "track", newJObject())), id)
  of ccRestoreClip:
    cmd = restoreClip(int32(node["trackIndex"].getInt),
                      int32(node["clipIndex"].getInt),
                      clipFromJson(field(node, "clip", newJObject())), id)
  else:
    return false
  cmd.apiVersion = api
  true
