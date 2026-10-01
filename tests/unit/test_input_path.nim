# tests/unit/test_input_path.nim
#
# Входной аудиотракт (issue #3).
#
# Что доказывает тест:
#   1. драйверный вход публикуется в граф и проходит input -> gain -> мастер
#      без изменений (unity);
#   2. метрики входных пиков считаются по сырому входу до нод;
#   3. устройство без входных каналов не роняет движок и даёт тишину;
#   4. offline-рендер не регрессирует: вход = тишина, флаг pfOffline
#      доезжает до нод (проверяется нодой-пробником);
#   5. маршрутизация input -> TrackInputRouting -> AudioRecorder: записанный
#      WAV действительно содержит поданный синус 1 кГц.
#
# Тест синхронный: блоки «прокручиваются» вручную, поток драйвера не нужен.

import std/[unittest, os, tables]
import signal_types
import node_interface
import graph_compiler
import audio_engine
import audio_recorder
import ipc_bus
import wav_codec
import sdk/node_api
import sdk/node_registry
import sdk/pipeline_builder
import builtin/builtin_registry
import test_support

const
  BlockSize = 128
  SineFreq = 1000.0f

# ==============================================================================
# Нода-пробник: запоминает, какие ProcessingFlags доехали до process()
# ==============================================================================

type
  FlagProbeState = object
    seenOffline: bool
    seenRealtime: bool

var
  probeDesc: NodeDesc
  probeFactory: NodeFactory
  probeReady = false

proc probeCreate(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard desc
  discard userData
  allocShared0(sizeof(FlagProbeState))

proc probeDestroy(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  deallocShared(state)

proc probeProcess(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard audio
  discard ctrl
  discard events
  let st = cast[ptr FlagProbeState](userData)
  if st.isNil or ctx.isNil:
    return
  if pfOffline in ctx.flags:
    st.seenOffline = true
  if pfRealtime in ctx.flags:
    st.seenRealtime = true

proc initProbe() =
  probeDesc = NodeDesc(
    id: fixedId("test.flagprobe"),
    name: fixedName("FlagProbe"),
    category: fixedName("test"),
    audioInCount: 1, audioOutCount: 1,
    maxChannels: 2
  )
  probeFactory = NodeFactory(
    create: probeCreate, destroy: probeDestroy, process: probeProcess
  )

proc ensureProbe(): ptr NodeFactory =
  if not probeReady:
    initProbe()
    probeReady = true
  addr probeFactory

# ==============================================================================
# Оснастка: сборка графа input -> gain (мастер)
# ==============================================================================

type
  InputRig = object
    reg: NodeRegistry
    inputNode: EditorNode
    gainNode: EditorNode

proc buildInputRig(rig: var InputRig): tuple[cr: CompileResult, binding: ptr PipelineBinding] =
  ## Граф: euterpia.input (id 1) -> euterpia.gain (id 2, мастер).
  rig.reg = initNodeRegistry()
  check registerBuiltinNodes(rig.reg) == BuiltinCount

  check rig.reg.instantiateNode("euterpia.input", 1, rig.inputNode)
  check rig.reg.instantiateNode("euterpia.gain", 2, rig.gainNode)

  var g: NodeGraph
  g.nodes[1] = rig.inputNode
  g.nodes[2] = rig.gainNode
  g.connections.add EditorConnection(
    srcNodeId: 1, srcPortIdx: 0,
    dstNodeId: 2, dstPortIdx: 0,
    sigType: sigAudio
  )

  result.binding = nil
  check buildPipeline(rig.reg, g, 2, result.cr, result.binding)
  check result.cr.success
  check result.binding != nil

proc destroyInputRig(rig: var InputRig) =
  ## Состояния нод движку не принадлежат: освобождаем их сами.
  let inEntry = rig.reg.findNodeType("euterpia.input")
  let gainEntry = rig.reg.findNodeType("euterpia.gain")
  if not inEntry.isNil:
    destroyNodeState(inEntry, rig.inputNode.userData)
  if not gainEntry.isNil:
    destroyNodeState(gainEntry, rig.gainNode.userData)

proc fillSine(buf: var array[BlockSize * 2, float32]) =
  for i in 0 ..< BlockSize:
    let s = sineAt(i, SineFreq)
    buf[i * 2] = s
    buf[i * 2 + 1] = s

proc lastMetric(engine: ptr AudioEngine): EngineMetric =
  ## Последняя метрика из SPSC-очереди (в тесте блоков мало).
  var m: EngineMetric
  var tmp: EngineMetric
  while engine.pollMetrics(tmp):
    m = tmp
  m

# ==============================================================================
# Тесты
# ==============================================================================

suite "input path: публикация входа":
  test "input -> gain -> мастер: сигнал проходит без изменений":
    var rig: InputRig
    let (cr, binding) = rig.buildInputRig()
    discard binding

    let engine = createAudioEngine(
      sampleRate = 48000.0f, blockSize = int32(BlockSize)
    )
    check engine != nil
    engine.setInputChannels(2)

    check engine.postGraphUpdate(cr.pipeline)
    check engine.postPlay()

    var inBuf: array[BlockSize * 2, float32]
    var outBuf: array[BlockSize * 2, float32]
    fillSine(inBuf)

    let pin = cast[ptr UncheckedArray[float32]](addr inBuf[0])
    let pout = cast[ptr UncheckedArray[float32]](addr outBuf[0])

    # Первый блок применяет граф и несёт флаг pfFirstBlock.
    engine.renderBlock(pin, 2'i32, pout)

    # Второй блок — чистый проход: вход не должен быть окрашен.
    engine.renderBlock(pin, 2'i32, pout)
    for i in 0 ..< BlockSize * 2:
      check abs(outBuf[i] - inBuf[i]) < 1e-6f

    # Метрика входа считается по сырому драйверному буферу.
    let m = lastMetric(engine)
    check abs(m.inputPeakL - 1.0f) < 1e-4f
    check abs(m.inputPeakR - 1.0f) < 1e-4f

    destroyAudioEngine(engine)
    rig.destroyInputRig()

  test "устройство без входных каналов: тишина, без падения":
    var rig: InputRig
    let (cr, binding) = rig.buildInputRig()
    discard binding

    let engine = createAudioEngine(
      sampleRate = 48000.0f, blockSize = int32(BlockSize)
    )
    check engine != nil
    engine.setInputChannels(0)

    check engine.postGraphUpdate(cr.pipeline)
    check engine.postPlay()

    var outBuf: array[BlockSize * 2, float32]
    let pout = cast[ptr UncheckedArray[float32]](addr outBuf[0])

    # Путь без входа: driverIn отсутствует.
    engine.renderBlock(pout)
    engine.renderBlock(pout)

    check isSilent(outBuf)

    let m = lastMetric(engine)
    check m.inputPeakL == 0.0f
    check m.inputPeakR == 0.0f

    destroyAudioEngine(engine)
    rig.destroyInputRig()

  test "статус драйвера считается в inputXruns":
    let engine = createAudioEngine(
      sampleRate = 48000.0f, blockSize = int32(BlockSize)
    )
    check engine != nil
    check engine.inputXrunCount() == 0'u32

    # paInputOverflow (0x2) и paInputUnderflow (0x1).
    engine.noteInputStatus(0x00000002'u32)
    engine.noteInputStatus(0x00000003'u32)
    check engine.inputXrunCount() == 2'u32

    destroyAudioEngine(engine)

suite "input path: offline не регрессирует":
  test "offline-рендер: вход = тишина, pfOffline доезжает до нод":
    discard ensureProbe()

    var reg = initNodeRegistry()
    check registerBuiltinNodes(reg) == BuiltinCount
    check reg.registerNodeType(addr probeDesc, addr probeFactory)

    var inputNode, probeNode: EditorNode
    check reg.instantiateNode("euterpia.input", 1, inputNode)
    check reg.instantiateNode("test.flagprobe", 2, probeNode)

    var g: NodeGraph
    g.nodes[1] = inputNode
    g.nodes[2] = probeNode
    g.connections.add EditorConnection(
      srcNodeId: 1, srcPortIdx: 0,
      dstNodeId: 2, dstPortIdx: 0,
      sigType: sigAudio
    )

    var cr: CompileResult
    var binding: ptr PipelineBinding
    check buildPipeline(reg, g, 2, cr, binding)

    let engine = createAudioEngine(
      sampleRate = 48000.0f, blockSize = int32(BlockSize)
    )
    check engine != nil
    engine.setInputChannels(2)
    check engine.postGraphUpdate(cr.pipeline)
    check engine.postPlay()

    let st = cast[ptr FlagProbeState](probeNode.userData)
    check st != nil

    var inBuf: array[BlockSize * 2, float32]
    var outBuf: array[BlockSize * 2, float32]
    fillSine(inBuf)
    let pin = cast[ptr UncheckedArray[float32]](addr inBuf[0])
    let pout = cast[ptr UncheckedArray[float32]](addr outBuf[0])

    engine.renderBlock(pin, 2'i32, pout)
    check st.seenRealtime
    check not st.seenOffline

    # Offline: движок обязан пометить блок pfOffline, а вход отдать тишиной.
    var offlineOut: array[BlockSize * 2, float32]
    var scratch: array[BlockSize * 2, float32]
    engine.renderOffline(
      int64(BlockSize),
      cast[ptr UncheckedArray[float32]](addr offlineOut[0]),
      cast[ptr UncheckedArray[float32]](addr scratch[0])
    )

    check st.seenOffline
    check isSilent(offlineOut)

    let m = lastMetric(engine)
    check m.inputPeakL == 0.0f
    check m.inputPeakR == 0.0f

    destroyAudioEngine(engine)
    destroyNodeState(reg.findNodeType("euterpia.input"), inputNode.userData)
    destroyNodeState(reg.findNodeType("test.flagprobe"), probeNode.userData)

suite "input path: запись в WAV":
  test "input -> TrackInputRouting -> AudioRecorder: WAV содержит 1 кГц":
    let recDir = getTempDir() / "euterpia_input_path_rec"
    if dirExists(recDir):
      removeDir(recDir)

    var rec = initAudioRecorder(
      sampleRate = 48000, blockSize = BlockSize, outputDir = recDir,
      inputChannels = 2, ringFrames = 32768
    )
    check rec.addTrackRecorder(
      trackId = 1, inputChannel = 0, channels = 2, preRollFrames = 0
    )
    rec.armTrack(1)
    rec.startRecording(currentSample = 0)
    sleep(150)

    # Граф нужен, чтобы транспорт шёл и движок вызывал recordBlock каждый блок.
    var rig: InputRig
    let (cr, binding) = rig.buildInputRig()
    discard binding

    let engine = createAudioEngine(
      sampleRate = 48000.0f, blockSize = int32(BlockSize)
    )
    check engine != nil
    engine.setInputChannels(2)
    check engine.postGraphUpdate(cr.pipeline)
    check engine.postPlay()
    engine.attachRecorder(addr rec)
    check engine.hasRecorder()

    var inBuf: array[BlockSize * 2, float32]
    var outBuf: array[BlockSize * 2, float32]
    fillSine(inBuf)
    let pin = cast[ptr UncheckedArray[float32]](addr inBuf[0])
    let pout = cast[ptr UncheckedArray[float32]](addr outBuf[0])

    for b in 0 ..< 24:
      engine.renderBlock(pin, 2'i32, pout)

    # Worker thread открывает WAV, увидев rsRecording.
    sleep(150)
    rec.stopRecording()
    # Ещё один блок: движок вызывает recordBlock, worker закрывает файл.
    engine.renderBlock(pin, 2'i32, pout)
    engine.detachRecorder()
    sleep(150)

    check not rec.isRecording()
    check rec.getTrackDroppedFrames(1) == 0'i64

    let regions = rec.getRecordedRegions()
    check regions.len >= 1

    if regions.len >= 1:
      check regions[0].sampleRate == 48000
      check regions[0].channels == 2

      var reader = openWavReader(regions[0].filename)
      check reader.info.sampleRate == 48000
      check reader.info.channels == 2

      var raw: array[8192, uint8]
      var samples: array[2048, float32]
      let n = readFrames(
        reader,
        cast[ptr UncheckedArray[uint8]](addr raw[0]),
        cast[ptr UncheckedArray[float32]](addr samples[0]),
        1024
      )
      close(reader)

      check n >= 512

      # Левый канал = каждый второй сэмпл interleaved-буфера.
      var ch0: seq[float32]
      for f in 0 ..< int(n):
        ch0.add samples[f * 2]

      check not isSilent(ch0)
      let freq = estimateFreq(ch0, 48000.0f)
      check freq > 900.0f
      check freq < 1100.0f

    destroyAudioEngine(engine)
    rig.destroyInputRig()
    rec.cleanupRecordings()
    destroyAudioRecorder(rec)
    if dirExists(recDir):
      removeDir(recDir)
