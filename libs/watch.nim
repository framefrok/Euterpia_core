# libs/watch.nim
#
# «Правил → послушал → поправил» без повторения команд руками (issue #344).
#
# Зачем библиотека, а не цикл в CLI:
#   дебаунс и ограничение частоты — это ПРАВИЛА, а не побочный эффект `sleep`.
#   Их надо проверить без файловой системы и без ожидания настоящих секунд,
#   иначе тест «два быстрых изменения → один рендер» либо мигает, либо спит.
#   Поэтому решение принимает чистая `watchStep` над снимками файлов, а
#   `watchPoll` только сканирует диск и передаёт снимок.
#
# Что здесь и чего здесь НЕТ:
#   ЗДЕСЬ — снимок файла (есть/нет, mtime, размер), сравнение, дебаунс,
#   ограничение частоты и решение «рендерить/ждать».
#   НЕ ЗДЕСЬ — сам рендер, печать, SIGINT и временные файлы: это клиент.
#   Библиотека не знает ни о `cli/`, ни о аудио.
#
# Почему mtime и размер, а не хеш:
#   хеш читает файл целиком на каждый опрос; для шаблона правки это дороже
#   самого рендера. mtime+размер — дешёвая эвристика, а ложное срабатывание
#   безвредно: лишний рендер, а не пропущенная правка.

import std/[monotimes, os, times]

const
  DefaultPollMs* = 200
    ## Как часто клиент сканирует файлы. Дебаунс и минимум считаются в мс.
  DefaultDebounceMs* = 300
    ## Сколько ждать тишины после последнего изменения. Две быстрые правки
    ## дают один рендер, а не два.
  DefaultMinIntervalMs* = 500
    ## Потолок частоты: между рендерами не меньше этого времени. Защита от
    ## шторма, когда редактор пишет файл несколько раз подряд.

type
  WatchFile* = object
    ## Снимок одного наблюдаемого файла. `exists = false` — файл удалён или
    ## ещё не создан: это тоже изменение, а не «ничего не произошло».
    path*: string
    exists*: bool
    mtime*: int64
      ## Наносекунды (см. `modificationTicks`): секунды слишком грубы для
      ## двух правок подряд внутри одной секунды.
    size*: int64

  WatchConfig* = object
    debounceMs*: int64
    minIntervalMs*: int64

  WatchAction* = enum
    waWait, waRender

  WatchDecision* = object
    ## Ответ «что делать сейчас». `changed` заполняется только у `waRender`,
    ## чтобы причина рендера была видна в отчёте, а не угадывалась.
    action*: WatchAction
    reason*: string
    changed*: seq[string]
    pendingMs*: int64
      ## Сколько изменение уже ждёт (для `waWait` — сколько осталось ждать).

  WatchState* = object
    ## Состояние наблюдения. Копируется свободно: обычное значение.
    files*: seq[WatchFile]
    pendingSince*: int64
      ## Время первого изменения в текущей серии; -1 — серии нет.
    pendingChanged*: seq[string]
    lastRender*: int64
      ## Время последнего рендера; инициализируется так, чтобы первый рендер
      ## не ждал `minIntervalMs` впустую.
    renders*: int

proc defaultWatchConfig*(): WatchConfig =
  WatchConfig(debounceMs: DefaultDebounceMs,
              minIntervalMs: DefaultMinIntervalMs)

proc modificationTicks*(t: Time): int64 =
  ## mtime в наносекундах эпохи. Разрешение файловой системы может быть
  ## грубее, но сравнение остаётся монотонным и не зависит от часового пояса.
  t.toUnix * 1_000_000_000'i64 + int64(t.nanosecond)

proc snapshot*(path: string): WatchFile =
  ## Снимок файла. Отсутствие — значение (`exists = false`), а не исключение:
  ## «файл удалили» — законное событие наблюдения.
  result.path = path
  if not fileExists(path):
    return
  try:
    let info = getFileInfo(path)
    result.exists = true
    result.mtime = modificationTicks(info.lastWriteTime)
    result.size = info.size
  except CatchableError:
    # Файл исчез между проверкой и чтением — считаем отсутствующим. Это не
    # ошибка: следующий опрос увидит его снова, если он вернулся.
    result.exists = false

proc scanFiles*(paths: openArray[string]): seq[WatchFile] =
  ## Снимки всех наблюдаемых файлов в порядке аргумента: порядок важен для
  ## детерминированного отчёта «что изменилось».
  for path in paths:
    result.add snapshot(path)

proc sameSnapshot*(a, b: WatchFile): bool =
  a.exists == b.exists and a.mtime == b.mtime and a.size == b.size

proc watchStart*(paths: openArray[string]; nowMs: int64;
                 cfg: WatchConfig = defaultWatchConfig()): WatchState =
  ## Начальное состояние: снимок без «изменений» (иначе первый же опрос
  ## считал бы только что запущенный процесс правкой).
  result.files = scanFiles(paths)
  result.pendingSince = -1
  result.pendingChanged = @[]
  result.renders = 0
  result.lastRender = nowMs - cfg.minIntervalMs

proc changedPaths*(before, after: seq[WatchFile]): seq[string] =
  ## Чем отличаются снимки. Сравнение идёт по пути, поэтому перестановка
  ## файлов в списке изменением не считается.
  for old in before:
    var found = false
    for fresh in after:
      if fresh.path == old.path:
        found = true
        if not sameSnapshot(old, fresh):
          result.add old.path
    if not found:
      result.add old.path
  for fresh in after:
    var known = false
    for old in before:
      if old.path == fresh.path:
        known = true
    if not known:
      result.add fresh.path

proc watchStep*(state: var WatchState; current: seq[WatchFile];
                nowMs: int64; cfg: WatchConfig): WatchDecision =
  ## Чистое решение по снимку: дебаунс, ограничение частоты, отчёт.
  ##
  ## Порядок проверок — часть контракта:
  ##   1. изменения накапливаются в одну серию (два быстрых — один рендер);
  ##   2. серия рендерится, когда тишина длится `debounceMs`;
  ##   3. но не чаще `minIntervalMs` — иначе автосохранение редактора даст
  ##      шторм рендеров.
  let changed = changedPaths(state.files, current)
  state.files = current
  if changed.len > 0:
    if state.pendingSince < 0:
      state.pendingSince = nowMs
      state.pendingChanged = @[]
    for path in changed:
      if path notin state.pendingChanged:
        state.pendingChanged.add path

  if state.pendingSince < 0:
    return WatchDecision(action: waWait, reason: "no changes", pendingMs: 0)

  let quietFor = nowMs - state.pendingSince
  if quietFor < cfg.debounceMs:
    return WatchDecision(action: waWait, reason: "debounce",
                         pendingMs: cfg.debounceMs - quietFor)
  let sinceRender = nowMs - state.lastRender
  if sinceRender < cfg.minIntervalMs:
    return WatchDecision(action: waWait, reason: "rate limit",
                         pendingMs: cfg.minIntervalMs - sinceRender)

  result.action = waRender
  result.reason = "changed"
  result.changed = state.pendingChanged
  result.pendingMs = quietFor
  state.pendingSince = -1
  state.pendingChanged = @[]
  state.lastRender = nowMs
  inc state.renders

proc watchPoll*(state: var WatchState; paths: openArray[string];
                nowMs: int64;
                cfg: WatchConfig = defaultWatchConfig()): WatchDecision =
  ## Опрос диска + `watchStep`. Клиенту не нужно самому собирать снимок.
  watchStep(state, scanFiles(paths), nowMs, cfg)

proc nowMs*(): int64 =
  ## Монотонные миллисекунды. Стенное время не годится: перевод часов не
  ## должен запускать или откладывать рендер.
  getMonoTime().ticks div 1_000_000'i64

proc watchPaths*(projectPath: string; extra: openArray[string] = [];
                 scenarioPath = ""): seq[string] =
  ## Что наблюдать: проект, сценарий (если задан), соседние партитуры
  ## (`*.notes`) и `*.eus`, плюс явные `--watch` файлы. Соседние файлы —
  ## потому что правка партитуры в каталоге проекта меняет звук, хотя сам
  ## `.eproj` не тронут (#344).
  var paths: seq[string] = @[]
  proc addUnique(path: string) =
    if path.len > 0 and path notin paths:
      paths.add path
  addUnique(projectPath)
  addUnique(scenarioPath)
  let dir = parentDir(projectPath)
  if dir.len > 0 and dirExists(dir):
    for path in walkFiles(dir / "*.notes"):
      addUnique(path)
    for path in walkFiles(dir / "*.eus"):
      addUnique(path)
  for path in extra:
    addUnique(path)
  result = paths

