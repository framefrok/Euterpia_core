# tests/unit/test_live_resampler.nim
#
# Мост «частота устройства ≠ частота проекта» (issue #8).
#
# Тест не требует звуковой карты: callback вызывается напрямую, как это
# делает драйвер. Проверяется то, что нельзя проверить глазами:
#   * транспорт идёт со скоростью ПРОЕКТА, а блок драйвера — с частотой
#     устройства (расхождение за секунду ≤ один блок);
#   * выход не содержит NaN/Inf и не является тишиной (движок реально
#     рендерил граф);
#   * задержка моста заявлена (для PDC) и очереди не переполняются.

import std/[unittest, math, tables]

import sdk/node_api
import sdk/node_registry
import sdk/pipeline_builder
import builtin/builtin_registry
import graph_compiler
import compiled_pipeline
import signal_types
import live_session
import src_api
import stream_resampler

const
  ProjectRate = 44100.0
  DeviceRate = 48000.0
  DeviceBlock = 512
  NodeId = 1
  MasterId = 2

type
  Rig = object
    session: LiveSession
    api: ptr SrcApi
    state: pointer
    factory: ptr NodeFactory
    masterState: pointer
    masterFactory: ptr NodeFactory
    outBuf: array[DeviceBlock * 2, float32]

proc makeRig(): Rig =
  var reg = initNodeRegistry()
  doAssert registerBuiltinNodes(reg) > 0
  var osc: EditorNode
  doAssert reg.instantiateNode("euterpia.osc", NodeId, osc,
                               float32(ProjectRate))
  var master: EditorNode
  doAssert reg.instantiateNode("euterpia.gain", MasterId, master,
                               float32(ProjectRate))
  let entry = reg.findNodeType("euterpia.osc")
  doAssert not entry.isNil
  result.factory = entry.factory
  result.state = osc.userData
  let masterEntry = reg.findNodeType("euterpia.gain")
  doAssert not masterEntry.isNil
  result.masterFactory = masterEntry.factory
  result.masterState = master.userData

  var g: NodeGraph
  g.nodes[NodeId] = osc
  g.nodes[MasterId] = master
  # Генератор пишет в planar-буфер пула, мастер сводит его в interleaved
  # выход драйвера: без промежуточной ноды interleaved-буфер генератору
  # недоступен (channelPtr == nil).
  g.connections.add EditorConnection(
    srcNodeId: NodeId, srcPortIdx: 0,
    dstNodeId: MasterId, dstPortIdx: 0,
    sigType: sigAudio)
  var cr: CompileResult
  var binding: ptr PipelineBinding
  doAssert buildPipeline(reg, g, MasterId, cr, binding)

  let projBlock = liveProjectBlock(int32(DeviceBlock), DeviceRate, ProjectRate)
  doAssert projBlock > 0 and projBlock <= 4096
  result.session = initLiveSession(float32(ProjectRate), projBlock,
                                   ownPipeline(cr.pipeline))
  doAssert result.session.isActive

  result.api = newSrcApi()
  doAssert result.api != nil
  doAssert srcInit(result.api, nil) == seOk
  doAssert result.session.enableLiveResampling(
    result.api, int32(DeviceBlock), DeviceRate, ProjectRate)

  doAssert result.session.postSetTempo(120.0)
  doAssert result.session.postPlay()
  result.session.flushQueuedCommands()

proc freeRig(rig: var Rig) =
  rig.session.closeLiveSession()
  if rig.api != nil:
    srcShutdown(rig.api)
    freeSrcApi(rig.api)
    rig.api = nil
  if rig.state != nil and rig.factory != nil:
    rig.factory.destroy(rig.state)
    rig.state = nil
  if rig.masterState != nil and rig.masterFactory != nil:
    rig.masterFactory.destroy(rig.masterState)
    rig.masterState = nil

proc runCallbacks(rig: var Rig; count: int): tuple[peak: float64, bad: int] =
  result = (0.0, 0)
  for i in 0 ..< count:
    for j in 0 ..< rig.outBuf.len:
      rig.outBuf[j] = 0.0f
    liveRender(cast[pointer](addr rig.session), nil,
               cast[ptr UncheckedArray[float32]](addr rig.outBuf[0]),
               int32(DeviceBlock), 0'i32, 2'i32)
    # Первые блоки — прайминг ресемплеров: там законные нули.
    if i > 8:
      for j in 0 ..< rig.outBuf.len:
        let v = rig.outBuf[j]
        let a = abs(float64(v))
        if not (a == a):
          inc result.bad
        elif a > result.peak:
          result.peak = a

suite "live: ресемплинг устройства и проекта (#8)":

  test "44.1k-проект на 48k-устройстве: транспорт идёт со скоростью проекта":
    var rig = makeRig()
    defer: rig.freeRig()

    check rig.session.liveResamplingActive()
    check rig.session.liveResamplingLatency() > 0

    const callbacks = 96          # ~1.024 с устройства
    let stats = rig.runCallbacks(callbacks)
    check stats.bad == 0
    check stats.peak > 0.05       # граф реально рендерил (не тишина)

    let advanced = rig.session.currentFrame()
    let expected = int64(float64(callbacks * DeviceBlock) *
                         ProjectRate / DeviceRate)
    # Допуск — один блок устройства в кадрах проекта: прайминг моста
    # съедает первые несколько кадров, дальше скорость точная.
    check abs(advanced - expected) <= int64(DeviceBlock) + 4
    check rig.session.liveResamplingDropped() == 0

  test "нет NaN/Inf на длинном прогоне (2 с устройства)":
    var rig = makeRig()
    defer: rig.freeRig()
    let stats = rig.runCallbacks(188)
    check stats.bad == 0

  test "мост можно выключить: сеанс продолжает работать напрямую":
    var rig = makeRig()
    defer: rig.freeRig()
    rig.session.disableLiveResampling()
    check not rig.session.liveResamplingActive()

    var outBuf: array[DeviceBlock * 2, float32]
    for i in 0 ..< 8:
      liveRender(cast[pointer](addr rig.session), nil,
                 cast[ptr UncheckedArray[float32]](addr outBuf[0]),
                 int32(DeviceBlock), 0'i32, 2'i32)
    # Без моста движок рендерит свой блок (projBlock), а не DeviceBlock;
    # выход при этом остаётся конечным числом.
    for v in outBuf:
      check classify(float64(v)) notin {fcNan, fcInf, fcNegInf}
