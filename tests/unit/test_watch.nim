# tests/unit/test_watch.nim
#
# Unit-тесты наблюдения за файлами (`libs/watch`, issue #344).
#
# Критерии приёмки сформулированы временем: «два быстрых изменения — один
# рендер», «между рендерами не меньше интервала». Поэтому решение проверяется
# на подставных снимках и подставных часах: тест не спит и не мигает, а
# последовательность событий задаётся явно.

import std/[os, strutils, unittest]

import watch

proc file(path: string; mtime: int64; size: int64 = 10;
          exists = true): WatchFile =
  WatchFile(path: path, exists: exists, mtime: mtime, size: size)

proc started(files: seq[WatchFile]; cfg: WatchConfig): WatchState =
  ## Состояние «наблюдение уже идёт»: первый снимок принят, рендеров не было.
  result.files = files
  result.pendingSince = -1
  result.pendingChanged = @[]
  result.lastRender = -cfg.minIntervalMs
  result.renders = 0

let cfg = WatchConfig(debounceMs: 300, minIntervalMs: 500)

suite "watch: дебаунс и частота (#344)":
  test "без изменений рендера нет":
    var state = started(@[file("a", 1)], cfg)
    let decision = watchStep(state, @[file("a", 1)], 100, cfg)
    check decision.action == waWait
    check decision.reason == "no changes"
    check state.renders == 0

  test "изменение рендерится только после окна тишины":
    var state = started(@[file("a", 1)], cfg)
    var d = watchStep(state, @[file("a", 2)], 100, cfg)
    check d.action == waWait
    check d.reason == "debounce"
    check d.pendingMs == 300
    # Ровно на границе окна — уже рендер (условие «не меньше»).
    d = watchStep(state, @[file("a", 2)], 400, cfg)
    check d.action == waRender
    check d.changed == @["a"]
    check state.renders == 1

  test "два быстрых изменения дают ОДИН рендер":
    var state = started(@[file("a", 1)], cfg)
    check watchStep(state, @[file("a", 2)], 100, cfg).action == waWait
    check watchStep(state, @[file("a", 3)], 200, cfg).action == waWait
    let d = watchStep(state, @[file("a", 3)], 500, cfg)
    check d.action == waRender
    check d.changed == @["a"]
    check state.renders == 1
    # Серия закрыта: следующий опрос без правок ничего не рендерит.
    check watchStep(state, @[file("a", 3)], 900, cfg).action == waWait

  test "несколько файлов в серии называются все":
    var state = started(@[file("a", 1), file("b", 1)], cfg)
    discard watchStep(state, @[file("a", 2), file("b", 2)], 100, cfg)
    let d = watchStep(state, @[file("a", 2), file("b", 2)], 400, cfg)
    check d.action == waRender
    check "a" in d.changed
    check "b" in d.changed
    check d.changed.len == 2

  test "частота ограничена: следующий рендер не раньше minInterval":
    var state = started(@[file("a", 1)], cfg)
    discard watchStep(state, @[file("a", 2)], 100, cfg)
    check watchStep(state, @[file("a", 2)], 400, cfg).action == waRender
    # Правка сразу после рендера: окно тишины прошло, но частота — нет.
    discard watchStep(state, @[file("a", 3)], 450, cfg)
    var d = watchStep(state, @[file("a", 3)], 800, cfg)
    check d.action == waWait
    check d.reason == "rate limit"
    d = watchStep(state, @[file("a", 3)], 1000, cfg)
    check d.action == waRender
    check state.renders == 2

  test "удаление и появление файла — тоже изменения":
    var state = started(@[file("a", 1), file("b", 1)], cfg)
    discard watchStep(state, @[file("a", 1), file("b", 1, exists = false)],
                      100, cfg)
    var d = watchStep(state, @[file("a", 1), file("b", 1, exists = false)],
                      400, cfg)
    check d.action == waRender
    check "b" in d.changed
    # Новый файл в наблюдаемом каталоге.
    discard watchStep(state, @[file("a", 1), file("b", 1), file("c", 1)],
                      600, cfg)
    d = watchStep(state, @[file("a", 1), file("b", 1), file("c", 1)],
                  1200, cfg)
    check d.action == waRender
    check "c" in d.changed

  test "перестановка файлов в списке изменением не считается":
    var state = started(@[file("a", 1), file("b", 1)], cfg)
    let d = watchStep(state, @[file("b", 1), file("a", 1)], 900, cfg)
    check d.action == waWait
    check d.reason == "no changes"

suite "watch: снимок файлов":
  test "реальная правка файла видна по mtime и размеру":
    let dir = getTempDir() / "euterpia_watch_unit"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    let path = dir / "project.eproj"
    writeFile(path, "{}")
    var state = watchStart(@[path], 0, cfg)
    check state.files.len == 1
    check state.files[0].exists
    let before = state.files[0].mtime
    # mtime в наносекундах: даже быстрая запись даёт другое значение на
    # обычных ФС; если разрешение грубее, размер ниже всё равно изменится.
    writeFile(path, "{\"changed\":true}")
    let d = watchPoll(state, @[path], 100, cfg)
    check d.action == waWait
    check state.files[0].mtime != before or state.files[0].size > 2
    let rendered = watchPoll(state, @[path], 400, cfg)
    check rendered.action == waRender
    check rendered.changed == @[path]
    removeDir(dir)

  test "наблюдаются проект, сценарий и соседние партитуры":
    let dir = getTempDir() / "euterpia_watch_paths"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    let project = dir / "demo.eproj"
    let score = dir / "lead.notes"
    let scenario = dir / "edit.eus"
    let extra = dir / "external.txt"
    for path in [project, score, scenario, extra]:
      writeFile(path, "x")
    let paths = watchPaths(project, @[extra], scenarioPath = scenario)
    check project in paths
    check scenario in paths
    check score in paths
    check extra in paths
    check paths.len == 4
    removeDir(dir)
