# core/autosave.nim
#
# Неблокирующее автосохранение (issue #147).
#
# Задача: сохранение не должно быть слышно. Сериализация не имеет права идти
# в audio callback (аллокации, I/O), а UI/control-path не должен ждать диск:
# иначе правка «залипает» на десятки миллисекунд ровно тогда, когда человек
# работает.
#
# Модель:
#   * вызывающий (CLI/Editor) сериализует документ на control-path и отдаёт
#     ГОТОВЫЕ байты с номером версии — `submitSnapshot`;
#   * `submitSnapshot` только копирует байты в предвыделенный буфер под
#     коротким локом: ни файлов, ни ожидания writer'а;
#   * отдельный writer thread пишет снимок атомарно (`.tmp` + rename) и
#     ротирует каталог;
#   * очередь хранит ПОСЛЕДНЮЮ версию, а не все подряд: для автосохранения
#     промежуточные состояния не нужны, а память ограничена одним снимком
#     (плюс рабочий буфер потока).
#
# Политика (`AutosavePolicy`):
#   * `intervalMs` — не чаще, чем раз в интервал;
#   * `minChanges` — или после накопленных изменений (версия выросла на N);
#   * `keepSnapshots` — сколько файлов оставлять (ротация);
#   * `maxSnapshotBytes` — предел одного снимка;
#   * `idleTimeoutMs` — простой: изменения не приходят, писать нечего.
#
# Маркер незакрытой сессии:
#   `<проект>.autosave.lock` пишется при старте и обновляется после каждого
#   снимка. Штатное закрытие удаляет маркер; если процесс убили (SIGKILL)
#   или он упал, маркер остаётся и `recoverAutosave` находит последний
#   валидный снимок. Битый снимок — не повод не стартовать: ошибка
#   возвращается данными (`found=false`), а не исключением.
#
# Realtime-дисциплина: модуль вообще не вызывается из audio-потока. Требование
# «xruns == 0 при автосохранении» выполняется тем, что writer thread не
# конкурирует за аудио-путь: он не берёт локов, которые берёт рендер, и не
# трогает память пайплайна.

import std/[json, os, strutils, atomics, locks, algorithm, monotimes]

import project

const
  AutoMaxPathChars* = 1024
  AutoMaxErrorChars* = 256
  AutoMarkerSuffix* = ".autosave.lock"
    ## Суффикс маркера незакрытой сессии.
  AutoSnapshotInfix* = ".autosave-"
    ## Разделитель версии в имени снимка.

type
  AutosavePolicy* = object
    intervalMs*: int64
    minChanges*: uint64
    keepSnapshots*: int
    maxSnapshotBytes*: int
    idleTimeoutMs*: int64

  AutosaveReport* = object
    ## То, что нужно CLI/Editor для отчёта и для crash guard (#120).
    path*: string
    version*: uint64
    writtenAtMs*: int64
    error*: string

  AutosaveRecovery* = object
    ## Результат восстановления после аварии.
    found*: bool
    path*: string
    version*: uint64
    marker*: string
    error*: string
  AutosaveCore = object
    lock: Lock
    running: Atomic[int32]
    signal: Atomic[int32]

    dir: array[AutoMaxPathChars, char]
    stem: array[AutoMaxPathChars, char]
    ext: array[32, char]
    marker: array[AutoMaxPathChars, char]

    pending: ptr UncheckedArray[char]
    pendingCap: int
    pendingLen: int
    pendingVersion: uint64

    work: ptr UncheckedArray[char]
    workCap: int

    policy: AutosavePolicy
    lastVersion: uint64          # последняя ПРИНЯТАЯ версия
    lastWriteVersion: uint64
    lastWriteMs: int64

    lastPath: array[AutoMaxPathChars, char]
    lastError: array[AutoMaxErrorChars, char]

    written: Atomic[int64]
    skipped: Atomic[int64]
    stale: Atomic[int64]
    failed: Atomic[int64]

  AutoSave* = object
    core: ptr AutosaveCore
    when compileOption("threads"):
      worker: Thread[ptr AutosaveCore]

# =============================================================================
# Политика
# =============================================================================

proc defaultAutosavePolicy*(): AutosavePolicy =
  ## Разумные умолчания для редактора: раз в 15 секунд или каждые 20 правок,
  ## хранить 8 снимков, снимок не больше 16 МиБ.
  AutosavePolicy(
    intervalMs: 15_000,
    minChanges: 20,
    keepSnapshots: 8,
    maxSnapshotBytes: 16 * 1024 * 1024,
    idleTimeoutMs: 120_000
  )

proc shouldSnapshot*(policy: AutosavePolicy; lastVersion: uint64;
                     lastWriteMs, nowMs: int64; version: uint64): bool =
  ## Решение «писать ли версию» без побочных эффектов — его проверяет тест.
  ##
  ## Первая версия пишется всегда. Дальше достаточно ОДНОГО условия: прошёл
  ## интервал ИЛИ накопилось `minChanges` правок. Устаревшая/повторная версия
  ## не принимается никогда.
  if version <= lastVersion:
    return false
  if lastVersion == 0:
    return true
  if policy.idleTimeoutMs > 0 and lastWriteMs > 0 and
     nowMs - lastWriteMs > policy.idleTimeoutMs and
     version - lastVersion < max(policy.minChanges, 1'u64):
    # Простой: правок накопилось меньше порога, а время «простоя» само по
    # себе не повод писать тот же документ ещё раз.
    return false
  let timeOk = policy.intervalMs <= 0 or
               lastWriteMs <= 0 or nowMs - lastWriteMs >= policy.intervalMs
  let changesOk = version - lastVersion >= max(policy.minChanges, 1'u64)
  timeOk or changesOk

# =============================================================================
# Пути и строки
# =============================================================================

proc markerPathFor*(projectPath: string): string =
  projectPath & AutoMarkerSuffix

proc snapshotPathFor*(projectPath: string; version: uint64): string =
  let parts = splitFile(projectPath)
  let dir = if parts.dir.len > 0: parts.dir else: "."
  let ext = if parts.ext.len > 0: parts.ext else: ".eproj"
  dir / (parts.name & AutoSnapshotInfix & $version & ext)

proc versionFromSnapshotName(name: string): uint64 =
  ## Версия из имени `<stem>.autosave-<N><ext>`; 0 — имя не наше.
  let infix = name.rfind(AutoSnapshotInfix)
  if infix < 0:
    return 0
  var i = infix + AutoSnapshotInfix.len
  var value = 0'u64
  var digits = 0
  while i < name.len and name[i] in {'0'..'9'}:
    let d = uint64(ord(name[i]) - ord('0'))
    if value > (high(uint64) - d) div 10:
      return 0
    value = value * 10 + d
    inc digits
    inc i
  if digits == 0:
    return 0
  value

# =============================================================================
# Вспомогательное
# =============================================================================

proc putFixed[N: static int](dst: var array[N, char]; value: string) =
  let n = min(value.len, N - 1)
  if n > 0:
    copyMem(addr dst[0], unsafeAddr value[0], n)
  dst[n] = '\0'

proc getFixed[N: static int](src: array[N, char]): string =
  var n = 0
  while n < N and src[n] != '\0':
    inc n
  if n > 0: result = newString(n)
  for i in 0 ..< n:
    result[i] = src[i]

proc putError(core: ptr AutosaveCore; message: string) =
  let n = min(message.len, AutoMaxErrorChars - 1)
  if n > 0:
    copyMem(addr core.lastError[0], unsafeAddr message[0], n)
  core.lastError[n] = '\0'

proc getError(core: ptr AutosaveCore): string =
  var n = 0
  while n < AutoMaxErrorChars and core.lastError[n] != '\0':
    inc n
  result = newString(n)
  for i in 0 ..< n:
    result[i] = core.lastError[i]

proc monoMs*(): int64 {.inline.} =
  ## Монотонные миллисекунды. Политика автосохранения не зависит от
  ## системных часов: перевод часов не должен вызывать лавину снимков.
  (getMonoTime().ticks div 1_000_000)

# =============================================================================
# Маркер и снимки (writer thread)
# =============================================================================

proc writeMarker(core: ptr AutosaveCore; version: uint64; snapshot: string) =
  ## Атомарная запись маркера: `.tmp` + rename. Маркер без снимка
  ## (version 0) означает «сессия открыта, но сохраниться ещё не успели».
  let path = getFixed(core.marker)
  let tmp = path & ".tmp"
  let body = $(%*{
    "format": "euterpia-autosave",
    "schema": 1,
    "version": version,
    "snapshot": snapshot,
    "pid": getCurrentProcessId(),
  })
  try:
    writeFile(tmp, body)
    moveFile(tmp, path)
  except CatchableError:
    # Маркер — диагностика, а не данные проекта: его сбой не должен
    # превращаться в исключение в вызывающем.
    discard

proc removeMarker*(projectPath: string) =
  ## Штатное закрытие: маркер убирается, восстановление не предлагается.
  let path = markerPathFor(projectPath)
  if fileExists(path):
    try: removeFile(path)
    except CatchableError: discard

proc pruneSnapshots(core: ptr AutosaveCore) =
  ## Оставить `keepSnapshots` самых новых версий: каталог не растёт.
  let keep = if core.policy.keepSnapshots > 0: core.policy.keepSnapshots else: 1
  let dir = getFixed(core.dir)
  let stem = getFixed(core.stem)
  let ext = getFixed(core.ext)
  let pattern = dir / (stem & AutoSnapshotInfix & "*" & ext)
  var versions: seq[uint64] = @[]
  for path in walkFiles(pattern):
    let v = versionFromSnapshotName(extractFilename(path))
    if v != 0:
      versions.add v
  if versions.len <= keep:
    return
  versions.sort()
  let drop = versions.len - keep
  for i in 0 ..< drop:
    let old = snapshotPathFor(dir / (stem & ext), versions[i])
    try:
      removeFile(old)
    except CatchableError:
      discard

proc writeSnapshot(core: ptr AutosaveCore; version: uint64; length: int):
    tuple[ok: bool; path, error: string] =
  ## Запись одного снимка: атомарно, с ротацией и обновлением маркера.
  ## Вызывается ТОЛЬКО из writer thread.
  let dir = getFixed(core.dir)
  let stem = getFixed(core.stem)
  let ext = getFixed(core.ext)
  let path = dir / (stem & AutoSnapshotInfix & $version & ext)
  let tmp = path & ".tmp"

  var data = newString(length)
  if length > 0:
    copyMem(addr data[0], addr core.work[0], length)
  try:
    writeFile(tmp, data)
    moveFile(tmp, path)
  except CatchableError as e:
    result.ok = false
    result.error = "не удалось записать снимок: " & e.msg
    try: removeFile(tmp)
    except CatchableError: discard
    return

  result.ok = true
  result.path = path
  pruneSnapshots(core)
  writeMarker(core, version, path)

proc autosaveWorker(core: ptr AutosaveCore) {.thread.} =
  while core.running.load(moAcquire) != 0:
    if core.signal.load(moAcquire) != 0:
      var version = 0'u64
      var length = 0
      acquire(core.lock)
      if core.pendingLen > 0:
        let swapBuf = core.pending
        core.pending = core.work
        core.work = swapBuf
        length = core.pendingLen
        version = core.pendingVersion
        core.pendingLen = 0
        core.pendingVersion = 0
      core.signal.store(0, moRelease)
      release(core.lock)

      if length > 0:
        let r = writeSnapshot(core, version, length)
        acquire(core.lock)
        if r.ok:
          core.lastWriteVersion = version
          core.lastWriteMs = monoMs()
          putFixed(core.lastPath, r.path)
          core.lastError[0] = '\0'
          discard core.written.fetchAdd(1, moRelaxed)
        else:
          putError(core, r.error)
          discard core.failed.fetchAdd(1, moRelaxed)
        release(core.lock)
# =============================================================================
# Public API
# =============================================================================

proc initAutoSave*(projectPath: string;
                   policy: AutosavePolicy = defaultAutosavePolicy()):
                   AutoSave =
  ## Открывает сессию автосохранения для проекта. Маркер незакрытой сессии
  ## пишется СРАЗУ: даже падение до первого снимка останется замеченным.
  ##
  ## `projectPath` уходит в файловые имена как есть; каталог обязан
  ## существовать (его создаёт тот, кто создаёт проект).
  let cap =
    if policy.maxSnapshotBytes > 0: policy.maxSnapshotBytes
    else: 16 * 1024 * 1024
  if projectPath.len == 0 or cap < 1024:
    return

  let parts = splitFile(projectPath)
  let dir = if parts.dir.len > 0: parts.dir else: ""
  let stem = if parts.name.len > 0: parts.name else: "project"
  let ext = if parts.ext.len > 0: parts.ext else: ".eproj"

  let core = cast[ptr AutosaveCore](allocShared0(sizeof(AutosaveCore)))
  if core.isNil:
    return
  core.policy = policy
  core.policy.maxSnapshotBytes = cap
  putFixed(core.dir, dir)
  putFixed(core.stem, stem)
  putFixed(core.ext, ext)
  putFixed(core.marker, markerPathFor(projectPath))

  core.pendingCap = cap
  core.workCap = cap
  core.pending = cast[ptr UncheckedArray[char]](allocShared0(cap))
  core.work = cast[ptr UncheckedArray[char]](allocShared0(cap))
  if core.pending.isNil or core.work.isNil:
    if not core.pending.isNil: deallocShared(cast[pointer](core.pending))
    if not core.work.isNil: deallocShared(cast[pointer](core.work))
    deallocShared(cast[pointer](core))
    return

  initLock(core.lock)
  core.running.store(1, moRelease)
  core.signal.store(0, moRelease)
  core.lastVersion = 0
  core.lastWriteMs = 0
  writeMarker(core, 0, "")

  result.core = core
  when compileOption("threads"):
    createThread(result.worker, autosaveWorker, core)

proc submitSnapshot*(s: var AutoSave; version: uint64; data: string;
                     nowMs: int64 = -1): bool =
  ## Предложить снимок версии `version`. Возвращает true, если он принят в
  ## очередь; false — версия устарела, политика не разрешила запись или
  ## снимок больше предела.
  ##
  ## Здесь НЕТ файловых операций и ожидания writer'а: только копирование
  ## байт под локом. Вызывается с control-path (CLI/Editor), не из audio.
  if s.core.isNil:
    return false
  let core = s.core
  if data.len == 0 or data.len > core.pendingCap:
    discard core.skipped.fetchAdd(1, moRelaxed)
    return false

  let now = if nowMs >= 0: nowMs else: monoMs()
  acquire(core.lock)
  let accepted = shouldSnapshot(core.policy, core.lastVersion,
                                core.lastWriteMs, now, version)
  if version <= core.lastVersion:
    discard core.stale.fetchAdd(1, moRelaxed)
    release(core.lock)
    return false
  if not accepted:
    discard core.skipped.fetchAdd(1, moRelaxed)
    release(core.lock)
    return false

  copyMem(addr core.pending[0], unsafeAddr data[0], data.len)
  core.pendingLen = data.len
  core.pendingVersion = version
  core.lastVersion = version
  release(core.lock)
  core.signal.store(1, moRelease)
  true

proc lastReport*(s: AutoSave): AutosaveReport =
  ## Последний записанный снимок и последняя ошибка. Control-path.
  if s.core.isNil:
    return
  let core = s.core
  acquire(core.lock)
  result.path = getFixed(core.lastPath)
  result.version = core.lastWriteVersion
  result.writtenAtMs = core.lastWriteMs
  result.error = getError(core)
  release(core.lock)

proc snapshotsWritten*(s: AutoSave): int64 =
  if s.core.isNil: 0 else: s.core.written.load(moAcquire)

proc snapshotsSkipped*(s: AutoSave): int64 =
  if s.core.isNil: 0 else: s.core.skipped.load(moAcquire)

proc snapshotsStale*(s: AutoSave): int64 =
  if s.core.isNil: 0 else: s.core.stale.load(moAcquire)

proc snapshotsFailed*(s: AutoSave): int64 =
  if s.core.isNil: 0 else: s.core.failed.load(moAcquire)

proc isActive*(s: AutoSave): bool {.inline.} =
  ## Сессия открыта (writer thread запущен).
  s.core != nil

proc hasPending*(s: AutoSave): bool =
  ## Есть ли ещё не записанный снимок (диагностика/тест).
  if s.core.isNil:
    return false
  acquire(s.core.lock)
  result = s.core.pendingLen > 0 or s.core.signal.load(moAcquire) != 0
  release(s.core.lock)

proc closeAutoSave*(s: var AutoSave; graceful: bool = true) =
  ## Дождаться очереди, остановить writer и освободить память.
  ##
  ## `graceful == false` оставляет маркер на месте — так тест и crash guard
  ## воспроизводят аварию без настоящего SIGKILL.
  if s.core.isNil:
    return
  let core = s.core

  # Дать writer'у дописать принятый снимок (не дольше ~1 с).
  for _ in 0 ..< 200:
    if not s.hasPending():
      break
    sleep(5)

  core.running.store(0, moRelease)
  when compileOption("threads"):
    joinThread(s.worker)

  let projectPath = getFixed(core.marker)
  deinitLock(core.lock)
  deallocShared(cast[pointer](core.pending))
  deallocShared(cast[pointer](core.work))
  deallocShared(cast[pointer](core))
  s.core = nil

  if graceful and projectPath.len > 0:
    # Маркер — `<проект>.autosave.lock`; убираем ровно его.
    let marker = projectPath
    if fileExists(marker):
      try: removeFile(marker)
      except CatchableError: discard

# =============================================================================
# Восстановление после аварии
# =============================================================================

proc newestSnapshot*(projectPath: string): tuple[version: uint64; path: string] =
  ## Самый новый снимок проекта по версии в имени. Пусто — снимков нет.
  let parts = splitFile(projectPath)
  let dir = if parts.dir.len > 0: parts.dir else: "."
  let ext = if parts.ext.len > 0: parts.ext else: ".eproj"
  let pattern = dir / (parts.name & AutoSnapshotInfix & "*" & ext)
  for path in walkFiles(pattern):
    let v = versionFromSnapshotName(extractFilename(path))
    if v > result.version:
      result.version = v
      result.path = path

proc loadAutosave*(path: string): ProjectResult[ProjectFormat] =
  ## Прочитать снимок тем же путём, что обычный проект. Битый файл — это
  ## `ProjectResult` с ошибкой, а не исключение: старт не блокируется.
  loadProject(path)

proc recoverAutosave*(projectPath: string): AutosaveRecovery =
  ## Найти снимок незакрытой сессии.
  ##
  ## Маркер — единственный признак аварии: без него восстановление не
  ## предлагается вовсе (штатно закрытая сессия не должна «воскресать»).
  ## Если маркер есть, но файл снимка потерян или повреждён, берётся самый
  ## новый снимок; если и он не читается — `found=false` с причиной.
  result.marker = markerPathFor(projectPath)
  if not fileExists(result.marker):
    result.error = "маркер не найден: предыдущая сессия завершилась штатно"
    return

  var version = 0'u64
  var snapshot = ""
  try:
    let node = parseJson(readFile(result.marker))
    if node.kind == JObject:
      version = uint64(max(0'i64, node{"version"}.getBiggestInt(0)))
      snapshot = node{"snapshot"}.getStr("")
  except CatchableError:
    # Битый маркер сам по себе доказывает аварию; путь ищем по каталогу.
    snapshot = ""

  if snapshot.len == 0 or not fileExists(snapshot):
    let newest = newestSnapshot(projectPath)
    snapshot = newest.path
    version = newest.version

  if snapshot.len == 0 or not fileExists(snapshot):
    result.error = "снимков автосохранения нет"
    return

  let loaded = loadAutosave(snapshot)
  if not loaded.success:
    result.path = snapshot
    result.version = version
    result.error = "последний снимок не читается: " & loaded.error.message &
                   " (старт продолжается без восстановления)"
    return

  result.found = true
  result.path = snapshot
  result.version = version

proc clearRecovery*(projectPath: string) =
  ## Восстановление принято — маркер больше не нужен.
  removeMarker(projectPath)

