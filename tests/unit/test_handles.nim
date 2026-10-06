# tests/unit/test_handles.nim
#
# Handles — стабильные адреса сущностей документа (issue #143, MANIFEST §35/§36).
#
# Что проверяется:
#   - handle — значение, а не указатель: копия равна оригиналу, текст адреса
#     разбирается обратно (короткая и полная формы);
#   - handle переживает N пересборок графа: вставки и удаления ДРУГИХ нод не
#     трогают его, а после пересборки из файла адрес тот же самый;
#   - ABA: слот переиспользовали — старый handle отвергается (heStale);
#   - двойное удаление отвергается (heReleased), а не проходит «успешно»;
#   - чужой документ (heForeignDocument) и «не тот вид» (heKindMismatch) —
#     разные коды, а не молчаливый ответ;
#   - вложенная адресация «подграф → компонент → параметр» и «дорожка → клип»;
#   - проекция формата проекта: слот = id из файла, чужой id → heNoEntity.

import std/unittest
import project
import handles

const
  DocA = 0xA1B2C3D4'u32
  DocB = 0x0BADF00D'u32

proc newTable(docId: uint32 = DocA): HandleTable =
  var tbl: HandleTable
  discard initHandleTable(tbl, docId)
  tbl

proc sampleProject(): ProjectFormat =
  ## Проект-эталон: id нод разреженные (1, 2, 5) — так адрес слота и видна
  ## разница между «порядком в файле» и «id», из которого строится handle.
  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.graph.nodes = @[
    NodeFormat(id: 1, nodeType: "fx.gain", name: "Gain"),
    NodeFormat(id: 2, nodeType: "osc.osc", name: "Osc"),
    NodeFormat(id: 5, nodeType: "mix.mix", name: "Sum"),
  ]
  var track = TrackFormat(id: 1, name: "Drums")
  track.clips = @[
    ClipFormat(id: 1, name: "A", startTick: 0, lengthTicks: 480),
    ClipFormat(id: 2, name: "B", startTick: 480, lengthTicks: 480),
  ]
  result.sequencer.tracks = @[track]

# =============================================================================
# Handle как значение
# =============================================================================

suite "handles: значение и текст":
  test "handle — значение: копия равна оригиналу, размер фиксирован":
    var tbl = newTable()
    let h = tbl.acquireHandle(hkNode, 7'u64)
    check h.isValidHandle()
    # POD без указателей: размер одинаков при любом порядке полей и не растёт
    # при добавлении сущностей — это то, ради чего handle можно хранить.
    check sizeof(EntityHandle) == 16
    let copy = h
    check handleEquals(copy, h)
    check copy.slot == h.slot
    check copy.generation == h.generation
    for i in 0 ..< 500:
      discard tbl.acquireHandle(hkNode, uint64(100 + i))
    check sizeof(EntityHandle) == 16

  test "нулевой handle недействителен и печатается честно":
    check not EntityHandle().isValidHandle()
    check invalidHandle().handleToText() == "handle:none"
    check invalidHandle().handleToTextQualified() == "handle:none"
    var tbl = newTable()
    var zero: EntityHandle
    check tbl.entityOf(zero).error == heInvalid

  test "текст адреса разбирается обратно, короткие синонимы тоже":
    var tbl = newTable()
    let h = tbl.acquireHandle(hkTrack, 3'u64)
    check h.handleToText() == "track:0.1"
    var parsed: EntityHandle
    check parseHandleText("track:0.1", parsed) == heOk
    check parsed.kind == hkTrack
    check parsed.slot == h.slot
    check parsed.generation == h.generation
    check parseHandleText("t:0.1", parsed) == heOk
    check parsed.kind == hkTrack
    check parseHandleText("TRACK:0.1", parsed) == heOk
    check parsed.kind == hkTrack

  test "слот 0 — законный адрес первой сущности":
    var tbl = newTable()
    let first = tbl.acquireHandle(hkNode, 1'u64)
    check first.slot == 0'u32
    check first.handleToText() == "node:0.1"
    var parsed: EntityHandle
    check parseHandleText("node:0.1", parsed) == heOk
    check parsed.slot == 0'u32

  test "мусорный адрес отвергается, а не угадывается":
    var parsed: EntityHandle
    let bad = ["", "node", "node:", "node:1", "node:x.1", "node:1.x",
               "node:0.0", "node:1.0", "вертикол",
               "node:1.1@", "node:1.1@zz", "@a1b2c3d4"]
    for text in bad:
      check parseHandleText(text, parsed) == heInvalid
    # Полная форма проверяет суффикс отдельно от тела адреса.
    for text in ["node:1.1@", "node:1.1@zz", "@a1b2c3d4", "node:1.1@123456789"]:
      check parseHandleTextQualified(text, parsed) == heInvalid

  test "полная форма адреса несёт документ и разбирается обратно":
    var tbl = newTable()
    let h = tbl.acquireHandle(hkNode, 1'u64)
    let text = h.handleToTextQualified()
    check text == "node:0.1@a1b2c3d4"
    var parsed: EntityHandle
    check parseHandleTextQualified(text, parsed) == heOk
    check parsed.docId == DocA
    check parsed.kind == hkNode
    check parsed.generation == h.generation
    # Короткая форма документ не задаёт: его подставляет владелец.
    check parseHandleText("node:0.1", parsed) == heOk
    check parsed.docId == 0'u32

  test "идентификатор документа стабилен и ненулевой":
    let first = documentIdForPath("/home/u/demo.eut")
    check first == documentIdForPath("/home/u/demo.eut")
    check first != documentIdForPath("/home/u/other.eut")
    check first != 0'u32
    check docIdText(first).len == 8

# =============================================================================
# Стабильность при пересборках графа
# =============================================================================

suite "handles: стабильность при пересборках графа":
  test "handle переживает N пересборок: вставки и удаления других нод":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    let gain = tbl.nodeHandle(1)
    check gain.handleToText() == "node:1.1"
    check tbl.resolveAs(gain, hkNode).entityId == 1'u64

    # 300 циклов: в начало графа вставляются и удаляются ЧУЖИЕ ноды.
    # Адрес ноды #1 не должен поехать ни на текст, ни на сущность.
    for i in 0 ..< 300:
      let temp = tbl.acquireHandleAt(hkNode, uint32(1000 + i), uint64(1000 + i))
      check temp.isValidHandle()
      let freed = tbl.acquireHandleAt(hkNode, uint32(2000 + i), uint64(2000 + i))
      check tbl.releaseHandle(freed) == heOk
      check gain.handleToText() == "node:1.1"
      let resolved = tbl.resolveAs(gain, hkNode)
      check resolved.ok
      check resolved.entityId == 1'u64

  test "адрес из файла детерминирован: пересборка даёт тот же текст":
    ## Тот же сценарий, что у CLI: таблица строится заново на каждый запуск,
    ## поэтому handle должен печататься одинаково при одинаковом содержимом.
    var firstText = ""
    for rebuild in 0 ..< 50:
      var tbl = newTable()
      var proj = sampleProject()
      proj.graph.nodes.add NodeFormat(id: 6, nodeType: "fx.gain", name: "Late")
      check openProjectHandles(tbl, proj) == heOk
      let text = tbl.nodeHandle(1).handleToText() &
                " " & tbl.nodeHandle(6).handleToText()
      if rebuild == 0:
        firstText = text
      check text == firstText
      check text == "node:1.1 node:6.1"

  test "удалённая сущность больше не отвечает, повторное удаление отвергается":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    let osc = tbl.nodeHandle(2)
    check tbl.releaseHandle(osc) == heOk
    let resolved = tbl.entityOf(osc)
    check not resolved.ok
    check resolved.error == heReleased
    check tbl.releaseHandle(osc) == heReleased
    check tbl.nodeHandle(2).isValidHandle() == false

# =============================================================================
# ABA, чужие документы и виды
# =============================================================================

suite "handles: ABA, чужой документ, чужой вид":
  test "ABA: переиспользованный слот не отвечает старому handle":
    var tbl = newTable()
    let first = tbl.acquireHandle(hkNode, 1'u64)
    check first.slot == 0'u32
    check tbl.releaseHandle(first) == heOk
    let second = tbl.acquireHandle(hkNode, 2'u64)
    check second.slot == first.slot          # слот тот же…
    check second.generation == first.generation + 1'u32
    check tbl.entityOf(first).error == heStale    # …а handle старый
    check tbl.entityOf(second).entityId == 2'u64
    check tbl.releaseHandle(first) == heStale

  test "пересобранный документ: удалённая нода больше не адресуется":
    ## Таблица строится из файла заново на каждый запуск CLI, поэтому поколения
    ## в ней начинаются с единицы. Гарантия тут не «handle переживает удаление
    ## (это делает сессия, см. тест выше)», а обратная: адрес, напечатанный для
    ## существующей сущности, после пересборки указывает на ту же сущность, а
    ## адрес удалённой — не указывает ни на что.
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    let gain = tbl.nodeHandle(1)
    let osc = tbl.nodeHandle(2)
    check osc.isValidHandle()

    var proj = sampleProject()
    # Остаются #1 и #5 (и в файле они теперь стоят рядом), а ноды #2 нет:
    # пересборка не «чинит» порядок — адрес задаётся id, а не позицией.
    proj.graph.nodes = @[proj.graph.nodes[0], proj.graph.nodes[2]]
    var rebuilt = newTable()
    check openProjectHandles(rebuilt, proj) == heOk
    check rebuilt.nodeHandle(1).handleToText() == gain.handleToText()
    check rebuilt.nodeHandle(5).handleToText() == "node:5.1"
    check rebuilt.nodeHandle(2).isValidHandle() == false
    check rebuilt.requireHandle(hkNode, 2'u64).error == heNoEntity

  test "handle чужого документа отвергается, даже если слот совпал":
    var a = newTable(DocA)
    var b = newTable(DocB)
    discard a.acquireHandleAt(hkNode, 3'u32, 3'u64)
    discard b.acquireHandleAt(hkNode, 3'u32, 3'u64)
    let fromA = a.nodeHandle(3)
    let fromB = b.nodeHandle(3)
    check fromA.docId == DocA
    check fromB.docId == DocB
    check b.entityOf(fromA).error == heForeignDocument
    check b.releaseHandle(fromA) == heForeignDocument
    check a.entityOf(fromB).error == heForeignDocument
    check a.entityOf(fromA).ok

  test "связывание пользовательского адреса сверяет документ":
    var a = newTable(DocA)
    var b = newTable(DocB)
    discard a.acquireHandleAt(hkNode, 3'u32, 3'u64)
    let text = a.nodeHandle(3).handleToTextQualified()
    var h: EntityHandle
    check a.bindHandleText(text, h) == heOk
    check h.docId == DocA
    check b.bindHandleText(text, h) == heForeignDocument
    # Короткая форма привязывается к тому документу, в котором разбирается.
    check b.bindHandleText("node:3.1", h) == heOk
    check h.docId == DocB

  test "не тот вид сущности — отдельный код, а не молчаливый ответ":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    let gain = tbl.nodeHandle(1)
    check tbl.resolveAs(gain, hkParam).error == heKindMismatch
    check tbl.resolveAs(gain, hkNode).ok
    # Подделанный вид в самом handle тоже не проходит: у параметров свой
    # слот, и номер ноды в нём ничего не значит.
    var forged = gain
    forged.kind = hkParam
    check not tbl.entityOf(forged).ok
    var paramSlot = tbl.acquireHandle(hkParam, 1'u64)
    check paramSlot.slot == 0'u32
    check tbl.resolveAs(paramSlot, hkNode).error == heKindMismatch

  test "таблица без документа и без инициализации отказывает честно":
    var empty: HandleTable
    check initHandleTable(empty, 0'u32) == heInvalid
    check empty.docId == 0'u32
    check openProjectHandles(empty, sampleProject()) == heInvalid
    check empty.acquireHandle(hkNode, 1'u64).isValidHandle() == false
    var h: EntityHandle
    check empty.bindHandleText("node:1.1", h) == heInvalid

# =============================================================================
# Вложенная адресация и проекция формата проекта
# =============================================================================

suite "handles: вложенная адресация":
  test "путь «подграф → компонент → параметр» печатается и разбирается":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    let owner = tbl.nodeHandle(5)

    let simple = tbl.nodeParamRef(5, 2'u32)
    check simple.isValidNested()
    check nestedToText(simple) == "node:5.1/param:2"

    let deep = tbl.nodeComponentParamRef(5, 1'u32, 0'u32)
    check nestedToText(deep) == "node:5.1/component:1/param:0"

    let component = componentRef(owner, 3'u32)
    check nestedToText(component) == "node:5.1/component:3"

    let clip = tbl.trackClipRef(1, 1'u32)
    check nestedToText(clip) == "track:1.1/clip:1"

    # Разбор обратно даёт ровно тот же путь: форма однозначна.
    for text in ["node:5.1/param:2", "node:5.1/component:1/param:0",
                 "node:5.1/component:3", "track:1.1/clip:1"]:
      var parsed: NestedRef
      check bindNestedText(tbl, text, parsed) == heOk
      check parsed.isValidNested()
      var rebound: NestedRef
      check bindNestedText(tbl, nestedToText(parsed), rebound) == heOk
      check nestedToText(rebound) == text

  test "путь разрешается, пока владелец жив, и отказывается после его удаления":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    let ref2 = tbl.nodeParamRef(5, 2'u32)
    let resolved = tbl.resolveNested(ref2)
    check resolved.ok
    check resolved.ownerId == 5'u64
    check resolved.index == 2'u32

    check tbl.releaseHandle(tbl.nodeHandle(5)) == heOk
    let afterDelete = tbl.resolveNested(ref2)
    check not afterDelete.ok
    check afterDelete.error == heReleased

  test "кривые пути отвергаются, а не обрезаются":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    var parsed: NestedRef
    # Без шага после владельца — это ещё не вложенная сущность.
    check bindNestedText(tbl, "node:5.1", parsed) == heBadPath
    check bindNestedText(tbl, "node:5.1/param", parsed) == heBadPath
    check bindNestedText(tbl, "node:5.1/param:", parsed) == heBadPath
    check bindNestedText(tbl, "node:5.1/param:x", parsed) == heBadPath
    # Смешивать виды в одном пути нельзя: это две разные сущности.
    check bindNestedText(tbl, "node:5.1/param:1/param:2", parsed) == heBadPath
    check bindNestedText(tbl, "node:5.1/clip:0/param:1", parsed) == heBadPath
    # Владелец неизвестного вида — не вложенная сущность.
    check bindNestedText(tbl, "node:5.1/node:2", parsed) == heBadPath
    check not parsed.isValidNested()
    check nestedToText(parsed) == "handle:none"
    # Глубже MaxNestedDepth не принимается.
    check bindNestedText(tbl, "node:5.1/" & "component:0/" &
                            "component:0/component:0/component:0/" &
                            "component:0/component:0/component:0/" &
                            "component:0/component:0", parsed) == heBadPath

  test "путь из чужого документа не применяется":
    var a = newTable(DocA)
    var b = newTable(DocB)
    check openProjectHandles(a, sampleProject()) == heOk
    check openProjectHandles(b, sampleProject()) == heOk
    let text = a.nodeParamRef(5, 1'u32).nestedToTextQualified()
    check text == "node:5.1/param:1@a1b2c3d4"
    var parsed: NestedRef
    check a.bindNestedText(text, parsed) == heOk
    check b.bindNestedText(text, parsed) == heForeignDocument
    check b.bindNestedText("node:5.1/param:1", parsed) == heOk
    check parsed.owner.docId == DocB

suite "handles: проекция формата проекта":
  test "слот = id из файла: адрес ноды не зависит от её места в графе":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    check tbl.liveHandleCount() == 4   # 3 ноды + дорожка (клипы адресуются вложенно)
    check tbl.nodeHandle(1).handleToText() == "node:1.1"
    check tbl.nodeHandle(2).handleToText() == "node:2.1"
    check tbl.nodeHandle(5).handleToText() == "node:5.1"
    check tbl.trackHandle(1).handleToText() == "track:1.1"
    check tbl.nodeHandle(0).isValidHandle() == false
    check tbl.trackHandle(0).isValidHandle() == false
    # Клипы слота не имеют: их id уникальны только внутри дорожки, поэтому
    # размещение адресуется вложенно — «клип №N на дорожке».
    check tbl.slotCount(hkClip) == 0
    check tbl.clipHandle(1).isValidHandle() == false
    check nestedToText(tbl.trackClipRef(1, 1'u32)) == "track:1.1/clip:1"

  test "поиск по id и постой выход для чужого id":
    var tbl = newTable()
    check openProjectHandles(tbl, sampleProject()) == heOk
    let byId = tbl.findHandle(hkNode, 5'u64)
    check byId.isValidHandle()
    check byId.slot == 5'u32
    check tbl.hasEntity(hkNode, 5'u64)
    check not tbl.hasEntity(hkNode, 4'u64)
    let missing = tbl.requireHandle(hkNode, 4'u64)
    check not missing.ok
    check missing.error == heNoEntity
    check missing.handle.isValidHandle() == false

  test "дубль id в файле — ошибка проекции, но остальные адреса живы":
    var tbl = newTable()
    var proj = sampleProject()
    proj.graph.nodes.add NodeFormat(id: 1, nodeType: "fx.gain", name: "Copy")
    check openProjectHandles(tbl, proj) == heSlotOccupied
    # Одна сломанная нода не должна лишать адресов весь документ.
    check tbl.nodeHandle(2).isValidHandle()
    check tbl.nodeHandle(5).isValidHandle()
    check tbl.trackHandle(1).isValidHandle()
    # И повторный вызов не «чинит» файл молча: дубль виден снова.
    var twice = newTable()
    discard openProjectHandles(twice, proj)
    check openProjectHandles(twice, proj) == heSlotOccupied

  test "id не из файла (ноль, отрицательный) не адресуется":
    var tbl = newTable()
    var proj = sampleProject()
    proj.graph.nodes = @[NodeFormat(id: 0, nodeType: "fx.gain", name: "Bad"),
                         NodeFormat(id: -3, nodeType: "fx.gain", name: "Worse")]
    proj.sequencer.tracks.setLen(0)
    check openProjectHandles(tbl, proj) == heOk
    check tbl.liveHandleCount() == 0
    check tbl.slotCount(hkNode) == 0
