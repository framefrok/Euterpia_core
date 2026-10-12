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
    check cr.error.kind == cekCycleDetected

  test "пустой граф компилируется в пустой пайплайн":
    var g: NodeGraph
    let cr = compileGraph(g)
    check cr.success
    if cr.success:
      destroyPipeline(cr.pipeline)


# =============================================================================
# issue #391: валидация до компиляции + детерминизм layout'а
# =============================================================================

suite "graph_compiler: конкретные ошибки валидации (#391)":
  test "связь на несуществующую ноду -> cekUnknownNode с id":
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 999, dstPortIdx: 0,   # такой ноды нет
      sigType: sigAudio
    )
    let cr = compileGraph(g)
    check not cr.success
    # Ошибка называет конкретную ноду, а не «проверьте данные».
    check cr.error.kind == cekUnknownNode
    check cr.error.nodeId == 999
    check cr.error.connection == 0

  test "ссылка на порт, которого у ноды нет -> cekUnknownDstPort":
    # У Sink один вход, а связь идёт в порт 3. Раньше проверка шла только
    # против MaxAudioPorts, и компилятор писал за пределами массивов.
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.nodes[2] = makeNode(2, "Sink", 1, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 2, dstPortIdx: 3,
      sigType: sigAudio
    )
    let cr = compileGraph(g)
    check not cr.success
    check cr.error.kind == cekUnknownDstPort
    check cr.error.nodeId == 2
    check cr.error.portIdx == 3

  test "ссылка на несуществующий порт источника -> cekUnknownSrcPort":
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.nodes[2] = makeNode(2, "Sink", 1, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 7,
      dstNodeId: 2, dstPortIdx: 0,
      sigType: sigAudio
    )
    let cr = compileGraph(g)
    check not cr.success
    check cr.error.kind == cekUnknownSrcPort
    check cr.error.nodeId == 1
    check cr.error.portIdx == 7

  test "дубль связи -> cekDuplicateConnection":
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.nodes[2] = makeNode(2, "Sink", 1, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio)
    let cr = compileGraph(g)
    check not cr.success
    check cr.error.kind == cekDuplicateConnection
    check cr.error.nodeId == 2
    check cr.error.portIdx == 0

  test "отрицательный индекс порта -> cekNegativePortIdx":
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.nodes[2] = makeNode(2, "Sink", 1, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: -5,
      dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio)
    let cr = compileGraph(g)
    check not cr.success
    check cr.error.kind == cekNegativePortIdx

  test "несколько источников в один вход разрешены (микс шин)":
    # Смешение — легальный паттерн (миксер, обход с PDC): проверка
    # multiple-writer НЕ должна его отвергать, иначе ломается issue #72.
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "SourceA", 0, 1)
    g.nodes[2] = makeNode(2, "SourceB", 0, 1)
    g.nodes[3] = makeNode(3, "Sink", 1, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 3, dstPortIdx: 0, sigType: sigAudio)
    g.connections.add EditorConnection(
      srcNodeId: 2, srcPortIdx: 0,
      dstNodeId: 3, dstPortIdx: 0, sigType: sigAudio)
    let cr = compileGraph(g)
    check cr.success
    if cr.success:
      destroyPipeline(cr.pipeline)

  test "битый граф не доходит до аллокаций пайплайна":
    # Валидация идёт ДО flattenGraph: при ошибке пайплайн не создаётся
    # вовсе, значит и освобождать нечего.
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 42, dstPortIdx: 0, sigType: sigAudio)
    let cr = compileGraph(g)
    check not cr.success

suite "graph_compiler: детерминизм layout'а (#391)":
  test "топологический порядок сходится к одному результату":
    # Два независимых корня + общий сток: порядок шагов обязан быть
    # детерминированным (по отсортированным id), а не зависеть от Table.
    # Раньше очередь засевалась обходом Table, и layout менялся между
    # запусками — вместе с номерами буферов и метриками.
    proc sortOrder(): seq[int] =
      var g: NodeGraph
      g.nodes[5] = makeNode(5, "RootB", 0, 1)
      g.nodes[1] = makeNode(1, "RootA", 0, 1)
      g.nodes[9] = makeNode(9, "Sink", 2, 0)
      g.connections.add EditorConnection(
        srcNodeId: 5, srcPortIdx: 0,
        dstNodeId: 9, dstPortIdx: 1, sigType: sigAudio)
      g.connections.add EditorConnection(
        srcNodeId: 1, srcPortIdx: 0,
        dstNodeId: 9, dstPortIdx: 0, sigType: sigAudio)
      var sortedIds: seq[int]
      discard topologicalSort(g, initAdjacencyList(g), sortedIds)
      result = sortedIds

    # Засев очереди по отсортированным id: RootA(1) раньше RootB(5),
    # общий Sink(9) — последним.
    check sortOrder() == @[1, 5, 9]
    check sortOrder() == sortOrder()

  test "порядок вставки в Table не меняет порядок шагов":
    # Цепочка 1 -> 2 -> 3 -> 4 без ветвлений: вставка в обратном порядке
    # не должна менять ни порядок шагов, ни число шагов.
    proc compileChain(idsDescending: bool): (bool, int32) =
      var g: NodeGraph
      let nodes = @[
        makeNode(1, "N1", 0, 1),
        makeNode(2, "N2", 1, 1),
        makeNode(3, "N3", 1, 1),
        makeNode(4, "N4", 1, 0)
      ]
      if idsDescending:
        for i in countdown(nodes.len - 1, 0):
          g.nodes[nodes[i].id] = nodes[i]
      else:
        for n in nodes:
          g.nodes[n.id] = n
      for i in 0 ..< 3:
        g.connections.add EditorConnection(
          srcNodeId: i + 1, srcPortIdx: 0,
          dstNodeId: i + 2, dstPortIdx: 0, sigType: sigAudio)

      let cr = compileGraph(g)
      result = (cr.success, if cr.pipeline.isNil: -1'i32
                             else: cr.pipeline.stepCount)
      if not cr.pipeline.isNil:
        destroyPipeline(cr.pipeline)

    let forward = compileChain(false)
    let backward = compileChain(true)
    check forward == backward
    check forward[0]
    check forward[1] == 4

  test "одинаковый граф дважды даёт одинаковое число шагов":
    # Компиляция не должна зависеть от состояния хеш-таблицы процесса.
    proc compileOnce(): int32 =
      var g: NodeGraph
      g.nodes[10] = makeNode(10, "A", 0, 1)
      g.nodes[20] = makeNode(20, "B", 1, 0)
      g.connections.add EditorConnection(
        srcNodeId: 10, srcPortIdx: 0,
        dstNodeId: 20, dstPortIdx: 0, sigType: sigAudio)
      let cr = compileGraph(g)
      result = if cr.pipeline.isNil: -1'i32 else: cr.pipeline.stepCount
      if not cr.pipeline.isNil:
        destroyPipeline(cr.pipeline)

    check compileOnce() == compileOnce()
    check compileOnce() == 2