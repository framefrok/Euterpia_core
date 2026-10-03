# nodes/sdk/graph_check.nim
#
# Проверка «этот граф из данных проекта компилируется» — без создания
# движка, без устройства и без рендера (issue #90).
#
# Почему это отдельный модуль SDK, а не код CLI:
#   компиляция графа — операция Core (MANIFEST §20: «CLI сам компилирует
#   Graph» запрещено). Но Core не знает ни списка нод (§54), ни того, как
#   строка `nodeType` из файла проекта превращается в живую ноду. Место, где
#   сходятся эти три знания, — SDK нод: он зависит от Core, но не от CLI и
#   не от формата проекта. Поэтому CLI передаёт сюда ПЛОСКИЕ описания
#   (идентификатор + тип + связи), а не файл проекта.
#
# Владение: состояния нод создаются здесь и здесь же освобождаются; после
# возврата ни один указатель наружу не уходит — иначе вызывающий получил бы
# обязанность, о которой не просил (§33).

import
  std/tables,
  signal_types,
  graph_compiler,
  compiled_pipeline,
  node_registry

{.push raises: [].}

type
  GraphNodeSpec* = object
    ## Нода из данных проекта: только то, что нужно для компиляции.
    id*: int
    nodeType*: string

  GraphConnSpec* = object
    ## Связь из данных проекта. `sigType` — ординал SignalType из файла.
    srcNodeId*, srcPortIdx*, dstNodeId*, dstPortIdx*: int
    sigType*: int

  GraphVerdictKind* = enum
    gvCompiles           ## граф компилируется
    gvCycle              ## цикл без компенсирующей задержки
    gvPdcCycle           ## цикл после расстановки компенсации задержки
    gvAllocationFailed   ## не хватило памяти на пайплайн
    gvUnknownType        ## тип ноды не зарегистрирован
    gvInstantiateFailed  ## состояние ноды не создалось (или повтор id)

  GraphVerdict* = object
    kind*: GraphVerdictKind
    nodeType*: string
      ## Тип/нода, из-за которой проверка провалилась. Пусто при успехе.
    stepCount*: int32
      ## Сколько шагов в скомпилированном пайплайне. Для `graph check`
      ## это факт «граф действительно собран», а не «ошибки не нашлось».

proc verdictName*(k: GraphVerdictKind): string =
  ## Стабильные имена для `--json`: агент читает их, а не русский текст.
  case k
  of gvCompiles: "compiles"
  of gvCycle: "cycle"
  of gvPdcCycle: "pdcCycle"
  of gvAllocationFailed: "allocationFailed"
  of gvUnknownType: "unknownType"
  of gvInstantiateFailed: "instantiateFailed"

proc describe*(v: GraphVerdict): string =
  ## Человекочитаемое объяснение вердикта: причина и что она означает.
  case v.kind
  of gvCompiles:
    "граф компилируется: шагов " & $v.stepCount
  of gvCycle:
    "в графе цикл: сигнал возвращается к источнику без ноды задержки"
  of gvPdcCycle:
    "цикл остался после расстановки компенсации задержки: соединение замкнуто"
  of gvAllocationFailed:
    "не удалось выделить память под пайплайн: граф слишком велик"
  of gvUnknownType:
    "тип ноды не зарегистрирован: " & v.nodeType
  of gvInstantiateFailed:
    "нода " & v.nodeType & " не создалась (повтор id или отказ фабрики)"

proc verifyGraph*(reg: NodeRegistry; nodes: seq[GraphNodeSpec];
                  conns: seq[GraphConnSpec]): GraphVerdict =
  ## Компилирует граф, собранный из описаний, и освобождает всё созданное.
  ##
  ## Проверяется ровно то, что проверяла бы загрузка проекта: тип ноды
  ## известен, состояние создаётся, связи образуют ациклический граф.
  ## Значения параметров здесь не применяются: неверное значение — это
  ## проверка данных (`param`/`project validate`), а не структуры графа.
  var g: NodeGraph
  var created: seq[tuple[entry: ptr NodeTypeEntry, state: pointer]] = @[]
  var cr: CompileResult

  ## Освобождение — до возврата, при любом исходе: `defer` срабатывает и на
  ## раннем `return`, поэтому забыть про уборку невозможно.
  defer:
    for item in created:
      destroyNodeState(item.entry, item.state)
    if cr.success and not cr.pipeline.isNil:
      destroyPipeline(cr.pipeline)

  for spec in nodes:
    if g.nodes.hasKey(spec.id):
      # Повтор id делает выбор состояния неоднозначным; наружу это ошибка
      # данных, но и компилировать такой граф нельзя.
      return GraphVerdict(kind: gvInstantiateFailed,
                          nodeType: spec.nodeType)
    let entry = reg.findNodeType(spec.nodeType)
    if entry.isNil:
      return GraphVerdict(kind: gvUnknownType, nodeType: spec.nodeType)

    var node: EditorNode
    if not reg.instantiateNode(spec.nodeType, spec.id, node):
      return GraphVerdict(kind: gvInstantiateFailed, nodeType: spec.nodeType)
    created.add (entry, node.userData)
    g.nodes[spec.id] = node

  for c in conns:
    if c.sigType < 0 or c.sigType > ord(SignalType.high):
      # Вид сигнала из файла вне диапазона: это ошибка данных, которую
      # ловит вызывающий до компиляции; здесь граф не строится.
      return GraphVerdict(kind: gvInstantiateFailed, nodeType: "sigType")
    g.connections.add EditorConnection(
      srcNodeId: c.srcNodeId, srcPortIdx: c.srcPortIdx,
      dstNodeId: c.dstNodeId, dstPortIdx: c.dstPortIdx,
      sigType: cast[SignalType](c.sigType)
    )

  cr = compileGraph(g)
  if cr.success:
    return GraphVerdict(kind: gvCompiles,
                        stepCount: (if cr.pipeline.isNil: 0'i32
                                    else: cr.pipeline.stepCount))

  case cr.error
  of cekNone: GraphVerdict(kind: gvCompiles)
  of cekCycleDetected: GraphVerdict(kind: gvCycle)
  of cekPdcCycleDetected: GraphVerdict(kind: gvPdcCycle)
  of cekAllocationFailed: GraphVerdict(kind: gvAllocationFailed)

{.pop.}
