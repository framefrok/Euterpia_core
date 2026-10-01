# tests/unit/test_pdc.nim
#
# Выравнивание задержек графа (PDC) — issue #72.
#
# Ранее PDC не был покрыт тестами вообще (`grep -rn "PDC\|delayComp" tests/`
# не находил ничего), поэтому моно-кольцо в stereo-графе жило незамеченным.
#
# Что доказывается:
#   - задержка равна `delayFrames` КАДРОВ (а не «кадров / channels»);
#   - каналы не обмениваются данными (L остаётся L, R остаётся R);
#   - работают обе раскладки буфера: planar и interleaved;
#   - каналов больше стерео-модели кольца -> нет выхода за границы;
#   - отсутствие кольца (OOM при компиляции) -> passthrough, а не мусор.

import std/[unittest, math, tables]
import signal_types
import node_interface
import compiled_pipeline
import graph_compiler
import sdk/audio_buffers

# ---------------------------------------------------------------------------
# Прямой вызов узла PDC: без графа, детерминированно.
# ---------------------------------------------------------------------------

type
  PdcRig = object
    ring: seq[float32]
    state: DelayCompensationData
    inData: seq[float32]
    outData: seq[float32]
    inBuf: AudioBuffer
    outBuf: AudioBuffer
    ports: NodeAudioPorts
    ctx: NodeProcessContext

proc initRig(rig: var PdcRig; frames, channels, delayFrames: int;
             interleaved = false) =
  let ringFrames = 1024
  rig.ring = newSeq[float32](ringFrames * DelayCompensationRingChannels)
  rig.state = DelayCompensationData(
    delayFrames: delayFrames,
    writePos: 0,
    buffer: cast[ptr UncheckedArray[float32]](addr rig.ring[0]),
    bufferSize: ringFrames * DelayCompensationRingChannels,
    ringChannels: int32(DelayCompensationRingChannels))

  rig.inData = newSeq[float32](frames * channels)
  rig.outData = newSeq[float32](frames * channels)

  # planar: канал ch начинается со смещения ch * frames (stride == frames);
  # interleaved: stride = 1, значит planar == false.
  let stride = if interleaved: 1 else: frames
  rig.inBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr rig.inData[0]),
    channels: int32(channels), frames: int32(frames), stride: int32(stride))
  rig.outBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr rig.outData[0]),
    channels: int32(channels), frames: int32(frames), stride: int32(stride))

  rig.ports = NodeAudioPorts()
  rig.ports.inputs[0] = addr rig.inBuf
  rig.ports.inputCount = 1
  rig.ports.outputs[0] = addr rig.outBuf
  rig.ports.outputCount = 1
  rig.ctx = NodeProcessContext(sampleRate: 48000.0'f32, blockSize: int32(frames))

proc setSample(rig: var PdcRig; ch, frame: int; v: float32; interleaved = false) =
  let idx = if interleaved: frame * int(rig.inBuf.channels) + ch
            else: ch * int(rig.inBuf.stride) + frame
  rig.inData[idx] = v

proc getSample(rig: PdcRig; ch, frame: int; interleaved = false): float32 =
  let idx = if interleaved: frame * int(rig.outBuf.channels) + ch
            else: ch * int(rig.outBuf.stride) + frame
  rig.outData[idx]

proc run(rig: var PdcRig) =
  processDelayComp(addr rig.ctx, addr rig.ports, nil, nil, addr rig.state)

# ---------------------------------------------------------------------------
# Граф с двумя ветвями разной задержки — чтобы PDC вообще включился.
# ---------------------------------------------------------------------------

proc passThroughProc(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctx
  discard ctrl
  discard events
  discard userData
  if audio.isNil or audio.inputCount < 1 or audio.outputCount < 1:
    return
  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf.isNil or outBuf.isNil:
    return
  let frames = min(inBuf.frames, outBuf.frames)
  let chans = min(inBuf.channels, outBuf.channels)
  for ch in 0 ..< chans:
    let src = cast[ptr UncheckedArray[float32]](inBuf.channelPtr(ch, frames))
    let dst = cast[ptr UncheckedArray[float32]](outBuf.channelPtr(ch, frames))
    if src.isNil or dst.isNil:
      continue
    for i in 0 ..< frames.int:
      dst[i] = src[i]

proc makeNode(id: int; name: string; inCh, outCh: int32;
              latency: uint32): EditorNode =
  EditorNode(
    id: id, name: name, nodeType: "test.pass",
    processProc: passThroughProc,
    userData: nil,
    audioInCount: inCh, audioOutCount: outCh,
    latency: LatencyProfile(reported: latency, intrinsic: 0, compensation: 0))

suite "PDC (issue #72)":
  test "испульс в L приходит в L через ровно delayFrames кадров":
    const Frames = 256
    const Delay = 64
    var rig: PdcRig
    rig.initRig(Frames, channels = 2, delayFrames = Delay)
    # Импульс только в левом канале, на первом кадре блока.
    rig.setSample(0, 0, 1.0'f32)
    rig.run()

    # Первые `delay` кадров — тишина (кольцо пустое).
    for i in 0 ..< Delay:
      check rig.getSample(0, i) == 0.0'f32
      check rig.getSample(1, i) == 0.0'f32

    # Импульс вышел в СВОЁМ канале ровно на delay-м кадре.
    check rig.getSample(0, Delay) == 1.0'f32
    check rig.getSample(1, Delay) == 0.0'f32

    # И больше нигде.
    for i in 0 ..< Frames:
      if i != Delay:
        check rig.getSample(0, i) == 0.0'f32

  test "постоянные, но РАЗНЫЕ каналы не обмениваются данными":
    const Frames = 256
    const Delay = 32
    var rig: PdcRig
    rig.initRig(Frames, channels = 2, delayFrames = Delay)
    for i in 0 ..< Frames:
      rig.setSample(0, i, 1.0'f32)
      rig.setSample(1, i, -2.0'f32)
    rig.run()

    # Первые `delay` кадров — кольцо пустое: тишина в ОБОИХ каналах.
    # На моно-кольце здесь в правом канале уже стоял бы левый сигнал.
    for i in 0 ..< Delay:
      check rig.getSample(0, i) == 0.0'f32
      check rig.getSample(1, i) == 0.0'f32

    # На моно-кольце здесь был бы обмен: L получал бы -2.0, а R — +1.0.
    for i in Delay ..< Frames:
      check rig.getSample(0, i) == 1.0'f32
      check rig.getSample(1, i) == -2.0'f32

  test "задержка не зависит от числа блоков: 4 блока по 64 при delay = 128":
    const Frames = 64
    const Delay = 128
    var rig: PdcRig
    rig.initRig(Frames, channels = 2, delayFrames = Delay)

    var outs: seq[float32] = @[]
    for b in 0 ..< 4:
      # Вход ненулевой РОВНО ОДИН раз — в самом первом кадре первого блока.
      for i in 0 ..< Frames:
        rig.setSample(0, i, (if b == 0 and i == 0: 1.0'f32 else: 0.0'f32))
        rig.setSample(1, i, 0.0'f32)
      rig.run()
      for i in 0 ..< Frames:
        outs.add rig.getSample(0, i)

    # 4 блока × 64 = 256 кадров; импульс обязан стоять на 128-м.
    check outs.len == 256
    for i in 0 ..< outs.len:
      check outs[i] == (if i == Delay: 1.0'f32 else: 0.0'f32)

  test "интерлив-раскладка обрабатывается так же":
    const Frames = 128
    const Delay = 16
    var rig: PdcRig
    rig.initRig(Frames, channels = 2, delayFrames = Delay, interleaved = true)
    for i in 0 ..< Frames:
      rig.setSample(0, i, 1.0'f32, interleaved = true)
      rig.setSample(1, i, -3.0'f32, interleaved = true)
    rig.run()

    for i in Delay ..< Frames:
      check rig.getSample(0, i, interleaved = true) == 1.0'f32
      check rig.getSample(1, i, interleaved = true) == -3.0'f32

  test "каналов больше модели кольца: без выхода за границы":
    # 4 канала: кольцо обслуживает 2, остальные идут passthrough.
    const Frames = 64
    var rig: PdcRig
    rig.initRig(Frames, channels = 4, delayFrames = 8)
    for i in 0 ..< Frames:
      for ch in 0 ..< 4:
        rig.setSample(ch, i, float32(ch + 1))
    rig.run()

    # Каналы 2 и 3 не обслуживаются кольцом — обязаны пройти без задержки.
    for i in 0 ..< Frames:
      check rig.getSample(2, i) == 3.0'f32
      check rig.getSample(3, i) == 4.0'f32

  test "нет кольца (OOM при компиляции): passthrough, а не мусор":
    const Frames = 32
    var rig: PdcRig
    rig.initRig(Frames, channels = 2, delayFrames = 8)
    # Эмулируем отказ аллокации кольца.
    rig.state.buffer = nil
    for i in 0 ..< Frames:
      rig.setSample(0, i, 0.5'f32)
      rig.setSample(1, i, -0.5'f32)
    rig.run()

    for i in 0 ..< Frames:
      check rig.getSample(0, i) == 0.5'f32
      check rig.getSample(1, i) == -0.5'f32

suite "PDC: компиляция графа (issue #72)":
  test "кольцо выделяется на кадры × каналы":
    # Две ветви: source -> A(latency 100) -> sink и source -> sink напрямую.
    # Прямая ветвь обязана получить компенсацию diff = 100 кадров.
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1, 0)
    g.nodes[2] = makeNode(2, "Latent", 1, 1, 100)
    g.nodes[3] = makeNode(3, "Sink", 1, 0, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio)
    g.connections.add EditorConnection(
      srcNodeId: 2, srcPortIdx: 0, dstNodeId: 3, dstPortIdx: 0, sigType: sigAudio)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0, dstNodeId: 3, dstPortIdx: 0, sigType: sigAudio)

    let cr = compileGraph(g)
    check cr.success
    check cr.pipeline.delayStateCount == 2

    for i in 0 ..< cr.pipeline.delayStateCount:
      let st = cr.pipeline.delayStates[i]
      check st.delayFrames == 100
      check st.ringChannels == int32(DelayCompensationRingChannels)
      # max(100 + 256, 1024) кадров × 2 канала слотов.
      check st.bufferSize == 1024 * DelayCompensationRingChannels
      check st.buffer != nil
      check st.writePos == 0

    destroyPipeline(cr.pipeline)

  test "граф без латентных нод не создаёт состояний задержки":
    var g: NodeGraph
    g.nodes[1] = makeNode(1, "Source", 0, 1, 0)
    g.nodes[2] = makeNode(2, "Sink", 1, 0, 0)
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio)

    let cr = compileGraph(g)
    check cr.success
    check cr.pipeline.delayStateCount == 0
    check cr.pipeline.delayStates == nil
    destroyPipeline(cr.pipeline)

