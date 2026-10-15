# tests/unit/test_graph_check.nim
#
# graph_check: «этот граф компилируется» без движка и без устройства
# (issue #90). Проверяются вердикты, а не внутренности: CLI печатает именно
# их, поэтому контракт — это вид вердикта и отсутствие утечек после возврата.

import std/unittest
import signal_types
import node_interface
import graph_compiler
import sdk/node_api
import sdk/node_registry
import sdk/graph_check
import builtin/builtin_registry

proc registry(): NodeRegistry =
  result = initNodeRegistry()
  discard registerBuiltinNodes(result)

proc audioConn(srcId, dstId: int): GraphConnSpec =
  GraphConnSpec(srcNodeId: srcId, srcPortIdx: 0,
                dstNodeId: dstId, dstPortIdx: 0,
                sigType: ord(sigAudio))

suite "SDK: проверка графа (#90)":
  test "цепочка из двух нод компилируется в два шага":
    let nodes = @[GraphNodeSpec(id: 1, nodeType: "euterpia.osc"),
                  GraphNodeSpec(id: 2, nodeType: "euterpia.gain")]
    let verdict = verifyGraph(registry(), nodes, @[audioConn(1, 2)])
    check verdict.kind == gvCompiles
    check verdict.stepCount == 2

  test "пустой граф компилируется в ноль шагов":
    let verdict = verifyGraph(registry(), @[], @[])
    check verdict.kind == gvCompiles
    check verdict.stepCount == 0

  test "замкнутая связь даёт вердикт «цикл»":
    let nodes = @[GraphNodeSpec(id: 1, nodeType: "euterpia.gain")]
    let verdict = verifyGraph(registry(), nodes, @[audioConn(1, 1)])
    check verdict.kind == gvCycle

  test "неизвестный тип назван в вердикте, а не проглочен":
    let nodes = @[GraphNodeSpec(id: 1, nodeType: "euterpia.reverb")]
    let verdict = verifyGraph(registry(), nodes, @[])
    check verdict.kind == gvUnknownType
    check verdict.nodeType == "euterpia.reverb"

  test "повтор id — ошибка, а не молчаливая подмена состояния":
    let nodes = @[GraphNodeSpec(id: 1, nodeType: "euterpia.gain"),
                  GraphNodeSpec(id: 1, nodeType: "euterpia.gain")]
    let verdict = verifyGraph(registry(), nodes, @[])
    check verdict.kind == gvInstantiateFailed

  test "имена и описания вердиктов стабильны (машинный контракт --json)":
    check verdictName(gvCompiles) == "compiles"
    check verdictName(gvCycle) == "cycle"
    check verdictName(gvPdcCycle) == "pdcCycle"
    check verdictName(gvAllocationFailed) == "allocationFailed"
    check verdictName(gvUnknownType) == "unknownType"
    check verdictName(gvInstantiateFailed) == "instantiateFailed"
    for kind in GraphVerdictKind:
      check describe(GraphVerdict(kind: kind)).len > 0

# =============================================================================
# #393: prepare под частоту сессии на холодной стороне
# =============================================================================

var
  prepProbeDesc: NodeDesc
  prepProbeFactory: NodeFactory
  prepProbeReady = false
  prepCalls = 0
  prepLastRate = -1.0'f32
  prepProbeState: pointer = nil
    ## Один блок состояния на весь тест: create гарантирован, а destroy
    ## ничего не освобождает — владение живёт до конца процесса.

proc prepProbeCreate(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard desc
  discard userData
  if prepProbeState.isNil:
    prepProbeState = allocShared0(8)
  prepProbeState

proc prepProbeDestroy(state: pointer) {.cdecl, raises: [], gcsafe.} =
  discard state

proc prepProbeProcess(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                      ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                      userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctx
  discard audio
  discard ctrl
  discard events
  discard userData

proc prepProbePrepare(state: pointer; sampleRate: float32)
    {.cdecl, raises: [], gcsafe.} =
  discard state
  prepCalls += 1
  prepLastRate = sampleRate

proc ensurePrepProbe() =
  if not prepProbeReady:
    prepProbeDesc = NodeDesc(
      id: fixedId("test.prepprobe"),
      name: fixedName("PrepProbe"),
      category: fixedName("test"),
      audioInCount: 0, audioOutCount: 1,
      maxChannels: 2
    )
    prepProbeFactory = NodeFactory(
      create: prepProbeCreate,
      destroy: prepProbeDestroy,
      process: prepProbeProcess,
      prepare: prepProbePrepare
    )
    prepProbeReady = true

suite "SDK: prepare под частоту сессии (#393)":
  test "instantiateNode вызывает prepare с заданной частотой":
    ensurePrepProbe()
    var reg = initNodeRegistry()
    check reg.registerNodeType(addr prepProbeDesc, addr prepProbeFactory)
    prepCalls = 0
    prepLastRate = -1.0'f32

    var node: EditorNode
    check reg.instantiateNode("test.prepprobe", 1, node, 44100.0f)
    check prepCalls == 1
    check prepLastRate == 44100.0f
    destroyNodeState(reg.findNodeType("test.prepprobe"), node.userData)

  test "sampleRate <= 0 — prepare не вызывается (хук опционален)":
    ensurePrepProbe()
    var reg = initNodeRegistry()
    check reg.registerNodeType(addr prepProbeDesc, addr prepProbeFactory)
    prepCalls = 0

    var node: EditorNode
    check reg.instantiateNode("test.prepprobe", 1, node, 0.0f)
    check prepCalls == 0
    destroyNodeState(reg.findNodeType("test.prepprobe"), node.userData)

  test "verifyGraph пробрасывает свою частоту в prepare":
    ensurePrepProbe()
    var reg = initNodeRegistry()
    check reg.registerNodeType(addr prepProbeDesc, addr prepProbeFactory)
    prepCalls = 0
    prepLastRate = -1.0'f32

    let nodes = @[GraphNodeSpec(id: 1, nodeType: "test.prepprobe")]
    let verdict = verifyGraph(reg, nodes, @[], 96000.0f)
    check verdict.kind == gvCompiles
    check prepCalls == 1
    check prepLastRate == 96000.0f

  test "нода без prepare-хука проходит instantiate как раньше":
    # Хук опционален: euterpia.gain его не имеет, и это не ошибка.
    var reg = initNodeRegistry()
    check registerBuiltinNodes(reg) > 0
    prepCalls = 0
    var node: EditorNode
    check reg.instantiateNode("euterpia.gain", 1, node, 44100.0f)
    check prepCalls == 0
    destroyNodeState(reg.findNodeType("euterpia.gain"), node.userData)

