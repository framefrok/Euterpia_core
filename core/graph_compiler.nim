# graph_compiler.nim
import std/[algorithm, tables, math]
import signal_types, node_interface, compiled_pipeline, aligned_mem

{.push raises: [].}

# ============================================================================
# CORE TYPES
# ============================================================================
type
  EditorConnection* = object
    srcNodeId*: int
    srcPortIdx*: int
    dstNodeId*: int
    dstPortIdx*: int
    sigType*: SignalType

  LatencyProfile* = object
    reported*: uint32      
    intrinsic*: uint32     
    compensation*: uint32  

  EditorNode* = object
    id*: int               
    name*: string
    nodeType*: string
    processProc*: ProcessProc
    userData*: pointer
    audioInCount*, audioOutCount*: int32
    ctrlInCount*, ctrlOutCount*: int32
    eventInCount*, eventOutCount*: int32
    latency*: LatencyProfile
    isSubgraph*: bool
    subgraphNodes*: seq[EditorNode]
    subgraphConnections*: seq[EditorConnection]

  NodeGraph* = object
    nodes*: Table[int, EditorNode]
    connections*: seq[EditorConnection]

  ## Классификация ошибки компиляции (issue #391, EUT-NEW-035).
  ##
  ## Раньше было 4 вида, и все, кроме цикла, звучали как «не компилируется».
  ## Пользователь не мог отличить «соединение ссылается на несуществующую
  ## ноду» от «на ноде нет такого порта» — и правил граф наугад. Теперь
  ## каждый класс — отдельный вердикт с указанием ноды/порта, и `graph check`
  ## называет конкретное место поломки.
  CompileErrorKind* = enum
    cekNone
    cekCycleDetected
    cekPdcCycleDetected
    cekAllocationFailed
    cekUnknownNode           ## связь ссылается на ноду, которой нет в графе
    cekUnknownSrcPort        ## нет такого аудиовыхода у ноды-источника
    cekUnknownDstPort        ## нет такого аудиовхода у ноды-приёмника
    cekSignalMismatch        ## sigType связи невалиден
    cekMultipleWriter        ## на один вход пишут два источника
    cekDuplicateConnection   ## одна и та же связь задана дважды
    cekNegativePortIdx       ## отрицательный индекс порта
    cekMasterInvalid         ## мастер ненайдён / не может быть мастером

  ## Ошибка компиляции с адресом поломки (issue #391).
  ##
  ## `kind` — класс, остальное — координаты, чтобы сообщение было
  ## «нода 7, аудиовыход 2: нет такого порта», а не «ошибка компиляции».
  CompileError* = object
    kind*: CompileErrorKind
    nodeId*: int             ## виновная нода (0, если не применимо)
    portIdx*: int            ## виновный порт (-1, если не применимо)
    connection*: int         ## индекс связи в `srcGraph.connections` (-1)
    detail*: string          ## уточнение для лога/CLI (без аллокаций в RT)

  CompileResult* = object
    case success*: bool
    of true:
      pipeline*: ptr CompiledPipeline
    of false:
      error*: CompileError

# ============================================================================
# COMPILER STATE & HELPERS
# ============================================================================
type
  IdAllocator* = object
    nextId*: int

  AdjacencyList* = object
    outgoing*: Table[int, seq[int]] 
    incoming*: Table[int, seq[int]] 

  GraphCompiler* = object
    allocator*: IdAllocator
    delayStateCount*: int
    delayStates*: ptr UncheckedArray[DelayCompensationData]

proc nextId*(a: var IdAllocator): int =
  result = a.nextId
  inc(a.nextId)

proc initAdjacencyList*(g: NodeGraph): AdjacencyList =
  result.outgoing = initTable[int, seq[int]]()
  result.incoming = initTable[int, seq[int]]()
  
  for id in g.nodes.keys:
    result.outgoing[id] = @[]
    result.incoming[id] = @[]

  for c in g.connections:
    if not result.outgoing.hasKey(c.srcNodeId): result.outgoing[c.srcNodeId] = @[]
    if not result.incoming.hasKey(c.dstNodeId): result.incoming[c.dstNodeId] = @[]
    
    let outList = result.outgoing.getOrDefault(c.srcNodeId, @[])
    if c.dstNodeId notin outList:
      var outs = outList
      outs.add(c.dstNodeId)
      result.outgoing[c.srcNodeId] = outs

      var ins = result.incoming.getOrDefault(c.dstNodeId, @[])
      ins.add(c.srcNodeId)
      result.incoming[c.dstNodeId] = ins

# ============================================================================
# DSP NODES (PDC Delay)
# ============================================================================
proc copyThroughDelayNode(inBuf, outBuf: ptr AudioBuffer; channels, stride: int;
                         planar: bool; frames: int) {.inline.} =
  ## Пропустить блок как есть (без задержки). Нужно для безопасного фолбэка.
  for ch in 0 ..< channels:
    for i in 0 ..< frames:
      let idx = if planar: ch * stride + i else: i * channels + ch
      outBuf.data[idx] = inBuf.data[idx]

proc processDelayComp*(ctx: ptr NodeProcessContext,
                       audio: ptr NodeAudioPorts,
                       ctrl: ptr NodeControlPorts,
                       events: ptr NodeEventPorts,
                       userData: pointer) {.cdecl, raises: [].} =
  ## Задержка для выравнивания фаз (PDC).
  ##
  ## Память кольца — per-frame: слоты канала `ch` лежат на
  ## `frame * ringChannels + ch`, а `writePos` считается в КАДРАХ.
  ##
  ## Раньше кольцо было моно: один `writePos`, который продвигался на КАЖДЫЙ
  ## сэмпл, и общая линейная память на все каналы. Для стерео это давало
  ## задержку `diff / channels` кадров и обмен данными между каналами —
  ## компенсация фаз работала неверно (issue #72).
  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf == nil or outBuf == nil or inBuf.data == nil or outBuf.data == nil: return
  if inBuf.channels <= 0 or inBuf.frames <= 0: return

  let frames = min(ctx.blockSize, inBuf.frames)
  if frames <= 0: return
  let channels = inBuf.channels
  let stride = if inBuf.stride > 0: inBuf.stride else: inBuf.frames
  let planar = stride >= inBuf.frames

  let state = cast[ptr DelayCompensationData](userData)
  if state == nil or state.buffer == nil or state.bufferSize <= 0 or
     state.ringChannels <= 0:
    # Кольца нет (не хватило памяти при компиляции графа). Пропускаем сигнал
    # как есть: оставлять в арене старые данные было бы хуже — следующий узел
    # получил бы мусор, который выглядит как звук.
    copyThroughDelayNode(inBuf, outBuf, int(channels), stride, planar, frames)
    return

  let ringCh = int(state.ringChannels)
  let ringFrames = state.bufferSize div ringCh      # ёмкость кольца в кадрах
  if ringFrames <= 0: return

  var delay = state.delayFrames
  if delay < 0: delay = 0
  # Больше кольца задержка быть не может: иначе чтение «завернётся» и
  # задержка молча станет `delay mod ringFrames`.
  if delay >= ringFrames: delay = ringFrames - 1

  let ring = state.buffer
  let ringed = min(int(channels), ringCh)

  for i in 0 ..< frames:
    let wPos = state.writePos * ringCh
    var rFrame = state.writePos - delay
    if rFrame < 0: rFrame += ringFrames
    let rPos = rFrame * ringCh

    for ch in 0 ..< ringed:
      let idx = if planar: ch * stride + i else: i * int(channels) + ch
      outBuf.data[idx] = ring[rPos + ch]
      ring[wPos + ch] = inBuf.data[idx]

    state.writePos = (state.writePos + 1) mod ringFrames

  # Каналы сверх стерео-модели кольца пропускаем как есть: не теряем звук и
  # не выходим за границы буфера. В проекте таких каналов быть не может
  # (`MaxInputChannels = 2`), поэтому «без компенсации» здесь — осознанный
  # безопасный фолбэк, а не рабочий режим.
  if int(channels) > ringed:
    for ch in ringed ..< int(channels):
      for i in 0 ..< frames:
        let idx = if planar: ch * stride + i else: i * int(channels) + ch
        outBuf.data[idx] = inBuf.data[idx]
# ============================================================================
# 1. FLATTENING 
# ============================================================================
proc flattenNode(node: EditorNode,
                 parentId: int,
                 allocator: var IdAllocator,
                 idRemap: var Table[int, int],
                 outNodes: var Table[int, EditorNode],
                 outConnections: var seq[EditorConnection]) =
  let safeId = allocator.nextId()
  idRemap[node.id] = safeId
  
  var newNode = node
  newNode.id = safeId
  newNode.isSubgraph = false
  newNode.subgraphNodes = @[]
  newNode.subgraphConnections = @[]
  
  outNodes[safeId] = newNode

  if node.isSubgraph:
    for subNode in node.subgraphNodes:
      flattenNode(subNode, node.id, allocator, idRemap, outNodes, outConnections)
    
    for subConn in node.subgraphConnections:
      outConnections.add(EditorConnection(
        srcNodeId: idRemap.getOrDefault(subConn.srcNodeId, subConn.srcNodeId),
        srcPortIdx: subConn.srcPortIdx,
        dstNodeId: idRemap.getOrDefault(subConn.dstNodeId, subConn.dstNodeId),
        dstPortIdx: subConn.dstPortIdx,
        sigType: subConn.sigType
      ))

proc flattenGraph*(g: NodeGraph, allocator: var IdAllocator): NodeGraph =
  result.nodes = initTable[int, EditorNode]()
  result.connections = @[]
  
  var idRemap = initTable[int, int]()

  # Обход нод по отсортированным id (issue #391, EUT-NEW-036): `for id, node
  # in g.nodes` шёл в произвольном порядке Table, из-за чего `idRemap` (а с ним
  # и все сгенерированные id сабграфов/PDC) зависел от хеш-порядка. Теперь
  # разворачивание и переприсвоение id — функция только от состава графа.
  var flatIds: seq[int] = @[]
  for id in g.nodes.keys: flatIds.add id
  flatIds.sort()

  for id in flatIds:
    let node = g.nodes.getOrDefault(id, EditorNode())
    flattenNode(node, 0, allocator, idRemap, result.nodes, result.connections)

  for c in g.connections:
    result.connections.add(EditorConnection(
      srcNodeId: idRemap.getOrDefault(c.srcNodeId, c.srcNodeId),
      srcPortIdx: c.srcPortIdx,
      dstNodeId: idRemap.getOrDefault(c.dstNodeId, c.dstNodeId),
      dstPortIdx: c.dstPortIdx,
      sigType: c.sigType
    ))

proc flattenGraph*(g: NodeGraph, allocator: ptr IdAllocator): NodeGraph =
  if allocator != nil:
    result = flattenGraph(g, allocator[])

# ============================================================================
# 2. TOPOLOGICAL SORT 
# ============================================================================
proc topologicalSort*(g: NodeGraph, adj: AdjacencyList, sortedIds: var seq[int]): bool =
  ## Порядок шагов пайплайна (issue #391, EUT-NEW-036).
  ##
  ## Очередь засевается обходом `Table`, чей порядок произволен — один и тот
  ## же граф давал разный `sortedIds`, а значит и разный layout пайплайна
  ## (разные шаги, разные буферы, разные версии в метриках). Теперь и засев,
  ## и развязка идут по отсортированным по id, поэтому порядок шагов —
  ## функция только от структуры графа.
  var inDegree = initTable[int, int]()
  # Отсортированный список id: детерминированный обход вместо порядка Table.
  var nodeIds: seq[int] = @[]
  for id in g.nodes.keys: nodeIds.add id
  nodeIds.sort()
  for id in nodeIds:
    inDegree[id] = adj.incoming.getOrDefault(id, @[]).len

  var q: seq[int] = @[]
  q.setLen(g.nodes.len)
  var head = 0
  var tail = 0

  for id in nodeIds:
    if inDegree.getOrDefault(id, 0) == 0:
      # Защита от переполнения фиксированного буфера очереди
      if tail >= q.len:
        return false
      q[tail] = id
      inc(tail)

  sortedIds.setLen(0)
  while head < tail:
    let u = q[head]
    inc(head)
    sortedIds.add(u)

    # Соседи обходятся в отсортированном порядке: две связи к одной ноде
    # не должны переставлять её в зависимости от порядка вставки в Table.
    let outs = adj.outgoing.getOrDefault(u, @[])
    var outsSorted = outs
    outsSorted.sort()
    for v in outsSorted:
      let curDeg = inDegree.getOrDefault(v, 0) - 1
      inDegree[v] = curDeg
      if curDeg == 0:
        # Защита от переполнения фиксированного буфера при обходе графа
        if tail >= q.len:
          return false
        q[tail] = v
        inc(tail)

  return sortedIds.len == g.nodes.len

# ============================================================================
# 3. LATENCY ANALYSIS & PDC 
# ============================================================================
# ИНВАРИАНТ ПАМЯТИ PDC:
# Массив compiler.delayStates аллоцируется один раз на точный размер delayStateCount.
# Указатели addr compiler.delayStates[currentDelayIdx], сохраняемые в userData нод,
# остаются абсолютно стабильными, так как массив никогда не переаллоцируется и не
# перемещается. Право владения массивом передается 1:1 в pipeline.delayStates в конце
# сборки. Освобождение памяти контролируется функцией destroyPipeline.
proc applyPDC*(g: var NodeGraph, adj: var AdjacencyList, sortedIds: seq[int], compiler: var GraphCompiler) =
  var nodeTotalLatency = initTable[int, uint32]()
  
  for id in sortedIds:
    var maxParentLatency: uint32 = 0
    for srcId in adj.incoming.getOrDefault(id, @[]):
      let pLat = nodeTotalLatency.getOrDefault(srcId, 0'u32)
      if pLat > maxParentLatency:
        maxParentLatency = pLat
    
    if g.nodes.hasKey(id):
      let node = g.nodes.getOrDefault(id, EditorNode())
      let currentLatency = maxParentLatency + node.latency.reported + node.latency.intrinsic
      nodeTotalLatency[id] = currentLatency

  var maxGraphLatency: uint32 = 0
  for id in sortedIds:
    let total = nodeTotalLatency.getOrDefault(id, 0'u32)
    if total > maxGraphLatency:
      maxGraphLatency = total

  var newConnections: seq[EditorConnection] = @[]
  var delayStateCount = 0
  
  for c in g.connections:
    if c.sigType == sigAudio:
      let srcLat = nodeTotalLatency.getOrDefault(c.srcNodeId, 0'u32)
      if srcLat < maxGraphLatency:
        inc(delayStateCount)

  compiler.delayStateCount = delayStateCount
  if delayStateCount > 0:
    compiler.delayStates = cast[ptr UncheckedArray[DelayCompensationData]](
      allocShared0(sizeof(DelayCompensationData) * delayStateCount)
    )
  
  var currentDelayIdx = 0
  for c in g.connections:
    if c.sigType == sigAudio:
      let srcLat = nodeTotalLatency.getOrDefault(c.srcNodeId, 0'u32)
      if srcLat < maxGraphLatency:
        let diff = int(maxGraphLatency - srcLat)
        # Кольцо per-frame: ёмкость в СЛОТАХ = кадры × каналы. Раньше считалось
        # на один канал, поэтому stereo-история не помещалась, а каналы
        # перемешивались (issue #72).
        let ringFrames = max(diff + 256, 1024)
        let bufferSize = ringFrames * DelayCompensationRingChannels
        let buf = cast[ptr UncheckedArray[float32]](allocShared0(sizeof(float32) * bufferSize))
        
        compiler.delayStates[currentDelayIdx] = DelayCompensationData(
          delayFrames: diff,
          writePos: 0,
          buffer: buf,
          bufferSize: bufferSize,
          ringChannels: int32(DelayCompensationRingChannels)
        )
        
        let dNodeId = compiler.allocator.nextId()
        let dNode = EditorNode(
          id: dNodeId,
          name: "PDC_Delay",
          nodeType: "core.pdc_delay",
          processProc: processDelayComp, 
          userData: addr compiler.delayStates[currentDelayIdx], 
          audioInCount: 1, audioOutCount: 1,
          latency: LatencyProfile(reported: uint32(diff), intrinsic: 0, compensation: uint32(diff)),
          isSubgraph: false
        )
        g.nodes[dNodeId] = dNode
        
        newConnections.add(EditorConnection(srcNodeId: c.srcNodeId, srcPortIdx: c.srcPortIdx, dstNodeId: dNodeId, dstPortIdx: 0, sigType: sigAudio))
        newConnections.add(EditorConnection(srcNodeId: dNodeId, srcPortIdx: 0, dstNodeId: c.dstNodeId, dstPortIdx: c.dstPortIdx, sigType: sigAudio))
        
        inc(currentDelayIdx)
        continue
    newConnections.add(c)

  g.connections = newConnections
  adj = initAdjacencyList(g)

# ============================================================================
# 4. BUFFER ALLOCATION & LIFETIME ANALYSIS 
# ============================================================================
type
  NetKey* = tuple[srcNodeId: int, srcPortIdx: int, sigType: SignalType]
  NetLifetime* = object
    net*: NetKey
    birthStep*: int
    deathStep*: int

proc analyzeLifetimes(g: NodeGraph, adj: AdjacencyList, sortedIds: seq[int]): (seq[NetLifetime], Table[NetKey, int]) =
  var nodeStepMap = initTable[int, int]()
  for idx, id in sortedIds:
    nodeStepMap[id] = idx

  var netLifetimes = initTable[NetKey, NetLifetime]()

  for c in g.connections:
    let key = (c.srcNodeId, c.srcPortIdx, c.sigType)
    let birth = nodeStepMap.getOrDefault(c.srcNodeId, 0)
    let death = nodeStepMap.getOrDefault(c.dstNodeId, 0)

    if not netLifetimes.hasKey(key):
      netLifetimes[key] = NetLifetime(net: key, birthStep: birth, deathStep: death)
    else:
      var nl = netLifetimes.getOrDefault(key, NetLifetime(net: key, birthStep: birth, deathStep: death))
      nl.deathStep = max(nl.deathStep, death)
      netLifetimes[key] = nl

  var sortedNets: seq[NetLifetime] = @[]
  for v in netLifetimes.values:
    sortedNets.add(v)

  # Полный tie-break (issue #391, EUT-NEW-036): сортировка только по birthStep
  # оставляла порядок нетов с одинаковым birthStep на усмотрение `sort`
  # (нестабильного) и порядка Table — и назначенные номера буферов менялись
  # между запусками. Детерминированный ключ делает reuse-план буферов
  # воспроизводимым.
  sortedNets.sort(proc(a, b: NetLifetime): int =
    result = cmp(a.birthStep, b.birthStep)
    if result == 0: result = cmp(a.net.srcNodeId, b.net.srcNodeId)
    if result == 0: result = cmp(a.net.srcPortIdx, b.net.srcPortIdx)
    if result == 0: result = cmp(ord(a.net.sigType), ord(b.net.sigType)))

  var netToBuffer = initTable[NetKey, int]()
  var bufferEndSteps: seq[int] = @[]

  for n in sortedNets:
    var assigned = -1
    for bIdx in 0 ..< bufferEndSteps.len:
      if bufferEndSteps[bIdx] <= n.birthStep:
        assigned = bIdx
        bufferEndSteps[bIdx] = n.deathStep
        break
    if assigned == -1:
      assigned = bufferEndSteps.len
      bufferEndSteps.add(n.deathStep)
    netToBuffer[n.net] = assigned

  return (sortedNets, netToBuffer)

# ============================================================================
# 5. COMPILATION PIPELINE
# ============================================================================
proc initGraphCompiler*(): GraphCompiler =
  GraphCompiler(allocator: IdAllocator(nextId: 100_000)) 

proc validateGraph*(srcGraph: NodeGraph): CompileError =
  ## Единая проверка графа ДО компиляции (issue #391, EUT-NEW-035).
  ##
  ## Раньше связи проверялись только внутри `topologicalSort`/`applyPDC`, и
  ## битая ссылка всплывала либо как цикл («связь на несуществующую ноду»),
  ## либо не всплывала вовсе — а дальше писала в память за пределами массивов
  ## портов. Здесь проверяется всё, что можно проверить без компиляции:
  ##   - существование нод в связях;
  ##   - индексы портов против фактических `audioInCount/audioOutCount`
  ##     (а не только против `MaxAudioPorts`);
  ##   - валидность `sigType`;
  ##   - занятость входа (два писателя на один вход);
  ##   - дубли связей и отрицательные индексы.
  ##
  ## Возвращает `CompileError` с координатами; `cekNone` — граф валиден.
  ## Детерминирован: связи обходятся в порядке `srcGraph.connections`, поэтому
  ## одна и та же поломка всегда даёт одно и то же сообщение.
  ##
  ## `detail` здесь не заполняется: модуль целиком под `raises: []`, а
  ## строковая конкатенация аллоцирует и может бросить. Человекочитаемый текст
  ## по `kind`/`nodeId`/`portIdx` строит вызывающий (`graph_check.describe`) —
  ## там это контрольная плоскость, а не RT.
  result = CompileError(kind: cekNone, nodeId: 0, portIdx: -1, connection: -1)

  # Занятость входов: ключ «нода-порт», значение — индекс связи-писателя.
  var writers = initTable[(int, int), int]()

  for i, c in srcGraph.connections:
    # 1. Отрицательные индексы портов — мусор, а не «порт 0».
    if c.srcPortIdx < 0:
      return CompileError(kind: cekNegativePortIdx, nodeId: c.srcNodeId,
        portIdx: c.srcPortIdx, connection: i)
    if c.dstPortIdx < 0:
      return CompileError(kind: cekNegativePortIdx, nodeId: c.dstNodeId,
        portIdx: c.dstPortIdx, connection: i)

    # 2. Ноды связи должны существовать.
    if not srcGraph.nodes.hasKey(c.srcNodeId):
      return CompileError(kind: cekUnknownNode, nodeId: c.srcNodeId,
        portIdx: -1, connection: i)
    if not srcGraph.nodes.hasKey(c.dstNodeId):
      return CompileError(kind: cekUnknownNode, nodeId: c.dstNodeId,
        portIdx: -1, connection: i)

    # 3. Порт должен существовать у ноды по фактическому числу портов
    #    СООТВЕТСТВУЮЩЕГО ТИПА. Проверка только против `MaxAudioPorts`
    #    пропускала ссылку на порт, которого у ноды нет, — а компилятор потом
    #    писал за пределами массивов. Проверять audio-порты для event-связи
    #    тоже нельзя: у `euterpia.notes` их ноль, и связь eventOut→eventIn
    #    объявлялась бы битой (issue #391).
    #    `getOrDefault` не бросает KeyError (модуль под `raises: []`), а
    #    «нода без портов этого типа» означает «порта нет» — ошибка.
    let emptyNode = EditorNode(audioOutCount: 0, audioInCount: 0,
                               ctrlOutCount: 0, ctrlInCount: 0,
                               eventOutCount: 0, eventInCount: 0)
    let srcNode = srcGraph.nodes.getOrDefault(c.srcNodeId, emptyNode)
    let dstNode = srcGraph.nodes.getOrDefault(c.dstNodeId, emptyNode)
    case c.sigType
    of sigAudio:
      if c.srcPortIdx >= int(srcNode.audioOutCount):
        return CompileError(kind: cekUnknownSrcPort, nodeId: c.srcNodeId,
          portIdx: c.srcPortIdx, connection: i)
      if c.dstPortIdx >= int(dstNode.audioInCount):
        return CompileError(kind: cekUnknownDstPort, nodeId: c.dstNodeId,
          portIdx: c.dstPortIdx, connection: i)
    of sigControl:
      if c.srcPortIdx >= int(srcNode.ctrlOutCount):
        return CompileError(kind: cekUnknownSrcPort, nodeId: c.srcNodeId,
          portIdx: c.srcPortIdx, connection: i)
      if c.dstPortIdx >= int(dstNode.ctrlInCount):
        return CompileError(kind: cekUnknownDstPort, nodeId: c.dstNodeId,
          portIdx: c.dstPortIdx, connection: i)
    of sigEvent:
      if c.srcPortIdx >= int(srcNode.eventOutCount):
        return CompileError(kind: cekUnknownSrcPort, nodeId: c.srcNodeId,
          portIdx: c.srcPortIdx, connection: i)
      if c.dstPortIdx >= int(dstNode.eventInCount):
        return CompileError(kind: cekUnknownDstPort, nodeId: c.dstNodeId,
          portIdx: c.dstPortIdx, connection: i)

    # 4. sigType должен быть известным классом (sigAudio/sigControl/sigEvent).
    #    Мусор из файла (`sigType: 99`) не должен доходить до аудиобуферов,
    #    где `case` просто проигнорирует неизвестный класс — и связь молча
    #    перестанет проводить сигнал. Но `!= sigAudio` здесь быть НЕ должно:
    #    нода может принимать event на вход и выдавать audio (инструменты —
    #    ровно этот паттерн), поэтому аудио-проверка уже сделана выше по
    #    фактическим портам соответствующего типа (issue #391).
    if ord(c.sigType) < ord(sigAudio) or ord(c.sigType) > ord(sigEvent):
      return CompileError(kind: cekSignalMismatch, nodeId: c.dstNodeId,
        portIdx: c.dstPortIdx, connection: i)

    # 5. Дубль связи: тот же источник пишет в тот же приёмник повторно. Это
    #    безусловная ошибка — сигнал пришёл бы дважды, а при одинаковом diff
    #    PDC выдало бы два одинаковых компенсатора в один вход.
    #    `getOrDefault(-1)`: чтение таблицы не должно бросать под `raises: []`.
    let key = (c.dstNodeId, c.dstPortIdx)
    let prevIdx = writers.getOrDefault(key, -1)
    if prevIdx >= 0:
      let prev = srcGraph.connections[prevIdx]
      if prev.srcNodeId == c.srcNodeId and prev.srcPortIdx == c.srcPortIdx:
        return CompileError(kind: cekDuplicateConnection, nodeId: c.dstNodeId,
          portIdx: c.dstPortIdx, connection: i)
    writers[key] = i

proc compileGraph*(srcGraph: NodeGraph): CompileResult =
  var compiler = initGraphCompiler()

  # Полная валидация до любой аллокации (issue #391): битый граф не должен
  # доходить до `flattenGraph`, где индексы портов начинают трогать память.
  let vErr = validateGraph(srcGraph)
  if vErr.kind != cekNone:
    return CompileResult(success: false, error: vErr)
  
  var g = flattenGraph(srcGraph, compiler.allocator)
  var adj = initAdjacencyList(g)
  
  var order: seq[int]
  if not topologicalSort(g, adj, order):
    if compiler.delayStates != nil: deallocShared(compiler.delayStates)
    return CompileResult(success: false,
      error: CompileError(kind: cekCycleDetected, portIdx: -1, connection: -1))

  applyPDC(g, adj, order, compiler)
  
  if not topologicalSort(g, adj, order):
    if compiler.delayStates != nil:
      for i in 0 ..< compiler.delayStateCount:
        if compiler.delayStates[i].buffer != nil:
          deallocShared(compiler.delayStates[i].buffer)
      deallocShared(compiler.delayStates)
    return CompileResult(success: false,
      error: CompileError(kind: cekPdcCycleDetected, portIdx: -1, connection: -1))

  let (sortedNets, netToBuffer) = analyzeLifetimes(g, adj, order)

  var maxAudioBuffers = 0
  var maxCtrl = 0
  var maxEvent = 0
  
  for n in sortedNets:
    let bufIdx = netToBuffer.getOrDefault(n.net, 0)
    case n.net.sigType
    of sigAudio: maxAudioBuffers = max(maxAudioBuffers, bufIdx + 1)
    of sigControl: maxCtrl = max(maxCtrl, bufIdx + 1)
    of sigEvent: maxEvent = max(maxEvent, bufIdx + 1)

  maxAudioBuffers = max(maxAudioBuffers, 1)
  maxCtrl = max(maxCtrl, 1)
  maxEvent = max(maxEvent, 1)

  # Единственная точка создания пайплайна (issue #79): версия графа
  # ставится только в newCompiledPipeline, чтобы её нельзя было забыть.
  let p = newCompiledPipeline()
  if p == nil:
    if compiler.delayStates != nil:
      for i in 0 ..< compiler.delayStateCount:
        if compiler.delayStates[i].buffer != nil:
          deallocShared(compiler.delayStates[i].buffer)
      deallocShared(compiler.delayStates)
    return CompileResult(success: false,
      error: CompileError(kind: cekAllocationFailed, portIdx: -1, connection: -1))

  # Каждый скомпилированный граф обязан иметь непустую монотонную версию:
  # audio thread публикует её в метриках и по ней же отбрасывает устаревшие
  # пайплайны. Версия проставлена newCompiledPipeline; проверяем инвариант.
  doAssert(p.graphVersion != 0'u64, "пайплайн без версии графа")

  p.stepCount = order.len.int32
  p.steps = cast[ptr UncheckedArray[PipelineStep]](allocShared0(sizeof(PipelineStep) * order.len))
  
  p.audioBufferPoolCount = maxAudioBuffers
  p.audioBufferPool = cast[ptr UncheckedArray[AudioBuffer]](allocShared0(sizeof(AudioBuffer) * maxAudioBuffers))

  # Арена сэмплов под аудиобуферы.
  #
  # Раньше здесь выделялись только структуры AudioBuffer, а поле data
  # оставалось nil. Следствие: любая нода получала пустой порт, цепочка
  # нод не могла выдать ни одного сэмпла, а master-выход вообще не
  # с чем было соединить. Теперь память под сэмплы выделяется ровно
  # один раз, на холодной стороне, и раздаётся буферам пула.
  #
  # Формат — planar stereo (channels = 2, stride = arenaFrames).
  # Planar выбран потому, что DSP-ядра обрабатывают каналы независимо:
  # так циклы в C получаются линейными, а не шагающими через stride.
  # Ноды, ожидающие interleaved, определяют раскладку по stride/channels.
  let arenaFrames = int32(signal_types.MaxBlockSize)
  let arenaChannels = 2
  let samplesPerBuffer = int(arenaFrames) * arenaChannels

  p.arenaFrames = arenaFrames
  p.audioArena = cast[ptr UncheckedArray[float32]](
    allocShared0(sizeof(float32) * maxAudioBuffers * samplesPerBuffer)
  )

  if p.audioArena != nil:
    for i in 0 ..< maxAudioBuffers:
      p.audioBufferPool[i].data =
        cast[ptr UncheckedArray[float32]](addr p.audioArena[i * samplesPerBuffer])
      p.audioBufferPool[i].frames = arenaFrames
      p.audioBufferPool[i].channels = int32(arenaChannels)
      p.audioBufferPool[i].stride = arenaFrames
      p.audioBufferPool[i].layout = alPlanar
  
  p.ctrlPoolCount = maxCtrl
  p.ctrlPool = cast[ptr UncheckedArray[float32]](allocShared0(sizeof(float32) * maxCtrl))
  
  p.eventPoolCount = maxEvent
  # У EventQueue поле events помечено {.align: 64.}, а allocShared0 гарантирует
  # только MemAlign (16). Пока аллокатор Nim'а отдавал страницы, выравнивание
  # получалось само; с -d:useMalloc (#364) память идёт из libc malloc, и
  # обращение к полю становится UB — UBSan ловит это на первом же событии.
  p.eventPool = cast[ptr UncheckedArray[EventQueue]](
    alignedSharedAlloc0(sizeof(EventQueue) * maxEvent, alignof(EventQueue))
  )

  let flagsSize = max(maxAudioBuffers, max(maxCtrl, maxEvent))
  p.poolFlags = cast[ptr UncheckedArray[set[PoolFlag]]](allocShared0(sizeof(set[PoolFlag]) * flagsSize))
  for i in 0 ..< maxCtrl: p.poolFlags[i].incl(pfNeedsZeroing)
  for i in 0 ..< maxEvent: p.poolFlags[i].incl(pfNeedsZeroing)

  # Передача владения массивом состояний задержки в конвейер.
  # Так как compiler.delayStates указывает на непрерывный массив,
  # ранее проинициализированные указатели step.userData остаются валидными.
  p.delayStateCount = compiler.delayStateCount
  p.delayStates = compiler.delayStates
  compiler.delayStates = nil 

  for stepIdx, id in order:
    let node = g.nodes.getOrDefault(id, EditorNode())
    p.steps[stepIdx].processProc = node.processProc
    p.steps[stepIdx].userData = node.userData
    
    p.steps[stepIdx].audio.inputCount = node.audioInCount
    p.steps[stepIdx].audio.outputCount = node.audioOutCount
    p.steps[stepIdx].ctrl.inputCount = node.ctrlInCount
    p.steps[stepIdx].ctrl.outputCount = node.ctrlOutCount
    p.steps[stepIdx].events.inputCount = node.eventInCount
    p.steps[stepIdx].events.outputCount = node.eventOutCount

    for c in g.connections:
      if c.srcNodeId == id:
        let key = (c.srcNodeId, c.srcPortIdx, c.sigType)
        let bIdx = netToBuffer.getOrDefault(key, 0)
        case c.sigType
        of sigAudio:
          if c.srcPortIdx < MaxAudioPorts and bIdx < maxAudioBuffers:
            p.steps[stepIdx].audio.outputs[c.srcPortIdx] = addr p.audioBufferPool[bIdx]
        of sigControl:
          if c.srcPortIdx < MaxCtrlPorts and bIdx < maxCtrl:
            p.steps[stepIdx].ctrl.outputs[c.srcPortIdx] = addr p.ctrlPool[bIdx]
        of sigEvent:
          if c.srcPortIdx < MaxEventPorts and bIdx < maxEvent:
            p.steps[stepIdx].events.outputs[c.srcPortIdx] = addr p.eventPool[bIdx]

      if c.dstNodeId == id:
        let key = (c.srcNodeId, c.srcPortIdx, c.sigType)
        let bIdx = netToBuffer.getOrDefault(key, 0)
        case c.sigType
        of sigAudio:
          if c.dstPortIdx < MaxAudioPorts and bIdx < maxAudioBuffers:
            p.steps[stepIdx].audio.inputs[c.dstPortIdx] = addr p.audioBufferPool[bIdx]
        of sigControl:
          if c.dstPortIdx < MaxCtrlPorts and bIdx < maxCtrl:
            p.steps[stepIdx].ctrl.inputs[c.dstPortIdx] = addr p.ctrlPool[bIdx]
        of sigEvent:
          if c.dstPortIdx < MaxEventPorts and bIdx < maxEvent:
            p.steps[stepIdx].events.inputs[c.dstPortIdx] = addr p.eventPool[bIdx]

  return CompileResult(success: true, pipeline: p)

{.pop.}