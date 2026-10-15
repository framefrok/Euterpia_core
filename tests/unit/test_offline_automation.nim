# tests/unit/test_offline_automation.nim
#
# Lossless automation офлайн-рендера (issue #395, аудит EUT-NEW-026).
#
# Раньше параметры automation шли через realtime-очередь команд
# (`postSetParam`, ёмкость 1024): батч из числа lanes больше ёмкости
# переполнял очередь, `push` молча отдавал false — рендер терял
# автоматизацию и становился недетерминированным. `applyParamNow`
# применяет параметр напрямую в пайплайн, поэтому потеря невозможна
# при любом числе параметров.
#
# Что проверяется:
#   * flushQueuedCommands активирует граф и play ДО первого блока;
#   * батч из 1500 параметров (больше ёмкости очереди) доходит целиком;
#   * параметр, посланный до активации пайплайна, применяется при
#     активации (pendingParams), а не теряется.

import std/[unittest, tables]
import graph_compiler
import sdk/node_api
import sdk/node_registry
import sdk/pipeline_builder
import builtin/builtin_registry
import builtin/mixing/gain
import audio_engine
import ipc_bus   ## `tsPlaying` — состояние транспорта.

const
  EngineSr = 48000.0'f32
  EngineBlock = 256'i32
  GainNodeId = 1

type GainRig = object
  engine: ptr AudioEngine
  entry: ptr NodeTypeEntry
  state: pointer

proc mkGainRig(): GainRig =
  ## Движок + одна нода gain (она же мастер). Владение пайплайном переходит
  ## движку; состояние ноды освобождает разрушитель рига.
  var reg = initNodeRegistry()
  doAssert registerBuiltinNodes(reg) > 0

  var node: EditorNode
  doAssert reg.instantiateNode("euterpia.gain", GainNodeId, node)
  result.entry = reg.findNodeType("euterpia.gain")
  result.state = node.userData

  var g: NodeGraph
  g.nodes[GainNodeId] = node

  var cr: CompileResult
  var binding: ptr PipelineBinding
  doAssert buildPipeline(reg, g, GainNodeId, cr, binding)

  result.engine = createAudioEngine(EngineSr, EngineBlock)
  doAssert result.engine != nil
  doAssert result.engine.postGraphUpdate(cr.pipeline)

proc freeRig(rig: var GainRig) =
  # Порядок обязателен: движок сначала освобождает пайплайн (и биндинг),
  # затем тест освобождает состояние ноды — биндинг на него только ссылался.
  if not rig.engine.isNil:
    destroyAudioEngine(rig.engine)
    rig.engine = nil
  if not rig.state.isNil and not rig.entry.isNil:
    destroyNodeState(rig.entry, rig.state)
    rig.state = nil

suite "офлайн: lossless automation (#395)":
  test "flushQueuedCommands активирует граф и play до первого блока":
    var rig = mkGainRig()
    defer: rig.freeRig()

    check rig.engine.transportState() == tsStopped
    discard rig.engine.postPlay()
    # Без flush очередь разобрал бы первый renderBlock; офлайн-рендер
    # делает это явно, чтобы параметры шли напрямую в пайплайн.
    flushQueuedCommands(rig.engine)
    check rig.engine.transportState() == tsPlaying

  test "батч из 1500 параметров больше ёмкости очереди не теряется":
    var rig = mkGainRig()
    defer: rig.freeRig()
    flushQueuedCommands(rig.engine)

    # Ёмкость toAudio = 1024: через postSetParam последние ~476 команд
    # (включая последнюю) потерялись бы. applyParamNow минует очередь.
    for i in 1 .. 1500:
      let v = if i == 1500: -3.0'f32 else: -20.0'f32
      check rig.engine.applyParamNow(GainNodeId.int32, GainParamGain, v)

    # Последний параметр обязан дойти до состояния ноды.
    var got = 0.0'f32
    check rig.entry.factory.getParam(rig.state, GainParamGain, addr got)
    check got == -3.0'f32

  test "параметр до активации пайплайна применяется при активации":
    var rig = mkGainRig()
    # postPlay, но БЕЗ flush: пайплайн ещё в очереди (pendingParams).
    discard rig.engine.postPlay()
    check rig.engine.applyParamNow(GainNodeId.int32, GainParamGain, -9.0'f32)

    var got = 0.0'f32
    check rig.entry.factory.getParam(rig.state, GainParamGain, addr got)
    check got != -9.0'f32   # до активации ещё не применён

    flushQueuedCommands(rig.engine)
    check rig.entry.factory.getParam(rig.state, GainParamGain, addr got)
    check got == -9.0'f32   # replayPendingParams довёл значение
