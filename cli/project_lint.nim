# cli/project_lint.nim
#
# Строгий lint проекта для `project validate --strict` (issue #339).
#
# Зачем отдельно от `validate`:
#   `validate` отвечает на вопрос «файл корректен?» — формат, версия,
#   значения, которые ломают загрузку. Он НЕ отвечает на вопрос «проект
#   в порядке?»: нода без входа, дорожка без клипов, ресурс, на который
#   никто не ссылается, клип, ссылающийся на удалённый файл, дубль id в
#   коллекции — всё это читается, но приводит к тихим ошибкам на рендере.
#
# Границы (§20, §63):
#   ЗДЕСЬ — только чтение модели через Query API и сборка находок с АДРЕСОМ
#   сущности. Ни движка, ни компилятора, ни записи: `project validate`
#   обязан работать без аудиоустройства и плагинов (#89).
#   Циклы графа НЕ проверяются здесь: их находит компилятор (`graph check`,
#   gvCycle). Дублировать компиляцию в валидаторе значило бы держать две
#   правды о графе; `ci check` запускает `graph check` отдельным шагом.
#
# Уровни (§339):
#   `fail` — проект заведомо неработоспособен (висячая ссылка, дубль id);
#   `warn` — проиграется, но не так, как записано (нота за границей клипа,
#   уровень вне диапазона);
#   `note` — «на заметку»: возможно, так и задумано (неиспользуемая нода,
#   дорожка без клипов), но повод посмотреть.
#   Код возврата `validate` меняет только `fail` — как и раньше.

import std/[json, strutils, tables]

import checks
import control/document
import control/query

proc addrNode(id: int): string =
  "node:" & $id

proc addrTrack(id: int32): string =
  "track:" & $id

proc addrClip(track, clip: int32): string =
  "track:" & $track & "/clip:" & $clip

proc addrLane(nodeId: int32; paramId: uint32): string =
  "lane:" & $nodeId & ":" & $int(paramId)

proc addrResource(id: int32): string =
  "resource:" & $id

proc jsonList(values: seq[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add %value

proc lintReferences(doc: Document): Section =
  ## Висячие ссылки: клип → ресурс, линия автоматизации → нода и параметр.
  ## Связи графа проверяет `validate` (секция `graph`), состояния плагинов —
  ## секция `plugins`; здесь только то, чего там нет.
  result.id = "lint-references"
  result.title = "lint: висячие ссылки"

  let nodes = doc.queryNodes().nodes
  var byId = initTable[int, NodeInfo]()
  for node in nodes:
    byId[node.id] = node

  var resourceIds: seq[int32] = @[]
  for resource in doc.queryResources():
    resourceIds.add resource.id

  var danglingClips: seq[string] = @[]
  var emptyClips: seq[string] = @[]
  for track in doc.queryTracks():
    for clip in track.clips:
      if clip.resourceId >= 0 and clip.resourceId notin resourceIds:
        danglingClips.add addrClip(track.id, clip.id) &
          " → ресурс " & $clip.resourceId
      if clip.resourceId < 0 and clip.notes == 0:
        emptyClips.add addrClip(track.id, clip.id)

  var unknownNodes: seq[string] = @[]
  var unknownParams: seq[string] = @[]
  for lane in doc.queryAutomationLanes():
    let address = addrLane(lane.nodeId, lane.paramId)
    if int(lane.nodeId) notin byId:
      unknownNodes.add address
      continue
    var found = false
    for param in byId[int(lane.nodeId)].params:
      if param.index == int(lane.paramId):
        found = true
        break
    if not found:
      unknownParams.add address

  var lines: seq[string] = @[
    "клипов: " & $doc.querySummary().clips,
    "линий автоматизации: " & $doc.queryAutomationLanes().len,
  ]
  for item in danglingClips:
    lines.add "клип ссылается на отсутствующий ресурс: " & item
  for item in unknownNodes:
    lines.add "линия автоматизации ссылается на отсутствующую ноду: " & item
  for item in unknownParams:
    lines.add "у ноды нет параметра с таким id: " & item
  if emptyClips.len > 0:
    lines.add "клипов без нот и без аудио: " & $emptyClips.len

  result.checks.add mkCheck("resolved",
    "ссылки клипов и автоматизации разрешаются",
    (if danglingClips.len > 0 or unknownNodes.len > 0: csFail
     elif unknownParams.len > 0: csWarn
     elif emptyClips.len > 0: csNote
     else: csOk),
    lines = lines,
    advice = (if danglingClips.len > 0:
                "импортируйте файл заново (`import`) или удалите клип: " &
                  "на отсутствующий ресурс рендер не откроется"
              elif unknownNodes.len > 0:
                "линия ссылается на ноду, которой нет: удалите её или " &
                  "восстановите ноду"
              elif unknownParams.len > 0:
                "параметр мог быть переименован: пересоздайте линию " &
                  "(`automation add`)"
              elif emptyClips.len > 0:
                "пустой клип ничего не играет — так бывает после правки нот"
              else: ""),
    body = %*{
      "danglingResources": jsonList(danglingClips),
      "unknownNodes": jsonList(unknownNodes),
      "unknownParams": jsonList(unknownParams),
      "emptyClips": jsonList(emptyClips),
    })

proc lintDuplicates(doc: Document): Section =
  ## Дубли идентификаторов: клип внутри дорожки, ресурс, линия автоматизации,
  ## связь. Дубли нод и дорожек проверяет `validate` — здесь только те
  ## коллекции, до которых он не доходит.
  result.id = "lint-duplicates"
  result.title = "lint: дубли идентификаторов"

  var clipDuplicates: seq[string] = @[]
  for track in doc.queryTracks():
    var seen: seq[int32] = @[]
    for clip in track.clips:
      if clip.id in seen:
        clipDuplicates.add addrClip(track.id, clip.id)
      seen.add clip.id

  var resourceDuplicates: seq[string] = @[]
  var seenResources: seq[int32] = @[]
  for resource in doc.queryResources():
    if resource.id in seenResources:
      resourceDuplicates.add addrResource(resource.id)
    seenResources.add resource.id

  var laneDuplicates: seq[string] = @[]
  var seenLanes: seq[string] = @[]
  for lane in doc.queryAutomationLanes():
    let address = addrLane(lane.nodeId, lane.paramId)
    if address in seenLanes:
      laneDuplicates.add address
    seenLanes.add address

  var connectionDuplicates: seq[string] = @[]
  var seenConnections: seq[string] = @[]
  for conn in doc.queryConnections():
    let address = "connection:" & $conn.srcNodeId & ":" & $conn.sigType & ":" &
                  $conn.srcPortIdx & "->" & $conn.dstNodeId & ":" &
                  $conn.sigType & ":" & $conn.dstPortIdx
    if address in seenConnections:
      connectionDuplicates.add address
    seenConnections.add address

  var lines: seq[string] = @[
    "клипов: " & $doc.querySummary().clips,
    "ресурсов: " & $doc.queryResources().len,
    "связей: " & $doc.queryConnections().len,
  ]
  for item in clipDuplicates:
    lines.add "повтор id клипа на дорожке: " & item
  for item in resourceDuplicates:
    lines.add "повтор id ресурса: " & item
  for item in laneDuplicates:
    lines.add "две линии на один параметр: " & item
  for item in connectionDuplicates:
    lines.add "повтор связи: " & item

  result.checks.add mkCheck("unique", "идентификаторы коллекций уникальны",
    (if clipDuplicates.len > 0 or resourceDuplicates.len > 0 or
        laneDuplicates.len > 0: csFail
     elif connectionDuplicates.len > 0: csWarn
     else: csOk),
    lines = lines,
    advice = (if clipDuplicates.len > 0 or resourceDuplicates.len > 0 or
                 laneDuplicates.len > 0:
                "повтор id делает выбор сущности неоднозначным: " &
                  "адрес должен указывать на одну вещь"
              elif connectionDuplicates.len > 0:
                "две одинаковые связи не меняют звук, но путают счётчики"
              else: ""),
    body = %*{
      "clips": jsonList(clipDuplicates),
      "resources": jsonList(resourceDuplicates),
      "lanes": jsonList(laneDuplicates),
      "connections": jsonList(connectionDuplicates),
    })

proc lintUnused(doc: Document): Section =
  ## Неиспользуемое: нода без связей, дорожка без клипов, ресурс, на который
  ## никто не ссылается. Это «на заметку», а не предупреждение: заготовка
  ## ноды и пустая дорожка — законное состояние работы.
  result.id = "lint-unused"
  result.title = "lint: неиспользуемое"

  var lonelyNodes: seq[string] = @[]
  for node in doc.queryNodes().nodes:
    if node.connections == 0:
      lonelyNodes.add addrNode(node.id) &
        (if node.name.len > 0: " «" & node.name & "»" else: "")

  var emptyTracks: seq[string] = @[]
  for track in doc.queryTracks():
    if track.clips.len == 0:
      emptyTracks.add addrTrack(track.id)

  var usedResources: seq[int32] = @[]
  for track in doc.queryTracks():
    for clip in track.clips:
      if clip.resourceId >= 0 and clip.resourceId notin usedResources:
        usedResources.add clip.resourceId
  var unusedResources: seq[string] = @[]
  for resource in doc.queryResources():
    if resource.id notin usedResources:
      unusedResources.add addrResource(resource.id) & " «" & resource.path & "»"

  var lines: seq[string] = @[
    "нод: " & $doc.queryNodes().nodes.len,
    "дорожек: " & $doc.queryTracks().len,
    "ресурсов: " & $doc.queryResources().len,
  ]
  for item in lonelyNodes:
    lines.add "нода без связей: " & item
  for item in emptyTracks:
    lines.add "дорожка без клипов: " & item
  for item in unusedResources:
    lines.add "ресурс не используется: " & item

  result.checks.add mkCheck("reachable", "всё содержимое используется",
    (if lonelyNodes.len > 0 or emptyTracks.len > 0 or
        unusedResources.len > 0: csNote
     else: csOk),
    lines = lines,
    advice = (if lonelyNodes.len > 0 or emptyTracks.len > 0 or
                 unusedResources.len > 0:
                "если это не заготовка — удалите лишнее, иначе проект " &
                  "путает счётчики и переносимый архив"
              else: ""),
    body = %*{
      "nodes": jsonList(lonelyNodes),
      "tracks": jsonList(emptyTracks),
      "resources": jsonList(unusedResources),
    })


proc lintRanges(doc: Document): Section =
  ## Значения вне разумного диапазона: уровень/панорама дорожки, вход и
  ## выход шины, нота за границей клипа. `validate` проверяет то, что ломает
  ## загрузку (тики, длины); здесь — то, что звучит не так, как записано.
  result.id = "lint-ranges"
  result.title = "lint: значения в диапазоне"

  var outOfRange: seq[string] = @[]
  var silentNotes: seq[string] = @[]
  var outsideClip: seq[string] = @[]
  for track in doc.queryTracks():
    if track.volume < 0.0f or track.volume > 2.0f:
      outOfRange.add addrTrack(track.id) & ".volume = " & $track.volume
    if track.pan < -1.0f or track.pan > 1.0f:
      outOfRange.add addrTrack(track.id) & ".pan = " & $track.pan
    if track.inputChannel < 0:
      outOfRange.add addrTrack(track.id) & ".inputChannel = " & $track.inputChannel
    if track.outputBus < 0:
      outOfRange.add addrTrack(track.id) & ".outputBus = " & $track.outputBus
    for clipIndex in 0 ..< track.clips.len:
      let clip = track.clips[clipIndex]
      let notes = doc.queryNotes(track.id, clipIndex)
      if not notes.ok:
        continue
      for note in notes.notes:
        let address = addrClip(track.id, clip.id) & "/note:" &
                      $note.startTick & ":" & $int(note.pitch) & ":" &
                      $int(note.channel)
        if note.velocity == 0:
          silentNotes.add address
        if clip.lengthTicks > 0 and
           int(note.startTick) + int(note.duration) > int(clip.lengthTicks):
          outsideClip.add address

  var lines: seq[string] = @[
    "дорожек: " & $doc.queryTracks().len,
    "нот: " & $doc.querySummary().notes,
  ]
  for item in outOfRange:
    lines.add "вне диапазона: " & item
  for item in outsideClip:
    lines.add "нота выходит за границу клипа: " & item
  for item in silentNotes:
    lines.add "нота с нулевой силой звука: " & item

  result.checks.add mkCheck("values", "значения дорожек и нот осмысленны",
    (if outOfRange.len > 0 or outsideClip.len > 0: csWarn
     elif silentNotes.len > 0: csNote
     else: csOk),
    lines = lines,
    advice = (if outOfRange.len > 0:
                "уровень 0…2, панорама −1…1, каналы и шины ≥ 0: " &
                  "проверьте значения после импорта"
              elif outsideClip.len > 0:
                "нота короче записанной: увеличьте длину клипа или " &
                  "сократите ноту"
              elif silentNotes.len > 0:
                "нота с velocity 0 не звучит — так бывает после правки"
              else: ""),
    body = %*{
      "outOfRange": jsonList(outOfRange),
      "outsideClip": jsonList(outsideClip),
      "silentNotes": jsonList(silentNotes),
    })

proc lintTypes(doc: Document): Section =
  ## Типы нод: зарегистрирован ли тип в этой сборке. Незарегистрированный тип
  ## — «на заметку», а не провал: `plugin:<id>` регистрируется при рендере
  ## (плагин загружается по пути из проекта), и валидатор без плагинов не
  ## имеет права объявлять такой проект сломанным.
  result.id = "lint-types"
  result.title = "lint: типы нод"

  var unknown: seq[string] = @[]
  var pluginNodes = 0
  for node in doc.queryNodes().nodes:
    if node.nodeType.startsWith("plugin:"):
      inc pluginNodes
      continue
    if not node.known:
      unknown.add addrNode(node.id) & " «" & node.nodeType & "»"

  var lines: seq[string] = @[
    "нод: " & $doc.queryNodes().nodes.len,
    "нод плагинов: " & $pluginNodes,
  ]
  for item in unknown:
    lines.add "тип не зарегистрирован: " & item

  result.checks.add mkCheck("known", "типы нод известны сборке",
    (if unknown.len > 0: csNote else: csOk),
    lines = lines,
    advice = (if unknown.len > 0:
                "тип появится после подключения плагина или обновления " &
                  "сборки; до этого рендер откажет `unknown node type`"
              else: ""),
    body = %*{"unknown": jsonList(unknown), "plugins": pluginNodes})

proc lintSections*(doc: Document): seq[Section] =
  ## Все секции строгого отчёта в фиксированном порядке. Порядок — часть
  ## контракта `--json`: агент читает секции по id, а человек — сверху вниз,
  ## от «сломано» к «на заметку».
  @[
    lintReferences(doc),
    lintDuplicates(doc),
    lintRanges(doc),
    lintUnused(doc),
    lintTypes(doc),
  ]

