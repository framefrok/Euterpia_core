# cli/addressing.nim
#
# Handle-адресация в CLI (issue #143, MANIFEST §35/§36).
#
# Зачем отдельный модуль: адрес — это не «ещё одно поле в отчёте», а форма
# ссылки, которую человек и агент вводят руками. Сборка таблицы, печать и
# разбор должны жить в одном месте, иначе `node list` и `param set` со временем
# начнут показывать разные адреса одной и той же ноды (§37).
#
# Что видит пользователь:
#
#   euterpia node list                    →  #1 Gain (fx.gain) [node:1.1]
#   euterpia node list --json             →  "handle": "node:1.1",
#                                            "handleRef": "node:1.1@a1b2c3d4"
#   euterpia param list 1                 →  freq = 440 (node:1.1/param:0)
#   euterpia node show node:1.1          →  та же нода, адрес — вход
#   euterpia param get 1 node:1.1/param:0 →  тот же параметр по адресу
#
# Адрес устойчив к пересборке графа: слот = id ноды из файла, поэтому вставка
# ноды в начало графа не меняет адреса уже напечатанных нод, а удалённая нода
# адреса не имеет. Поколение ловит переиспользование слота внутри сессии.

import std/os

import project
import handles
import context

const
  HandleHint* = "адреса печатает: euterpia node list (--json — полная форма)"

proc documentTable*(path: string; proj: ProjectFormat): HandleTable =
  ## Таблица адресов документа. Идентификатор документа — хэш абсолютного пути,
  ## поэтому один и тот же файл из двух каталогов узнаётся как один документ,
  ## а адрес из чужого файла отвергается, а не «случайно подходит».
  var tbl: HandleTable
  discard initHandleTable(tbl, documentIdForPath(absolutePath(path)))
  # Дубли id внутри вида дают heSlotOccupied, но уже выданные адреса остаются
  # в силе: одна сломанная нода не должна лишать адресов весь документ.
  discard openProjectHandles(tbl, proj)
  tbl

proc documentIdOf*(path: string): string =
  ## Идентификатор документа для отчётов (`project show --json`).
  docIdText(documentIdForPath(absolutePath(path)))

proc handleErrorReport*(err: HandleError; what: string): Report =
  ## Отказ адресации в терминах пользователя: что он написал и что делать.
  usageError(what & ": " & handleErrorText(err) &
             " (код " & $handleErrorCode(err) & ")", HandleHint)

proc looksLikeHandleText*(text: string): bool =
  ## Ссылка на адрес — это `вид:слот.поколение`. Всё, что на это похоже,
  ## разбирается как адрес: молча считать `node:9.9` именем ноды значило бы
  ## ответить не на то, что человек написал (§82).
  text.len > 0 and ':' in text and '.' in text

proc resolveNodeHandle*(tbl: HandleTable; text: string):
    tuple[ok: bool, nodeId: int; rep: Report] =
  ## Адрес ноды → её id в файле. Короткая и полная формы; «просрочен» и
  ## «чужой документ» — разные сообщения, а не «не нашлась нода».
  var h: EntityHandle
  let err = tbl.bindHandleText(text, h)
  if err != heOk:
    return (false, -1, handleErrorReport(err, "адрес " & text))
  if h.kind != hkNode:
    return (false, -1,
            usageError("адрес " & text & " указывает на " &
                       $KindNames[h.kind] & ", а здесь нужна нода", HandleHint))
  let resolved = tbl.entityOf(h)
  if not resolved.ok:
    if resolved.error == heInvalid:
      # Адрес разобран, но такого слота в документе нет — это «нет такой ноды»,
      # а не «плохой адрес»: сообщения разные, потому что подсказки разные.
      return (false, -1,
              usageError("в документе нет ноды с адресом " & text,
                         HandleHint))
    return (false, -1, handleErrorReport(resolved.error, "адрес " & text))
  (true, int(resolved.entityId), okReport())

proc resolveParamHandle*(tbl: HandleTable; text: string; nodeId: int):
    tuple[ok: bool, paramIndex: int; rep: Report] =
  ## Адрес параметра `node:1.1/param:0` → номер параметра. Владелец пути обязан
  ## совпадать с указанной нодой: путь, ведущий в другую ноду, — это ошибка
  ## вызова, а не повод молча взять параметр из «той» ноды.
  var r: NestedRef
  let err = bindNestedText(tbl, text, r)
  if err != heOk:
    return (false, -1, handleErrorReport(err, "адрес " & text))
  if r.target != hkParam:
    return (false, -1,
            usageError("адрес " & text & " указывает на " &
                       $KindNames[r.target] & ", а здесь нужен параметр",
                       HandleHint))
  let resolved = tbl.resolveNested(r)
  if not resolved.ok:
    return (false, -1, handleErrorReport(resolved.error, "адрес " & text))
  if int(resolved.ownerId) != nodeId:
    return (false, -1,
            usageError("адрес " & text & " ведёт в ноду #" &
                       $int(resolved.ownerId) & ", а указана нода #" & $nodeId,
                       "адрес параметра должен принадлежать указанной ноде"))
  (true, int(resolved.index), okReport())

# =============================================================================
# Печать адресов в отчётах
# =============================================================================

proc nodeHandleText*(tbl: HandleTable; nodeId: int): string =
  ## Короткая форма для человеческого вывода: `node:1.1`.
  let h = tbl.nodeHandle(nodeId)
  if h.isValidHandle(): h.handleToText() else: "node:нет"

proc nodeHandleRef*(tbl: HandleTable; nodeId: int): string =
  ## Полная форма для машинного вывода: `node:1.1@a1b2c3d4`.
  let h = tbl.nodeHandle(nodeId)
  if h.isValidHandle(): h.handleToTextQualified() else: "node:нет"

proc nodeParamHandleText*(tbl: HandleTable; nodeId: int; paramIndex: int): string =
  ## Вложенный адрес параметра: `node:1.1/param:0`.
  let r = tbl.nodeParamRef(nodeId, uint32(max(0, paramIndex)))
  if r.isValidNested(): nestedToText(r) else: "node:нет"

proc trackHandleText*(tbl: HandleTable; trackId: int32): string =
  let h = tbl.trackHandle(trackId)
  if h.isValidHandle(): h.handleToText() else: "track:нет"

proc clipHandleText*(tbl: HandleTable; trackId: int32; clipIndex: int): string =
  ## Адрес клипа — вложенный: `track:1.1/clip:0`. id клипа уникален только
  ## внутри дорожки, поэтому адрес «клип №N на дорожке» — единственный честный.
  let r = clipRef(tbl.trackHandle(trackId), uint32(max(0, clipIndex)))
  if r.isValidNested(): nestedToText(r) else: "clip:нет"
