# handles.nim
#
# Стабильные handle-ID для сущностей документа (issue #143, MANIFEST §35/§36).
#
# Зачем:
#   GUI и CLI держат ссылки на объекты МЕЖДУ пересборками графа: выделение,
#   открытые панели, цепочки undo, цели автоматизации. Индекс в массиве для
#   этого не годится (вставил ноду — сдвинулось всё, что было дальше), указатель
#   — тем более (объект мог умереть). Handle — это ЗНАЧЕНИЕ, которое можно
#   хранить, копировать, сравнивать и передавать между слоями.
#
# Что такое handle:
#   docId      — какому документу принадлежит handle (выдаёт владелец);
#   slot       — номер слота ВНУТРИ вида сущности (у нод, дорожек и клипов
#                свои пространства слотов — как и свои id, §35);
#   generation — поколение слота: растёт при каждой выдаче;
#   kind       — что именно адресовано (нода, параметр, компонент, дорожка, клип).
#
# Инварианты:
#   - поколение 0 означает «handle недействителен»: zero-handle отвергается;
#   - адрес с чужим docId отвергается (heForeignDocument), даже если слот и
#     поколение случайно совпали: handle одного документа нельзя применить
#     к другому;
#   - адрес с устаревшим поколением отвергается (heStale) — это защита от ABA:
#     слот переиспользовали, а handle у клиента старый;
#   - повторное удаление отвергается (heReleased), а не «успешно»;
#   - слот = постоянный id из формата проекта (§58): добавление ноды в конец
#     графа не сдвигает handle'ы уже существующих нод, а удаление ноды честно
#     обессмысливает её адрес. Переиспользование освобождённого id — решение
#     слоя документа (CLI его не допускает), а не адресации.
#
# Про пересборку таблицы: поколения живут в таблице, поэтому таблица, построенная
#   заново из того же файла, выдаёт те же адреса с тем же текстом — это и нужно
#   CLI, который перечитывает проект на каждый запуск. Handle, переживший
#   удаление и переиспользование слота внутри ОДНОЙ сессии, отвергается по
#   поколению: там адреса выдаёт владелец документа (будущий Control Core).
#
# Слой: control-path. Здесь нет ни блокировок, ни realtime-контракта: handle —
#   число, в audio-поток оно попадает только как предвыделенное значение.
#   Всё, что этому модулю нужно знать о документе, приходит снаружи (id из
#   формата проекта), поэтому Core не знает ни списка нод, ни типов (§54).
#
# Вложенность: параметр и компонент — не самостоятельные объекты таблицы, а
#   часть своей ноды, поэтому адрес вложенной сущности — это handle владельца
#   плюс путь шагов: `node:3.2/component:1/param:0`. Такой путь печатается,
#   разбирается и проверяется тем же кодом, что и одиночный handle.

import std/[strutils]

import project

{.push raises: [].}

const
  MaxHandleSlots* = 65536
    ## Предел слотов на один вид сущностей в документе. 64k с запасом перекрывают
    ## проект GUI-сессии; переполнение — ошибка, а не тихая порча данных.

  MaxNestedDepth* = 8
    ## Глубина пути «подграф → компонент → параметр». Значение фиксировано:
    ## путь — значение, а не выделяемая строка (§34).

type
  HandleKind* = enum
    ## Что адресовано. `hkInvalid` — ноль: handle без вида не проходит разбор.
    hkInvalid = 0
    hkNode
    hkParam
    hkComponent
    hkTrack
    hkClip

  HandleError* = enum
    ## Причина отказа. Числовое значение — контракт: CLI, скрипты и будущий
    ## единый код ошибок (#117) обязаны различать «handle просрочен» и
    ## «handle чужой», поэтому значения не переставляются.
    heOk = 0
    heInvalid
      ## Мусор на входе или нулевой handle: разбирать нечего.
    heForeignDocument
      ## Handle выдан другим документом (docId не совпал).
    heStale
      ## Поколение слота не совпало: слот переиспользован (ABA).
    heReleased
      ## Сущность удалена, handle с тем же поколением уже недействителен.
    heKindMismatch
      ## Handle ноды использован как параметр (или наоборот).
    heUnboundEntity
      ## Слот есть, но сущность к нему ещё не привязана.
    heNoEntity
      ## В документе нет сущности с таким id.
    heSlotExhausted
      ## Свободных слотов нет: документ больше не адресуем.
    heSlotOccupied
      ## Слот уже занят другой сущностью (явная выдача слота).
    heBadPath
      ## Некорректный путь вложенной сущности (глубина, вид шага, порядок).

  EntityHandle* = object
    ## Значение-адрес. Копируется свободно: это не «ссылка на объект», а
    ## тройка чисел, по которой владелец находит сущность или отказывает.
    docId*: uint32
    slot*: uint32
    generation*: uint32
    kind*: HandleKind

  NestedStep* = object
    ## Один шаг пути внутрь владельца: что за подсущность и какой её номер.
    kind*: HandleKind
    index*: uint32

  NestedRef* = object
    ## Адрес вложенной сущности: handle владельца + путь шагов.
    owner*: EntityHandle
    target*: HandleKind
      ## Что адресовано в итоге (последний шаг): удобно вызывающему.
    steps*: array[MaxNestedDepth, NestedStep]
    depth*: uint8

  HandleSlot = object
    ## Слот таблицы. `entityId` — постоянный id из формата проекта (§58):
    ## проекция адреса обратно в файл не должна угадывать.
    generation*: uint32
    deadGeneration*: uint32
      ## Поколение, под которым слот УЖЕ освобождали. Оно нужно, чтобы
      ## «повторное удаление» (heReleased) отличалось от «слот переиспользован»
      ## (heStale): после переиспользования метка обнуляется.
    entityId*: uint64
    kind*: HandleKind
    alive*: bool
    bound*: bool

  HandleTable* = object
    ## Владелец handle'ов — документ/сессия. Скрытого глобального состояния
    ## нет (§72): таблица — обычное значение. Слоты у каждого вида свои:
    ## нода #1, дорожка #1 и клип #1 не мешают друг другу, как не мешают их id.
    docId*: uint32
    slots*: array[HandleKind, seq[HandleSlot]]
    freeSlots*: array[HandleKind, seq[uint32]]
    liveCount*: int

const
  KindNames*: array[HandleKind, string] = [
    hkInvalid: "invalid", hkNode: "node", hkParam: "param",
    hkComponent: "component", hkTrack: "track", hkClip: "clip",
  ]
    ## Канонические имена видов: ими печатаем handle, по ним же разбираем.
    ## Короткие синонимы понимаются при разборе (`n`, `p`, `c`, `t`, `k`) —
    ## печатать короткие нельзя, иначе отчёт перестаёт читаться.

  KindAliases*: array[HandleKind, string] = [
    hkInvalid: "", hkNode: "n", hkParam: "p",
    hkComponent: "c", hkTrack: "t", hkClip: "k",
  ]

# =============================================================================
# Handle: значение и его разбор
# =============================================================================

proc invalidHandle*(): EntityHandle {.inline.} =
  EntityHandle(docId: 0'u32, slot: 0'u32, generation: 0'u32,
               kind: hkInvalid)

proc isValidHandle*(h: EntityHandle): bool {.inline.} =
  ## Handle без поколения — заведомо недействителен (поколение 0 не выдаётся).
  ## Слот 0 допустим: это первая сущность вида, а не «пусто».
  h.docId != 0'u32 and h.generation != 0'u32 and h.kind != hkInvalid

proc handleEquals*(a, b: EntityHandle): bool {.inline.} =
  a.docId == b.docId and a.slot == b.slot and
    a.generation == b.generation and a.kind == b.kind

proc handleErrorCode*(e: HandleError): uint32 {.inline.} =
  ## Числовой код отказа — контракт для CLI/скриптов (#117).
  uint32(ord(e))

proc handleErrorText*(e: HandleError): string =
  ## Текст отказа: по нему человек понимает, что делать, а не только ЧТО
  ## случилось (§44).
  case e
  of heOk: "адрес в порядке"
  of heInvalid: "адрес разобран как пустой или неверный"
  of heForeignDocument: "handle принадлежит другому документу"
  of heStale: "handle просрочен: слот уже переиспользован"
  of heReleased: "сущность удалена, handle больше не действителен"
  of heKindMismatch: "handle указывает на другой вид сущности"
  of heUnboundEntity: "слот есть, но сущность к нему не привязана"
  of heNoEntity: "в документе нет сущности с таким id"
  of heSlotExhausted: "в документе закончились адреса"
  of heSlotOccupied: "слот уже занят другой сущностью"
  of heBadPath: "путь вложенной сущности некорректен"

proc docIdText*(docId: uint32): string =
  ## Идентификатор документа в тексте адреса: восемь hex-символов.
  let text = toHex(docId).toLowerAscii()
  if text.len > 8: text[0 ..< 8] else: text

proc handleToText*(h: EntityHandle): string =
  ## `node:3.2` — вид, слот, поколение. Формат короткий, но достаточный:
  ## поколение в нём есть, поэтому handle нельзя спутать с «просто номером».
  if not h.isValidHandle():
    return "handle:none"
  KindNames[h.kind] & ":" & $h.slot & "." & $h.generation

proc handleToTextQualified*(h: EntityHandle): string =
  ## Полная форма `node:3.2@ab12cd34`: документ входит в адрес, поэтому его
  ## нельзя по ошибке применить к другому файлу. Машинный вывод (`--json`)
  ## печатает эту форму, человеческий список — короткую.
  if not h.isValidHandle():
    return "handle:none"
  handleToText(h) & "@" & docIdText(h.docId)

proc parseUint32*(text: string; value: var uint32): bool {.inline.} =
  ## Разбор целого без `parseInt`: этот модуль объявлен `raises: []`, а
  ## `parseInt` бросает исключение на мусоре. Пустая строка и переполнение —
  ## тоже «не число».
  if text.len == 0 or text.len > 10:
    return false
  var acc = 0'u64
  for ch in text:
    if ch < '0' or ch > '9':
      return false
    acc = acc * 10'u64 + uint64(ord(ch) - ord('0'))
    if acc > uint64(high(uint32)):
      return false
  value = uint32(acc)
  true

proc parseHex32*(text: string; value: var uint32): bool =
  ## Hex-разбор без исключений — по тем же правилам, что и `parseUint32`.
  if text.len == 0 or text.len > 8:
    return false
  var acc = 0'u64
  for ch in text:
    var digit = -1
    if ch >= '0' and ch <= '9':
      digit = int(ord(ch) - ord('0'))
    elif ch >= 'a' and ch <= 'f':
      digit = int(ord(ch) - ord('a') + 10)
    elif ch >= 'A' and ch <= 'F':
      digit = int(ord(ch) - ord('A') + 10)
    if digit < 0:
      return false
    acc = acc * 16'u64 + uint64(digit)
  value = uint32(acc)
  true

proc parseKindText*(text: string; kind: var HandleKind): bool =
  ## Полное имя вида или однобуквенный синоним. Регистр не важен: handle
  ## вводят руками и копируют из отчёта.
  let lowered = text.toLowerAscii()
  for k in HandleKind:
    if lowered == KindNames[k] or
       (lowered.len > 0 and lowered == KindAliases[k]):
      kind = k
      return true
  false

proc splitDocSuffix*(text: string; body: var string; docId: var uint32;
                     qualified: var bool): HandleError =
  ## Отделить `@ab12cd34` от адреса. Короткая форма — просто без суффикса;
  ## пустой или не-hex суффикс — ошибка, а не «просто короткий адрес».
  body = text
  docId = 0'u32
  qualified = false
  let at = text.rfind('@')
  if at < 0:
    return heOk
  if at == 0 or at + 1 >= text.len:
    return heInvalid
  var parsed: uint32
  if not parseHex32(text[at + 1 .. ^1], parsed):
    return heInvalid
  body = text[0 ..< at]
  docId = parsed
  qualified = true
  heOk

proc parseHandleText*(text: string; h: var EntityHandle): HandleError =
  ## `node:3.2` → handle. Всё, что не разобралось, — `heInvalid`: разбор не
  ## должен «угадывать» адрес (то же правило, что у ссылок CLI, §82).
  result = heInvalid
  let colon = text.find(':')
  if colon <= 0 or colon + 1 >= text.len:
    return
  var kind: HandleKind
  if not parseKindText(text[0 ..< colon], kind):
    return
  let rest = text[colon + 1 .. ^1]
  let dot = rest.find('.')
  if dot < 0 or dot + 1 >= rest.len:
    return
  var slot, generation: uint32
  if not parseUint32(rest[0 ..< dot], slot) or
     not parseUint32(rest[dot + 1 .. ^1], generation):
    return
  if kind == hkInvalid or generation == 0'u32:
    return
  h = EntityHandle(docId: 0'u32, slot: slot, generation: generation, kind: kind)
  result = heOk

proc parseHandleTextQualified*(text: string;
                              h: var EntityHandle): HandleError =
  ## Разбор полной формы: `node:3.2@ab12cd34`. Документ из адреса попадает в
  ## `h.docId`, чтобы вызывающий мог сверить его со своим.
  var body: string
  var docId: uint32
  var qualified: bool
  let split = splitDocSuffix(text, body, docId, qualified)
  if split != heOk:
    result = split
    return
  var parsed: EntityHandle
  let head = parseHandleText(body, parsed)
  if head != heOk:
    result = head
    return
  if qualified:
    parsed.docId = docId
  h = parsed
  result = heOk

proc bindHandleText*(tbl: HandleTable; text: string;
                     h: var EntityHandle): HandleError =
  ## Разбор пользовательской ссылки в адрес ЭТОГО документа. Короткая форма
  ## привязывается к текущему документу, полная — сверяется с ним: handle из
  ## чужого файла отвергается (heForeignDocument), а не «случайно подходит».
  result = heInvalid
  if tbl.docId == 0'u32:
    return
  var parsed: EntityHandle
  let err = parseHandleTextQualified(text, parsed)
  if err != heOk:
    return err
  if parsed.docId != 0'u32 and parsed.docId != tbl.docId:
    return heForeignDocument
  parsed.docId = tbl.docId
  h = parsed
  result = heOk

# =============================================================================
# Таблица адресов документа
# =============================================================================

proc initHandleTable*(tbl: var HandleTable; docId: uint32): HandleError =
  ## Пустая таблица документа. `docId` обязан быть задан владельцем: без него
  ## handle из разных документов выглядели бы одинаково, и проверка «свой или
  ## чужой» была бы невозможна.
  if docId == 0'u32:
    tbl = HandleTable()
    return heInvalid
  tbl = HandleTable(docId: docId)
  heOk

proc nextGeneration(old: uint32): uint32 {.inline.} =
  ## Поколение 0 зарезервировано под «недействителен», поэтому переход через
  ## ноль возвращаем к 2: handle с поколением 0 не должен снова стать рабочим.
  result = old + 1'u32
  if result == 0'u32 or result > uint32(high(int32)):
    result = 2'u32

proc slotOf*(tbl: HandleTable; h: EntityHandle): int =
  ## Индекс слота ВИДА handle'а или -1, если слот за пределами таблицы.
  if h.kind == hkInvalid or int(h.slot) >= tbl.slots[h.kind].len:
    return -1
  int(h.slot)

proc takeSlot*(tbl: var HandleTable; kind: HandleKind): int =
  ## Занять слот вида: сначала свободные, затем новый.
  if kind == hkInvalid:
    return -1
  if tbl.freeSlots[kind].len > 0:
    return int(tbl.freeSlots[kind].pop())
  if tbl.slots[kind].len >= MaxHandleSlots:
    return -1
  let slot = tbl.slots[kind].len
  tbl.slots[kind].add HandleSlot()
  slot

proc occupySlot*(tbl: var HandleTable; slot: int; kind: HandleKind;
                 entityId: uint64): EntityHandle =
  ## Сделать слот занятым с новым поколением. Общая часть для выдачи по
  ## свободному слоту и по конкретному слоту (id из файла).
  var s = addr tbl.slots[kind][slot]
  s.generation = nextGeneration(s.generation)
  s.deadGeneration = 0'u32
  s.entityId = entityId
  s.kind = kind
  s.alive = true
  s.bound = true
  inc tbl.liveCount
  EntityHandle(docId: tbl.docId, slot: uint32(slot),
               generation: s.generation, kind: kind)

proc acquireHandle*(tbl: var HandleTable; kind: HandleKind;
                    entityId: uint64 = 0'u64): EntityHandle =
  ## Новый адрес в свободном слоте. `entityId` сразу привязывает слот к
  ## сущности документа: handle, по которому нечего найти, выдавать нельзя.
  result = invalidHandle()
  if tbl.docId == 0'u32:
    return
  let slot = tbl.takeSlot(kind)
  if slot < 0:
    return
  result = tbl.occupySlot(slot, kind, entityId)

proc acquireHandleAt*(tbl: var HandleTable; kind: HandleKind; slot: uint32;
                      entityId: uint64): EntityHandle =
  ## Адрес в КОНКРЕТНОМ слоте. Так проектируется документ: слот = id из
  ## формата проекта, поэтому handle ноды не сдвигается от того, что перед ней
  ## вставили другую ноду.
  result = invalidHandle()
  if tbl.docId == 0'u32 or kind == hkInvalid:
    return
  if int(slot) >= MaxHandleSlots:
    return
  while tbl.slots[kind].len < int(slot) + 1:
    tbl.slots[kind].add HandleSlot()
  if tbl.slots[kind][int(slot)].alive:
    return   # слот занят: второй handle на чужой слот выдавать нельзя
  result = tbl.occupySlot(int(slot), kind, entityId)

proc checkSlot*(tbl: HandleTable; h: EntityHandle;
                kind: HandleKind): HandleError =
  ## Проверка адреса без чтения полезной нагрузки: документ, поколение, вид.
  ## Именно она отличает «чужой документ» от «просрочен» от «не того вида».
  if not h.isValidHandle():
    return heInvalid
  if h.docId != tbl.docId:
    return heForeignDocument
  if h.kind != kind:
    return heKindMismatch
  let index = tbl.slotOf(h)
  if index < 0:
    return heInvalid
  let s = tbl.slots[kind][index]
  if s.generation == 0'u32:
    # Слот ни разу не выдавался: такого адреса в документе просто нет. Это
    # не «просрочен» — поколение нечего сверять.
    return heInvalid
  if not s.alive and s.deadGeneration != 0'u32 and
     h.generation == s.deadGeneration:
    return heReleased
  if h.generation != s.generation:
    return heStale
  if not s.alive:
    return heStale
  heOk

proc resolveAs*(tbl: HandleTable; h: EntityHandle; kind: HandleKind):
    tuple[ok: bool, error: HandleError, entityId: uint64] =
  ## Адрес → постоянный id сущности, с проверкой ОЖИДАЕМОГО вида: «вместо
  ## параметра передали ноду» должно отвергаться (heKindMismatch), а не молча
  ## отвечать. Никаких указателей наружу: клиент получает число и сам решает,
  ## что с ним делать (§63).
  let err = tbl.checkSlot(h, kind)
  if err != heOk:
    return (false, err, 0'u64)
  let s = tbl.slots[kind][tbl.slotOf(h)]
  if not s.bound:
    return (false, heUnboundEntity, 0'u64)
  (true, heOk, s.entityId)

proc entityOf*(tbl: HandleTable; h: EntityHandle):
    tuple[ok: bool, error: HandleError, entityId: uint64] =
  ## Адрес → постоянный id без проверки вида (вид берётся из самого handle).
  tbl.resolveAs(h, h.kind)

proc releaseHandle*(tbl: var HandleTable; h: EntityHandle): HandleError =
  ## Удаление сущности: слот освобождается, а его «умершее» поколение
  ## запоминается. Поколение растёт при СЛЕДУЮЩЕЙ выдаче, поэтому handle
  ## удалённой сущности отвергается как heReleased, а после переиспользования
  ## слота — уже как heStale (ABA).
  let err = tbl.checkSlot(h, h.kind)
  if err != heOk:
    return err
  let index = tbl.slotOf(h)
  var s = addr tbl.slots[h.kind][index]
  s.alive = false
  s.bound = false
  s.deadGeneration = s.generation
  dec tbl.liveCount
  tbl.freeSlots[h.kind].add uint32(index)
  heOk

proc findHandleAt*(tbl: HandleTable; slot: uint32;
                   kind: HandleKind): EntityHandle =
  ## Handle по слоту и виду — O(1), этим пользуется разбор ссылки CLI.
  let index = tbl.slotOf(EntityHandle(docId: tbl.docId, slot: slot,
                                       generation: 1'u32, kind: kind))
  if index < 0:
    return invalidHandle()
  let s = tbl.slots[kind][index]
  if not s.alive or s.kind != kind:
    return invalidHandle()
  EntityHandle(docId: tbl.docId, slot: slot, generation: s.generation,
               kind: kind)

proc findHandle*(tbl: HandleTable; kind: HandleKind; entityId: uint64):
    EntityHandle =
  ## Handle по постоянному id. Линейный поиск: адресация идёт на control-path,
  ## при тысячах сущностей это десятки микросекунд, а индекс по id стоил бы
  ## второй структуры, которую придётся держать в согласии (§37).
  for i in 0 ..< tbl.slots[kind].len:
    let s = tbl.slots[kind][i]
    if s.alive and s.bound and s.kind == kind and s.entityId == entityId:
      return EntityHandle(docId: tbl.docId, slot: uint32(i),
                          generation: s.generation, kind: kind)
  invalidHandle()

proc requireHandle*(tbl: HandleTable; kind: HandleKind; entityId: uint64):
    tuple[ok: bool, error: HandleError, handle: EntityHandle] =
  ## Адрес по постоянному id: «нет сущности» — тоже код (heNoEntity), чтобы
  ## вызывающий отличал «нет такой ноды» от «слот занят другим видом».
  let h = tbl.findHandle(kind, entityId)
  if not h.isValidHandle():
    return (false, heNoEntity, invalidHandle())
  (true, heOk, h)

proc hasEntity*(tbl: HandleTable; kind: HandleKind; entityId: uint64): bool =
  tbl.findHandle(kind, entityId).isValidHandle()

proc liveHandleCount*(tbl: HandleTable): int {.inline.} =
  ## Сколько адресов выдано прямо сейчас (тест «жизненного цикла»).
  tbl.liveCount

proc slotCount*(tbl: HandleTable; kind: HandleKind): int {.inline.} =
  ## Сколько слотов занято в пространстве вида (включая освобождённые).
  tbl.slots[kind].len

# =============================================================================
# Вложенные сущности: подграф → компонент → параметр, дорожка → клип
# =============================================================================

proc nestedRef*(owner: EntityHandle; kind: HandleKind;
                steps: openArray[NestedStep]): NestedRef =
  ## Путь вложенной сущности. Пустой путь или глубина больше MaxNestedDepth —
  ## отказ (остаётся невалидный путь), а не тихое обрезание.
  if steps.len == 0 or steps.len > MaxNestedDepth:
    return NestedRef()
  result.owner = owner
  result.target = kind
  result.depth = uint8(steps.len)
  for i in 0 ..< steps.len:
    result.steps[i] = steps[i]

proc paramRef*(owner: EntityHandle; paramIndex: uint32): NestedRef =
  ## Параметр ноды: `node:3.2/param:1`.
  nestedRef(owner, hkParam, [NestedStep(kind: hkParam, index: paramIndex)])

proc componentRef*(owner: EntityHandle; componentIndex: uint32): NestedRef =
  ## Компонент ноды (F6): `node:3.2/component:0`.
  nestedRef(owner, hkComponent,
           [NestedStep(kind: hkComponent, index: componentIndex)])

proc componentParamRef*(owner: EntityHandle; componentIndex: uint32;
                        paramIndex: uint32): NestedRef =
  ## Путь «подграф → компонент → параметр» — самая глубокая адресация, которая
  ## сейчас нужна: параметр параметров сложного компонента.
  nestedRef(owner, hkParam, [NestedStep(kind: hkComponent, index: componentIndex),
                             NestedStep(kind: hkParam, index: paramIndex)])

proc clipRef*(track: EntityHandle; clipIndex: uint32): NestedRef =
  ## Клип на дорожке (F10): размещение клипа адресуется дорожкой и номером.
  nestedRef(track, hkClip, [NestedStep(kind: hkClip, index: clipIndex)])

proc isValidNested*(r: NestedRef): bool {.inline.} =
  r.owner.isValidHandle() and r.depth > 0'u8 and
    int(r.depth) <= MaxNestedDepth and r.target != hkInvalid

proc nestedToText*(r: NestedRef): string =
  ## Печать пути: `node:3.2/component:1/param:0`. Путь печатается целиком —
  ## по одному handle сущности не отличить от её родителя.
  if not r.isValidNested():
    return "handle:none"
  var parts = newSeq[string](int(r.depth) + 1)
  parts[0] = handleToText(r.owner)
  for i in 0 ..< int(r.depth):
    parts[i + 1] = KindNames[r.steps[i].kind] & ":" & $r.steps[i].index
  parts.join("/")

proc nestedToTextQualified*(r: NestedRef): string =
  ## Полная форма пути с суффиксом документа: `node:3.2/param:1@ab12cd34`.
  if not r.isValidNested():
    return "handle:none"
  nestedToText(r) & "@" & docIdText(r.owner.docId)

proc nestedStepAllowed*(kind: HandleKind; container: HandleKind): bool =
  ## Правило формы пути: что может лежать ВНУТРИ предыдущего шага. Владелец
  ## (нода/дорожка) содержит параметр, компонент или клип; компонент — свои
  ## параметры и вложенные компоненты; параметр и клип не содержат ничего.
  ## Смешанные виды в глубине («параметр в параметре») означали бы две разные
  ## сущности — это heBadPath, а не «попробуем угадать».
  if kind != hkParam and kind != hkComponent and kind != hkClip:
    return false
  if container == hkComponent:
    return kind == hkParam or kind == hkComponent
  if container == hkParam or container == hkClip:
    return false
  true

proc parseNestedText*(text: string; r: var NestedRef): HandleError =
  ## Разбор пути: первая часть — handle, дальше шаги `вид:номер`.
  result = heInvalid
  if text.len == 0:
    return
  let parts = text.split('/')
  var owner: EntityHandle
  let first = parseHandleText(parts[0], owner)
  if first != heOk:
    return first
  if parts.len == 1 or parts.len > MaxNestedDepth + 1:
    return heBadPath
  var steps: array[MaxNestedDepth, NestedStep]
  for i in 1 ..< parts.len:
    let colon = parts[i].find(':')
    if colon <= 0 or colon + 1 >= parts[i].len:
      return heBadPath
    var stepKind: HandleKind
    if not parseKindText(parts[i][0 ..< colon], stepKind):
      return heBadPath
    let container =
      if i == 1: hkInvalid   # прямо в владельце
      else: steps[i - 2].kind
    if not nestedStepAllowed(stepKind, container):
      return heBadPath
    var index: uint32
    if not parseUint32(parts[i][colon + 1 .. ^1], index):
      return heBadPath
    steps[i - 1] = NestedStep(kind: stepKind, index: index)
  r.owner = owner
  r.target = steps[parts.len - 2].kind
  r.depth = uint8(parts.len - 1)
  for i in 0 ..< parts.len - 1:
    r.steps[i] = steps[i]
  result = heOk

proc bindNestedText*(tbl: HandleTable; text: string;
                     r: var NestedRef): HandleError =
  ## Разбор пути в адрес ЭТОГО документа. Суффикс документа, если он есть,
  ## сверяется с таблицей — путь из чужого файла отвергается так же, как
  ## одиночный handle.
  result = heInvalid
  if tbl.docId == 0'u32:
    return
  var body: string
  var docId: uint32
  var qualified: bool
  let split = splitDocSuffix(text, body, docId, qualified)
  if split != heOk:
    return split
  var parsed: NestedRef
  let err = parseNestedText(body, parsed)
  if err != heOk:
    return err
  if qualified and docId != tbl.docId:
    return heForeignDocument
  parsed.owner.docId = tbl.docId
  r = parsed
  result = heOk

proc resolveNested*(tbl: HandleTable; r: NestedRef):
    tuple[ok: bool, error: HandleError, ownerId: uint64, index: uint32] =
  ## Проверка вложенного адреса: сначала владелец (тем же кодом, что и
  ## одиночный handle), затем глубина пути. Саму сущность по индексу проверяет
  ## владелец документа — здесь про вид ноды ничего не известно (§54).
  if not r.isValidNested():
    return (false, heBadPath, 0'u64, 0'u32)
  let owner = tbl.entityOf(r.owner)
  if not owner.ok:
    return (false, owner.error, 0'u64, 0'u32)
  (true, heOk, owner.entityId, r.steps[int(r.depth) - 1].index)

# =============================================================================
# Проекция: формат проекта ↔ адреса
# =============================================================================

proc documentIdForPath*(path: string): uint32 =
  ## Стабильный между запусками идентификатор документа для CLI: FNV-1a от
  ## абсолютного пути. Не `hash()`: он зависит от версии компилятора и соли,
  ## а handle должен печататься и разбираться одинаково всегда.
  ## Путь обязан быть абсолютным — вызывающий приводит его сам
  ## (`absolutePath`), иначе один и тот же файл из двух каталогов получил бы
  ## два разных документа.
  var acc = 0x811C9DC5'u32
  for ch in path:
    acc = (acc xor uint32(ord(ch))) * 0x01000193'u32
  if acc == 0'u32: 1'u32 else: acc

proc openProjectHandles*(tbl: var HandleTable; proj: ProjectFormat): HandleError =
  ## Адреса нод и дорожек документа: слот = id из файла (§58), поэтому адрес
  ## переживает пересборку графа и любую перестановку в файле. Порядок обхода —
  ## порядок файла, и вывод детерминирован (#88).
  ##
  ## Клипы слота НЕ получают: их id уникальны только внутри дорожки (в проекте
  ## каждая дорожка нумерует клипы с единицы). Правильная адресация клипа —
  ## вложенная, `track:1.1/clip:0`: «клип №N на дорожке», то есть и есть
  ## размещение клипа (F10).
  ##
  ## Дубль id внутри одного вида — возвращается `heSlotOccupied`, но уже
  ## выданные адреса остаются в силе: одна сломанная нода не должна лишать
  ## адресов весь документ. Вызывающий решает, что показывать.
  if tbl.docId == 0'u32:
    return heInvalid
  var error = heOk
  for node in proj.graph.nodes:
    if node.id <= 0:
      continue
    if not tbl.acquireHandleAt(hkNode, uint32(node.id), uint64(node.id))
        .isValidHandle() and error == heOk:
      error = heSlotOccupied
  for track in proj.sequencer.tracks:
    if track.id <= 0:
      continue
    if not tbl.acquireHandleAt(hkTrack, uint32(track.id), uint64(track.id))
        .isValidHandle() and error == heOk:
      error = heSlotOccupied
  error

proc nodeHandle*(tbl: HandleTable; nodeId: int): EntityHandle =
  ## Адрес ноды по её id в файле.
  if nodeId <= 0:
    return invalidHandle()
  tbl.findHandleAt(uint32(nodeId), hkNode)

proc trackHandle*(tbl: HandleTable; trackId: int32): EntityHandle =
  if trackId <= 0:
    return invalidHandle()
  tbl.findHandleAt(uint32(trackId), hkTrack)

proc clipHandle*(tbl: HandleTable; clipId: int32): EntityHandle =
  ## Адрес клипа по его id возможен, только если id уникален во всём проекте
  ## (см. `openProjectHandles`). Обычный случай — вложенный `trackClipRef`.
  if clipId <= 0:
    return invalidHandle()
  tbl.findHandleAt(uint32(clipId), hkClip)

proc nodeParamRef*(tbl: HandleTable; nodeId: int; paramIndex: uint32): NestedRef =
  ## Вложенный адрес параметра: handle ноды + номер параметра в описателе
  ## типа. Номер, а не имя: имя переименовывается, номер — позиция в
  ## описателе, которую читает и CLI, и будущий Editor.
  paramRef(tbl.nodeHandle(nodeId), paramIndex)

proc nodeComponentParamRef*(tbl: HandleTable; nodeId: int; componentIndex: uint32;
                            paramIndex: uint32): NestedRef =
  componentParamRef(tbl.nodeHandle(nodeId), componentIndex, paramIndex)

proc trackClipRef*(tbl: HandleTable; trackId: int32; clipIndex: uint32): NestedRef =
  clipRef(tbl.trackHandle(trackId), clipIndex)

{.pop.}
