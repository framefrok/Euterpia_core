# tests/unit/test_graph_compiler.nim
#
# Компилятор графа: топология, порядок шагов, отказ на цикле,
# монотонность версий пайплайна.

import std/[unittest, tables]
import signal_types
import node_interface
import graph_compiler
import compiled_pipeline
import aligned_mem
import sdk/audio_buffers

proc passThroughProc(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  discard userData
  discard ctx
  if audio.isNil or audio.inputCount < 1 or audio.outputCount < 1:
    return
  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf.isNil or outBuf.isNil:
    return
  let frames = min(inBuf.frames, outBuf.frames)
  let chans = min(inBuf.channels, outBuf.channels)
  for ch in 0 ..< chans:
    let src = inBuf.channelPtr(ch, frames)
    let dst = outBuf.channelPtr(ch, frames)
    if src.isNil or dst.isNil:
      continue
    let sa = cast[ptr UncheckedArray[float32]](src)
    let da = cast[ptr UncheckedArray[float32]](dst)
    for i in 0 ..< frames.int:
      da[i] = sa[i]

proc makeNode(id: int; name: string; inCh, outCh: int32): EditorNode =
  EditorNode(
    id: id, name: name, nodeType: "test.pass",
    processProc: passThroughProc,
    userData: nil,
    audioInCount: inCh, audioOutCount: outCh,
    latency: LatencyProfile()
  )

suite "graph_compiler":
  test "линейная цепочка компилируется в два шага":
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.nodes[2] = makeNode(2, "Sink", 1, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 2, dstPortIdx: 0,
      sigType: sigAudio
    )

    let cr = compileGraph(g)
    check cr.success
    check cr.pipeline.stepCount == 2
    check cr.pipeline.audioBufferPoolCount >= 1
    check cr.pipeline.audioBufferPool != nil
    # Арена событий обязана быть выровнена по 64 байта при любом аллокаторе
    # (#364): с -d:useMalloc allocShared0 даёт только MemAlign, и обращение
    # к полю EventQueue.events становится UB (UBSan это и поймал).
    check cr.pipeline.eventPool != nil
    check isAlignedShared(cast[pointer](cr.pipeline.eventPool), alignof(EventQueue))
    destroyPipeline(cr.pipeline)

  test "версия пайплайна монотонно растёт между компиляциями":
    # Audio thread отбрасывает пайплайны по версии: если вторая
    # компиляция вернёт ту же или 0, устаревший пайплайн не будет
    # распознан и может утечь или выполниться дважды.
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.nodes[2] = makeNode(2, "Sink", 1, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 2, dstPortIdx: 0,
      sigType: sigAudio
    )

    let cr1 = compileGraph(g)
    check cr1.success
    let v1 = cr1.pipeline.graphVersion
    destroyPipeline(cr1.pipeline)

    let cr2 = compileGraph(g)
    check cr2.success
    let v2 = cr2.pipeline.graphVersion
    destroyPipeline(cr2.pipeline)

    check v1 != 0
    check v2 != 0
    check v2 > v1

  test "цикл в графе -> отказ, а не зависание":
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "A", 1, 1)
    g.nodes[2] = makeNode(2, "B", 1, 1)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 2, dstPortIdx: 0,
      sigType: sigAudio
    )
    g.connections.add EditorConnection(
      srcNodeId: 2, srcPortIdx: 0,
      dstNodeId: 1, dstPortIdx: 0,
      sigType: sigAudio
    )

    let cr = compileGraph(g)
    check not cr.success
    check cr.error == cekCycleDetected

  test "пустой граф компилируется в пустой пайплайн":
    var g: NodeGraph
    let cr = compileGraph(g)
    check cr.success
    if cr.success:
      destroyPipeline(cr.pipeline)

# =============================================================================
# #403: субграфы — пространство имён по (scope, localId) и явные порты
# =============================================================================

proc subgraphLeaf(id: int; name: string): EditorNode =
  EditorNode(
    id: id, name: name, nodeType: "test.pass",
    processProc: passThroughProc,
    audioInCount: 1, audioOutCount: 1,
    latency: LatencyProfile()
  )

proc audioPort(localNodeId, localPortIdx: int): SubgraphPort =
  SubgraphPort(localNodeId: localNodeId, localPortIdx: localPortIdx,
               sigType: sigAudio)

proc twoNodeSubgraph(id: int; name: string): EditorNode =
  ## Субграф из двух листьев с ЛОКАЛЬНЫМИ id 100/101 и объявленными
  ## внешними портами: вход 0 -> 100, выход 0 <- 101.
  ##
  ## id намеренно одинаковы у всех субграфов: именно этот случай раньше
  ## затирал `idRemap` (issue #403).
  result = EditorNode(
    id: id, name: name, nodeType: "core.subgraph", isSubgraph: true,
    audioInCount: 1, audioOutCount: 1,
    subgraphInputs: @[audioPort(100, 0)],
    subgraphOutputs: @[audioPort(101, 0)]
  )
  result.subgraphNodes = @[
    subgraphLeaf(100, name & ".in"),
    subgraphLeaf(101, name & ".out")
  ]
  result.subgraphConnections = @[
    EditorConnection(srcNodeId: 100, srcPortIdx: 0,
                     dstNodeId: 101, dstPortIdx: 0, sigType: sigAudio)
  ]

proc hasLink(g: NodeGraph; srcId, dstId: int): bool =
  for c in g.connections:
    if c.srcNodeId == srcId and c.dstNodeId == dstId:
      return true
  false

suite "graph_compiler: субграфы (#403)":
  test "одинаковые локальные id в разных субграфах не collide":
    var g: NodeGraph
    g.nodes[10] = subgraphLeaf(10, "RootSource")
    g.nodes[20] = subgraphLeaf(20, "RootSink")
    g.nodes[1] = twoNodeSubgraph(1, "A")
    g.nodes[2] = twoNodeSubgraph(2, "B")

    g.connections = @[
      EditorConnection(srcNodeId: 10, srcPortIdx: 0,
                       dstNodeId: 1, dstPortIdx: 0, sigType: sigAudio),
      EditorConnection(srcNodeId: 1, srcPortIdx: 0,
                       dstNodeId: 20, dstPortIdx: 0, sigType: sigAudio),
      EditorConnection(srcNodeId: 10, srcPortIdx: 0,
                       dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio),
      EditorConnection(srcNodeId: 2, srcPortIdx: 0,
                       dstNodeId: 20, dstPortIdx: 0, sigType: sigAudio)
    ]

    var allocator = IdAllocator(nextId: 1000)
    var error = cekNone
    let flat = flattenGraph(g, allocator, error)
    check error == cekNone

    # Субграфы — контейнеры, шагами не становятся: 2 корневых листа + 4 внутри.
    check flat.nodes.len == 6

    var byName = initTable[string, int]()
    for id, node in flat.nodes:
      check not node.isSubgraph
      check not byName.hasKey(node.name)
      byName[node.name] = id

    for name in ["RootSource", "RootSink", "A.in", "A.out", "B.in", "B.out"]:
      check byName.hasKey(name)

    # Одинаковые локальные id дали РАЗНЫЕ глобальные.
    check byName["A.in"] != byName["B.in"]
    check byName["A.out"] != byName["B.out"]
    check byName["A.in"] != byName["A.out"]

    # Внешние связи разрешились во внутренние ноды через порты.
    check flat.hasLink(byName["RootSource"], byName["A.in"])
    check flat.hasLink(byName["A.out"], byName["RootSink"])
    check flat.hasLink(byName["RootSource"], byName["B.in"])
    check flat.hasLink(byName["B.out"], byName["RootSink"])
    # Внутренние связи остались внутри своего субграфа.
    check flat.hasLink(byName["A.in"], byName["A.out"])
    check flat.hasLink(byName["B.in"], byName["B.out"])
    check flat.connections.len == 6

    # Компилятор принимает такой граф (6 шагов).
    let cr = compileGraph(g)
    check cr.success
    if cr.success:
      check cr.pipeline.stepCount == 6
      destroyPipeline(cr.pipeline)

  test "вложенный субграф пробрасывает порт через свой уровень":
    # Root: source -> Outer.input, Outer.output -> sink.
    # Outer: вход 0 -> вход Inner; выход Inner -> выход 0 Outer.
    # Inner: вход 0 -> лист 100; лист 101 -> выход 0.
    var g: NodeGraph
    g.nodes[10] = subgraphLeaf(10, "RootSource")
    g.nodes[20] = subgraphLeaf(20, "RootSink")

    var inner = EditorNode(
      id: 7, name: "Inner", nodeType: "core.subgraph", isSubgraph: true,
      audioInCount: 1, audioOutCount: 1,
      subgraphInputs: @[audioPort(100, 0)],
      subgraphOutputs: @[audioPort(101, 0)]
    )
    inner.subgraphNodes = @[
      subgraphLeaf(100, "Inner.in"),
      subgraphLeaf(101, "Inner.out")
    ]
    inner.subgraphConnections = @[
      EditorConnection(srcNodeId: 100, srcPortIdx: 0,
                       dstNodeId: 101, dstPortIdx: 0, sigType: sigAudio)
    ]

    var outer = EditorNode(
      id: 1, name: "Outer", nodeType: "core.subgraph", isSubgraph: true,
      audioInCount: 1, audioOutCount: 1,
      subgraphInputs: @[audioPort(7, 0)],   # вход Outer -> вход Inner
      subgraphOutputs: @[audioPort(7, 0)]   # выход Outer <- выход Inner
    )
    outer.subgraphNodes = @[inner]
    outer.subgraphConnections = @[]
    g.nodes[1] = outer

    g.connections = @[
      EditorConnection(srcNodeId: 10, srcPortIdx: 0,
                       dstNodeId: 1, dstPortIdx: 0, sigType: sigAudio),
      EditorConnection(srcNodeId: 1, srcPortIdx: 0,
                       dstNodeId: 20, dstPortIdx: 0, sigType: sigAudio)
    ]

    var allocator = IdAllocator(nextId: 1000)
    var error = cekNone
    let flat = flattenGraph(g, allocator, error)
    check error == cekNone
    check flat.nodes.len == 4

    var byName = initTable[string, int]()
    for id, node in flat.nodes:
      byName[node.name] = id
    check flat.hasLink(byName["RootSource"], byName["Inner.in"])
    check flat.hasLink(byName["Inner.out"], byName["RootSink"])

  test "связь в субграф без объявленного порта — ошибка, а не потеря связи":
    var g: NodeGraph
    g.nodes[10] = subgraphLeaf(10, "RootSource")
    g.nodes[1] = twoNodeSubgraph(1, "A")
    # Порт 5 не объявлен (объявлен только 0).
    g.connections = @[
      EditorConnection(srcNodeId: 10, srcPortIdx: 0,
                       dstNodeId: 1, dstPortIdx: 5, sigType: sigAudio)
    ]

    let cr = compileGraph(g)
    check not cr.success
    check cr.error == cekInvalidSubgraphPort

  test "несовпадение вида сигнала на порту субграфа — ошибка":
    var g: NodeGraph
    g.nodes[10] = subgraphLeaf(10, "RootSource")
    g.nodes[1] = twoNodeSubgraph(1, "A")
    g.connections = @[
      EditorConnection(srcNodeId: 10, srcPortIdx: 0,
                       dstNodeId: 1, dstPortIdx: 0, sigType: sigEvent)
    ]

    let cr = compileGraph(g)
    check not cr.success
    check cr.error == cekInvalidSubgraphPort
