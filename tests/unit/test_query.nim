# tests/unit/test_query.nim
#
# Query API: чтение модели без внутренностей (issue #141, MANIFEST §63).
#
# Что проверяется:
#   - ссылка на ноду в трёх видах (id, адрес #143, имя) и ВНЯТРЕННИЕ коды отказа:
#     «нет такой ноды», «адрес чужого документа», «адрес просрочен», «имя неоднозначно»;
#   - детерминированный порядок и фильтр с окном: два вызова дают одно и то же,
#     а `total` позволяет клиенту сказать «показать ещё»;
#   - параметры приходят в порядке описателя, со значением ИЗ ФАЙЛА или
#     умолчанием, с адресом и свойствами фактами (Core не знает `NodeParamFlag`);
#   - вложенные сущности: клип адресуется как `track:1.1/clip:0`, ноты читаются
#     по дорожке и номеру клипа;
#   - один и тот же вопрос из двух клиентов даёт одинаковый ответ (критерий #139
#     для чтения), а коды ответа адресации переводятся в коды control-слоя (#117).

import std/[json, strutils, tables, times, unittest]

import project
import handles
import control/error_frame
import control/commands
import control/document
import control/query

import control_fakes

proc filled(): Document =
  ## Документ со всем, что должен читать Query API: две ноды, связь, параметры
  ## из файла и умолчание, трек с клипами и нотами.
  var doc = newDoc()
  discard doc.applyCommand(createNode("test.gain", "Gain"))
  discard doc.applyCommand(createNode("test.gain", "Второй"))
  discard doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)))
  discard doc.applyCommand(setParameter(1, 1.75f32, "gain"))
  var track = TrackFormat(id: 1, name: "Дорожка", volume: 0.9f32)
  track.clips = @[
    ClipFormat(id: 1, name: "A", startTick: 0, lengthTicks: 480,
      notes: @[NoteFormat(startTick: 0, duration: 240, pitch: 60'u8,
                          velocity: 100'u8)]),
    ClipFormat(id: 2, name: "B", startTick: 480, lengthTicks: 480)
  ]
  doc.proj.sequencer.tracks = @[track]
  # Трек добавлен в модель мимо команд — адреса синхронизируем вручную,
  # как и для ноды «из будущего» ниже: handle-таблица не читает модель сама.
  doc.refreshHandles()
  doc

suite "query: ссылки на ноду":
  test "id, адрес и имя ведут к одной и той же ноде":
    let doc = filled()
    let byId = doc.queryNode("1")
    check byId.ok
    check byId.node.name == "Gain"
    let byHandle = doc.queryNode(byId.node.handle)
    check byHandle.ok
    check byHandle.node.id == byId.node.id
    let byFull = doc.queryNode(byId.node.handleRef)
    check byFull.ok
    check byFull.node.id == byId.node.id
    let byName = doc.queryNode("gain")       # без учёта регистра
    check byName.ok
    check byName.node.id == 1

  test "внутренние отказы с разными кодами, а не «не нашлась нода»":
    var doc = filled()
    check doc.queryNode("99").frame.code == ecNotFound
    check doc.queryNode("НетТакой").frame.code == ecNotFound
    check doc.queryNode("node:9.9").frame.code == ecInvalidArgument
    check doc.queryNode("").frame.code == ecInvalidArgument
    # Адрес другого документа — отдельный код: это не «ноды нет», это «не тот файл».
    var other = filled()
    other.docId = 0xDEADBEEF'u32
    other.refreshHandles()          # тот же проект, но другой документ
    # Короткий адрес — ссылка внутри текущего документа, поэтому он разрешается.
    let short = other.queryNode(doc.handles.nodeHandle(1).handleToText())
    check short.ok
    # Полный адрес привязан к документу: в чужом файле он отвергается.
    let foreignFull = other.queryNode(doc.handles.nodeHandle(1).handleToTextQualified())
    check not foreignFull.ok
    check foreignFull.frame.code == ecForeignDocument

  test "просроченный адрес отвергается, а не читает чужую ноду":
    ## ABA: слот освобождён и уже выдан заново, а у клиента — старый адрес.
    ## Таблица здесь не пересобирается (в сессии она и не должна: адреса живут
    ## до конца сессии, #143).
    var doc = filled()
    let stale = doc.handles.nodeHandle(1)
    discard doc.handles.releaseHandle(stale)
    let fresh = doc.handles.acquireHandleAt(hkNode, stale.slot, 1'u64)
    check fresh.slot == stale.slot
    check doc.queryNode(stale.handleToText()).frame.code == ecStaleHandle
    # Свежий адрес после переиспользования слота работает и указывает на то же.
    let byFresh = doc.queryNode(fresh.handleToText())
    check byFresh.ok
    check byFresh.node.id == 1

  test "удалённая нода адреса не имеет даже после пересборки таблицы":
    var doc = filled()
    let address = doc.handles.nodeHandle(1).handleToText()
    discard doc.applyCommand(deleteNode(1))
    let gone = doc.queryNode(address)
    check not gone.ok
    check gone.frame.code in {ecStaleHandle, ecInvalidArgument, ecNotFound}

  test "неоднозначное имя — отказ, а не выбор первой ноды":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain", "Дубль"))
    discard doc.applyCommand(createNode("test.gain", "ДУБЛЬ"))
    let found = doc.queryNode("дубль")
    check not found.ok
    check found.frame.code == ecInvalidArgument
    check "несколько" in found.frame.message

suite "query: список нод, фильтр и окно":
  test "порядок детерминирован: узлы идут по id":
    let doc = filled()
    let listed = doc.queryNodes()
    check listed.frame.isOk()
    check listed.nodes.len == 2
    check listed.nodes[0].id == 1
    check listed.nodes[1].id == 2
    check listed.total == 2
    # Повторный вызов — то же самое, иначе «сравнение снапшотов» бессмысленно.
    let again = doc.queryNodes()
    check $again.nodes[0] == $listed.nodes[0]

  test "фильтр по имени и типу, окно offset/limit и счётчик total":
    let doc = filled()
    let byName = doc.queryNodes(NodeFilter(text: "второй"))
    check byName.nodes.len == 1
    check byName.nodes[0].name == "Второй"
    let byType = doc.queryNodes(NodeFilter(nodeType: "test.gain"))
    check byType.total == 2
    let missingType = doc.queryNodes(NodeFilter(nodeType: "test.osc"))
    check missingType.total == 0
    let window = doc.queryNodes(NodeFilter(offset: 1, limit: 1))
    check window.nodes.len == 1
    check window.nodes[0].id == 2
    check window.total == 2          # сколько всего под фильтром, не считая окна
    check window.offset == 1 and window.limit == 1

  test "нода несёт адреса, счётчик связей и неизвестный тип не выдумывается":
    var doc = filled()
    doc.proj.graph.nodes.add NodeFormat(id: 9, nodeType: "future.node",
                                        name: "Из будущего")
    doc.refreshHandles()           # модель правили вручную — адреса синхронизируем
    let listed = doc.queryNodes(NodeFilter(nodeType: "future.node"))
    check listed.nodes.len == 1
    let node = listed.nodes[0]
    check node.known == false
    check node.typeName == ""
    check node.handle == "node:9.1"
    let first = doc.queryNodes(NodeFilter(limit: 1)).nodes[0]
    check first.connections == 1

suite "query: параметры":
  test "порядок описателя, источник значения и свойства фактами":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.osc"))
    discard doc.applyCommand(setParameter(1, 220.0f32, "freq"))
    let params = doc.queryParams("1")
    check params.ok
    check params.params.len == 4          # waveform, hiddenOne, freq, level
    check params.params[0].name == "waveform"
    check params.params[0].index == 0
    check params.params[0].integerLike
    # `node add` записывает умолчания в файл, поэтому источник — «файл».
    check params.params[0].fromFile
    check params.params[0].value == 0.0f32
    check params.params[1].hidden
    let freq = params.params[2]
    check freq.name == "freq"
    check freq.fromFile
    check freq.value == 220.0f32
    check freq.defaultValue == 440.0f32
    check freq.modulatable
    check freq.handle == "node:1.1/param:2"
    check freq.minValue == 0.01f32

    # Параметра нет в файле — значение берётся как умолчание типа, и клиенту
    # об этом сказано явно (fromFile = false).
    var bare = newDoc()
    discard bare.applyCommand(createNode("test.osc"))
    bare.proj.graph.nodes[0].parameters.del("level")
    let fallback = bare.queryParam("1", "level")
    check fallback.ok
    check fallback.param.fromFile == false
    check fallback.param.value == fallback.param.defaultValue

  test "один параметр: по имени и по номеру, чужое имя — код":
    let doc = filled()
    let byName = doc.queryParam("1", "gain")
    check byName.ok
    check byName.param.value == 1.75f32
    let byIndex = doc.queryParam("1", "0")
    check byIndex.ok
    check byIndex.param.name == "gain"
    check doc.queryParam("1", "freq").frame.code == ecUnknownParameter
    check doc.queryParam("99", "gain").frame.code == ecNotFound

  test "незарегистрированный тип: только то, что лежит в файле, по алфавиту":
    var doc = filled()
    doc.proj.graph.nodes.add NodeFormat(id: 9, nodeType: "future.node",
                                        name: "Из будущего")
    doc.refreshHandles()
    doc.proj.graph.nodes[^1].parameters = initTable[string, float32]()
    doc.proj.graph.nodes[^1].parameters["zeta"] = 2.0f32
    doc.proj.graph.nodes[^1].parameters["alpha"] = 1.0f32
    let params = doc.queryParams("9")
    check params.ok
    check params.params.len == 2
    check params.params[0].name == "alpha"     # порядок ключей таблицы не контракт
    check params.params[1].name == "zeta"
    check params.params[0].fromFile

suite "query: дорожки, клипы и ноты":
  test "клип адресуется как дорожка и номер, ноты читаются по нему":
    let doc = filled()
    let tracks = doc.queryTracks()
    check tracks.len == 1
    check tracks[0].handle == "track:1.1"
    check tracks[0].clips.len == 2
    check tracks[0].clips[0].handle == "track:1.1/clip:0"
    check tracks[0].clips[0].notes == 1
    check tracks[0].volume == 0.9f32

    let notes = doc.queryNotes(1, 0)
    check notes.ok
    check notes.notes.len == 1
    check notes.notes[0].pitch == 60'u8
    check doc.queryNotes(1, 9).frame.code == ecNotFound
    check doc.queryNotes(7, 0).frame.code == ecNotFound

suite "query: сводка и коды":
  test "сводка считает содержимое и называет документ":
    let doc = filled()
    let summary = doc.querySummary()
    check summary.nodes == 2
    check summary.connections == 1
    check summary.tracks == 1
    check summary.clips == 2
    check summary.notes == 1
    check summary.documentId == doc.docId
    check summary.document.len == 8
    # Состояния плагинов считаются объёмом: по нему видно «тяжёлый» проект,
    # не разворачивая сами состояния (#336).
    check summary.pluginStates == 0
    check summary.pluginStateBytes == 0

  test "метаданные приходят значением, а не ссылкой на поле формата":
    var doc = newDoc()
    doc.proj.metadata.name = "Demo"
    doc.proj.metadata.author = "Автор"
    doc.proj.metadata.tempo = 140.0f32
    doc.proj.metadata.sampleRate = 44100.0f32
    doc.proj.metadata.timeSignature =
      TimeSignatureFormat(numerator: 3, denominator: 4)
    let meta = doc.queryMetadata()
    check meta.name == "Demo"
    check meta.author == "Автор"
    check meta.tempo == 140.0f32
    check meta.sampleRate == 44100.0f32
    check meta.tsNumerator == 3
    check meta.tsDenominator == 4

  test "автоматизация и состояния плагинов читаются списками DTO":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain", "Gain"))
    doc.proj.sequencer.automationLanes = @[
      AutomationLaneFormat(nodeId: 1, paramId: 0,
        points: @[AutomationPointFormat(tick: 0, value: 0.0f32),
                  AutomationPointFormat(tick: 480, value: 1.0f32)]),
    ]
    doc.proj.pluginStates = @[
      PluginStateFormat(nodeId: 1, pluginId: "euterpia.test",
        state: @[1'u8, 2'u8, 3'u8]),
    ]
    let lanes = doc.queryAutomationLanes()
    check lanes.len == 1
    check lanes[0].nodeId == 1
    check lanes[0].paramId == 0
    check lanes[0].points == 2
    let states = doc.queryPluginStates()
    check states.len == 1
    check states[0].nodeId == 1
    check states[0].pluginId == "euterpia.test"
    check states[0].bytes == 3
    # Сводка считает то же самое: объём состояний — отдельным полем.
    let summary = doc.querySummary()
    check summary.automationLanes == 1
    check summary.automationPoints == 2
    check summary.pluginStates == 1
    check summary.pluginStateBytes == 3

  test "параметр адресуется и путём, а чужой путь — отказ с подсказкой":
    let doc = filled()
    let byPath = doc.queryParam("1", "node:1.1/param:0")
    check byPath.ok
    check byPath.param.name == "gain"
    # Путь в другую ноду: параметр НЕ берётся «оттуда» — это ошибка вызова.
    let foreign = doc.queryParam("1", "node:2.1/param:0")
    check not foreign.ok
    check foreign.frame.code == ecInvalidArgument
    check "указанной ноде" in foreign.frame.hint
    # Путь в другую сущность: ядро отвечает «нужен параметр», а не «нет ноды».
    let wrongKind = doc.queryParam("1", "node:1.1")
    check not wrongKind.ok
    check wrongKind.frame.code == ecKindMismatch

  test "проект на 1000 нод: чтение укладывается в бюджет кадра":
    ## Критерий #141 («проект на 1000 нод укладывается в бюджет кадра без
    ## блокировок») для чтения. Бюджет — один кадр при 48 кГц (20.8 мс); на
    ## обычной сборке запрос укладывается в него с большим запасом, потому что
    ## читает неизменяемый снимок и ничего не запирает.
    ##
    ## В сборке под санитайзером время НЕ проверяется: инструментирование
    ## замедляет код на порядок (CI-джоб `thread sanitizer` мерил бы
    ## инструмент, а не код). Такие сборки помечены флагом `-d:sanitizer`
    ## (`nimble tsan`-шаг в CI, `nimble asan`/`ubsan`). Форма роста остаётся
    ## под проверкой всегда: окно и фильтр не зависят от размера проекта.
    var doc = newDoc()
    for i in 1 .. 1000:
      discard doc.applyCommand(createNode("test.gain", "N" & $i))
    let started = epochTime()
    let listed = doc.queryNodes()
    let elapsed = epochTime() - started
    check listed.frame.isOk()
    check listed.total == 1000
    check listed.nodes.len == 1000
    when defined(sanitizer):
      echo "SKIP: сборка под санитайзером — бюджет времени не проверяется " &
           "(замер: " & $elapsed & " с)"
    else:
      check elapsed < 0.020
    # Фильтр и окно не зависят от размера проекта: клиент не пересылает всё.
    let page = doc.queryNodes(NodeFilter(text: "N99", offset: 0, limit: 5))
    check page.total >= 1
    check page.nodes.len <= 5

  test "коды адресации переводятся в коды control-слоя":
    check heOk.errorCodeOf == ecOk
    check heForeignDocument.errorCodeOf == ecForeignDocument
    check heStale.errorCodeOf == ecStaleHandle
    check heReleased.errorCodeOf == ecStaleHandle
    check heKindMismatch.errorCodeOf == ecKindMismatch
    check heNoEntity.errorCodeOf == ecNotFound
    check heInvalid.errorCodeOf == ecInvalidArgument
    check heBadPath.errorCodeOf == ecInvalidArgument
    check heSlotOccupied.errorCodeOf == ecInternal

  test "одни и те же данные из двух клиентов совпадают побайтово":
    ## Критерий #141: «один и тот же вопрос из CLI и из Editor даёт одинаковый
    ## ответ». Здесь — два независимых документа с одним и тем же содержимым.
    var first = filled()
    var second = filled()
    check $first.queryNodes().nodes == $second.queryNodes().nodes
    check $first.queryParams("1").params == $second.queryParams("1").params
