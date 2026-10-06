# tests/unit/test_control_history.nim
#
# Транзакции и история control-слоя (issue #139 вместе с #109, MANIFEST §65/§66).
#
# Что проверяется:
#   - составная операция атомарна: отказ на середине не оставляет НИ ОДНОГО
#     изменения (проба идёт на копии — откатывать нечего);
#   - обратные команды строятся из состояния ДО правки, идут в обратном порядке
#     и восстанавливают документ побайтово;
#   - отмена удаления ноды возвращает её ВМЕСТЕ со связями, дорожками
#     автоматизации и состояниями плагинов — то, что удаление унесло;
#   - одна составная операция — одна запись истории; undo/redo возвращают
#     документ к снимку побайтово (кроме отметки времени);
#   - новая операция сбрасывает redo (поведение Commons), а испорченная запись
#     не выполняется молча, а даёт код.

import std/[json, strutils, tables, unittest]

import project
import control/error_frame
import control/commands
import control/document
import control/history

import control_fakes

suite "control: транзакции":
  test "отказ на середине не оставляет ни одного изменения":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    let before = snapshot(doc)

    # Три команды, вторая невыполнима: третья нода с занятым id.
    let plan = doc.applyTransaction(@[
      createNode("test.osc"),
      createNode("test.gain", "", 1),
      createNode("test.seq", "Позже")
    ], "собрать каскад")
    check not plan.frame.isOk()
    check plan.frame.code == ecAlreadyExists
    check "собрать каскад" in plan.frame.message
    check "ни одна команда не применена" in plan.frame.hint
    check snapshot(doc) == before
    check doc.proj.graph.nodes.len == 1

  test "успешная транзакция применяет всё и даёт обратные команды":
    var doc = newDoc()
    let plan = doc.applyTransaction(@[
      createNode("test.gain"),
      createNode("test.gain"),
      connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)),
      setParameter(1, 1.5f32, "gain")
    ], "два gain и связь")
    check plan.frame.isOk()
    check doc.proj.graph.nodes.len == 2
    check doc.proj.graph.connections.len == 1
    check doc.proj.graph.nodes[0].parameters["gain"] == 1.5f32
    # Обратных столько же, сколько команд, и они идут в обратном порядке:
    # первой отменяется ПОСЛЕДНЯЯ команда.
    check plan.undo.len == 4
    check plan.redo.len == 4
    check plan.undo[0].kind == ccSetParameter
    check plan.undo[0].value == 1.0f32      ## вернули прежнее значение
    check plan.undo[3].kind == ccDeleteNode ## отмена первого создания

  test "пустая транзакция и неоткатываемая команда отвергаются":
    var doc = newDoc()
    check doc.applyTransaction(@[], "пусто").frame.code == ecInvalidArgument
    let plan = doc.applyTransaction(@[newCommand(ccAddTrack)], "не реализовано")
    check plan.frame.code == ecUnsupportedCommand

suite "control: история":
  test "одна составная операция — одна запись истории":
    var doc = newDoc()
    var hist = newHistory()
    check not hist.canUndo()
    check hist.execute(doc, @[
      createNode("test.gain"),
      createNode("test.gain"),
      connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0))
    ], "две ноды и связь").isOk()
    check doc.proj.graph.nodes.len == 2
    check hist.canUndo()
    check hist.undoLen() == 1

  test "отмена и повтор возвращают документ побайтово":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    let before = snapshotWithoutStamp(doc)

    var hist = newHistory()
    # Приёмник обязан иметь вход: у test.osc аудиовхода нет, поэтому узел
    # назначения — второй gain, а значение параметра ставим у него же.
    check hist.execute(doc, @[
      createNode("test.gain"),
      setParameter(2, 1.25f32, "gain"),
      connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0))
    ], "узел в граф").isOk()
    check snapshotWithoutStamp(doc) != before

    check hist.undo(doc).isOk()
    check snapshotWithoutStamp(doc) == before
    check hist.canRedo()

    check hist.redo(doc).isOk()
    check doc.proj.graph.nodes.len == 2
    check doc.proj.graph.nodes[1].parameters["gain"] == 1.25f32
    check doc.proj.graph.connections.len == 1

  test "отмена удаления возвращает ноду со всем, что на неё ссылалось":
    var doc = newDoc()
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(createNode("test.gain"))
    discard doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)))
    doc.proj.sequencer.automationLanes = @[
      AutomationLaneFormat(paramId: 1'u32, nodeId: 2)]
    doc.proj.pluginStates = @[
      PluginStateFormat(nodeId: 2, pluginId: "test.plugin")]
    let before = snapshotWithoutStamp(doc)

    var hist = newHistory()
    check hist.execute(doc, @[deleteNode(2)], "удалить ноду").isOk()
    check doc.proj.graph.nodes.len == 1
    check doc.proj.graph.connections.len == 0
    check doc.proj.pluginStates.len == 0

    check hist.undo(doc).isOk()
    # Восстановилось ВСЁ, что удаление унесло, — иначе отмена была бы
    # «почти отменой».
    check snapshotWithoutStamp(doc) == before
    check doc.proj.pluginStates.len == 1
    check doc.proj.pluginStates[0].pluginId == "test.plugin"
    check doc.proj.sequencer.automationLanes.len == 1
    check doc.proj.graph.connections.len == 1

  test "новая операция сбрасывает redo, отменять нечего — код, а не тишина":
    var doc = newDoc()
    var hist = newHistory()
    discard doc.applyCommand(createNode("test.gain"))
    check hist.execute(doc, @[createNode("test.gain")], "вторая нода").isOk()
    check hist.undo(doc).isOk()
    check hist.canRedo()

    check hist.execute(doc, @[createNode("test.gain")], "третья нода").isOk()
    check not hist.canRedo()
    check hist.redoLen() == 0
    # Отменённая запись ушла в redo, поэтому в undo осталась только новая.
    check hist.undoLen() == 1

    while hist.canUndo():
      discard hist.undo(doc)
    check not hist.canUndo()
    check hist.undo(doc).code == ecInvalidArgument

  test "испорченная запись не выполняется молча":
    var doc = newDoc()
    var hist = newHistory()
    var entry: HistoryEntry
    check entry.decodeEntry("не json") == false
    check entry.decodeEntry("""{"v":99,"redo":[]}""") == false
    # Запись с обратными командами разбирается и обратно собирается.
    let original = HistoryEntry(
      redo: @[createNode("test.gain", "Узел", 4),
              setParameter(4, 0.5f32, "gain")],
      undo: @[setParameter(4, 1.0f32, "gain"), deleteNode(4)],
      description: "round-trip")
    check entry.decodeEntry(original.encodeEntry)
    check entry.description == "round-trip"
    check entry.redo.len == 2 and entry.undo.len == 2
    check entry.redo[0].kind == ccCreateNode
    check entry.redo[0].newNodeId == 4
    check entry.undo[1].kind == ccDeleteNode
    check entry.undo[0].value == 1.0f32

suite "control: контракт команды на проводе":
  test "команда переживает JSON-раунд для всех реализованных видов":
    let cases = @[
      createNode("test.osc", "Лид", 7, 5'u32),
      deleteNode(3, 6'u32),
      connect(port(1, cpkAudio, 0), port(2, cpkEvent, 2), 7'u32),
      disconnect(port(1, cpkControl, 1), port(2, cpkControl, 0), false, 8'u32),
      setParameter(2, -3.5f32, "level", -1, 9'u32),
      setParameter(2, 1.25f32, "", 1, 10'u32),
      restoreNodeState(4,
        @[AutomationLaneFormat(nodeId: 4, paramId: 2)],
        @[PluginStateFormat(nodeId: 4, pluginId: "p")], 11'u32)
    ]
    for cmd in cases:
      var back: ControlCommand
      check cmd.toJson.fromJson(back)
      check back.kind == cmd.kind
      check back.id == cmd.id
      check back.apiVersion == cmd.apiVersion
      check back.toJson == cmd.toJson

  test "чужая или неизвестная команда не разбирается молча":
    var cmd: ControlCommand
    check (newJObject()).fromJson(cmd) == false
    check parseJson("""{"kind":"node.explode","api":1,"nodeId":1}""").fromJson(cmd) == false
    # Более новая версия API, чем знает ядро, — тоже отказ, а не «примерно».
    check parseJson("""{"kind":"node.delete","api":99,"nodeId":1}""").fromJson(cmd) == false
    # Связь без портов — не наша форма.
    check parseJson("""{"kind":"graph.connect","api":1}""").fromJson(cmd) == false
