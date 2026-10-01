# tests/integration_test.nim
#
# Интеграционный тест ЯДРА EUTERPIA.
# Требует компиляции с --threads:on (из-за dsp_scheduler.nim и audio_recorder.nim).
#
# Сборка:
#   nim c --threads:on -r tests/integration_test.nim

when not compileOption("threads"):
  {.error: "integration_test requires --threads:on".}

import std/[strformat, math, os, tables, atomics]

import ../core/signal_types
import ../core/node_interface
import ../core/graph_compiler
import ../core/compiled_pipeline
import ../core/audio_engine
import ../core/transport
import ../core/sequencer
import ../core/project
import ../core/memory_pool
import ../core/dsp_scheduler
import ../core/audio_recorder
import ../core/audio_buffer
import ../core/param_registry
import ../core/audio_params
import ../core/wav_codec

from ../core/ipc_bus import
  MpscQueue, SpscQueue, SharedPool,
  initMpscQueue, initSpscQueue, initSharedPool,
  push, pop,
  acquireBlock, releaseBlock

# ---------------------------------------------------------------------------
# Тестовые DSP-proc'и (заменяют удалённые core_nodes/dsp_nodes).
# 'out' — зарезервированное слово Nim, используем 'outBuf' / 'inBuf'.
# ---------------------------------------------------------------------------

proc testPassThroughProc(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [].} =
  discard ctrl
  discard events
  discard userData
  if audio.inputCount < 1 or audio.outputCount < 1:
    return
  let inBuf = audio.inputs[0]
  let outBuf = audio.outputs[0]
  if inBuf == nil or outBuf == nil:
    return
  if inBuf.data == nil or outBuf.data == nil:
    return
  let n = min(ctx.blockSize, inBuf.frames)
  var i: int32 = 0
  while i < n:
    outBuf.data[i] = inBuf.data[i]
    inc i

proc dummySchedulerTask(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctx
  discard audio
  discard ctrl
  discard events
  discard userData

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc dirIsEmpty(path: string): bool =
  ## Проверяет, что каталог пуст (нет ни файлов, ни подкаталогов).
  result = true
  for _ in walkDir(path):
    result = false
    break

# ---------------------------------------------------------------------------
# Тест
# ---------------------------------------------------------------------------

proc runCoreIntegrationTest() =
  echo "================================================================"
  echo "        EUTERPIA CORE INTEGRATION TEST                          "
  echo "================================================================"

  # ========================================================================
  # [1] Memory pools
  # ========================================================================
  echo "\n[1] Testing Memory Pools..."

  var memPool: MemoryPool
  doAssert initMemoryPool(memPool, capacity = 64, blockSize = 1024),
    "initMemoryPool failed"
  echo &"   MemoryPool: cap={memPool.capacity()}, blockSize={memPool.blockSize()}, used={memPool.usedCount()}"

  var handles: seq[PoolHandle] = @[]
  for i in 0 ..< 16:
    let h = memPool.allocBlock()
    doAssert isValidHandle(h), "allocBlock returned invalid handle"
    handles.add h
  echo &"   Allocated 16 blocks, used={memPool.usedCount()}, free={memPool.freeCount()}"

  doAssert memPool.freeBlock(handles[0]), "freeBlock failed"
  doAssert not memPool.freeBlock(handles[0]), "double-free must be rejected"

  for i in 1 ..< handles.len:
    doAssert memPool.freeBlock(handles[i])
  echo &"   Freed all, used={memPool.usedCount()}"
  destroyMemoryPool(memPool)

  var audioPool: AudioBufferPool
  doAssert initAudioBufferPool(audioPool, capacity = 16)
  var lease = allocAudioBuffer(audioPool)
  doAssert lease.buffer != nil, "allocAudioBuffer returned nil"
  clearAudioBuffer(lease.buffer)
  doAssert freeAudioBuffer(audioPool, lease), "freeAudioBuffer failed"
  doAssert lease.buffer == nil, "lease must be invalidated after free"
  destroyAudioBufferPool(audioPool)
  echo "   AudioBufferPool OK"

  var eventPool: EventQueuePool
  doAssert initEventQueuePool(eventPool, capacity = 16)
  var eqLease = allocEventQueue(eventPool)
  doAssert eqLease.queue != nil, "allocEventQueue returned nil"
  doAssert freeEventQueue(eventPool, eqLease)
  destroyEventQueuePool(eventPool)
  echo "   EventQueuePool OK"

  # ========================================================================
  # [2] IPC queues
  # ========================================================================
  echo "\n[2] Testing IPC queues..."

  var mpsc: MpscQueue[int32, 16]
  initMpscQueue(mpsc)
  for i in 0'i32 ..< 8:
    doAssert mpsc.push(i), "MPSC push failed"
  var readVal: int32
  var count = 0
  while mpsc.pop(readVal):
    inc count
  doAssert count == 8, "MPSC pop count mismatch"
  echo "   MPSC queue OK (8 in / 8 out)"

  var spsc: SpscQueue[int32, 16]
  initSpscQueue(spsc)
  for i in 0'i32 ..< 8:
    doAssert spsc.push(i), "SPSC push failed"
  count = 0
  while spsc.pop(readVal):
    inc count
  doAssert count == 8, "SPSC pop count mismatch"
  echo "   SPSC queue OK (8 in / 8 out)"

  var sharedPool: SharedPool
  initSharedPool(sharedPool)
  let bid1 = sharedPool.acquireBlock()
  let bid2 = sharedPool.acquireBlock()
  doAssert bid1 >= 0 and bid2 >= 0 and bid1 != bid2
  sharedPool.releaseBlock(bid1)
  sharedPool.releaseBlock(bid2)
  echo "   SharedPool OK"

  # ========================================================================
  # [3] Transport (control-plane)
  # ========================================================================
  echo "\n[3] Testing Transport..."

  var trans = initTransport(48000.0f)
  doAssert not trans.isPlaying()
  trans.play()
  doAssert trans.isPlaying()
  trans.setTempo(140.0f)
  trans.setLoop(true, 0'i64, 96000'i64)

  let spq = trans.samplesPerQuarter()
  let spb = trans.samplesPerBar()
  doAssert spq > 0.0 and spb > 0.0
  echo &"   samplesPerQuarter @140BPM = {spq:.2f}"
  echo &"   samplesPerBar             = {spb:.2f}"

  let (bar, beat, tick) = trans.sampleToBarBeatTick(48000'i64)
  echo &"   48000 samples -> Bar:Beat:Tick = {bar}:{beat}:{tick}"

  let back = trans.barBeatTickToSample(bar, beat, tick)
  echo &"   Roundtrip back to samples      = {back}"

  let snap = trans.getSnapshot()
  echo &"   Snapshot: isPlaying={snap.isPlaying}, tempo={snap.tempo}, pos={snap.samplePosition}"

  trans.stop()
  doAssert not trans.isPlaying()
  doAssert trans.samplePosition.load() == 0'i64
  echo "   Transport OK"

  # ========================================================================
  # [4] Signal types
  # ========================================================================
  echo "\n[4] Testing Signal Types..."

  var evq: EventQueue
  clearEvents(addr evq)
  doAssert evq.count == 0

  let ev = RealtimeEvent(
    frameOffset: 0'u32,
    subFrame: 0.0f,
    kind: evNoteOn,
    channel: 0'u8,
    data: [60.0f, 0.8f, 0.0f, 0.0f]
  )
  doAssert pushEvent(addr evq, ev)
  doAssert pushEvent(addr evq, ev)
  doAssert evq.count == 2
  sortEvents(addr evq)
  clipEvents(addr evq, 128'u32)
  echo &"   EventQueue: {evq.count} events after clip"

  var sm = initSmoother(timeMs = 10.0f, sampleRate = 48000.0f, initialVal = 0.0f)
  sm.setTarget(1.0f)
  for _ in 0 ..< 1000:
    discard sm.process()
  doAssert abs(sm.current - 1.0f) < 0.01f
  echo &"   ParamSmoother converged to {sm.current:.4f}"
  echo "   Signal types OK"

  # ========================================================================
  # [5] StreamingAudioBuffer (SPSC ring)
  # ========================================================================
  echo "\n[5] Testing Streaming Audio Buffer..."

  var streambuf = StreamingAudioBuffer.init(1024'i64, 2'i32)
  doAssert streambuf.availableForWrite() == 1024'i64

  var src: array[256, float32]
  for i in 0 ..< src.len: src[i] = 0.5f
  let written = streambuf.write(
    cast[ptr UncheckedArray[float32]](addr src[0]), 64'i32
  )
  doAssert written == 64
  doAssert streambuf.availableForRead() == 64'i64

  var dst: array[256, float32]
  let readCount = streambuf.read(
    cast[ptr UncheckedArray[float32]](addr dst[0]), 64'i32
  )
  doAssert readCount == 64
  doAssert abs(dst[0] - 0.5f) < 1e-6f
  doAssert streambuf.availableForRead() == 0'i64

  streambuf.destroy()
  echo "   StreamingAudioBuffer OK"

  # ========================================================================
  # [6] Param Registry
  # ========================================================================
  echo "\n[6] Testing Param Registry..."

  var reg = initParamRegistry(64'u32)
  let b1 = reg.bindParam(1'u32, 100'u32)
  doAssert b1.isValid(), "binding must be valid"

  let b1_again = reg.bindParam(1'u32, 100'u32)
  doAssert b1.slot == b1_again.slot

  var lookedUp: ParamBinding
  doAssert lookupParam(addr reg, 1'u32, 100'u32, lookedUp)
  doAssert lookedUp.slot == b1.slot

  reg.releaseParam(1'u32, 100'u32)
  doAssert not lookupParam(addr reg, 1'u32, 100'u32, lookedUp)

  deinitParamRegistry(reg)
  echo "   ParamRegistry OK"

  # ========================================================================
  # [7] Graph Compiler
  # ========================================================================
  echo "\n[7] Testing Graph Compiler..."

  var g: NodeGraph
  let node1 = EditorNode(
    id: 1, name: "Source", nodeType: "test.source",
    processProc: testPassThroughProc,
    userData: nil,
    audioInCount: 0, audioOutCount: 1,
    latency: LatencyProfile()
  )
  let node2 = EditorNode(
    id: 2, name: "Sink", nodeType: "test.sink",
    processProc: testPassThroughProc,
    userData: nil,
    audioInCount: 1, audioOutCount: 0,
    latency: LatencyProfile()
  )
  g.nodes[1] = node1
  g.nodes[2] = node2
  g.connections.add EditorConnection(
    srcNodeId: 1, srcPortIdx: 0,
    dstNodeId: 2, dstPortIdx: 0,
    sigType: sigAudio
  )

  let cr = compileGraph(g)
  doAssert cr.success, "compileGraph failed"
  let pipeline = cr.pipeline
  echo &"   Pipeline compiled: steps={pipeline.stepCount}, graphVersion={pipeline.graphVersion}"

  doAssert pipeline.stepCount == 2
  doAssert pipeline.audioBufferPoolCount >= 1
  doAssert pipeline.audioBufferPool != nil
  doAssert pipeline.steps[0].audio.outputCount == 1
  doAssert pipeline.steps[1].audio.inputCount == 1

  destroyPipeline(pipeline)
  echo "   Graph compiler OK"

  # ========================================================================
  # [8] Sequencer
  # ========================================================================
  echo "\n[8] Testing Sequencer..."

  var sqTrans = initTransport(48000.0f)
  var seq = initSequencer(addr sqTrans)

  let tid = seq.addTrack(ttMidi, "Test Track")
  doAssert tid == 1
  let cid = seq.addClip(1, ctMidi, 0, 3840)
  doAssert cid == 1

  seq.addNote(1, 1, 0,    240, 60, 100)
  seq.addNote(1, 1, 480,  240, 64, 100)
  seq.addNote(1, 1, 960,  240, 67, 100)
  seq.addNote(1, 1, 1440, 240, 72, 100)

  seq.addAutomationPoint(nodeId = 1, paramId = 42'u32,
                         tick = 0, value = 0.0f, curve = acLinear)
  seq.addAutomationPoint(nodeId = 1, paramId = 42'u32,
                         tick = 1920, value = 1.0f, curve = acSmooth)

  let compiled = seq.compile(48000)
  doAssert compiled.tracks.len == 1
  doAssert compiled.tracks[0].clips.len == 1
  doAssert compiled.tracks[0].clips[0].events.len == 8
  doAssert compiled.automation.len == 1
  doAssert compiled.maxTick > 0
  echo &"   Tracks={compiled.tracks.len}, events={compiled.tracks[0].clips[0].events.len}, lanes={compiled.automation.len}"
  echo &"   maxTick={compiled.maxTick}"

  let autVal = compiled.getAutomationValue(1'i32, 42'u32, 960'i64)
  echo &"   Automation value at tick 960 = {autVal:.4f}"
  doAssert autVal > 0.0f and autVal < 1.0f

  echo "   Sequencer OK"

  # ========================================================================
  # [9] Project save/load
  # ========================================================================
  echo "\n[9] Testing Project save/load..."

  var proj: ProjectFormat
  proj.format = ProjectFormatName
  proj.version = ProjectFormatVersion
  proj.metadata.name = "Core Test Project"
  proj.metadata.author = "EUTERPIA"
  proj.metadata.sampleRate = 48000.0f
  proj.metadata.tempo = 120.0f
  proj.metadata.timeSignature = TimeSignatureFormat(numerator: 4, denominator: 4)

  var nf: NodeFormat
  nf.id = 1
  nf.nodeType = "test.osc"
  nf.name = "Osc 1"
  nf.audioOutCount = 1
  nf.parameters["freq"] = 440.0f
  proj.graph.nodes.add nf

  proj.graph.connections.add ConnectionFormat(
    srcNodeId: 1, srcPortIdx: 0,
    dstNodeId: 2, dstPortIdx: 0,
    sigType: 0
  )

  var tf: TrackFormat
  tf.id = 1
  tf.name = "Track 1"
  tf.trackType = 0
  tf.volume = 1.0f
  tf.pan = 0.0f
  proj.sequencer.tracks.add tf

  let testPath = "core_test_project.json"
  let sr = saveProject(proj, testPath)
  doAssert sr.success, "saveProject failed"
  echo &"   Saved to {testPath}"

  let lr = loadProject(testPath)
  doAssert lr.success, "loadProject failed"
  doAssert lr.value.metadata.name == "Core Test Project"
  doAssert lr.value.graph.nodes.len == 1
  doAssert lr.value.graph.nodes[0].nodeType == "test.osc"
  doAssert lr.value.graph.nodes[0].parameters["freq"] == 440.0f
  doAssert lr.value.sequencer.tracks.len == 1

  echo &"   Loaded: name='{lr.value.metadata.name}', nodes={lr.value.graph.nodes.len}, tracks={lr.value.sequencer.tracks.len}"
  removeFile(testPath)
  echo "   Project OK"

  # ========================================================================
  # [10] WAV codec
  # ========================================================================
  echo "\n[10] Testing WAV codec..."

  let wavPath = "core_test.wav"
  let info = AudioFileInfo(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 24,
    isFloat: false
  )

  var writer = openWavWriter(wavPath, info)
  var buf: array[256, float32]
  for i in 0 ..< 256:
    buf[i] = sin(2.0f * PI * float32(i) / 48000.0f) * 0.5f

  writeFrames(writer, cast[ptr UncheckedArray[float32]](addr buf[0]), 128)
  close(writer)
  echo "   Wrote 128 frames @ 24-bit"

  var reader = openWavReader(wavPath)
  doAssert reader.info.sampleRate == 48000
  doAssert reader.info.channels == 2
  doAssert reader.info.bitsPerSample == 24
  doAssert reader.info.numFrames == 128
  echo &"   Header: {reader.info.sampleRate}Hz, {reader.info.channels}ch, {reader.info.bitsPerSample}bit, {reader.info.numFrames} frames"

  var rawBuf: array[4096, uint8]
  var outBuf: array[256, float32]
  let framesRead = readFrames(
    reader,
    cast[ptr UncheckedArray[uint8]](addr rawBuf[0]),
    cast[ptr UncheckedArray[float32]](addr outBuf[0]),
    128
  )
  doAssert framesRead == 128
  doAssert abs(outBuf[0]) < 1e-3f
  echo &"   Read back {framesRead} frames, first sample={outBuf[0]:.6f}"
  close(reader)
  removeFile(wavPath)
  echo "   WAV codec OK"

  # ========================================================================
  # [11] Audio Engine
  # ========================================================================
  echo "\n[11] Testing Audio Engine..."

  let engine = createAudioEngine(sampleRate = 48000.0f, blockSize = 128)
  doAssert engine != nil, "createAudioEngine returned nil"

  var outBuf2: array[256, float32]
  engine.renderBlock(cast[ptr UncheckedArray[float32]](addr outBuf2[0]))

  var energy = 0.0f
  for i in 0 ..< 256: energy += abs(outBuf2[i])
  doAssert energy == 0.0f, "silent render must be zero"
  echo "   Silent render OK"

  doAssert engine.postPlay(), "postPlay failed"
  engine.renderBlock(cast[ptr UncheckedArray[float32]](addr outBuf2[0]))
  doAssert engine.currentFrame() == 128, "transport must advance after play"
  echo &"   After 1 block: frame={engine.currentFrame()}"

  doAssert engine.postStop()
  destroyAudioEngine(engine)
  echo "   Audio Engine OK"

  # ========================================================================
  # [12] DSP Scheduler
  # ========================================================================
  echo "\n[12] Testing DSP Scheduler..."

  var descs: seq[TaskDesc] = @[]
  for i in 0 ..< 3:
    var task: DspTask
    task.process = dummySchedulerTask
    task.nodeId = int32(i)
    var desc = TaskDesc(task: task)
    if i > 0:
      desc.reads.add audioResource(int32(i - 1), 0)
    desc.writes.add audioResource(int32(i), 0)
    descs.add desc

  var sched: DspScheduler
  let schedOk = initScheduler(sched, descs, workerCount = 2)
  doAssert schedOk, "initScheduler failed"
  echo "   Scheduler initialized (2 workers)"

  var ctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)
  for _ in 0 ..< 16:
    sched.renderBlock(addr ctx)
  echo "   Rendered 16 blocks"
  deinitScheduler(sched)
  echo "   DSP Scheduler OK"

  # ========================================================================
  # [13] Audio Recorder
  # ========================================================================
  echo "\n[13] Testing Audio Recorder..."

  let recDir = "core_test_recordings"
  var recorder = initAudioRecorder(
    sampleRate = 48000,
    blockSize = 128,
    outputDir = recDir,
    inputChannels = 2,
    ringFrames = 4096
  )

  doAssert recorder.addTrackRecorder(
    trackId = 1,
    routing = TrackInputRouting(channels: 2, src0: 0, src1: 1),
    preRollFrames = 0
  )
  doAssert recorder.addTrackRecorder(
    trackId = 2, inputChannel = 0, channels = 1, preRollFrames = 0
  )

  recorder.armTrack(1)
  doAssert recorder.hasArmedTracks()
  recorder.disarmTrack(1)

  var inputBuf: array[256, float32]
  for i in 0 ..< 256:
    inputBuf[i] = sin(2.0f * PI * float32(i) / 48000.0f) * 0.5f

  recorder.recordBlock(
    cast[ptr UncheckedArray[float32]](addr inputBuf[0]),
    currentSample = 0
  )

  let regions = recorder.getRecordedRegions()
  echo &"   Active regions (before cleanup): {regions.len}"

  recorder.cleanupRecordings()
  destroyAudioRecorder(recorder)

  if dirExists(recDir) and dirIsEmpty(recDir):
    removeDir(recDir)
  echo "   Audio Recorder OK"

  echo "\n================================================================"
  echo "        ALL CORE INTEGRATION TESTS PASSED                       "
  echo "================================================================"


when isMainModule:
  runCoreIntegrationTest()