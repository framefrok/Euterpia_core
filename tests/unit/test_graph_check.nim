# tests/unit/test_graph_check.nim
#
# graph_check: «этот граф компилируется» без движка и без устройства
# (issue #90). Проверяются вердикты, а не внутренности: CLI печатает именно
# их, поэтому контракт — это вид вердикта и отсутствие утечек после возврата.

import std/unittest
import signal_types
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
