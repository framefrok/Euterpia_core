# project.nim
import std/[algorithm, json, tables, os, strutils]
import signal_types

{.push raises: [].}

# ============================================================================
# ERROR HANDLING & RESULT TYPE
# ============================================================================
type
  ProjectErrorKind* = enum
    pekNone
    pekFileNotFound
    pekIOError
    pekJsonParseError
    pekInvalidFormat
    pekUnsupportedVersion
    pekMissingField
    pekUnknownError

  ProjectError* = object
    kind*: ProjectErrorKind
    message*: string

  ProjectResult*[T] = object
    when T is void:
      case success*: bool
      of true:
        discard
      of false:
        error*: ProjectError
    else:
      case success*: bool
      of true:
        value*: T
      of false:
        error*: ProjectError

proc ok*[T: void](): ProjectResult[void] {.inline.} =
  ProjectResult[void](success: true)

proc ok*[T: not void](val: T): ProjectResult[T] {.inline.} =
  ProjectResult[T](success: true, value: val)

proc err*[T](kind: ProjectErrorKind, msg: string): ProjectResult[T] {.inline.} =
  ProjectResult[T](success: false, error: ProjectError(kind: kind, message: msg))

# ============================================================================
# PROJECT FORMAT (Disk Representation - NO Pointers, NO Runtime State)
# ============================================================================
const
  ProjectFormatName* = "euterpia-project"
  ProjectFormatVersion* = 2
    ## Текущая версия формата. v2 добавил секцию `resources` — аудио-ресурсы
    ## (импорт аудио, issue #107): файлы, на которые ссылаются аудиоклипы.
  ProjectFormatMinVersion* = 1
    ## Минимальная читаемая версия. v1 (проекты без аудио-ресурсов) читается
    ## без потери данных: `resources` пуст — миграция не требуется (§58/§59:
    ## версии не смешиваются, но старый файл открывается, а не отвергается).

  MaxProjectSubgraphDepth* = 32
    ## Предел вложенности субграфов при разборе/записи проекта (аудит, P0).
    ##
    ## Должен совпадать с `graph_compiler.MaxSubgraphDepth`: компилятор
    ## отвергает более глубокие графы, но проверка там стоит ПОСЛЕ загрузки.
    ## Без ограничения здесь враждебный `.eproj` с тысячами вложенных
    ## `subgraphNodes` ронял процесс stack overflow ещё в `loadProject`.
    ## Инвариант «значения равны» проверяет unit-тест.


type
  TimeSignatureFormat* = object
    numerator*: int32
    denominator*: int32

  ProjectMetadata* = object
    name*: string
    author*: string
    sampleRate*: float32
    tempo*: float32
    timeSignature*: TimeSignatureFormat
    created*: string
    modified*: string

  SubgraphPortFormat* = object
    ## Портообразующая связь субграфа (issue #403).
    ##
    ## Субграф — это КОНТЕЙНЕР, а не DSP-нода: у него нет processProc, а его
    ## внешние порты должны быть отображены на порты внутренних нод. Без
    ## такой модели flattening не мог связать внешнюю связь с внутренней.
    ##
    ## `localNodeId` — id ноды ВНУТРИ этого субграфа (локальное пространство),
    ## `localPortIdx` — порт этой ноды того же вида `sigType`, что и внешний
    ## порт. Индекс в `subgraphInputs`/`subgraphOutputs` — это номер внешнего
    ## порта субграфа.
    name*: string
    localNodeId*: int
    localPortIdx*: int
    sigType*: int             # Ordinal of SignalType

  NodeFormat* = object
    id*: int
    nodeType*: string         # ID для NodeFactory (например, "fx.gain")
    name*: string
    audioInCount*: int
    audioOutCount*: int
    ctrlInCount*: int
    ctrlOutCount*: int
    eventInCount*: int
    eventOutCount*: int
    latencyReported*: uint32
    latencyIntrinsic*: uint32
    isSubgraph*: bool
    parameters*: Table[string, float32] # Состояние для восстановления nodeData
    subgraphNodes*: seq[NodeFormat]
    subgraphConnections*: seq[ConnectionFormat]
    subgraphInputs*: seq[SubgraphPortFormat]
      ## Внешний вход k -> внутренняя нода/порт. Только для `isSubgraph`.
    subgraphOutputs*: seq[SubgraphPortFormat]
      ## Внутренняя нода/порт -> внешний выход k. Только для `isSubgraph`.

  ConnectionFormat* = object
    srcNodeId*: int
    srcPortIdx*: int
    dstNodeId*: int
    dstPortIdx*: int
    sigType*: int             # Ordinal of SignalType

  GraphFormat* = object
    nodes*: seq[NodeFormat]
    connections*: seq[ConnectionFormat]

  NoteFormat* = object
    startTick*: int32
    duration*: int32
    pitch*: uint8
    velocity*: uint8
    channel*: uint8

  AudioResourceFormat* = object
    ## Аудио-ресурс проекта (issue #107): ссылка на аудиофайл и его метаданные.
    ##
    ## Сам файл (сэмплы) в проекте НЕ хранится: миллионы float в JSON — это
    ## раздувание и потеря совместимости с внешними редакторами. Формат
    ## фиксирует ССЫЛОЧНУЮ модель (§58); `copy` отмечает, что файл скопирован
    ## в каталог проекта (`--copy`) и переживёт перемещение оригинала.
    id*: int32
    path*: string
      ## Путь к файлу: абсолютный или относительный к файлу проекта.
    sampleRate*: int32
    channels*: int32
    numFrames*: int64
    bitsPerSample*: int32
    isFloat*: bool
    copy*: bool

  ClipFormat* = object
    id*: int32
    clipType*: int
    name*: string
    startTick*: int32
    lengthTicks*: int32
    loopEnabled*: bool
    notes*: seq[NoteFormat]
    audioBufferId*: int32
    resourceId*: int32
      ## Ссылка на `AudioResourceFormat` (audio-клип, issue #107);
      ## -1 — клип не ссылается на аудиоресурс.
    offsetFrames*: int64
      ## Смещение в сэмплах от начала ресурса (audio-клип).
    color*: uint32

  TrackFormat* = object
    id*: int32
    name*: string
    trackType*: int
    clips*: seq[ClipFormat]
    volume*: float32
    pan*: float32
    mute*: bool
    solo*: bool
    armed*: bool
    inputChannel*: int32
    outputBus*: int32

  AutomationPointFormat* = object
    tick*: int32
    value*: float32
    curve*: int               # Ordinal of AutomationCurve

  AutomationLaneFormat* = object
    paramId*: uint32
    nodeId*: int32
    points*: seq[AutomationPointFormat]

  SequencerFormat* = object
    tracks*: seq[TrackFormat]
    automationLanes*: seq[AutomationLaneFormat]

  PluginStateFormat* = object
    ## Непрозрачный снимок состояния плагина, привязанный к узлу графа
    ## (issue #53). Core не знает ни одного формата плагинов: здесь просто
    ## байты, которые положил и заберёт адаптер (CLAP/EUT/…) на стороне
    ## CLI/Editor. Блобы хранятся как массив байт, чтобы round-trip был
    ## байт-в-байт (base64 в JSON был бы лишним слоем кодирования).
    nodeId*: int
    pluginId*: string
    state*: seq[byte]

  ProjectFormat* = object
    format*: string
    version*: int
    metadata*: ProjectMetadata
    graph*: GraphFormat
    sequencer*: SequencerFormat
    pluginStates*: seq[PluginStateFormat]
    resources*: seq[AudioResourceFormat]
      ## Аудио-ресурсы (issue #107). Ссылочная модель: здесь только пути и
      ## метаданные, сэмплы хост загружает при открытии/render.

# ============================================================================
# JSON SERIALIZATION (Exception Safe)
# ============================================================================
proc toJson*(p: ProjectFormat): JsonNode =
  var root = newJObject()
  root["format"] = %p.format
  root["version"] = %p.version
  
  var meta = newJObject()
  meta["name"] = %p.metadata.name
  meta["author"] = %p.metadata.author
  meta["sampleRate"] = %p.metadata.sampleRate
  meta["tempo"] = %p.metadata.tempo
  # 0 в нулевом TimeSignatureFormat означает «не задан» — это дефолт
  # Nim-объекта, а не размер такта. Пишем 4/4, как при загрузке
  # отсутствующего блока: иначе round-trip self-made проекта отклонялся
  # бы собственной валидацией диапазона (issue #390).
  let tsNum = (if p.metadata.timeSignature.numerator <= 0: 4
               else: p.metadata.timeSignature.numerator)
  let tsDen = (if p.metadata.timeSignature.denominator <= 0: 4
               else: p.metadata.timeSignature.denominator)
  meta["timeSignature"] = %*{
    "numerator": tsNum,
    "denominator": tsDen
  }
  meta["created"] = %p.metadata.created
  meta["modified"] = %p.metadata.modified
  root["metadata"] = meta
  
  var graphJson = newJObject()
  var nodesJson = newJArray()
  
  proc nodeToJson(n: NodeFormat; depth = 0): JsonNode =
    result = newJObject()
    result["id"] = %n.id
    result["nodeType"] = %n.nodeType
    result["name"] = %n.name
    result["audioInCount"] = %n.audioInCount
    result["audioOutCount"] = %n.audioOutCount
    result["ctrlInCount"] = %n.ctrlInCount
    result["ctrlOutCount"] = %n.ctrlOutCount
    result["eventInCount"] = %n.eventInCount
    result["eventOutCount"] = %n.eventOutCount
    result["latencyReported"] = %int(n.latencyReported)
    result["latencyIntrinsic"] = %int(n.latencyIntrinsic)
    result["isSubgraph"] = %n.isSubgraph
    
    # Канонический JSON (issue #390): ключи параметров сортируются, иначе два
    # логически равных проекта (разный порядок вставки в Table) дают разный
    # байт-поток — мусорные git-диффы и невоспроизводимость в CI/AI.
    var params = newJObject()
    var paramKeys: seq[string] = @[]
    for k in n.parameters.keys: paramKeys.add k
    paramKeys.sort()
    for k in paramKeys: params[k] = %n.parameters.getOrDefault(k)
    result["parameters"] = params
    
    var subNodes = newJArray()
    # Защита от неограниченной рекурсии (аудит, P0). `saveProject` заранее
    # отвергает слишком глубокий граф, но `toJson` публичный: здесь глубина
    # обрезается, чтобы сериализация не могла уронить стек.
    if depth < MaxProjectSubgraphDepth:
      for sn in n.subgraphNodes: subNodes.add(nodeToJson(sn, depth + 1))
    result["subgraphNodes"] = subNodes
    
    var subConns = newJArray()
    for sc in n.subgraphConnections:
      subConns.add(%*{
        "srcNodeId": sc.srcNodeId, "srcPortIdx": sc.srcPortIdx,
        "dstNodeId": sc.dstNodeId, "dstPortIdx": sc.dstPortIdx,
        "sigType": sc.sigType
      })
    result["subgraphConnections"] = subConns

    var subIns = newJArray()
    for port in n.subgraphInputs:
      subIns.add(%*{
        "name": port.name, "localNodeId": port.localNodeId,
        "localPortIdx": port.localPortIdx, "sigType": port.sigType
      })
    result["subgraphInputs"] = subIns

    var subOuts = newJArray()
    for port in n.subgraphOutputs:
      subOuts.add(%*{
        "name": port.name, "localNodeId": port.localNodeId,
        "localPortIdx": port.localPortIdx, "sigType": port.sigType
      })
    result["subgraphOutputs"] = subOuts

  for node in p.graph.nodes:
    nodesJson.add(nodeToJson(node))
  graphJson["nodes"] = nodesJson
  
  var connsJson = newJArray()
  for conn in p.graph.connections:
    connsJson.add(%*{
      "srcNodeId": conn.srcNodeId, "srcPortIdx": conn.srcPortIdx,
      "dstNodeId": conn.dstNodeId, "dstPortIdx": conn.dstPortIdx,
      "sigType": conn.sigType
    })
  graphJson["connections"] = connsJson
  root["graph"] = graphJson
  
  var seqJson = newJObject()
  var tracksJson = newJArray()
  for track in p.sequencer.tracks:
    var trackJson = newJObject()
    trackJson["id"] = %track.id
    trackJson["name"] = %track.name
    trackJson["trackType"] = %track.trackType
    trackJson["volume"] = %track.volume
    trackJson["pan"] = %track.pan
    trackJson["mute"] = %track.mute
    trackJson["solo"] = %track.solo
    trackJson["armed"] = %track.armed
    trackJson["inputChannel"] = %track.inputChannel
    trackJson["outputBus"] = %track.outputBus
    
    var clipsJson = newJArray()
    for clip in track.clips:
      var clipJson = newJObject()
      clipJson["id"] = %clip.id
      clipJson["clipType"] = %clip.clipType
      clipJson["name"] = %clip.name
      clipJson["startTick"] = %clip.startTick
      clipJson["lengthTicks"] = %clip.lengthTicks
      clipJson["loopEnabled"] = %clip.loopEnabled
      clipJson["audioBufferId"] = %clip.audioBufferId
      clipJson["resourceId"] = %clip.resourceId
      clipJson["offsetFrames"] = %clip.offsetFrames
      clipJson["color"] = %int(clip.color)
      
      var notesJson = newJArray()
      for note in clip.notes:
        notesJson.add(%*{
          "startTick": note.startTick, "duration": note.duration,
          "pitch": note.pitch, "velocity": note.velocity, "channel": note.channel
        })
      clipJson["notes"] = notesJson
      clipsJson.add(clipJson)
    trackJson["clips"] = clipsJson
    tracksJson.add(trackJson)
  seqJson["tracks"] = tracksJson
  
  var lanesJson = newJArray()
  for lane in p.sequencer.automationLanes:
    var laneJson = newJObject()
    laneJson["paramId"] = %int(lane.paramId)
    laneJson["nodeId"] = %lane.nodeId
    var ptsJson = newJArray()
    for pt in lane.points:
      ptsJson.add(%*{"tick": pt.tick, "value": pt.value, "curve": pt.curve})
    laneJson["points"] = ptsJson
    lanesJson.add(laneJson)
  seqJson["automationLanes"] = lanesJson
  
  root["sequencer"] = seqJson

  # Состояние плагинов: непрозрачные блобы, привязанные к узлам графа.
  var statesJson = newJArray()
  for ps in p.pluginStates:
    var stJson = newJObject()
    stJson["nodeId"] = %ps.nodeId
    stJson["pluginId"] = %ps.pluginId
    var bytesJson = newJArray()
    for b in ps.state:
      bytesJson.add(%int(b))
    stJson["state"] = bytesJson
    statesJson.add(stJson)
  root["pluginStates"] = statesJson

  # Аудио-ресурсы (issue #107): ссылки на файлы + метаданные. Секция читается
  # форматом v2; в v1 её нет — тогда `resources` пуст (миграция не нужна).
  var resourcesJson = newJArray()
  for res in p.resources:
    resourcesJson.add(%*{
      "id": res.id, "path": res.path, "sampleRate": res.sampleRate,
      "channels": res.channels, "numFrames": res.numFrames,
      "bitsPerSample": res.bitsPerSample, "isFloat": res.isFloat,
      "copy": res.copy
    })
  root["resources"] = resourcesJson

  return root

# ============================================================================
# DESERIALIZATION HELPERS
# ============================================================================
proc safeStr(n: JsonNode, key: string, def: string = ""): string =
  let val = n{key}
  if val != nil and val.kind == JString: val.str else: def

proc safeInt(n: JsonNode, key: string, def: int = 0): int =
  ## Целое поле без проверки смыслового диапазона.
  ##
  ## Платформенная страховка (аудит, P0): `JsonNode.num` — `int64`, а `int`
  ## на 32-битных сборках уже. Прямое `int(val.num)` вне диапазона давало
  ## `RangeDefect`; теперь значение, не помещающееся в `int`, считается
  ## отсутствующим. Смысловые границы (`int32`, `uint8`, порты) проверяет
  ## `narrowInt`.
  let val = n{key}
  if val != nil and val.kind == JInt:
    when sizeof(int) < sizeof(int64):
      if val.num < int64(low(int)) or val.num > int64(high(int)):
        return def
    int(val.num)
  else:
    def

proc safeSigType(n: JsonNode, key: string, err: var string): int =
  ## Ordinal `SignalType` из файла с проверкой диапазона (аудит, P0).
  ##
  ## Раньше `sigType` читался без валидации: значение 99 позже превращалось
  ## в `ControlPortKind(conn.sigType)` / `SignalType(...)` и давало
  ## RangeDefect уже в control-слое. Теперь мусор — ошибка формата.
  result = safeInt(n, key, 0)
  if result < 0 or result > ord(high(SignalType)):
    if err.len > 0: err.add("; ")
    err.add("'" & key & "'=" & $result & " вне диапазона [0.." &
            $ord(high(SignalType)) & "]")
    result = 0

proc latencyValue(n: JsonNode; key: string): uint32 =
  ## Latency из файла с насыщением на пределе (issue #405).
  ##
  ## `uint32(-1)` или гигантское число из повреждённого проекта раньше
  ## заворачивались в «маленькую» задержку. Теперь любое значение вне
  ## `0 .. MaxLatencyFrames` превращается в предел, и компилятор честно
  ## отказывает `cekLatencyOverflow`, а не компенсирует мусор.
  let value = safeInt(n, key)
  if value == 0:
    return 0'u32
  if value < 0 or uint64(value) > uint64(MaxLatencyFrames):
    # Маркер «заведомо больше предела»: компилятор вернёт
    # `cekLatencyOverflow`, а не примет мусор за валидную задержку.
    return MaxLatencyFrames + 1'u32
  uint32(value)

proc safeFloat(n: JsonNode, key: string, def: float = 0.0): float =
  let val = n{key}
  if val != nil:
    if val.kind == JFloat: val.fnum
    elif val.kind == JInt: float(val.num)
    else: def
  else: def

proc safeBool(n: JsonNode, key: string, def: bool = false): bool =
  let val = n{key}
  if val != nil and val.kind == JBool: val.bval else: def

proc isJObject(n: JsonNode): bool {.inline.} =
  ## Элемент массива — объект?
  ##
  ## Все массивы формата проекта содержат ТОЛЬКО объекты. Не-объект — это
  ## повреждённый файл, и подставлять вместо него «мусорную» ноду/точку из
  ## дефолтов `safe*` нельзя: граф молча получал бы лишние узлы (issue #75).
  ## Поэтому такие элементы пропускаются.
  not n.isNil and n.kind == JObject

proc narrowInt(n: JsonNode, key: string, lo, hi: int64, def: int,
               err: var string): int =
  ## Целочисленное поле с проверкой диапазона (issue #390, EUT-NEW-034).
  ##
  ## JSON-число читается как `int64` и проверяется на попадание в `[lo, hi]`
  ## ДО сужения до целевого типа поля. Выход за диапазон — ошибка формата с
  ## именем поля, а не молчаливый wrap: `pitch: 300` раньше превращался в 44,
  ## `latency: -1` — в 4294967295. Отсутствующее поле (или не-целое значение)
  ## по-прежнему даёт `def` — необязательные поля не роняют загрузку.
  let val = n{key}
  if val == nil or val.kind != JInt: return def
  let v = val.num
  if v < lo or v > hi:
    if err.len > 0: err.add("; ")
    err.add("'" & key & "'=" & $v & " вне диапазона [" & $lo & ".." & $hi & "]")
    return def
  return int(v)

proc parseNode(n: JsonNode, err: var string; depth = 0): NodeFormat =
  ## Разбор ноды проекта. `depth` ограничивает вложенность субграфов:
  ## рекурсия глубже `MaxProjectSubgraphDepth` — ошибка формата, а не
  ## stack overflow (аудит, P0).
  result.id = safeInt(n, "id")
  if depth > MaxProjectSubgraphDepth:
    if err.len > 0: err.add("; ")
    err.add("вложенность субграфов больше " & $MaxProjectSubgraphDepth)
    return
  result.nodeType = safeStr(n, "nodeType")
  result.name = safeStr(n, "name")
  result.audioInCount = safeInt(n, "audioInCount")
  result.audioOutCount = safeInt(n, "audioOutCount")
  result.ctrlInCount = safeInt(n, "ctrlInCount")
  result.ctrlOutCount = safeInt(n, "ctrlOutCount")
  result.eventInCount = safeInt(n, "eventInCount")
  result.eventOutCount = safeInt(n, "eventOutCount")
  result.latencyReported = latencyValue(n, "latencyReported")
  result.latencyIntrinsic = latencyValue(n, "latencyIntrinsic")
  result.isSubgraph = safeBool(n, "isSubgraph")
  
  let paramsNode = n{"parameters"}
  if paramsNode != nil and paramsNode.kind == JObject:
    for k, v in paramsNode:
      if v.kind == JFloat: result.parameters[k] = float32(v.fnum)
      elif v.kind == JInt: result.parameters[k] = float32(v.num)
      
  let subNodesNode = n{"subgraphNodes"}
  if subNodesNode != nil and subNodesNode.kind == JArray:
    for sn in subNodesNode:
      if not isJObject(sn): continue
      if depth < MaxProjectSubgraphDepth:
        result.subgraphNodes.add(parseNode(sn, err, depth + 1))
      elif err.len == 0 or not err.contains("вложенность субграфов"):
        # Рекурсия дальше предела не идёт: файл всё равно будет отклонён,
        # но стек остаётся целым.
        if err.len > 0: err.add("; ")
        err.add("вложенность субграфов больше " & $MaxProjectSubgraphDepth)
      
  let subConnsNode = n{"subgraphConnections"}
  if subConnsNode != nil and subConnsNode.kind == JArray:
    for sc in subConnsNode:
      if not isJObject(sc): continue
      result.subgraphConnections.add(ConnectionFormat(
        srcNodeId: safeInt(sc, "srcNodeId"), srcPortIdx: safeInt(sc, "srcPortIdx"),
        dstNodeId: safeInt(sc, "dstNodeId"), dstPortIdx: safeInt(sc, "dstPortIdx"),
        sigType: safeSigType(sc, "sigType", err)
      ))

  let subInsNode = n{"subgraphInputs"}
  if subInsNode != nil and subInsNode.kind == JArray:
    for port in subInsNode:
      if not isJObject(port): continue
      result.subgraphInputs.add(SubgraphPortFormat(
        name: safeStr(port, "name"),
        localNodeId: safeInt(port, "localNodeId"),
        localPortIdx: safeInt(port, "localPortIdx"),
        sigType: safeSigType(port, "sigType", err)
      ))

  let subOutsNode = n{"subgraphOutputs"}
  if subOutsNode != nil and subOutsNode.kind == JArray:
    for port in subOutsNode:
      if not isJObject(port): continue
      result.subgraphOutputs.add(SubgraphPortFormat(
        name: safeStr(port, "name"),
        localNodeId: safeInt(port, "localNodeId"),
        localPortIdx: safeInt(port, "localPortIdx"),
        sigType: safeSigType(port, "sigType", err)
      ))

# ============================================================================
# PUBLIC API: SAVE & LOAD
# ============================================================================

proc subgraphDepthWithinLimit(nodes: seq[NodeFormat]; depth: int): bool =
  ## Проверка глубины ПЕРЕД сериализацией (аудит, P0).
  ##
  ## Рекурсия ограничена самим лимитом: на `depth > MaxProjectSubgraphDepth`
  ## функция сразу возвращает false, поэтому стек не растёт бесконечно.
  ## Пустой список детей глубину не увеличивает (лист на пределе допустим).
  if nodes.len == 0:
    return true
  if depth > MaxProjectSubgraphDepth:
    return false
  for n in nodes:
    if not subgraphDepthWithinLimit(n.subgraphNodes, depth + 1):
      return false
  true

proc saveProject*(project: ProjectFormat, filepath: string): ProjectResult[void] =
  ## Атомарная запись проекта (issue #390): tmp-файл рядом с целью + flush +
  ## close + переименование. Читатель видит либо старый файл целиком, либо
  ## новый целиком: падение в момент записи не портит `project.eproj`.
  ##
  ## Имя tmp содержит PID: две параллельные записи не подменят друг другу
  ## буфер. Прежний файл сохраняется как `.bak` (best-effort: неудача бэкапа
  ## не отменяет успешную запись, это страховка, а не контракт).
  if not subgraphDepthWithinLimit(project.graph.nodes, 0):
    return err[void](pekInvalidFormat,
      "вложенность субграфов больше " & $MaxProjectSubgraphDepth &
      ": запись невозможна (загруженный проект такую глубину не примет)")
  let tmp = filepath & ".tmp-" & $getCurrentProcessId()
  var f: File
  try:
    f = open(tmp, fmWrite)
    try:
      f.write(pretty(project.toJson()))
      f.flushFile()
    finally:
      close(f)
    # Best-effort бэкап прежней версии до подмены.
    if fileExists(filepath):
      try:
        copyFile(filepath, filepath & ".bak")
      except CatchableError:
        discard
    moveFile(tmp, filepath)
    return ok[void]()
  except CatchableError as e:
    # Мусорный tmp-файл не оставляем: иначе он переживёт процесс и будет
    # выглядеть как «второй проект».
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return err[void](pekIOError, "Failed to save project: " & e.msg)
  except Exception:
    # `moveFile` — `extern` без аннотации raises, поэтому под `raises: []`
    # требует перехвата и `Exception` (Defect = авария: OOM, assertion).
    # Ловим, чтобы сбой записи стал `pekIOError`, а не стеком наружу.
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return err[void](pekIOError, "Failed to save project: OS error")

proc loadProject*(filepath: string): ProjectResult[ProjectFormat] =
  if not fileExists(filepath):
    return err[ProjectFormat](pekFileNotFound, "Project file not found: " & filepath)
  
  var jsonStr: string
  try:
    jsonStr = readFile(filepath)
  except CatchableError as e:
    return err[ProjectFormat](pekIOError, "Failed to read file: " & e.msg)
    
  var root: JsonNode
  try:
    root = parseJson(jsonStr)
  except CatchableError as e:
    return err[ProjectFormat](pekJsonParseError, "Invalid JSON format: " & e.msg)
    
  if root.kind != JObject:
    return err[ProjectFormat](pekInvalidFormat, "Root JSON element must be an object.")
    
  let fmt = safeStr(root, "format")
  if fmt != ProjectFormatName:
    return err[ProjectFormat](pekInvalidFormat, "Invalid project format. Expected: " & ProjectFormatName)
    
  let ver = safeInt(root, "version")
  if ver < ProjectFormatMinVersion or ver > ProjectFormatVersion:
    return err[ProjectFormat](pekUnsupportedVersion,
      "Unsupported project version: " & $ver & " (supported " &
      $ProjectFormatMinVersion & ".." & $ProjectFormatVersion & ")")

  var res: ProjectFormat
  res.format = fmt
  res.version = ver

  # Коллектор нарушений диапазонов (issue #390, EUT-NEW-034): сужение типа
  # (`pitch: 300` → 44, `latency: -1` → 4294967295) раньше происходило молча.
  # Теперь файл с такими значениями отклоняется целиком: частично
  # протащенная нота хуже честной ошибки.
  var rangeErr: string

  # Дефолты метаданных совпадают с initTransport (48 кГц, 120 BPM, 4/4).
  # Без этого проект без блока metadata — или без timeSignature внутри
  # него — давал бы вырожденное состояние: tempo 0 обнуляет
  # samplesPerQuarter(), размер 0/0 обнуляет beatsPerBar(), и таймлайн
  # (BBT, loop) перестаёт двигаться. Тест #57 это фиксирует.
  res.metadata.sampleRate = 48000.0f
  res.metadata.tempo = 120.0f
  res.metadata.timeSignature = TimeSignatureFormat(numerator: 4, denominator: 4)

  let metaNode = root{"metadata"}
  if metaNode != nil and metaNode.kind == JObject:
    res.metadata.name = safeStr(metaNode, "name")
    res.metadata.author = safeStr(metaNode, "author")
    res.metadata.sampleRate = float32(safeFloat(metaNode, "sampleRate", 48000.0))
    res.metadata.tempo = float32(safeFloat(metaNode, "tempo", 120.0))
    let tsNode = metaNode{"timeSignature"}
    if tsNode != nil and tsNode.kind == JObject:
      res.metadata.timeSignature.numerator =
        int32(narrowInt(tsNode, "numerator", 1, 64, 4, rangeErr))
      res.metadata.timeSignature.denominator =
        int32(narrowInt(tsNode, "denominator", 1, 64, 4, rangeErr))
    res.metadata.created = safeStr(metaNode, "created")
    res.metadata.modified = safeStr(metaNode, "modified")
    
  let graphNode = root{"graph"}
  if graphNode != nil and graphNode.kind == JObject:
    let nodesNode = graphNode{"nodes"}
    if nodesNode != nil and nodesNode.kind == JArray:
      for n in nodesNode:
        if not isJObject(n): continue
        res.graph.nodes.add(parseNode(n, rangeErr))
    let connsNode = graphNode{"connections"}
    if connsNode != nil and connsNode.kind == JArray:
      for c in connsNode:
        if not isJObject(c): continue
        res.graph.connections.add(ConnectionFormat(
          srcNodeId: safeInt(c, "srcNodeId"), srcPortIdx: safeInt(c, "srcPortIdx"),
          dstNodeId: safeInt(c, "dstNodeId"), dstPortIdx: safeInt(c, "dstPortIdx"),
          sigType: safeSigType(c, "sigType", rangeErr)
        ))
        
  let seqNode = root{"sequencer"}
  if seqNode != nil and seqNode.kind == JObject:
    let tracksNode = seqNode{"tracks"}
    if tracksNode != nil and tracksNode.kind == JArray:
      for t in tracksNode:
        if not isJObject(t): continue
        var track = TrackFormat(
          id: int32(narrowInt(t, "id", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
          name: safeStr(t, "name"),
          trackType: safeInt(t, "trackType"),
          volume: float32(safeFloat(t, "volume", 1.0)),
          pan: float32(safeFloat(t, "pan")),
          mute: safeBool(t, "mute"),
          solo: safeBool(t, "solo"),
          armed: safeBool(t, "armed"),
          inputChannel: int32(narrowInt(t, "inputChannel", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
          outputBus: int32(narrowInt(t, "outputBus", int64(low(int32)), int64(high(int32)), 0, rangeErr))
        )
        let clipsNode = t{"clips"}
        if clipsNode != nil and clipsNode.kind == JArray:
          for c in clipsNode:
            if not isJObject(c): continue
            var clip = ClipFormat(
              id: int32(narrowInt(c, "id", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
              clipType: safeInt(c, "clipType"),
              name: safeStr(c, "name"),
              startTick: int32(narrowInt(c, "startTick", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
              lengthTicks: int32(narrowInt(c, "lengthTicks", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
              loopEnabled: safeBool(c, "loopEnabled"),
              audioBufferId: int32(narrowInt(c, "audioBufferId", int64(low(int32)), int64(high(int32)), -1, rangeErr)),
              resourceId: int32(narrowInt(c, "resourceId", int64(low(int32)), int64(high(int32)), -1, rangeErr)),
              offsetFrames: int64(narrowInt(c, "offsetFrames", 0, int64(high(int64)), 0, rangeErr)),
              color: uint32(narrowInt(c, "color", 0, int64(high(uint32)), 0, rangeErr))
            )
            let notesNode = c{"notes"}
            if notesNode != nil and notesNode.kind == JArray:
              for n in notesNode:
                if not isJObject(n): continue
                clip.notes.add(NoteFormat(
                  startTick: int32(narrowInt(n, "startTick", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
                  duration: int32(narrowInt(n, "duration", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
                  pitch: uint8(narrowInt(n, "pitch", 0, 255, 0, rangeErr)),
                  velocity: uint8(narrowInt(n, "velocity", 0, 255, 0, rangeErr)),
                  channel: uint8(narrowInt(n, "channel", 0, 255, 0, rangeErr))
                ))
            track.clips.add(clip)
        res.sequencer.tracks.add(track)
        
    let lanesNode = seqNode{"automationLanes"}
    if lanesNode != nil and lanesNode.kind == JArray:
      for l in lanesNode:
        if not isJObject(l): continue
        var lane = AutomationLaneFormat(
          paramId: uint32(narrowInt(l, "paramId", 0, int64(high(uint32)), 0, rangeErr)),
          nodeId: int32(narrowInt(l, "nodeId", int64(low(int32)), int64(high(int32)), 0, rangeErr))
        )
        let pointsNode = l{"points"}
        if pointsNode != nil and pointsNode.kind == JArray:
          for p in pointsNode:
            if not isJObject(p): continue
            lane.points.add(AutomationPointFormat(
              tick: int32(narrowInt(p, "tick", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
              value: float32(safeFloat(p, "value")),
              curve: safeInt(p, "curve")
            ))
        res.sequencer.automationLanes.add(lane)

  let statesNode = root{"pluginStates"}
  if statesNode != nil and statesNode.kind == JArray:
    for s in statesNode:
      var ps = PluginStateFormat(
        nodeId: safeInt(s, "nodeId"),
        pluginId: safeStr(s, "pluginId"))
      let bytesNode = s{"state"}
      if bytesNode != nil and bytesNode.kind == JArray:
        for b in bytesNode:
          if b != nil and b.kind == JInt:
            ps.state.add(byte(int(b.num) and 0xFF))
      res.pluginStates.add(ps)

  let resourcesNode = root{"resources"}
  if resourcesNode != nil and resourcesNode.kind == JArray:
    for r in resourcesNode:
      if not isJObject(r): continue
      res.resources.add(AudioResourceFormat(
        id: int32(narrowInt(r, "id", int64(low(int32)), int64(high(int32)), 0, rangeErr)),
        path: safeStr(r, "path"),
        sampleRate: int32(narrowInt(r, "sampleRate", 1, int64(high(int32)), 0, rangeErr)),
        channels: int32(narrowInt(r, "channels", 1, int64(high(int32)), 0, rangeErr)),
        numFrames: int64(narrowInt(r, "numFrames", 0, int64(high(int64)), 0, rangeErr)),
        bitsPerSample: int32(narrowInt(r, "bitsPerSample", 0, int64(high(int32)), 0, rangeErr)),
        isFloat: safeBool(r, "isFloat"),
        copy: safeBool(r, "copy")))

  # Значения вне диапазона целевых типов (issue #390, EUT-NEW-034): файл
  # отклоняется целиком, а не загружается с молчаливо обрезанными полями.
  if rangeErr.len > 0:
    return err[ProjectFormat](pekInvalidFormat,
      "Значения полей вне допустимого диапазона: " & rangeErr)

  return ok[ProjectFormat](res)

{.pop.}