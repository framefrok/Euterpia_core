# tests/unit/test_undo_redo.nim
#
# commons/undo_redo.nim — история команд редактора (issue #57).
#
# Модуль не знает о графе/треках: он делегирует apply/undo/redo внешнему
# CommandExecutor. Поэтому тест подставляет собственный executor и проверяет
# именно логику истории:
#   - execute/undo/redo и описания шагов;
#   - новая команда инвалидирует redo;
#   - провал apply не меняет историю;
#   - limit (maxSteps) и его уменьшение на живом стеке;
#   - группы: один undo-шаг, пустая группа, вложенные группы;
#   - undo/redo внутри незакрытой группы запрещены;
#   - save/load истории (включая старый формат data/children).

import std/[unittest, os, options]
import undo_redo

type
  Counter = ref object
    applied: int
    undone: int
    redone: int
    undoOrder: seq[int32]

proc makeExecutor(c: Counter): CommandExecutor =
  initCommandExecutor(
    applyImpl = proc (cmd: CommandData): bool {.closure, raises: [].} =
      inc c.applied
      true,
    undoImpl = proc (cmd: CommandData): bool {.closure, raises: [].} =
      inc c.undone
      c.undoOrder.add cmd.nodeId
      true,
    redoImpl = proc (cmd: CommandData): bool {.closure, raises: [].} =
      inc c.redone
      true
  )

suite "undo_redo: базовый стек":
  test "execute/undo/redo и описания шагов":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(16)

    check not mgr.canUndo()
    check not mgr.canRedo()
    check mgr.undoDescription().isNone
    check mgr.redoDescription().isNone

    let cmd = cmdChangeParam(nodeId = 1, paramId = 2, oldVal = 0.0f, newVal = 1.0f)
    check mgr.execute(ex, cmd)
    check c.applied == 1
    check mgr.canUndo()
    check mgr.undoLen() == 1
    check mgr.undoDescription().get() == "Change Parameter"

    check mgr.undo(ex)
    check c.undone == 1
    check mgr.canRedo()
    check mgr.redoLen() == 1
    check not mgr.canUndo()
    check mgr.redoDescription().get() == "Change Parameter"

    check mgr.redo(ex)
    check c.redone == 1
    check mgr.canUndo()
    check not mgr.canRedo()

  test "новая команда инвалидирует redo":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(16)

    check mgr.execute(ex, cmdAddNode(1, 0, 1.0f, 2.0f))
    check mgr.undo(ex)
    check mgr.canRedo()

    check mgr.execute(ex, cmdAddNode(2, 0, 3.0f, 4.0f))
    check not mgr.canRedo()

  test "провал apply не меняет историю":
    var mgr = initUndoRedoManager(16)
    let failEx = initCommandExecutor(
      applyImpl = proc (cmd: CommandData): bool {.closure, raises: [].} = false)

    check not mgr.execute(failEx, cmdAddNode(1, 0, 0.0f, 0.0f))
    check not mgr.canUndo()
    check mgr.undoLen() == 0

  test "пустой undo/redo возвращают false":
    let ex = makeExecutor(Counter())
    var mgr = initUndoRedoManager(4)
    check not mgr.undo(ex)
    check not mgr.redo(ex)

  test "limit обрезает самые старые шаги":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(2)
    for i in 0 ..< 5:
      discard mgr.execute(ex, cmdAddNode(int32(i), 0, 0.0f, 0.0f))
    check mgr.maxSteps() == 2
    check mgr.undoLen() == 2

  test "setMaxSteps подрезает живой стек":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(8)
    for i in 0 ..< 4:
      discard mgr.execute(ex, cmdAddNode(int32(i), 0, 0.0f, 0.0f))
    check mgr.undoLen() == 4
    mgr.setMaxSteps(1)
    check mgr.undoLen() == 1

  test "clear полностью сбрасывает менеджер":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(8)
    discard mgr.execute(ex, cmdAddNode(1, 0, 0.0f, 0.0f))
    check mgr.undo(ex)
    mgr.clear()
    check not mgr.canUndo()
    check not mgr.canRedo()
    check mgr.groupDepth() == 0

suite "undo_redo: группы":
  test "группа — один undo-шаг":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(16)

    mgr.beginGroup("Move cluster")
    check mgr.isGrouping()
    check mgr.groupDepth() == 1
    check mgr.execute(ex, cmdMoveNode(1, 0.0f, 0.0f, 5.0f, 6.0f))
    check mgr.execute(ex, cmdMoveNode(2, 0.0f, 0.0f, 7.0f, 8.0f))
    check mgr.endGroup()

    check not mgr.isGrouping()
    check mgr.undoLen() == 1                 # вся группа — один шаг
    check mgr.undoDescription().get() == "Move cluster"

    check mgr.undo(ex)
    check c.undone == 2

  test "пустая группа не создаёт шаг":
    let ex = makeExecutor(Counter())
    var mgr = initUndoRedoManager(16)
    mgr.beginGroup("empty")
    check mgr.endGroup()
    check mgr.undoLen() == 0

  test "endGroup без begin возвращает false":
    let ex = makeExecutor(Counter())
    var mgr = initUndoRedoManager(16)
    check not mgr.endGroup()

  test "undo/redo внутри незакрытой группы запрещены":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(16)

    discard mgr.execute(ex, cmdAddNode(1, 0, 0.0f, 0.0f))
    mgr.beginGroup("g")
    check not mgr.undo(ex)
    check not mgr.redo(ex)
    discard mgr.endGroup()
    check mgr.undo(ex)

  test "вложенные группы сворачиваются в один шаг, undo идёт в обратном порядке":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(16)

    mgr.beginGroup("outer")
    discard mgr.execute(ex, cmdAddNode(1, 0, 0.0f, 0.0f))
    mgr.beginGroup("inner")
    discard mgr.execute(ex, cmdAddNode(2, 0, 0.0f, 0.0f))
    discard mgr.execute(ex, cmdAddNode(3, 0, 0.0f, 0.0f))
    discard mgr.endGroup()
    discard mgr.execute(ex, cmdAddNode(4, 0, 0.0f, 0.0f))
    discard mgr.endGroup()

    check mgr.undoLen() == 1
    check mgr.undoDescription().get() == "outer"

    check mgr.undo(ex)
    check c.undoOrder == @[4'i32, 3'i32, 2'i32, 1'i32]

  test "groupDepth для нескольких открытых групп":
    let ex = makeExecutor(Counter())
    var mgr = initUndoRedoManager(16)
    mgr.beginGroup("a")
    mgr.beginGroup("b")
    check mgr.groupDepth() == 2
    discard mgr.endGroup()
    check mgr.groupDepth() == 1
    discard mgr.endGroup()
    check mgr.groupDepth() == 0


suite "undo_redo: persistence":
  test "save/load сохраняет стеки и структуру групп":
    let c = Counter()
    let ex = makeExecutor(c)
    var mgr = initUndoRedoManager(16)
    discard mgr.execute(ex, cmdAddNode(1, 0, 1.0f, 2.0f))
    mgr.beginGroup("group")
    discard mgr.execute(ex, cmdAddNote(1, 1, 0, 100, 60, 100))
    discard mgr.execute(ex, cmdAddNote(1, 1, 200, 100, 62, 100))
    discard mgr.endGroup()
    discard mgr.execute(ex, cmdMoveNode(7, 0.0f, 0.0f, 5.0f, 6.0f))

    let path = getTempDir() / "euterpia_undo_history.json"
    check mgr.saveUndoHistory(path)
    defer: removeFile(path)

    var restored = initUndoRedoManager(16)
    check restored.loadUndoHistory(path)
    check restored.undoLen() == mgr.undoLen()
    check restored.undoDescription().get() == mgr.undoDescription().get()

    # Порядок и структура проверяются откатом: группа должна свернуться
    # в один шаг, а внутри неё undo идёт справа налево.
    let c2 = Counter()
    let ex2 = makeExecutor(c2)
    while restored.canUndo():
      discard restored.undo(ex2)
    # nodeId исходных команд: 1 (AddNode), 0 (AddNote), 0 (AddNote), 7 (MoveNode).
    # Группа откатывается как один шаг, значит порядок: 7, 0, 0, 1.
    check c2.undoOrder == @[7'i32, 0'i32, 0'i32, 1'i32]

  test "load после setMaxSteps применяет лимит":
    let ex = makeExecutor(Counter())
    var mgr = initUndoRedoManager(16)
    for i in 0 ..< 5:
      discard mgr.execute(ex, cmdAddNode(int32(i), 0, 0.0f, 0.0f))
    let path = getTempDir() / "euterpia_undo_limit.json"
    check mgr.saveUndoHistory(path)
    defer: removeFile(path)

    var restored = initUndoRedoManager(2)
    check restored.loadUndoHistory(path)
    check restored.undoLen() == 2

  test "loadUndoHistory: отсутствующий файл и битый JSON -> false":
    var mgr = initUndoRedoManager(4)
    check not mgr.loadUndoHistory(getTempDir() / "euterpia_undo_missing.json")

    let bad = getTempDir() / "euterpia_undo_bad.json"
    writeFile(bad, "не json")
    defer: removeFile(bad)
    check not mgr.loadUndoHistory(bad)

  test "loadUndoHistory: более новая версия отвергается":
    let path = getTempDir() / "euterpia_undo_future.json"
    writeFile(path, """{"version":999,"undoStack":[],"redoStack":[]}""")
    defer: removeFile(path)
    var mgr = initUndoRedoManager(4)
    check not mgr.loadUndoHistory(path)

  test "loadUndoHistory понимает старый формат data/children":
    let path = getTempDir() / "euterpia_undo_old.json"
    # type 0 == ctAddNode (команда), type 10 == ctRemoveNote.
    writeFile(path, """{"version":1,"redoStack":[],"undoStack":[
      {"data":{"type":0,"description":"old cmd","nodeId":3}},
      {"data":{"type":0,"description":"old group","nodeId":9},
       "children":[{"type":10,"description":"child","nodeId":4}]}
    ]}""")
    defer: removeFile(path)
    var mgr = initUndoRedoManager(16)
    check mgr.loadUndoHistory(path)
    check mgr.undoLen() == 2

    # Второй элемент — группа (имеет children).
    let c = Counter()
    let ex = makeExecutor(c)
    check mgr.undo(ex)                 # откатываем группу из хвоста
    check c.undone == 1

