# core/control/history.nim
#
# История команд поверх control-слоя (issue #109 в связке с #139, MANIFEST §66).
#
# Что здесь и чего не здесь:
#   Стек, группы, лимит шагов и сериализация истории — `commons/undo_redo`
#   (issue #109). Здесь только ПЕРЕВОД: одна транзакция документа → одна запись
#   истории, откат — обратными командами, повтор — исходными.
#
# Почему обратные КОМАНДЫ, а не снимок модели:
#   - откат виден: в истории лежит команда «создать ноду #3», а не «восстановить
#     состояние»;
#   - повтор и откат идут по ТОМУ ЖЕ пути, что и обычная правка, — значит
#     откат не может обойти правила графа;
#   - снимок документа на каждый шаг стоил бы памяти, пропорциональной
#     размеру проекта, и тихо разошёлся бы с моделью после любой правки мимо
#     команд.
#
# Запись истории переносима: обратные и исходные команды сериализуются в JSON
# (`commands.toJson`), поэтому история может лежать в файле сессии (#109) и не
# зависит от того, в каком порядке команды выполнялись в памяти.

import std/json

import undo_redo as ur
import commands
import document
import error_frame

const
  HistoryEntryKind* = ctGroupCommand
    ## Запись истории — это ТРАНЗАКЦИЯ (группа), даже если внутри одна команда:
    ## форма записи одна на оба случая, иначе «отменить одну ноду» и «отменить
    ## пять команд» были бы разными сущностями.
  HistoryPayloadVersion = 1

type
  HistoryEntry* = object
    ## Запись целиком: что повторить и чем отменить.
    redo*: seq[ControlCommand]
    undo*: seq[ControlCommand]
    description*: string

proc encodeEntry*(entry: HistoryEntry): string =
  ## Запись в строку `blob` истории Commons. Формат версионируется: история,
  ## сохранённая прошлой версией, читается этой — и наоборот, новая не должна
  ## молча превращаться в мусор в руках старой (§58/§59).
  var payload = newJObject()
  payload["v"] = %HistoryPayloadVersion
  payload["description"] = %entry.description
  var redo = newJArray()
  for cmd in entry.redo:
    redo.add cmd.toJson
  var undo = newJArray()
  for cmd in entry.undo:
    undo.add cmd.toJson
  payload["redo"] = redo
  payload["undo"] = undo
  $payload

proc decodeEntry*(entry: var HistoryEntry; blob: string): bool =
  ## Разбор записи. `false` — запись чужая или повреждённая; тогда история её
  ## не выполняет и говорит почему, а не «отменит половину».
  try:
    let payload = parseJson(blob)
    if payload.kind != JObject or not payload.hasKey("v"):
      return false
    if payload["v"].getInt != HistoryPayloadVersion:
      return false
    let description = (if payload.hasKey("description"): payload["description"].getStr
                       else: "")
    entry = HistoryEntry(description: description)
    if payload.hasKey("redo"):
      for item in payload["redo"].items:
        var cmd: ControlCommand
        if not item.fromJson(cmd):
          return false
        entry.redo.add cmd
    if payload.hasKey("undo"):
      for item in payload["undo"].items:
        var cmd: ControlCommand
        if not item.fromJson(cmd):
          return false
        entry.undo.add cmd
    entry.redo.len > 0
  except JsonParsingError:
    false

type
  HistoryState* = ref object
    ## Разделяемое состояние истории: исполнители Commons живут в замыканиях, а
    ## замыкание не имеет права захватывать `var`-структуру (память, Nim).
    ## Через `ref` они честно пишут в один и тот же кадр последней операции.
    lastFrame*: ErrorFrame

  DocumentHistory* = object
    ## История control-слоя. Стек — Commons (`commons/undo_redo`, #109): лимит
    ## шагов, усечение и сериализация — его забота, а наполняет его control.
    mgr*: ur.UndoRedoManager
    state*: HistoryState

proc newHistory*(maxSteps: int = ur.MaxUndoSteps): DocumentHistory =
  DocumentHistory(mgr: ur.initUndoRedoManager(maxSteps),
                  state: HistoryState(lastFrame: okFrame()))

proc lastFrame*(hist: DocumentHistory): ErrorFrame {.inline.} =
  ## Код последней операции истории (выполнение, отмена, повтор).
  hist.state.lastFrame

proc historyEntry*(entry: HistoryEntry): ur.CommandData =
  ## Запись истории в формате Commons. Это вся «упаковка»: одна команда с
  ## типом «группа», описание для интерфейса и полезная нагрузка в `blob`.
  var data = ur.CommandData(commandType: HistoryEntryKind,
                            description: entry.description)
  data.blob = entry.encodeEntry
  data

proc applyEntry*(hist: DocumentHistory; doc: ptr Document; blob: string;
                 undo: bool): bool =
  ## Выполнить запись: undo — обратные команды, иначе исходные.
  var entry: HistoryEntry
  if not entry.decodeEntry(blob):
    hist.state.lastFrame = errFrame(ecInvalidArgument,
                               "запись истории не принадлежит control-слою",
                               "история записана другой версией ядра (§58)")
    return false
  let commands = if undo: entry.undo else: entry.redo
  let frame = doc[].applyCommands(commands,
                                 if undo: "отмена: " & entry.description
                                 else: "повтор: " & entry.description)
  hist.state.lastFrame = frame
  frame.isOk()

proc guardedEntry(hist: DocumentHistory; doc: ptr Document; blob: string;
                  undo: bool): bool {.raises: [].} =
  ## Граница, через которую проходит всё исполнение истории. Исполнитель
  ## Commons обязан не бросать исключений (его тип `raises: []`), а отмена или
  ## повтор, упавшие внутри, — это КОД, а не авария: пользователь должен увидеть
  ## «отменить не удалось», а не перехват стека.
  try:
    result = applyEntry(hist, doc, blob, undo)
  except CatchableError:
    hist.state.lastFrame = errFrame(ecInternal,
                               "история: исключение при выполнении записи",
                               "внутренняя ошибка ядра")
    result = false
  except Exception:
    # Defect — это уже авария (OOM, assertion), но добраться сюда она может
    # только из модуля Commons; ловим и её, чтобы история не бросала наружу.
    hist.state.lastFrame = errFrame(ecInternal,
                               "история: авария при выполнении записи",
                               "внутренняя ошибка ядра")
    result = false

proc executorFor(hist: DocumentHistory; doc: ptr Document): ur.CommandExecutor =
  ## Исполнитель истории: apply/undo/redo разбирают запись и зовут control-слой.
  ## Клиент ничего не исполняет сам — иначе появился бы «второй Core» (§23).
  ##
  ## Документ передаётся указателем: замыкание не имеет права захватывать
  ## `var`-структуру (это запрещено из-за памяти), а документ менять надо по
  ## месту. Исполнитель живёт только внутри одного вызова истории — так и
  ## написано в контракте: сохранять его нельзя.
  ur.initCommandExecutor(
    proc(cmd: ur.CommandData): bool {.closure, raises: [].} =
      guardedEntry(hist, doc, cmd.blob, false),
    proc(cmd: ur.CommandData): bool {.closure, raises: [].} =
      guardedEntry(hist, doc, cmd.blob, true),
    proc(cmd: ur.CommandData): bool {.closure, raises: [].} =
      guardedEntry(hist, doc, cmd.blob, false))

proc execute*(hist: var DocumentHistory; doc: var Document;
              commands: seq[ControlCommand];
              description: string = ""): ErrorFrame =
  ## Одна составная операция — одна запись истории. Сначала план (он ничего не
  ## меняет), затем общее место исполнения `commons/undo_redo`: именно оно
  ## применяет и записывает, поэтому «применить» и «записать» не могут
  ## разойтись.
  let plan = doc.planTransaction(commands, description)
  if not plan.frame.isOk():
    return plan.frame
  let entry = HistoryEntry(redo: plan.redo, undo: plan.undo,
                           description: description)
  var docPtr = addr doc
  var executor = executorFor(hist, docPtr)
  if not ur.execute(hist.mgr, executor, historyEntry(entry)):
    return (if hist.state.lastFrame.isOk():
              errFrame(ecInternal, "история не выполнила операцию",
                       "запись принята, но не выполнена")
            else: hist.state.lastFrame)
  okFrame()

proc undo*(hist: var DocumentHistory; doc: var Document): ErrorFrame =
  ## Отмена последней операции: применяются ОБРАТНЫЕ команды. Неудача отмены —
  ## не тихий успех: код возвращается вызывающему, документ при этом не тронут
  ## (отмена идёт транзакцией).
  var docPtr = addr doc
  var executor = executorFor(hist, docPtr)
  if not ur.undo(hist.mgr, executor):
    return (if hist.state.lastFrame.isOk():
              errFrame(ecInvalidArgument, "отменять нечего", "")
            else: hist.state.lastFrame)
  okFrame()

proc redo*(hist: var DocumentHistory; doc: var Document): ErrorFrame =
  ## Повтор последней отменённой операции исходными командами.
  var docPtr = addr doc
  var executor = executorFor(hist, docPtr)
  if not ur.redo(hist.mgr, executor):
    return (if hist.state.lastFrame.isOk():
              errFrame(ecInvalidArgument, "повторять нечего", "")
            else: hist.state.lastFrame)
  okFrame()

proc canUndo*(hist: DocumentHistory): bool {.inline.} = hist.mgr.canUndo
proc canRedo*(hist: DocumentHistory): bool {.inline.} = hist.mgr.canRedo
proc undoLen*(hist: DocumentHistory): int {.inline.} = hist.mgr.undoLen
proc redoLen*(hist: DocumentHistory): int {.inline.} = hist.mgr.redoLen
proc clear*(hist: var DocumentHistory) = hist.mgr.clear()
