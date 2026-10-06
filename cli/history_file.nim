# cli/history_file.nim
#
# История правок CLI КАК ФАЙЛ рядом с проектом (issue #331).
#
# Зачем файл, а не память:
#   CLI — процесс на одну команду: он поднялся, применил команду и завершился.
#   История команд control-слоя (`core/control/history`) живёт в памяти и
#   умирает вместе с процессом, поэтому `undo` в СЛЕДУЮЩЕМ запуске не нашёл бы
#   ни одной записи. Здесь стек записей (`HistoryEntry`) сериализуется в файл
#   рядом с проектом и переживает перезапуск.
#
# Что здесь и чего здесь НЕ должно быть (§20, §65):
#   ЗДЕСЬ — форма файла истории, её чтение/запись и атомарная замена. Тело
#   записи (`HistoryEntry`, `encodeEntry`/`decodeEntry`) уже описано ядром:
#   копии формата записи в клиенте быть не должно — иначе обратные команды
#   разойдутся с теми, что строит `planTransaction`.
#   НЕ ЗДЕСЬ — исполнение отмены/повтора: команды применяет control-слой, а
#   CLI лишь двигает записи между стеками и зовёт его.
#
# Файл — САЙДКАР проекта (`<проект>.history`), а не часть формата `.eproj`:
# история — это локальная практика работы с файлом, а не содержимое пьесы.
# Формат версионируется (§58/§59): чужая или будущая версия — отказ с кодом,
# а не «пустая история» молча.

import std/[json, os, strutils]

import control/history
import control/error_frame

# Формат ЗАПИСИ истории живёт в ядре (`core/control/history`); клиент его не
# дублирует, а пользуется им. Реэкспорт — чтобы изменяющие команды CLI
# собирали запись (`HistoryEntry`) тем же типом, что строит `planTransaction`.
export history

const
  HistoryFileVersion* = 1
    ## Версия формы файла истории. Меняется только при несовместимом
    ## изменении состава полей: тогда старый файл не читается молча как новый.
  HistorySuffix* = ".history"
    ## Расширение сайдкара. Намеренно НЕ совпадает с расширением проекта
    ## (`ProjectSuffixes`): файл истории не должен приниматься за проект.

type
  CliHistory* = object
    ## Стек истории CLI. `undoStack` — записи, которые можно отменить (новые в
    ## конце); `redoStack` — отменённые, которые можно повторить (новые в
    ## конце). Порядок совпадает с `commons/undo_redo`: новая операция
    ## сбрасывает повтор.
    undoStack*: seq[HistoryEntry]
    redoStack*: seq[HistoryEntry]

proc historyPath*(projectPath: string): string =
  ## Путь сайдкара истории для проекта: `<проект>.history`. Рядом с проектом,
  ## а не в общем каталоге: история живёт и умирает вместе со своим проектом.
  projectPath & HistorySuffix

# =============================================================================
# Форма файла
# =============================================================================

proc encodeHistory*(hist: CliHistory): string =
  ## Стек в текст файла. Каждая запись кодируется ядром
  ## (`HistoryEntry.encodeEntry`) и вкладывается как объект — файл читается
  ## человеком, а не строкой внутри строки.
  var root = newJObject()
  root["v"] = %HistoryFileVersion
  var undo = newJArray()
  for entry in hist.undoStack:
    undo.add parseJson(entry.encodeEntry())
  root["undo"] = undo
  var redo = newJArray()
  for entry in hist.redoStack:
    redo.add parseJson(entry.encodeEntry())
  root["redo"] = redo
  $root


proc decodeHistory*(hist: var CliHistory; text: string): ErrorFrame =
  ## Разбор файла. `ecOk` — файл прочитан (в том числе пустой текст). Иначе —
  ## `ecCheckFailed` с причиной: повреждённый, чужой или несовместимой версии
  ## файл НЕ превращается в «пустую историю» молча, иначе `undo` сказал бы
  ## «отменять нечего», скрыв настоящую проблему.
  hist = CliHistory()
  if text.strip().len == 0:
    return okFrame()
  var root: JsonNode
  try:
    root = parseJson(text)
  except JsonParsingError:
    return errFrame(ecCheckFailed, "файл истории не разобран как JSON",
                    "удалите его, чтобы начать историю заново")
  if root.kind != JObject or not root.hasKey("v"):
    return errFrame(ecCheckFailed, "файл истории повреждён или чужой",
                    "удалите его, чтобы начать историю заново")
  if root["v"].getInt != HistoryFileVersion:
    return errFrame(ecCheckFailed,
                    "версия файла истории не поддерживается: " & $root["v"].getInt,
                    "поддерживается версия " & $HistoryFileVersion)
  for part in [("undo", "отменяемые"), ("redo", "повторяемые")]:
    let key = part[0]
    if not root.hasKey(key):
      continue
    if root[key].kind != JArray:
      return errFrame(ecCheckFailed,
                      "раздел «" & part[1] & "» в файле истории не список",
                      "файл истории повреждён")
    for item in root[key].items:
      var entry: HistoryEntry
      if not entry.decodeEntry($item):
        return errFrame(ecCheckFailed,
                        "запись истории из раздела «" & part[1] & "» не разобрана",
                        "файл истории повреждён или создан другой версией")
      if key == "undo":
        hist.undoStack.add entry
      else:
        hist.redoStack.add entry
  okFrame()

# =============================================================================
# Атомарная запись текста
# =============================================================================

proc writeAtomicText*(path, text: string): tuple[ok: bool; message: string] =
  ## Атомарная запись: временный файл рядом с целью + переименование. Читатель
  ## видит либо старый файл истории целиком, либо новый; «половина истории» не
  ## появляется даже при обрыве процесса. Имя tmp содержит PID — параллельные
  ## записи не подменяют друг другу буфер (как у `writeAtomic` проекта).
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  try:
    writeFile(tmp, text)
  except CatchableError as e:
    return (false, "не удалось записать файл истории: " & e.msg)
  try:
    moveFile(tmp, path)
  except CatchableError as e:
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return (false, "не удалось заменить файл истории: " & e.msg)
  (true, "")

# =============================================================================
# Чтение и запись стека рядом с проектом
# =============================================================================

proc readHistory*(projectPath: string; hist: var CliHistory): ErrorFrame =
  ## История проекта. Отсутствие файла — не ошибка: истории просто ещё нет.
  ## Недоступный для чтения файл — ошибка среды (`ecEnvironment`).
  hist = CliHistory()
  let path = historyPath(projectPath)
  if not fileExists(path):
    return okFrame()
  var text: string
  try:
    text = readFile(path)
  except CatchableError as e:
    return errFrame(ecEnvironment, "не удалось прочитать файл истории: " & e.msg,
                    "проверьте права: " & path)
  decodeHistory(hist, text)

proc writeHistory*(projectPath: string; hist: CliHistory): ErrorFrame =
  ## Записать стек рядом с проектом. Ошибка — `ecEnvironment` с путём.
  let path = historyPath(projectPath)
  let written = writeAtomicText(path, encodeHistory(hist))
  if not written.ok:
    return errFrame(ecEnvironment, written.message,
                    "проверьте каталог и права: " & path)
  okFrame()

# =============================================================================
# Операции над стеком
# =============================================================================

proc pushEntry*(hist: var CliHistory; entry: HistoryEntry) =
  ## Новая операция: запись ложится на стек отмены, а повтор сбрасывается —
  ## после новой правки «будущее» прошлой ветки недостижимо (как в Commons).
  hist.undoStack.add entry
  hist.redoStack.setLen(0)

proc recordEntry*(projectPath: string; entry: HistoryEntry): ErrorFrame =
  ## Записать одну операцию в историю проекта. Читает текущий файл, дописывает
  ## запись и сохраняет — поэтому история прирастает, а не перезаписывается
  ## последней командой.
  var hist: CliHistory
  let read = readHistory(projectPath, hist)
  if not read.isOk():
    return read
  hist.pushEntry(entry)
  writeHistory(projectPath, hist)

proc popUndo*(hist: var CliHistory): tuple[ok: bool; entry: HistoryEntry] =
  ## Снять последнюю запись со стека отмены (не трогая повтор): решение, куда
  ## её положить, принимает вызывающий — он же отвечает за запись файла.
  if hist.undoStack.len == 0:
    return (false, HistoryEntry())
  let entry = hist.undoStack[^1]
  hist.undoStack.setLen(hist.undoStack.len - 1)
  (true, entry)

proc popRedo*(hist: var CliHistory): tuple[ok: bool; entry: HistoryEntry] =
  ## Снять последнюю запись со стека повтора.
  if hist.redoStack.len == 0:
    return (false, HistoryEntry())
  let entry = hist.redoStack[^1]
  hist.redoStack.setLen(hist.redoStack.len - 1)
  (true, entry)

proc pushRedo*(hist: var CliHistory; entry: HistoryEntry) =
  ## Положить запись в стек повтора (её сняли при отмене).
  hist.redoStack.add entry

proc pushUndo*(hist: var CliHistory; entry: HistoryEntry) =
  ## Вернуть запись в стек отмены (её сняли при повторе).
  hist.undoStack.add entry
