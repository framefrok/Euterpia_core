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
    # Структурные поломки графа (issue #391): раньше все они выглядели либо
    # как цикл, либо не всплывали вовсе. Каждый класс — свой вердикт с
    # адресом, чтобы `graph check` назвал конкретное место.
    gvUnknownNode        ## связь ссылается на ноду, которой нет в графе
    gvUnknownSrcPort     ## у ноды-источника нет такого аудиовыхода
    gvUnknownDstPort     ## у ноды-приёмника нет такого аудиовхода
    gvSignalMismatch     ## неподдерживаемый тип сигнала у связи
    gvMultipleWriter     ## на один вход пишут два источника
    gvDuplicateConnection ## одна и та же связь задана дважды
    gvNegativePortIdx    ## отрицательный индекс порта
    gvMasterInvalid      ## мастер-нода не может быть мастером
    gvUnsupportedChannels ## нода обещает больше каналов, чем умеет Core (#401)
    gvInvalidSubgraphPort ## связь через границу субграфа не разрешилась (#403)
    gvSubgraphDepth      ## вложенность субграфов больше предела (#404)
    gvNodeLimit          ## после flattening слишком много нод (#404)
    gvConnectionLimit    ## после разрешения портов слишком много связей (#404)
    gvLatencyOverflow    ## сумма latency вышла за предел (#405)
    gvPdcLimit           ## суммарный размер PDC-колец больше бюджета (#404)

  GraphVerdict* = object
    kind*: GraphVerdictKind
    nodeType*: string
      ## Тип/нода, из-за которой проверка провалилась. Пусто при успехе.
    nodeId*: int
      ## Идентификатор виновной ноды (issue #391). -1, если неприменимо.
    portIdx*: int
      ## Индекс виновного порта. -1, если неприменимо.
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
  of gvUnknownNode: "unknownNode"
  of gvUnknownSrcPort: "unknownSrcPort"
  of gvUnknownDstPort: "unknownDstPort"
  of gvSignalMismatch: "signalMismatch"
  of gvMultipleWriter: "multipleWriter"
  of gvDuplicateConnection: "duplicateConnection"
  of gvNegativePortIdx: "negativePortIdx"
  of gvMasterInvalid: "masterInvalid"
  of gvUnsupportedChannels: "unsupportedChannels"
  of gvInvalidSubgraphPort: "invalidSubgraphPort"
  of gvSubgraphDepth: "subgraphDepth"
  of gvNodeLimit: "nodeLimit"
  of gvConnectionLimit: "connectionLimit"
  of gvLatencyOverflow: "latencyOverflow"
  of gvPdcLimit: "pdcLimit"

proc describe*(v: GraphVerdict): string =
  ## Человекочитаемое объяснение вердикта: причина и что она означает.
  ##
  ## Для структурных поломок (issue #391) адрес обязателен: «нода 7, порт 2» —
  ## иначе пользователь не знает, что чинить.
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
  of gvUnknownNode:
    "связь ссылается на несуществующую ноду " & $v.nodeId
  of gvUnknownSrcPort:
    "у ноды " & $v.nodeId & " нет аудиовыхода " & $v.portIdx
  of gvUnknownDstPort:
    "у ноды " & $v.nodeId & " нет аудиовхода " & $v.portIdx
  of gvSignalMismatch:
    "неподдерживаемый тип сигнала у связи к ноде " & $v.nodeId &
      ", порт " & $v.portIdx
  of gvMultipleWriter:
    "вход ноды " & $v.nodeId & ", порт " & $v.portIdx &
      ": на него пишут два источника — один затирает другой"
  of gvDuplicateConnection:
    "связь к ноде " & $v.nodeId & ", порт " & $v.portIdx & " задана дважды"
  of gvNegativePortIdx:
    "отрицательный индекс порта у ноды " & $v.nodeId & ": " & $v.portIdx
  of gvMasterInvalid:
    "мастер-нода " & $v.nodeId & " не может быть мастером: нет аудиовыхода " &
    "или есть исходящие связи"
  of gvUnsupportedChannels:
    "нода " & v.nodeType & " заявляет больше каналов, чем поддерживает " &
    "стерео-модель Core (" & $signal_types.MaxAudioChannels & ")"
  of gvInvalidSubgraphPort:
    "связь через границу субграфа не разрешилась: проверьте subgraphInputs/" &
    "subgraphOutputs и локальные id"
  of gvSubgraphDepth:
    "вложенность субграфов больше " & $MaxSubgraphDepth & ": разверните вручную"
  of gvNodeLimit:
    "после flattening больше " & $MaxFlattenedNodes &
    " нод: граф слишком велик"
  of gvConnectionLimit:
    "после разрешения портов больше " & $MaxGraphConnections &
    " связей: граф слишком велик"
  of gvLatencyOverflow:
    "суммарная latency цепи больше " & $MaxLatencyFrames & " кадров: " &
    "проверьте latency нод/плагинов"
  of gvPdcLimit:
    "PDC требует больше " & $MaxPdcBufferSamples &
    " сэмплов памяти: уменьшите задержки или число ветвей"

proc verifyGraph*(reg: NodeRegistry; nodes: seq[GraphNodeSpec];
                  conns: seq[GraphConnSpec];
                  sampleRate: float32 = 48000.0f): GraphVerdict =
  ## Компилирует граф, собранный из описаний, и освобождает всё созданное.
  ##
  ## `reg` обязан жить до возврата: верификатор различает указатели на
  ## записи реестра (`entry`) только внутри вызова и освобождает состояния
  ## до выхода. Выносить `entry` за пределы вызова (как поле объекта) нельзя:
  ## seq реестра может быть освобождён раньше — ASan ловит
  ## heap-use-after-free при выходе из процесса (#395).
  ## Проверяется ровно то, что проверяла бы загрузка проекта: тип ноды
  ## известен, состояние создаётся, связи образуют ациклический граф.
  ## Значения параметров здесь не применяются: неверное значение — это
  ## проверка данных (`param`/`project validate`), а не структуры графа.
  ##
  ## `sampleRate` уходит в instantiateNode, чтобы состояние получило хук
  ## prepare под частоту сессии — ровно то же, что сделала бы загрузка (#393).
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
    if entry.desc != nil and
       entry.desc.maxChannels > signal_types.MaxAudioChannels:
      # issue #401: стерео — это контракт рантайма, а не пожелание ноды.
      # Отказ виден здесь, до компиляции и до рендера.
      return GraphVerdict(kind: gvUnsupportedChannels, nodeType: spec.nodeType)

    var node: EditorNode
    if not reg.instantiateNode(spec.nodeType, spec.id, node, sampleRate):
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

  # Класс ошибки компиляции → вердикт с адресом (issue #391): раньше всё,
  # кроме цикла, давало `gvInstantiateFailed` с бесполезным «проверьте данные».
  # Теперь `graph check` называет ноду и порт, которые не сходятся.
  template verdictFor(e: CompileError): GraphVerdict =
    case e.kind
    of cekNone: GraphVerdict(kind: gvCompiles, nodeId: -1, portIdx: -1)
    of cekCycleDetected: GraphVerdict(kind: gvCycle, nodeId: -1, portIdx: -1)
    of cekPdcCycleDetected:
      GraphVerdict(kind: gvPdcCycle, nodeId: -1, portIdx: -1)
    of cekAllocationFailed:
      GraphVerdict(kind: gvAllocationFailed, nodeId: -1, portIdx: -1)
    of cekUnknownNode:
      GraphVerdict(kind: gvUnknownNode, nodeId: e.nodeId, portIdx: -1)
    of cekUnknownSrcPort:
      GraphVerdict(kind: gvUnknownSrcPort, nodeId: e.nodeId, portIdx: e.portIdx)
    of cekUnknownDstPort:
      GraphVerdict(kind: gvUnknownDstPort, nodeId: e.nodeId, portIdx: e.portIdx)
    of cekSignalMismatch:
      GraphVerdict(kind: gvSignalMismatch, nodeId: e.nodeId, portIdx: e.portIdx)
    of cekMultipleWriter:
      GraphVerdict(kind: gvMultipleWriter, nodeId: e.nodeId, portIdx: e.portIdx)
    of cekDuplicateConnection:
      GraphVerdict(kind: gvDuplicateConnection, nodeId: e.nodeId,
                   portIdx: e.portIdx)
    of cekNegativePortIdx:
      GraphVerdict(kind: gvNegativePortIdx, nodeId: e.nodeId, portIdx: e.portIdx)
    of cekMasterInvalid:
      GraphVerdict(kind: gvMasterInvalid, nodeId: e.nodeId, portIdx: -1)
    of cekInvalidSubgraphPort:
      GraphVerdict(kind: gvInvalidSubgraphPort, nodeId: e.nodeId, portIdx: -1)
    of cekSubgraphDepthExceeded:
      GraphVerdict(kind: gvSubgraphDepth, nodeId: e.nodeId, portIdx: -1)
    of cekNodeLimitExceeded:
      GraphVerdict(kind: gvNodeLimit, nodeId: e.nodeId, portIdx: -1)
    of cekConnectionLimitExceeded:
      GraphVerdict(kind: gvConnectionLimit, nodeId: e.nodeId, portIdx: -1)
    of cekLatencyOverflow:
      GraphVerdict(kind: gvLatencyOverflow, nodeId: e.nodeId, portIdx: -1)
    of cekPdcLimitExceeded:
      GraphVerdict(kind: gvPdcLimit, nodeId: e.nodeId, portIdx: -1)

  verdictFor(cr.error)

{.pop.}
