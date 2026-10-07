# core/control/query.nim
#
# Query API: ЧТЕНИЕ модели без внутренностей (issue #141, MANIFEST §63).
#
# Зачем рядом с control-слоем, а не в CLI:
#   Писать и читать проект должен один код. Пока читающих команд в ядре не
#   было, CLI ходил по `ProjectFormat` руками — значит, Editor повторил бы ту же
#   логику, и мы получили бы «второй Core» (§23).
#
# Что здесь:
#   - неизменяемые DTO (значения, не указатели): наружу не отдаются ни указатели,
#     ни ссылки на внутренние структуры (§63);
#   - детерминированный порядок: результат двух клиентов совпадает побайтово,
#     иначе «сравнение снапшотов» невозможно (#139);
#   - фильтр и окно для проектов на 1000+ нод — иначе клиент читает всё, чтобы
#     показать двадцать строк;
#   - ссылка на сущность в трёх видах: постоянный `id`, адрес документа (#143) и
#     имя. Короткое имя типа («osc») — удобство CLI, а не контракт ядра: в ядре
#     двусмысленность отвергается, а не угадывается (§82);
#   - короткая форма адреса — ссылка ВНУТРИ текущего документа, полная
#     (`@doc`) — привязка к документу: только она отвергается как «чужой».
#
# Чего здесь нет: мутаций. Правка идёт только командами (`document.nim`).
#
# Описание типов приходит от хозяина документа, как и для команд (§54): Query API
# знает, сколько у типа портов и какие у параметра границы, но не знает, какие
# типы бывают.

import std/[algorithm, strutils, tables, unicode]

import project
import handles
import error_frame
import document

const
  AddressHint* = "адреса печатает: euterpia node list (--json — полная форма)"

proc errorCodeOf*(code: HandleError): ErrorCode =
  ## Код ответа адресации (#143) в коде control-слоя (#117). Клиент должен
  ## различать «устарел» и «чужой документ», а получать один набор кодов, а не
  ## два: `ErrorCode` и `HandleError` живут в разных слоях по необходимости.
  case code
  of heOk: ecOk
  of heForeignDocument: ecForeignDocument
  of heStale, heReleased: ecStaleHandle
  of heKindMismatch: ecKindMismatch
  of heNoEntity: ecNotFound
  of heSlotOccupied, heSlotExhausted, heUnboundEntity: ecInternal
  of heInvalid, heBadPath: ecInvalidArgument

type
  NodeRefKind* = enum
    ## Как адресована нода. Число, `вид:слот.поколение` или имя.
    nrInvalid = 0
    nrById
    nrByHandle
    nrByName

  NodeFilter* = object
    ## Что показать. Пустые поля означают «любой узел».
    text*: string
      ## Подстрока в имени или типе, без учёта регистра.
    nodeType*: string
      ## Полный id типа (`euterpia.gain`).
    offset*: int
      ## Сколько узлов пропустить (окно для больших проектов).
    limit*: int
      ## 0 — без ограничения.

  ParamInfo* = object
    ## Параметр ноды для клиента: всё, что нужно показать и не выдумывать.
    name*: string
    index*: int
      ## Позиция в описателе типа — устойчива к переименованию.
    handle*: string
      ## `node:3.1/param:1` — адрес для правки и для отчёта.
    value*: float32
    fromFile*: bool
      ## Значение пришло из файла, а не взято как умолчание типа.
    defaultValue*, minValue*, maxValue*, step*: float32
    integerLike*, automatable*, modulatable*, hidden*: bool

  NodeInfo* = object
    ## Нода целиком для чтения. Значение, а не ссылка на модель.
    id*: int
    handle*: string
      ## Короткий адрес `node:3.1`.
    handleRef*: string
      ## Полный адрес с документом `node:3.1@4d379bc5`.
    name*, nodeType*: string
    typeName*, category*: string
      ## Человеческие имя и категория типа; пусто, если тип не зарегистрирован.
    known*: bool
      ## Зарегистрирован ли тип у хозяина: по нему клиент отличает ноду из
      ## будущей версии или плагина от опечатки.
    isSubgraph*: bool
    audioIn*, audioOut*, ctrlIn*, ctrlOut*, eventIn*, eventOut*: int
    latencyReported*, latencyIntrinsic*: uint32
    connections*: int
    params*: seq[ParamInfo]
      ## Параметры в порядке описателя; для незарегистрированного типа — только
      ## те, что лежат в файле.
    fileParams*: seq[string]
      ## Параметры, которые ЛЕЖАТ В ФАЙЛЕ, но отсутствуют в описателе типа
      ## (issue #373). Валидатор графа и компилятор должны их видеть, не заходя
      ## в `ProjectFormat` руками: `params` строится по описателю и такие ключи
      ## в него не попадают. По имени, отсортировано (детерминизм, #139).

  ConnectionInfo* = object
    srcNodeId*, srcPortIdx*, dstNodeId*, dstPortIdx*: int
    sigType*: int

  ClipInfo* = object
    id*: int32
    name*: string
    handle*: string
      ## `track:1.1/clip:0` — адрес размещения клипа на дорожке.
    startTick*, lengthTicks*: int32
    loopEnabled*: bool
    notes*: int

  TrackInfo* = object
    id*: int32
    name*: string
    handle*: string
      ## `track:1.1`
    trackType*: int
    volume*, pan*: float32
    mute*, solo*, armed*: bool
    inputChannel*, outputBus*: int32
    clips*: seq[ClipInfo]

  NoteInfo* = object
    startTick*, duration*: int32
    pitch*, velocity*, channel*: uint8

  MetadataInfo* = object
    ## Метаданные проекта для клиента: имя, автор, транспорт и отметки.
    ##
    ## Отдельный DTO, а не «прочитай поле из формата»: `project show` и
    ## `render` спрашивают темп и частоту у одного места, поэтому правило
    ## «откуда берётся частота рендера» не разъезжается с отчётом (#336).
    name*, author*: string
    tempo*, sampleRate*: float32
    tsNumerator*, tsDenominator*: int32
    created*, modified*: string

  AutomationLaneInfo* = object
    ## Дорожка автоматизации: узел, параметр и точки.
    nodeId*: int32
    paramId*: uint32
    points*: int
    negativeTicks*: int
      ## Сколько точек лежит до нуля (issue #373): валидатору нужен этот факт,
      ## чтобы не тянуть сами точки (их может быть много) ради проверки.

  PluginStateInfo* = object
    ## Сохранённое состояние плагина: узел, идентификатор и размер.
    nodeId*: int
    pluginId*: string
    bytes*: int

  ProjectSummary* = object
    ## Счётчики содержимого: клиенту они нужны чаще, чем всё остальное.
    nodes*, connections*, tracks*, clips*, notes*: int
    automationLanes*, automationPoints*, pluginStates*: int
    pluginStateBytes*: int
      ## Суммарный размер сохранённых состояний: по нему видно, «тяжёлый» ли
      ## проект из-за плагинов, не разворачивая сами состояния.
    documentId*: uint32
    document*: string
      ## Идентификатор документа в тексте (`docIdText`), чтобы клиент проверил,
      ## что адреса из его вывода относятся к тому же файлу.

# =============================================================================
# Ссылка на ноду
# =============================================================================

proc parseNodeRef*(doc: Document; text: string):
    tuple[kind: NodeRefKind, id: int, nodeId: int32, handle: EntityHandle,
          error: HandleError] =
  ## Разбор ссылки: `7`, `node:7.1`, `node:7.1@doc`, `Gain`. Порядок именно
  ## такой: число — всегда id, слово с двоеточием — всегда адрес. Иначе нода,
  ## названная «7», была бы то адресом, то именем.
  ##
  ## `error` — отказ связывания адреса («чужой документ», «битый формат»):
  ## без него разбор сворачивал бы все отказы к `ecInvalidArgument`, и клиент
  ## не отличал «не тот файл» от «опечатка в адресе» (тест #141).
  result = (nrInvalid, 0, 0'i32, invalidHandle(), heOk)
  let trimmed = text.strip()
  if trimmed.len == 0:
    return
  if trimmed.allCharsInSet({'0'..'9'}):
    result = (nrById, parseInt(trimmed), 0'i32, invalidHandle(), heOk)
    return
  if ':' in trimmed:
    var h: EntityHandle
    let err = doc.handles.bindHandleText(trimmed, h)
    if err != heOk:
      # Адрес не наш — но может быть именем ноды с двоеточием? Нет: имена
      # свободны, а двоеточие в них запрещено разбором портов. Значит, это
      # именно битый адрес, и молчать нельзя: код отказа уходит наверх.
      result = (nrInvalid, 0, 0'i32, h, err)
      return
    if h.kind != hkNode:
      result = (nrInvalid, 0, 0'i32, h, heKindMismatch)
      return
    result = (nrByHandle, int(h.slot), 0'i32, h, heOk)
    return
  result = (nrByName, 0, 0'i32, invalidHandle(), heOk)

proc sameName*(a, b: string): bool =
  ## Сравнение без учёта регистра ПО UNICODE. `cmpIgnoreCase` из `strutils`
  ## работает только с ASCII, а имена нод в проектах кириллические — значит,
  ## наивное сравнение молча не нашло бы «Гейт» по запросу «ГЕЙТ».
  a.toLower == b.toLower

proc nodeIdByName*(doc: Document; name: string): tuple[ok: bool, index: int] =
  ## Нода по имени без учёта регистра. Две ноды с одним именем — отказ: угадывать
  ## за пользователя здесь значило бы показать не ту ноду (§82).
  var matches: seq[int] = @[]
  for i in 0 ..< doc.proj.graph.nodes.len:
    if sameName(doc.proj.graph.nodes[i].name, name):
      matches.add i
  if matches.len == 1:
    return (true, matches[0])
  (false, -1)

proc resolveNodeIndex*(doc: Document; text: string):
    tuple[ok: bool, index: int, frame: ErrorFrame] =
  ## Ссылка → индекс ноды в документе. Адрес проверяется по поколению и
  ## документу (#143): чужой или просроченный адрес отвергается кодом, а не
  ## «не нашлась нода».
  let parsed = doc.parseNodeRef(text)
  case parsed.kind
  of nrById:
    for i in 0 ..< doc.proj.graph.nodes.len:
      if doc.proj.graph.nodes[i].id == parsed.id:
        return (true, i, okFrame())
    return (false, -1,
            errFrame(ecNotFound, "ноды #" & $parsed.id & " нет в проекте",
                     "список нод: euterpia node list"))
  of nrByHandle:
    let resolved = doc.handles.resolveAs(parsed.handle, hkNode)
    if not resolved.ok:
      # «Просрочен/удалён» и «не тот вид сущности» — разные причины, и подсказки
      # у них разные. Текст берётся из ядра: тот же ответ получает Editor,
      # поэтому клиент не пересказывает отказ своими словами (§82, #336).
      if resolved.error == heInvalid:
        # Адрес разобран, но слота в документе нет: «нет ноды с адресом» —
        # точнее, чем «битый адрес», потому что подсказки у них разные.
        return (false, -1,
                errFrame(ecInvalidArgument,
                         "в документе нет ноды с адресом " & text,
                         "файл изменился — возьмите адрес из свежего node list"))
      return (false, -1,
              errFrame(resolved.error.errorCodeOf,
                       "адрес " & text & ": " & handleErrorText(resolved.error) &
                         (if resolved.error == heKindMismatch:
                            " — здесь нужна нода" else: ""),
                       AddressHint))
    for i in 0 ..< doc.proj.graph.nodes.len:
      if doc.proj.graph.nodes[i].id == int(resolved.entityId):
        return (true, i, okFrame())
    return (false, -1,
            errFrame(ecNotFound,
                     "адрес " & text & " указывает на ноду, которой нет в файле",
                     "файл изменился — возьмите адрес из свежего node list"))
  of nrByName:
    let found = doc.nodeIdByName(text)
    if found.ok:
      return (true, found.index, okFrame())
    var names: seq[string] = @[]
    for node in doc.proj.graph.nodes:
      if sameName(node.name, text):
        names.add node.name
    if names.len > 1:
      return (false, -1,
              errFrame(ecInvalidArgument,
                       "нод с именем " & text & " несколько (" & $names.len & ")",
                       "укажите id или адрес: euterpia node list"))
    return (false, -1,
            errFrame(ecNotFound, "ноды с именем " & text & " нет",
                     "список нод: euterpia node list"))
  else:
    # Ни число, ни имя, ни адрес — пустое или битое. Отличаем «пусто» от «не
    # нашлось»: подсказки у них разные.
    let trimmed = text.strip()
    if trimmed.len == 0:
      return (false, -1, errFrame(ecInvalidArgument, "не указана нода",
                                  "например: 1 или node:1.1"))
    if ':' in trimmed:
      # Адрес разобран, но связать его не удалось: «чужой документ», «не тот
      # вид» и т.п. — сваливать в «адрес не разобран» (ecInvalidArgument)
      # нельзя, иначе клиент не отличит другой файл от опечатки.
      if parsed.error != heOk and parsed.error != heInvalid:
        return (false, -1,
                errFrame(parsed.error.errorCodeOf,
                         "адрес " & text & ": " &
                           handleErrorText(parsed.error) &
                           (if parsed.error == heKindMismatch:
                              " — здесь нужна нода" else: ""),
                         AddressHint))
      return (false, -1,
              errFrame(ecInvalidArgument, "адрес не разобран: " & text,
                       "формат адреса: node:1.1 или node:1.1@<документ>"))
    return (false, -1,
            errFrame(ecNotFound, "ноды с именем " & trimmed & " нет",
                     "список нод: euterpia node list"))

# =============================================================================
# DTO
# =============================================================================

proc countConnections*(doc: Document; nodeId: int): int =
  for conn in doc.proj.graph.connections:
    if conn.srcNodeId == nodeId or conn.dstNodeId == nodeId:
      inc result

proc paramInfoOf*(doc: Document; nodeId: int; spec: NodeTypeSpec;
                  index: int; stored: float32; fromFile: bool): ParamInfo =
  let p = spec.params[index]
  ParamInfo(
    name: p.name,
    index: index,
    handle: nestedToText(doc.handles.nodeParamRef(nodeId, uint32(index))),
    value: (if fromFile: stored else: p.defaultValue),
    fromFile: fromFile,
    defaultValue: p.defaultValue, minValue: p.minValue, maxValue: p.maxValue,
    step: p.step,
    integerLike: p.integerLike,
    automatable: p.automatable, modulatable: p.modulatable, hidden: p.hidden)

proc nodeInfoOf*(doc: Document; index: int): NodeInfo =
  ## Снимок ноды. Порядок параметров — как в описателе типа (устойчив к
  ## переименованию), а для незарегистрированного типа — по имени из файла,
  ## отсортированному: порядок ключей таблицы не является контрактом.
  let node = doc.proj.graph.nodes[index]
  var spec: NodeTypeSpec
  let known = doc.typeSpec(node.nodeType, spec).isOk()
  result = NodeInfo(
    id: node.id,
    handle: handleToText(doc.handles.nodeHandle(node.id)),
    handleRef: handleToTextQualified(doc.handles.nodeHandle(node.id)),
    name: node.name,
    nodeType: node.nodeType,
    known: known,
    isSubgraph: node.isSubgraph,
    audioIn: node.audioInCount, audioOut: node.audioOutCount,
    ctrlIn: node.ctrlInCount, ctrlOut: node.ctrlOutCount,
    eventIn: node.eventInCount, eventOut: node.eventOutCount,
    latencyReported: node.latencyReported,
    latencyIntrinsic: node.latencyIntrinsic,
    connections: doc.countConnections(node.id))
  if known:
    result.typeName = spec.name
    result.category = ""
    for i in 0 ..< spec.params.len:
      let name = spec.params[i].name
      let has = node.parameters.hasKey(name)
      result.params.add doc.paramInfoOf(node.id, spec, i,
                                        (if has: node.parameters[name] else: 0.0f32),
                                        has)
    # Параметры файла, которых нет в описателе типа (issue #373): их видит
    # валидатор графа, не заглядывая в формат.
    for key in node.parameters.keys:
      if spec.paramIndexOf(key, -1) < 0:
        result.fileParams.add key
    result.fileParams.sort()
  else:
    var keys: seq[string] = @[]
    for key in node.parameters.keys:
      keys.add key
    keys.sort()
    for key in keys:
      result.params.add ParamInfo(
        name: key, index: -1,
        handle: nestedToText(doc.handles.nodeParamRef(node.id, uint32(result.params.len))),
        value: node.parameters[key], fromFile: true)

# =============================================================================
# Запросы
# =============================================================================

proc matches*(doc: Document; node: NodeFormat; filter: NodeFilter): bool =
  ## Фильтр без учёта регистра: и по имени, и по типу. Пустой фильтр — «все».
  if filter.nodeType.len > 0 and not sameName(node.nodeType, filter.nodeType):
    return false
  if filter.text.len == 0:
    return true
  let needle = filter.text.toLower
  node.name.toLower.contains(needle) or node.nodeType.toLower.contains(needle)

proc queryNodes*(doc: Document; filter: NodeFilter = NodeFilter()):
    tuple[frame: ErrorFrame, nodes: seq[NodeInfo], total: int,
          offset: int, limit: int] =
  ## Список нод: фильтр, окно и счётчик «сколько всего под фильтром» — без него
  ## клиент не может сказать «показать ещё».
  ##
  ## Порядок — по id: он не меняется от запуска к запуску и не зависит от того,
  ## как клиент сортировал данные раньше (#88, детерминированный вывод).
  result.frame = okFrame()
  result.offset = max(0, filter.offset)
  result.limit = max(0, filter.limit)

  var matched: seq[int] = @[]
  for i in 0 ..< doc.proj.graph.nodes.len:
    if doc.matches(doc.proj.graph.nodes[i], filter):
      matched.add i
  result.total = matched.len

  var seen = 0
  for i in matched:
    if seen < result.offset:
      inc seen
      continue
    if result.limit > 0 and result.nodes.len >= result.limit:
      break
    result.nodes.add doc.nodeInfoOf(i)
    inc seen

proc queryNode*(doc: Document; reference: string):
    tuple[ok: bool, node: NodeInfo, frame: ErrorFrame] =
  ## Одна нода по ссылке (`7`, `node:7.1`, `Gain`).
  let found = doc.resolveNodeIndex(reference)
  if not found.ok:
    return (false, NodeInfo(), found.frame)
  (true, doc.nodeInfoOf(found.index), okFrame())

proc queryParams*(doc: Document; reference: string):
    tuple[ok: bool, params: seq[ParamInfo], frame: ErrorFrame] =
  ## Параметры ноды: в порядке описателя типа, с адресами и источником значения.
  let found = doc.resolveNodeIndex(reference)
  if not found.ok:
    return (false, @[], found.frame)
  (true, doc.nodeInfoOf(found.index).params, okFrame())

proc queryParam*(doc: Document; reference: string; paramText: string):
    tuple[ok: bool, param: ParamInfo, frame: ErrorFrame] =
  ## Один параметр по имени, номеру в описателе или адресу
  ## (`node:1.1/param:1`).
  ##
  ## Адрес разбирает ЯДРО, а не клиент (#336): иначе Editor и CLI отвечали бы
  ## на `param get 1 node:1.1/param:1` разными словами. Путь обязан вести в
  ## указанную ноду: адрес чужой ноды — ошибка вызова, а не повод молча взять
  ## параметр «оттуда».
  let params = doc.queryParams(reference)
  if not params.ok:
    return (false, ParamInfo(), params.frame)

  var text = paramText
  # Адрес — это `вид:слот.поколение` (признак тот же, что у ссылок на ноду):
  # `node:1.1` в месте параметра тоже адрес, и отвечать «нет параметра node:1.1»
  # значило бы скрыть, что указан не тот вид сущности (§82).
  if ':' in paramText and '.' in paramText:
    var nested: NestedRef
    let bound = bindNestedText(doc.handles, paramText, nested)
    if bound != heOk:
      # Не вложенный путь — возможно, это адрес НОДЫ (или другой сущности) в
      # месте параметра: отвечаем «нужен параметр», а не «битый адрес» — иначе
      # клиент не отличит опечатку от «не тот вид сущности» (§82).
      var handle: EntityHandle
      if bindHandleText(doc.handles, paramText, handle) == heOk and
         handle.kind != hkParam:
        return (false, ParamInfo(),
                errFrame(ecKindMismatch,
                         "адрес " & paramText & ": здесь нужен параметр",
                         AddressHint))
      return (false, ParamInfo(),
              errFrame(bound.errorCodeOf,
                       "адрес " & paramText & ": " & handleErrorText(bound),
                       AddressHint))
    if nested.target != hkParam:
      return (false, ParamInfo(),
              errFrame(ecKindMismatch,
                       "адрес " & paramText & ": " &
                         handleErrorText(heKindMismatch) &
                         " — здесь нужен параметр",
                       AddressHint))
    let resolved = doc.handles.resolveNested(nested)
    if not resolved.ok:
      if resolved.error == heInvalid:
        return (false, ParamInfo(),
                errFrame(ecNotFound,
                         "в документе нет параметра с адресом " & paramText,
                         AddressHint))
      return (false, ParamInfo(),
              errFrame(resolved.error.errorCodeOf,
                       "адрес " & paramText & ": " &
                         handleErrorText(resolved.error),
                       AddressHint))
    let owner = doc.resolveNodeIndex(reference)
    if not owner.ok:
      return (false, ParamInfo(), owner.frame)
    if int(resolved.ownerId) != doc.proj.graph.nodes[owner.index].id:
      return (false, ParamInfo(),
              errFrame(ecInvalidArgument,
                       "адрес " & paramText & " ведёт в ноду #" &
                         $int(resolved.ownerId) &
                         ", а указана другая нода",
                       "адрес параметра должен принадлежать указанной ноде"))
    text = $int(resolved.index)

  var found = -1
  if text.len > 0 and text.allCharsInSet({'0'..'9'}):
    let index = parseInt(text)
    if index >= 0 and index < params.params.len:
      found = index
  else:
    for i, p in params.params:
      if p.name == text:
        found = i
        break
  if found < 0:
    var names: seq[string] = @[]
    for p in params.params:
      names.add p.name
    return (false, ParamInfo(),
            errFrame(ecUnknownParameter,
                     "у ноды нет параметра " & paramText,
                     "параметры: " & names.join(", ")))
  (true, params.params[found], okFrame())

proc queryConnections*(doc: Document): seq[ConnectionInfo] =
  ## Связи в порядке файла: он и есть контракт документа.
  for conn in doc.proj.graph.connections:
    result.add ConnectionInfo(
      srcNodeId: conn.srcNodeId, srcPortIdx: conn.srcPortIdx,
      dstNodeId: conn.dstNodeId, dstPortIdx: conn.dstPortIdx,
      sigType: conn.sigType)

proc queryTrack*(doc: Document; trackId: int32): seq[ClipInfo] =
  ## Клипы дорожки с адресами размещения (`track:1.1/clip:0`).
  for track in doc.proj.sequencer.tracks:
    if track.id != trackId:
      continue
    for index, clip in track.clips:
      result.add ClipInfo(
        id: clip.id, name: clip.name,
        handle: nestedToText(doc.handles.trackClipRef(trackId, uint32(index))),
        startTick: clip.startTick, lengthTicks: clip.lengthTicks,
        loopEnabled: clip.loopEnabled, notes: clip.notes.len)

proc queryTracks*(doc: Document): seq[TrackInfo] =
  ## Дорожки в порядке файла.
  for track in doc.proj.sequencer.tracks:
    result.add TrackInfo(
      id: track.id, name: track.name,
      handle: handleToText(doc.handles.trackHandle(track.id)),
      trackType: track.trackType,
      volume: track.volume, pan: track.pan,
      mute: track.mute, solo: track.solo, armed: track.armed,
      inputChannel: track.inputChannel, outputBus: track.outputBus,
      clips: doc.queryTrack(track.id))

proc queryNotes*(doc: Document; trackId: int32; clipIndex: int):
    tuple[ok: bool, notes: seq[NoteInfo], frame: ErrorFrame] =
  ## Ноты клипа: адрес клипа — дорожка и номер, id клипа уникален только внутри
  ## дорожки, поэтому и ссылка такая.
  for track in doc.proj.sequencer.tracks:
    if track.id != trackId:
      continue
    if clipIndex < 0 or clipIndex >= track.clips.len:
      return (false, @[],
              errFrame(ecNotFound, "клипа №" & $clipIndex & " на дорожке #" &
                       $trackId & " нет",
                       "клипы дорожки: euterpia project show"))
    for note in track.clips[clipIndex].notes:
      result.notes.add NoteInfo(
        startTick: note.startTick, duration: note.duration,
        pitch: note.pitch, velocity: note.velocity, channel: note.channel)
    return (true, result.notes, okFrame())
  (false, @[], errFrame(ecNotFound, "дорожки #" & $trackId & " нет", ""))

proc querySummary*(doc: Document): ProjectSummary =
  ## Счётчики содержимого плюс идентификатор документа: клиент кладёт их в
  ## отчёт, чтобы адреса из вывода было видно, к какому файлу они относятся.
  ##
  ## Один источник: `summarize` больше не живёт в CLI — иначе «нод: 3» в отчёте
  ## и в схеме `--json` считались бы двумя разными проходами по модели (#336).
  result = ProjectSummary(
    nodes: doc.proj.graph.nodes.len,
    connections: doc.proj.graph.connections.len,
    tracks: doc.proj.sequencer.tracks.len,
    pluginStates: doc.proj.pluginStates.len,
    documentId: doc.docId,
    document: docIdText(doc.docId))
  for track in doc.proj.sequencer.tracks:
    result.clips += track.clips.len
    for clip in track.clips:
      result.notes += clip.notes.len
  for lane in doc.proj.sequencer.automationLanes:
    inc result.automationLanes
    result.automationPoints += lane.points.len
  for state in doc.proj.pluginStates:
    result.pluginStateBytes += state.state.len

proc queryMetadata*(doc: Document): MetadataInfo =
  ## Метаданные проекта — значение, а не ссылка на поле формата: клиент печатает
  ## то, что ему отдали, и не «додумывает» умолчания (§63).
  let meta = doc.proj.metadata
  MetadataInfo(
    name: meta.name, author: meta.author,
    tempo: meta.tempo, sampleRate: meta.sampleRate,
    tsNumerator: meta.timeSignature.numerator,
    tsDenominator: meta.timeSignature.denominator,
    created: meta.created, modified: meta.modified)

proc queryAutomationLanes*(doc: Document): seq[AutomationLaneInfo] =
  ## Дорожки автоматизации в порядке файла: `project show` и `validate`
  ## перечисляют их, не заглядывая в модель.
  for lane in doc.proj.sequencer.automationLanes:
    var neg = 0
    for point in lane.points:
      if point.tick < 0:
        inc neg
    result.add AutomationLaneInfo(nodeId: lane.nodeId, paramId: lane.paramId,
                                  points: lane.points.len, negativeTicks: neg)

proc queryPluginStates*(doc: Document): seq[PluginStateInfo] =
  ## Сохранённые состояния плагинов: узел, идентификатор и размер. Само
  ## состояние (байты) наружу не отдаётся — клиенту нужен факт и объём
  ## (§63).
  for state in doc.proj.pluginStates:
    result.add PluginStateInfo(nodeId: state.nodeId, pluginId: state.pluginId,
                               bytes: state.state.len)
