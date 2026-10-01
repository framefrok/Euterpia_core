# tests/unit/test_graph_compiler.nim
#
# Компилятор графа: топология, порядок шагов, отказ на цикле,
# монотонность версий пайплайна.

import std/[unittest, tables]
import signal_types
import node_interface
import graph_compiler
import compiled_pipeline
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