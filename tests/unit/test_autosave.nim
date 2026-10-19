# tests/unit/test_autosave.nim
#
# Автосохранение (#147): политика, writer thread, ротация, восстановление.
#
# Проверяется не «файл появился», а свойства, ради которых модуль написан:
#   * решение политики не зависит от часов и принимается до копирования;
#   * `submitSnapshot` не ждёт диск — очередь хранит только последнюю версию;
#   * повторная/устаревшая версия не перезаписывает новую;
#   * маркер живёт до аварии и исчезает при штатном закрытии;
#   * битый снимок не блокирует старт: ошибка — данные, а не исключение;
#   * ротация не даёт каталогу расти.

import std/[unittest, os, times, strutils, json]

import project
import autosave

const
  TestSuffix = ".eproj"

proc freshDir(tag: string): string =
  result = getTempDir() / ("euterpia_autosave_" & tag & "_" &
                           $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc tinyProject(name: string): ProjectFormat =
  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.metadata = ProjectMetadata(
    name: name, author: "test", sampleRate: 48000.0f32, tempo: 120.0f32,
    timeSignature: TimeSignatureFormat(numerator: 4, denominator: 4),
    created: "", modified: "")

proc projectJson(name: string; pad: int = 0): string =
  var p = tinyProject(name)
  p.metadata.author = repeat("x", pad)
  $p.toJson

proc waitUntil(cond: proc(): bool {.closure.}): bool =
  for _ in 0 ..< 800:
    if cond():
      return true
    sleep(5)
  false

proc fastPolicy(keep = 8): AutosavePolicy =
  AutosavePolicy(intervalMs: 0, minChanges: 1, keepSnapshots: keep,
                 maxSnapshotBytes: 1024 * 1024, idleTimeoutMs: 0)

suite "autosave: политика (#147)":
  test "первая версия пишется, повторная — нет":
    let p = defaultAutosavePolicy()
    check p.shouldSnapshot(0, 0, 1000, 1'u64)
    check not p.shouldSnapshot(1, 1000, 2000, 1'u64)
    check not p.shouldSnapshot(2, 1000, 2000, 2'u64)   # интервал не прошёл

  test "интервал ИЛИ число изменений":
    var p = defaultAutosavePolicy()
    p.intervalMs = 1000
    p.minChanges = 10
    # Время не прошло, но 10 правок накопились — пишем.
    check p.shouldSnapshot(5, 10_000, 10_500, 15'u64)
    # Прошёл интервал — пишем даже одну правку.
    check p.shouldSnapshot(5, 10_000, 11_100, 6'u64)
    # Ни времени, ни изменений — пропускаем.
    check not p.shouldSnapshot(5, 10_000, 10_500, 6'u64)

  test "простой не вызывает запись без изменений":
    var p = defaultAutosavePolicy()
    p.intervalMs = 10
    p.minChanges = 100
    p.idleTimeoutMs = 5000
    check not p.shouldSnapshot(5, 10_000, 20_000, 6'u64)

suite "autosave: writer thread (#147)":
  test "снимок пишется атомарно, читается и попадает в отчёт":
    let dir = freshDir("write")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)

    var s = initAutoSave(projectPath, fastPolicy())
    check s.isActive()
    check fileExists(markerPathFor(projectPath))   # маркер — сразу
    defer: closeAutoSave(s)

    check s.submitSnapshot(1, projectJson("Song A"), nowMs = 1000)
    check waitUntil(proc(): bool = s.snapshotsWritten() >= 1)

    let report = s.lastReport()
    check report.version == 1'u64
    check report.path.len > 0
    check fileExists(report.path)
    check report.error.len == 0

    let loaded = loadAutosave(report.path)
    check loaded.success
    check loaded.value.metadata.name == "Song A"

  test "устаревшая версия отклоняется и не затирает новую":
    let dir = freshDir("stale")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)

    var s = initAutoSave(projectPath, fastPolicy())
    defer: closeAutoSave(s)

    check s.submitSnapshot(5, projectJson("Five"), nowMs = 1)
    check waitUntil(proc(): bool = s.snapshotsWritten() >= 1)
    check not s.submitSnapshot(4, projectJson("Four"), nowMs = 2)
    check s.snapshotsStale() == 1
    check s.lastReport().version == 5'u64

  test "под нагрузкой сохраняется ПОСЛЕДНЯЯ версия":
    let dir = freshDir("latest")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)

    var s = initAutoSave(projectPath, fastPolicy())
    defer: closeAutoSave(s)

    for v in 1'u64 .. 50'u64:
      check s.submitSnapshot(v, projectJson("v" & $v), nowMs = int64(v))
    check waitUntil(proc(): bool = s.lastReport().version == 50'u64)
    let report = s.lastReport()
    check report.version == 50'u64
    check loadAutosave(report.path).success
    # Промежуточные версии не пишутся по одной: очередь держит последнюю.
    check s.snapshotsWritten() < 50

  test "слишком большой снимок отвергается":
    let dir = freshDir("big")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)

    var policy = fastPolicy()
    policy.maxSnapshotBytes = 2048
    var s = initAutoSave(projectPath, policy)
    defer: closeAutoSave(s)
    check not s.submitSnapshot(1, projectJson("Big", pad = 4096), nowMs = 1)
    check s.snapshotsSkipped() == 1

  test "ротация оставляет ровно keepSnapshots файлов":
    let dir = freshDir("rotate")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)

    var s = initAutoSave(projectPath, fastPolicy(keep = 3))
    defer: closeAutoSave(s)

    for v in 1'u64 .. 5'u64:
      check s.submitSnapshot(v, projectJson("v" & $v), nowMs = int64(v))
      check waitUntil(proc(): bool = s.snapshotsWritten() >= int64(v))

    let pattern = dir / ("song" & AutoSnapshotInfix & "*" & TestSuffix)
    var found = 0
    for _ in walkFiles(pattern):
      inc found
    check found == 3
    check s.lastReport().version == 5'u64

suite "autosave: восстановление (#147)":
  test "авария оставляет маркер, recover находит снимок":
    let dir = freshDir("recover")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)

    var s = initAutoSave(projectPath, fastPolicy())
    check s.submitSnapshot(7, projectJson("Saved"), nowMs = 1)
    check waitUntil(proc(): bool = s.snapshotsWritten() >= 1)
    # SIGKILL без штатного закрытия: маркер остаётся.
    closeAutoSave(s, graceful = false)
    check fileExists(markerPathFor(projectPath))

    let rec = recoverAutosave(projectPath)
    check rec.found
    check rec.version == 7'u64
    check fileExists(rec.path)
    check loadAutosave(rec.path).success

    clearRecovery(projectPath)
    check not recoverAutosave(projectPath).found

  test "штатное закрытие убирает маркер":
    let dir = freshDir("clean")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)

    var s = initAutoSave(projectPath, fastPolicy())
    check s.submitSnapshot(1, projectJson("Clean"), nowMs = 1)
    check waitUntil(proc(): bool = s.snapshotsWritten() >= 1)
    closeAutoSave(s)
    check not fileExists(markerPathFor(projectPath))
    check not recoverAutosave(projectPath).found

  test "снимок не перезаписывает файл пользователя":
    let dir = freshDir("userfile")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)
    writeFile(projectPath, "USER DATA")

    var s = initAutoSave(projectPath, fastPolicy())
    check s.submitSnapshot(1, projectJson("Auto"), nowMs = 1)
    check waitUntil(proc(): bool = s.snapshotsWritten() >= 1)
    closeAutoSave(s)
    check readFile(projectPath) == "USER DATA"

  test "битый снимок не блокирует старт":
    let dir = freshDir("corrupt")
    defer: removeDir(dir)
    let projectPath = dir / ("song" & TestSuffix)
    let snapshot = snapshotPathFor(projectPath, 3)
    writeFile(snapshot, "не json")
    writeFile(markerPathFor(projectPath),
      $(%*{"format": "euterpia-autosave", "version": 3,
           "snapshot": snapshot, "pid": 1}))

    let rec = recoverAutosave(projectPath)
    check not rec.found
    check rec.error.len > 0
    check rec.path == snapshot
    # Чтение возвращает ошибку данными, а не исключением.
    check not loadAutosave(snapshot).success

