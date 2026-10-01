# project.nim
import std/[json, tables, os]

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
  ProjectFormatVersion* = 1

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

  ClipFormat* = object
    id*: int32
    clipType*: int
    name*: string
    startTick*: int32
    lengthTicks*: int32
    loopEnabled*: bool
    notes*: seq[NoteFormat]
    audioBufferId*: int32
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
  meta["timeSignature"] = %*{
    "numerator": p.metadata.timeSignature.numerator,
    "denominator": p.metadata.timeSignature.denominator
  }
  meta["created"] = %p.metadata.created
  meta["modified"] = %p.metadata.modified
  root["metadata"] = meta
  
  var graphJson = newJObject()
  var nodesJson = newJArray()
  
  proc nodeToJson(n: NodeFormat): JsonNode =
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
    
    var params = newJObject()
    for k, v in n.parameters: params[k] = %v
    result["parameters"] = params
    
    var subNodes = newJArray()
    for sn in n.subgraphNodes: subNodes.add(nodeToJson(sn))
    result["subgraphNodes"] = subNodes
    
    var subConns = newJArray()
    for sc in n.subgraphConnections:
      subConns.add(%*{
        "srcNodeId": sc.srcNodeId, "srcPortIdx": sc.srcPortIdx,
        "dstNodeId": sc.dstNodeId, "dstPortIdx": sc.dstPortIdx,
        "sigType": sc.sigType
      })
    result["subgraphConnections"] = subConns

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

  return root

# ============================================================================
# DESERIALIZATION HELPERS
# ============================================================================
proc safeStr(n: JsonNode, key: string, def: string = ""): string =
  let val = n{key}
  if val != nil and val.kind == JString: val.str else: def

proc safeInt(n: JsonNode, key: string, def: int = 0): int =
  let val = n{key}
  if val != nil and val.kind == JInt: int(val.num) else: def

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

proc parseNode(n: JsonNode): NodeFormat =
  result.id = safeInt(n, "id")
  result.nodeType = safeStr(n, "nodeType")
  result.name = safeStr(n, "name")
  result.audioInCount = safeInt(n, "audioInCount")
  result.audioOutCount = safeInt(n, "audioOutCount")
  result.ctrlInCount = safeInt(n, "ctrlInCount")
  result.ctrlOutCount = safeInt(n, "ctrlOutCount")
  result.eventInCount = safeInt(n, "eventInCount")
  result.eventOutCount = safeInt(n, "eventOutCount")
  result.latencyReported = uint32(safeInt(n, "latencyReported"))
  result.latencyIntrinsic = uint32(safeInt(n, "latencyIntrinsic"))
  result.isSubgraph = safeBool(n, "isSubgraph")
  
  let paramsNode = n{"parameters"}
  if paramsNode != nil and paramsNode.kind == JObject:
    for k, v in paramsNode:
      if v.kind == JFloat: result.parameters[k] = float32(v.fnum)
      elif v.kind == JInt: result.parameters[k] = float32(v.num)
      
  let subNodesNode = n{"subgraphNodes"}
  if subNodesNode != nil and subNodesNode.kind == JArray:
    for sn in subNodesNode:
      result.subgraphNodes.add(parseNode(sn))
      
  let subConnsNode = n{"subgraphConnections"}
  if subConnsNode != nil and subConnsNode.kind == JArray:
    for sc in subConnsNode:
      result.subgraphConnections.add(ConnectionFormat(
        srcNodeId: safeInt(sc, "srcNodeId"), srcPortIdx: safeInt(sc, "srcPortIdx"),
        dstNodeId: safeInt(sc, "dstNodeId"), dstPortIdx: safeInt(sc, "dstPortIdx"),
        sigType: safeInt(sc, "sigType")
      ))

# ============================================================================
# PUBLIC API: SAVE & LOAD
# ============================================================================

proc saveProject*(project: ProjectFormat, filepath: string): ProjectResult[void] =
  try:
    let jsonStr = pretty(project.toJson())
    writeFile(filepath, jsonStr)
    return ok[void]()
  except CatchableError as e:
    return err[void](pekIOError, "Failed to save project: " & e.msg)

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
  if ver != ProjectFormatVersion:
    return err[ProjectFormat](pekUnsupportedVersion, "Unsupported project version: " & $ver)

  var res: ProjectFormat
  res.format = fmt
  res.version = ver

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
      res.metadata.timeSignature.numerator = int32(safeInt(tsNode, "numerator", 4))
      res.metadata.timeSignature.denominator = int32(safeInt(tsNode, "denominator", 4))
    res.metadata.created = safeStr(metaNode, "created")
    res.metadata.modified = safeStr(metaNode, "modified")
    
  let graphNode = root{"graph"}
  if graphNode != nil and graphNode.kind == JObject:
    let nodesNode = graphNode{"nodes"}
    if nodesNode != nil and nodesNode.kind == JArray:
      for n in nodesNode:
        res.graph.nodes.add(parseNode(n))
    let connsNode = graphNode{"connections"}
    if connsNode != nil and connsNode.kind == JArray:
      for c in connsNode:
        res.graph.connections.add(ConnectionFormat(
          srcNodeId: safeInt(c, "srcNodeId"), srcPortIdx: safeInt(c, "srcPortIdx"),
          dstNodeId: safeInt(c, "dstNodeId"), dstPortIdx: safeInt(c, "dstPortIdx"),
          sigType: safeInt(c, "sigType")
        ))
        
  let seqNode = root{"sequencer"}
  if seqNode != nil and seqNode.kind == JObject:
    let tracksNode = seqNode{"tracks"}
    if tracksNode != nil and tracksNode.kind == JArray:
      for t in tracksNode:
        var track = TrackFormat(
          id: int32(safeInt(t, "id")),
          name: safeStr(t, "name"),
          trackType: safeInt(t, "trackType"),
          volume: float32(safeFloat(t, "volume", 1.0)),
          pan: float32(safeFloat(t, "pan")),
          mute: safeBool(t, "mute"),
          solo: safeBool(t, "solo"),
          armed: safeBool(t, "armed"),
          inputChannel: int32(safeInt(t, "inputChannel")),
          outputBus: int32(safeInt(t, "outputBus"))
        )
        let clipsNode = t{"clips"}
        if clipsNode != nil and clipsNode.kind == JArray:
          for c in clipsNode:
            var clip = ClipFormat(
              id: int32(safeInt(c, "id")),
              clipType: safeInt(c, "clipType"),
              name: safeStr(c, "name"),
              startTick: int32(safeInt(c, "startTick")),
              lengthTicks: int32(safeInt(c, "lengthTicks")),
              loopEnabled: safeBool(c, "loopEnabled"),
              audioBufferId: int32(safeInt(c, "audioBufferId", -1)),
              color: uint32(safeInt(c, "color"))
            )
            let notesNode = c{"notes"}
            if notesNode != nil and notesNode.kind == JArray:
              for n in notesNode:
                clip.notes.add(NoteFormat(
                  startTick: int32(safeInt(n, "startTick")),
                  duration: int32(safeInt(n, "duration")),
                  pitch: uint8(safeInt(n, "pitch")),
                  velocity: uint8(safeInt(n, "velocity")),
                  channel: uint8(safeInt(n, "channel"))
                ))
            track.clips.add(clip)
        res.sequencer.tracks.add(track)
        
    let lanesNode = seqNode{"automationLanes"}
    if lanesNode != nil and lanesNode.kind == JArray:
      for l in lanesNode:
        var lane = AutomationLaneFormat(
          paramId: uint32(safeInt(l, "paramId")),
          nodeId: int32(safeInt(l, "nodeId"))
        )
        let pointsNode = l{"points"}
        if pointsNode != nil and pointsNode.kind == JArray:
          for p in pointsNode:
            lane.points.add(AutomationPointFormat(
              tick: int32(safeInt(p, "tick")),
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

  return ok[ProjectFormat](res)

{.pop.}