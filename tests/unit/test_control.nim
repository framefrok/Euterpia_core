# tests/unit/test_control.nim
#
# Control Core: команды документа (issue #139, MANIFEST §65).
#
# Что проверяется:
#   - команда создаёт/меняет/удаляет ровно то, что описана, и отказывает кодом,
#     а не `false` (конверт и `ErrorFrame`);
#   - ОТКАЗ НЕ ОСТАВЛЯЕТ ЧАСТИЧНЫХ ИЗМЕНЕНИЙ: документ до и после неудачной
#     команды совпадает побайтово — это и есть требование #127 на текущем
#     подэтапе, где транзакций ещё нет;
#   - один путь исполнения: одинаковый сценарий даёт одинаковый документ,
#     независимо от того, кто принёс описатели типов, а внедрённые часы делают
#     снимок детерминированным (по нему CLI и тестовый клиент сравнимы);
#   - удаление ноды каскадно убирает связи, автоматизацию и состояния плагинов;
#   - объявленные, но не реализованные команды отвечают `ecUnsupportedCommand`,
#     а чужая версия API — `ecApiVersionMismatch`.

import std/[strutils, tables, unittest]

import project
import handles
import control/error_frame
import control/commands
import control/document

import control_fakes

# =============================================================================
# Создание ноды
# =============================================================================

suite "control: создание ноды":
  test "id назначается сам, порты и умолчания берутся у типа":
    var doc = newDoc()
    let frame = doc.applyCommand(createNode("test.gain"))
    check frame.isOk()
    check doc.proj.graph.nodes.len == 1
    let node = doc.proj.graph.nodes[0]
    check node.id == 1
    check node.nodeType == "test.gain"
    check node.name == "Gain"          ## пустое имя — человеческое имя типа
    check node.audioInCount == 1 and node.audioOutCount == 1
    check node.parameters["gain"] == 1.0f32
    check doc.proj.metadata.modified == FixedStamp
    # Адрес ноды появился в той же команде (#143).
    check doc.handles.nodeHandle(1).isValidHandle()
    check doc.handles.nodeHandle(1).handleToText() == "node:1.1"

  test "имя и id из команды уважаются":
    var doc = newDoc()
    check doc.applyCommand(createNode("test.osc", "Lead", 7)).isOk()
    check doc.proj.graph.nodes[0].id == 7
    check doc.proj.graph.nodes[0].name == "Lead"

  test "занятый, неизвестный и пустой тип — разные коды":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    check doc.applyCommand(createNode("test.osc", "", 1)).code == ecAlreadyExists
    check doc.applyCommand(createNode("test.nope")).code == ecUnknownNodeType
    check doc.applyCommand(createNode("")).code == ecInvalidArgument
    check doc.applyCommand(createNode("test.gain", "", -3)).code == ecInvalidArgument
    check doc.proj.graph.nodes.len == 1

  test "хозяин без описателей — это проблема окружения, а не данные":
    var doc = newDoc(emptyProject(), nil)
    let frame = doc.applyCommand(createNode("test.gain"))
    check frame.code == ecNoDescriptor
    # Числа кодов — контракт для клиентов (#117): они зафиксированы, а не
    # «как получится»: 0 ok, 1 not_found, … 11 no_descriptor.
    check frameCodeValue(frame.code) == 11
    check frame.hint.len > 0

# =============================================================================
# Удаление, связи, параметры
# =============================================================================

suite "control: удаление ноды каскадно":
  test "нода уносит с собой связи, автоматизацию и состояния плагинов":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(createNode("test.gain"))
    check doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0))).isOk()

    doc.proj.sequencer.automationLanes = @[
      AutomationLaneFormat(paramId: 1'u32, nodeId: 2)]
    doc.proj.pluginStates = @[
      PluginStateFormat(nodeId: 2, pluginId: "test.plugin"),
      PluginStateFormat(nodeId: 1, pluginId: "keep.me")]

    check doc.applyCommand(deleteNode(2)).isOk()
    check doc.proj.graph.nodes.len == 1
    check doc.proj.graph.connections.len == 0
    check doc.proj.sequencer.automationLanes.len == 0
    check doc.proj.pluginStates.len == 1
    check doc.proj.pluginStates[0].pluginId == "keep.me"
    # Адрес удалённой ноды больше не адресуется.
    check doc.handles.nodeHandle(2).isValidHandle() == false
    check doc.handles.nodeHandle(1).handleToText() == "node:1.1"

  test "удаление несуществующей ноды — код, а не падение":
    var doc = newDoc()
    check doc.applyCommand(deleteNode(9)).code == ecNotFound

suite "control: связи":
  test "связь создаётся, повтор и несовпадение видов отвергаются":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(createNode("test.gain"))
    check doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0))).isOk()
    check doc.proj.graph.connections.len == 1
    check doc.proj.graph.connections[0].sigType == 0

    check doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0))).code ==
      ecDuplicateConnection
    # Приёмнику нужен ВХОД нужного вида: у test.osc аудиовхода нет, и это
    # должен сказать код, а не компилятор.
    discard doc.applyCommand(createNode("test.osc"))
    check doc.applyCommand(connect(port(1, cpkAudio, 0), port(3, cpkAudio, 0))).code ==
      ecPortNotAvailable
    check doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkEvent, 0))).code ==
      ecPortKindMismatch
    check doc.applyCommand(connect(port(1, cpkAudio, 3), port(2, cpkAudio, 0))).code ==
      ecPortNotAvailable
    check doc.applyCommand(connect(port(1, cpkAudio, -1), port(2, cpkAudio, 0))).code ==
      ecInvalidArgument
    check doc.applyCommand(connect(port(9, cpkAudio, 0), port(2, cpkAudio, 0))).code ==
      ecNotFound
    check doc.proj.graph.connections.len == 1

  test "самосоединение разрешено (цикл ловит graph check, а не команда)":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    check doc.applyCommand(connect(port(1, cpkAudio, 0), port(1, cpkAudio, 0))).isOk()

  test "разрыв по порту и разрыв всех связей между нодами":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(createNode("test.notes"))
    discard doc.applyCommand(createNode("test.seq"))
    discard doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)))
    discard doc.applyCommand(connect(port(1, cpkAudio, 0), port(3, cpkAudio, 0)))
    check doc.proj.graph.connections.len == 2

    check doc.applyCommand(disconnect(port(1, cpkAudio, 0), port(3, cpkAudio, 0))).isOk()
    check doc.proj.graph.connections.len == 1

    # Ни нода нот, ни секвенсор аудиопортов не имеют: разрыв «всего между
    # ними» всё равно должен работать, а не ругаться «нет порта 0». Связь здесь
    # по событиям — единственная, которая у них есть.
    discard doc.applyCommand(connect(port(4, cpkEvent, 0), port(5, cpkEvent, 0)))
    check doc.proj.graph.connections.len == 2
    check doc.applyCommand(disconnect(port(4, cpkEvent, 0), port(5, cpkEvent, 0), false)).isOk()
    check doc.proj.graph.connections.len == 1
    check doc.applyCommand(disconnect(port(1, cpkAudio, 0), port(3, cpkAudio, 0), false)).code ==
      ecConnectionNotFound

suite "control: параметры":
  test "значение пишется по имени и по номеру":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.osc"))
    check doc.applyCommand(setParameter(1, 220.0f32, "freq")).isOk()
    check doc.proj.graph.nodes[0].parameters["freq"] == 220.0f32
    check doc.applyCommand(setParameter(1, -3.5f32, "", 3)).isOk()
    check doc.proj.graph.nodes[0].parameters["level"] == -3.5f32
    check doc.applyCommand(setParameter(1, 2.0f32, "", 99)).code == ecUnknownParameter

  test "диапазон и целочисленность — по описателю типа":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.osc"))
    let range = doc.applyCommand(setParameter(1, 99999.0f32, "freq"))
    check range.code == ecOutOfRange
    check "вне диапазона" in range.message
    let integer = doc.applyCommand(setParameter(1, 1.5f32, "waveform"))
    check integer.code == ecOutOfRange
    check "целочисленный" in integer.message
    check doc.applyCommand(setParameter(1, 3.0f32, "waveform")).isOk()
    check doc.proj.graph.nodes[0].parameters["waveform"] == 3.0f32
    check doc.applyCommand(setParameter(9, 1.0f32, "freq")).code == ecNotFound
    check doc.applyCommand(setParameter(1, 1.0f32, "nope")).code == ecUnknownParameter

# =============================================================================
# Конверт и «отказ ничего не меняет»
# =============================================================================

suite "control: конверт команды":
  test "чужая версия API и нереализованная команда":
    var doc = newDoc()
    var wrongVersion = createNode("test.gain")
    wrongVersion.apiVersion = ControlApiVersion + 1
    check doc.applyCommand(wrongVersion).code == ecApiVersionMismatch

    # Версия 0 означает «клиент не про версии» — принимается.
    var unversioned = createNode("test.gain")
    unversioned.apiVersion = 0
    check doc.applyCommand(unversioned).isOk()

    var unsupported = newCommand(ccAddTrack)
    check doc.applyCommand(unsupported).code == ecUnsupportedCommand
    check not isImplemented(ccAddTrack)
    check isImplemented(ccCreateNode)

  test "имена команд стабильны и не пусты":
    for kind in ControlCommandKind:
      check commandName(kind).len > 0
      check commandName(kind) != $kind

  test "коды ошибок: числа и имена — контракт":
    check frameCodeValue(ecOk) == 0
    check frameCodeValue(ecNotFound) == 1
    check frameCodeValue(ecUnknownNodeType) == 5
    check $ecNotFound == "not_found"
    check $ecOutOfRange == "out_of_range"
    check not errFrame(ecInternal, "почти ок").isOk()
    check okFrame().isOk()

suite "control: отказ не оставляет частичных изменений":
  test "неудачные команды не меняют документ ни на байт":
    var doc = newDoc()
    # Готовим документ, в котором есть что терять: две ноды, связь, значение.
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(createNode("test.osc"))
    discard doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)))
    discard doc.applyCommand(setParameter(2, 440.0f32, "freq"))
    let before = snapshot(doc)

    let failing = @[
      createNode("test.nope"),                      # неизвестный тип
      createNode("test.gain", "", 1),               # занятый id
      createNode(""),                               # пустой тип
      deleteNode(42),                               # нет такой ноды
      connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)),  # повтор связи
      connect(port(1, cpkAudio, 0), port(2, cpkEvent, 0)),  # виды разные
      connect(port(1, cpkAudio, 9), port(2, cpkAudio, 0)),  # порта нет
      disconnect(port(1, cpkAudio, 0), port(42, cpkAudio, 0)),
      setParameter(1, 99.0f32, "freq"),             # вне диапазона
      setParameter(1, 1.5f32, "waveform"),          # целочисленный
      setParameter(1, 1.0f32, "nope"),              # нет параметра
      setParameter(42, 1.0f32, "freq"),             # нет ноды
    ]
    for cmd in failing:
      let frame = doc.applyCommand(cmd)
      check not frame.isOk()
      check snapshot(doc) == before

suite "control: один путь исполнения":
  test "тот же сценарий — тот же документ, независимо от хозяина":
    ## Два документа, у которых описания типов пришли из разных хозяев, после
    ## одного и того же сценария обязаны совпасть побайтово: иначе «клиент и
    ## Editor получат разное» — это и есть «второй Core» (§23).
    var byFake = newDoc()
    var byOther = newDoc(emptyProject(), altProvider)

    runScenario(byFake)
    runScenario(byOther)

    # Имена узлов у провайдеров разные — сравниваем всё, кроме них: сценарий
    # должен давать одну и ту же СТРУКТУРУ и одни и те же значения.
    check strippedSnapshot(byFake) == strippedSnapshot(byOther)

  test "снимок детерминирован: внедрённые часы, а не системные":
    var first = newDoc()
    var second = newDoc()
    discard first.applyCommand(createNode("test.gain"))
    discard second.applyCommand(createNode("test.gain"))
    check first.proj.metadata.modified == FixedStamp
    check snapshot(first) == snapshot(second)

    # Без часов отметка не меняется — и это тоже предсказуемо.
    var noClock: Document
    initDocument(noClock, emptyProject(), TestDocId, fakeProvider, nil)
    discard noClock.applyCommand(createNode("test.gain"))
    check noClock.proj.metadata.modified == ""

# =============================================================================
# Метаданные проекта (issue #373)
# =============================================================================

suite "control: метаданные проекта (#373)":
  test "меняются только поля из маски, отметка modified ставится":
    var doc = newDoc()
    let srBefore = doc.proj.metadata.sampleRate   # пустой проект: не задан
    check doc.applyCommand(
      setProjectInfo(ProjectFieldName or ProjectFieldTempo,
                     name = "Song", tempo = 140.0f)).isOk()
    check doc.proj.metadata.name == "Song"
    check abs(doc.proj.metadata.tempo - 140.0f) < 1e-4f
    # Sample rate не трогали — остался прежним.
    check doc.proj.metadata.sampleRate == srBefore
    check doc.proj.metadata.modified == FixedStamp

  test "границы проверяет ЯДРО, а не CLI":
    var doc = newDoc()
    let before = snapshotWithoutStamp(doc)
    check doc.applyCommand(
      setProjectInfo(ProjectFieldTempo, tempo = 0.0f)).code == ecOutOfRange
    check doc.applyCommand(
      setProjectInfo(ProjectFieldSampleRate,
                     sampleRate = 0.0f)).code == ecOutOfRange
    check doc.applyCommand(
      setProjectInfo(ProjectFieldTimeSignature,
                     tsNum = 4, tsDen = 3)).code == ecOutOfRange
    check doc.applyCommand(
      setProjectInfo(ProjectFieldTimeSignature,
                     tsNum = 0, tsDen = 4)).code == ecOutOfRange
    # Отказ не оставил изменений.
    check snapshotWithoutStamp(doc) == before

  test "JSON round-trip сохраняет маску и значения":
    let cmd = setProjectInfo(ProjectFieldName or ProjectFieldSampleRate,
                             name = "X", sampleRate = 44100.0f)
    var back: ControlCommand
    check cmd.toJson.fromJson(back)
    check back.kind == ccSetProjectInfo
    check back.projectMask == (ProjectFieldName or ProjectFieldSampleRate)
    check back.projectName == "X"
    check abs(back.projectSampleRate - 44100.0f) < 1e-3f

  test "транзакция отменяема: откат возвращает прежние метаданные":
    var doc = newDoc()
    let plan = doc.applyTransaction(
      @[setProjectInfo(ProjectFieldName, name = "New")], "rename")
    check plan.frame.isOk()
    check doc.proj.metadata.name == "New"
    let undone = doc.applyTransaction(plan.undo, "undo")
    check undone.frame.isOk()
    check doc.proj.metadata.name == ""    # было пусто
