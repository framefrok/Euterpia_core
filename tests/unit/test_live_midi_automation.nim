# tests/unit/test_live_midi_automation.nim
#
# Живой MIDI-вход и продюсер автоматизации (issue #413).
#
# Проверяется на движке БЕЗ звуковой карты: callback вызывается напрямую.
#   * внешнее MIDI-событие доходит до ноды-цели и меняет её параметр;
#   * событие из «будущего» за пределами блока считается опоздавшим
#     (`midiLate`), а не молча теряется;
#   * живая автоматизация применяется на границе блока по тику транспорта и
#     совпадает с офлайн-формулой (значение в середине линии);
#   * линии автоматизации публикуются двойным буфером: смена набора не
#     требует остановки транспорта и не рвёт блок.

import std/[unittest, math, tables]

import sdk/node_api
import sdk/node_registry
import sdk/pipeline_builder
import builtin/builtin_registry
import graph_compiler
import compiled_pipeline
import audio_engine
import signal_types
import live_automation
import builtin/generators/oscillator
import builtin/mixing/gain

const
  EngineSr = 48000.0'f32
  EngineBlock = 256
  Tempo = 120.0
  OscId = 1
  GainId = 2
  Ppq = 960

type
  Rig = object
    engine: ptr AudioEngine
    oscState, gainState: pointer
    oscFactory, gainFactory: ptr NodeFactory

proc makeRig(): Rig =
  var reg = initNodeRegistry()
  doAssert registerBuiltinNodes(reg) > 0

  var osc, gain: EditorNode
  doAssert reg.instantiateNode("euterpia.osc", OscId, osc, EngineSr)
  doAssert reg.instantiateNode("euterpia.gain", GainId, gain, EngineSr)
  let oscEntry = reg.findNodeType("euterpia.osc")
  let gainEntry = reg.findNodeType("euterpia.gain")
  doAssert not oscEntry.isNil and not gainEntry.isNil
  result.oscFactory = oscEntry.factory
  result.gainFactory = gainEntry.factory
  result.oscState = osc.userData
  result.gainState = gain.userData

  var g: NodeGraph
  g.nodes[OscId] = osc
  g.nodes[GainId] = gain
  g.connections.add EditorConnection(
    srcNodeId: OscId, srcPortIdx: 0,
    dstNodeId: GainId, dstPortIdx: 0,
    sigType: sigAudio)

  var cr: CompileResult
  var binding: ptr PipelineBinding
  doAssert buildPipeline(reg, g, GainId, cr, binding)

  result.engine = createAudioEngine(EngineSr, int32(EngineBlock))
  doAssert result.engine != nil
  doAssert result.engine.postGraphUpdate(ownPipeline(cr.pipeline))
  discard result.engine.postSetTempo(Tempo)
  discard result.engine.postPlay()
  flushQueuedCommands(result.engine)

proc freeRig(rig: var Rig) =
  if not rig.engine.isNil:
    destroyAudioEngine(rig.engine)
    rig.engine = nil
  if rig.oscState != nil: rig.oscFactory.destroy(rig.oscState)
  if rig.gainState != nil: rig.gainFactory.destroy(rig.gainState)

proc renderBlocks(rig: var Rig; count: int) =
  var buf: array[EngineBlock * 2, float32]
  for i in 0 ..< count:
    for j in 0 ..< buf.len:
      buf[j] = 0.0f
    renderBlock(rig.engine,
                cast[ptr UncheckedArray[float32]](addr buf[0]))

proc gainDb(rig: Rig): float32 =
  var v = 0.0'f32
  doAssert rig.gainFactory.getParam(rig.gainState, GainParamGain, addr v)
  v

proc oscFreq(rig: Rig): float32 =
  var v = 0.0'f32
  doAssert rig.oscFactory.getParam(rig.oscState, OscParamFrequency, addr v)
  v

suite "live: MIDI-вход в граф (#413)":

  test "note on доходит до ноды-цели и меняет частоту":
    var rig = makeRig()
    defer: rig.freeRig()

    rig.engine.setMidiInputTarget(int32(OscId))
    check rig.engine.midiInputTarget() == int32(OscId)
    # Note On, note 81 = 880 Гц.
    check rig.engine.postMidiEventAtFrame(0x90'u8, 81'u8, 100'u8, 0'i64)
    rig.renderBlocks(1)
    check abs(rig.oscFreq() - 880.0'f32) < 1.0'f32
    check rig.engine.midiLateCount() == 0
    check rig.engine.midiDroppedCount() == 0

  test "событие из будущего за пределами блока считается опоздавшим":
    var rig = makeRig()
    defer: rig.freeRig()

    rig.engine.setMidiInputTarget(int32(OscId))
    check rig.engine.postMidiEventAtFrame(0x90'u8, 45'u8, 100'u8,
                                          int64(EngineBlock) * 8)
    rig.renderBlocks(1)
    check rig.engine.midiLateCount() == 1
    # Частота осталась прежней (440 Гц по умолчанию).
    check abs(rig.oscFreq() - 440.0'f32) < 1.0'f32

  test "без ноды-цели события не теряются молча":
    var rig = makeRig()
    defer: rig.freeRig()

    check rig.engine.midiInputTarget() == -1
    check rig.engine.postMidiEventAtFrame(0x90'u8, 60'u8, 100'u8, 0'i64)
    rig.renderBlocks(1)
    check rig.engine.midiLateCount() == 1
    check abs(rig.oscFreq() - 440.0'f32) < 1.0'f32

suite "live: продюсер автоматизации (#413)":

  test "значение линии на тике совпадает с линейной интерполяцией":
    var lane = LiveAutomationLane(nodeId: 1, paramId: 0)
    lane.addLiveAutomationPoint(0, -20.0'f32, 0)     # acLinear
    lane.addLiveAutomationPoint(2 * Ppq, 0.0'f32, 0)

    check abs(liveAutomationValueAt(lane, 0.0) + 20.0'f32) < 0.01
    check abs(liveAutomationValueAt(lane, float64(Ppq)) + 10.0'f32) < 0.01
    check abs(liveAutomationValueAt(lane, float64(2 * Ppq))) < 0.01
    # За границами — крайние значения.
    check abs(liveAutomationValueAt(lane, -50.0) + 20.0'f32) < 0.01
    check abs(liveAutomationValueAt(lane, 9000.0)) < 0.01

  test "тик считается из кадра той же формулой, что у офлайн-рендера":
    # 1 секунда при 120 BPM = 2 четверти = 1920 тиков.
    check abs(liveAutomationTickForFrame(48000, 48000.0, 120.0) - 1920.0) < 0.001
    check abs(liveAutomationTickForFrame(0, 48000.0, 120.0)) < 0.001

  test "живой путь применяет линию на границе блока":
    var rig = makeRig()
    defer: rig.freeRig()

    # До публикации уровень — 0 дБ (значение по умолчанию).
    check abs(rig.gainDb()) < 0.001

    var lane = LiveAutomationLane(nodeId: int32(GainId),
                                  paramId: GainParamGain)
    lane.addLiveAutomationPoint(0, -20.0'f32, 0)
    lane.addLiveAutomationPoint(2 * Ppq, 0.0'f32, 0)
    var lanes = @[lane]
    check rig.engine.postLiveAutomation(lanes) == 1
    check rig.engine.liveAutomationLaneCount() == 1
    # На кадре 0 значение -20 дБ.
    rig.renderBlocks(1)
    check abs(rig.gainDb() + 20.0'f32) < 0.1'f32

    # Ещё ~0.5 c: тик ~960 -> -10 дБ.
    rig.renderBlocks(92)
    let v = rig.gainDb()
    check v > -11.0'f32
    check v < -9.0'f32

  test "смена набора линий не требует остановки транспорта":
    var rig = makeRig()
    defer: rig.freeRig()

    var lane = LiveAutomationLane(nodeId: int32(GainId),
                                  paramId: GainParamGain)
    lane.addLiveAutomationPoint(0, -12.0'f32, 0)
    check rig.engine.postLiveAutomation([lane]) == 1
    rig.renderBlocks(2)
    check abs(rig.gainDb() + 12.0'f32) < 0.1'f32

    # Публикуем новый набор «на ходу» (двойной буфер).
    var other = LiveAutomationLane(nodeId: int32(GainId),
                                   paramId: GainParamGain)
    other.addLiveAutomationPoint(0, -3.0'f32, 0)
    check rig.engine.postLiveAutomation([other]) == 1
    rig.renderBlocks(2)
    check abs(rig.gainDb() + 3.0'f32) < 0.1'f32

    rig.engine.clearLiveAutomation()
    check rig.engine.liveAutomationLaneCount() == 0
    rig.renderBlocks(1)
    # После снятия линий значение остаётся последним применённым: движок не
    # «возвращает» параметр сам — это решение хоста.
    check abs(rig.gainDb() + 3.0'f32) < 0.1'f32
