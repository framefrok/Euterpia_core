# cli/cmd_watch.nim
#
# `euterpia watch` — авто-ререндер при изменении файлов проекта (issue #344).
#
# Зачем команда:
#   «правил файл → послушал → поправил» в CLI требует двух команд и ручного
#   повторения. Для проектов, где рендер занимает секунды, это основная форма
#   работы: watch держит процесс, ловит изменение и перерендеривает.
#
# Границы:
#   * дебаунс и ограничение частоты — `libs/watch` (проверяются без ФС);
#   * рендер — тот же путь, что `render` (`cmd_render.renderPreparedProject`),
#     поэтому watch не заводит второй рендерер;
#   * проект не пишется вообще: команда только читает файл и пишет WAV.
#
# Атомарность вывода:
#   Рендер идёт во временный файл `<out>.tmp-<pid>` и переименовывается только
#   после успеха. Ctrl-C во время рендера обрабатывается после его завершения
#   (рендер не прерывается на середине), затем временный файл убирается —
#   «прерывание не оставляет временных файлов и не портит проект».
#
# Коды возврата: 0 — остановлено пользователем или `--once`; 1 — проект не
# читается/не рендерится в `--once`; 2 — среда.

import std/[json, os, strutils, syncio]

import context
import cli_spec
import cmd_project
import cmd_render
import watch
import project

const
  WatchSpec* = CommandSpec(
    name: "watch",
    summary: "наблюдать за проектом и перерендеривать при изменениях",
    synopsis: "watch [проект.eproj] [ключи]",
    args: @[
      arg("проект.eproj", "что наблюдать; по умолчанию " & DefaultProjectFile),
    ],
    options: @[
      opt("--file", "проект, если он не задан позиционно",
          value = projectSuffixesHint()),
      opt("--out", "куда писать WAV; без ключа — рядом с проектом",
          value = "файл.wav"),
      opt("--watch", "дополнительный файл для наблюдения; можно повторять",
          value = "файл"),
      opt("--seconds", "длительность каждого рендера; без ключа — партитура плюс хвост",
          value = "секунды"),
      opt("--tail", "добавка после последней ноты, секунды", value = "секунды",
          default = $int(DefaultTailSeconds)),
      opt("--sample-rate", "частота рендера; без ключа — из проекта",
          value = "Гц"),
      opt("--bits", "биты WAV (16, 24, 32)", value = "бит",
          default = $DefaultBits),
      opt("--poll", "как часто опрашивать файлы", value = "мс",
          default = $DefaultPollMs),
      opt("--debounce", "сколько ждать тишины после правки", value = "мс",
          default = $DefaultDebounceMs),
      opt("--min-interval", "минимальный интервал между рендерами", value = "мс",
          default = $DefaultMinIntervalMs),
      switch("--once", "отрендерить один раз и выйти (проверка в CI)"),
    ],
    example: "euterpia watch demo.eproj --out demo.wav --debounce 300",
    fields: @[
      field("path", "наблюдаемый проект"),
      field("out", "файл, который перезаписывается"),
      field("watched", "файлы под наблюдением"),
      field("renders", "сколько рендеров выполнено"),
      field("cycles", "сколько опросов сделано"),
      field("lastMs", "длительность последнего рендера, мс"),
      field("lastChanged", "что изменилось перед последним рендером"),
      field("stopped", "`signal` | `once`"),
      field("render", "результат последнего рендера: out, peak, rms, silent"),
    ],
    notes: @[
      "первый рендер выполняется сразу: watch — это «послушал», а не «ждал первой правки»",
      "дебаунс (`--debounce`) и `--min-interval` не дают шторму рендеров: две быстрые правки — один рендер (#344)",
      "наблюдаются проект, `*.notes` и `*.eus` рядом с ним, плюс явные `--watch` файлы",
      "output пишется атомарно: `<out>.tmp-<pid>` + переименование; Ctrl-C не оставляет временных файлов",
      "проект не изменяется: watch только читает его и пишет WAV",
      "`--once` — один рендер без ожидания: так команда проверяется в CI",
      "в `--json` каждый рендер — отдельная строка NDJSON, итог — обычный конверт",
    ])

  WatchKeys* = WatchSpec.optionKeys

type
  WatchScan = object
    ok: bool
    rep: Report
    project, outPath: string
    haveOut: bool
    extras: seq[string]
    seconds: float64
    haveSeconds: bool
    tail: float64
    bits, sampleRate: int
    pollMs, debounceMs, minIntervalMs: int64
    once: bool

var gWatchStop = false
  ## Флаг Ctrl-C. Обработчик только ставит его: рендер не прерывается на
  ## середине, иначе WAV остался бы недописанным.

proc parseNumber(text, key: string; low, high: float64;
                 ok: var bool): float64 =
  var value: float
  try:
    value = parseFloat(text.strip())
  except ValueError:
    ok = false
    return 0.0
  if not (float64(value) >= low) or not (float64(value) <= high):
    ok = false
    return 0.0
  ok = true
  float64(value)

proc scanArgs(args: seq[string]): WatchScan =
  result.project = DefaultProjectFile
  result.tail = DefaultTailSeconds
  result.bits = DefaultBits
  result.pollMs = DefaultPollMs
  result.debounceMs = DefaultDebounceMs
  result.minIntervalMs = DefaultMinIntervalMs
  var positional: seq[string] = @[]
  let tokens = splitInline(args)
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token == "--once":
      result.once = true
      inc i
      continue
    if token in ["--file", "--out", "--watch", "--seconds", "--tail",
                 "--sample-rate", "--bits", "--poll", "--debounce",
                 "--min-interval"]:
      if i + 1 >= tokens.len:
        result.rep = usageError(token & " требует значение",
                                "ключи: " & WatchKeys.join(", "))
        return
      let value = tokens[i + 1]
      var ok = true
      case token
      of "--file": result.project = value
      of "--out":
        result.outPath = value
        result.haveOut = true
      of "--watch": result.extras.add value
      of "--seconds":
        result.seconds = parseNumber(value, token, 0.001, 86_400.0, ok)
        result.haveSeconds = true
      of "--tail": result.tail = parseNumber(value, token, 0.0, 600.0, ok)
      of "--bits":
        result.bits = int(parseNumber(value, token, 16.0, 32.0, ok))
      of "--sample-rate":
        result.sampleRate = int(parseNumber(value, token, 8000.0, 384_000.0, ok))
      of "--poll":
        result.pollMs = int64(parseNumber(value, token, 20.0, 60_000.0, ok))
      of "--debounce":
        result.debounceMs = int64(parseNumber(value, token, 0.0, 60_000.0, ok))
      of "--min-interval":
        result.minIntervalMs = int64(parseNumber(value, token, 0.0, 600_000.0, ok))
      else: discard
      if not ok:
        result.rep = usageError(token &
          ": ожидается число в допустимом диапазоне, получено «" & value & "»")
        return
      inc i, 2
      continue
    if token.startsWith("--"):
      result.rep = usageError("неизвестный ключ watch: " & token,
                              "ключи: " & WatchKeys.join(", "))
      return
    positional.add token
    inc i
  if positional.len > 1:
    result.rep = usageError("watch принимает один проект, получено: " &
                            positional.join(" "))
    return
  if positional.len == 1:
    result.project = positional[0]
  if not result.haveOut:
    result.outPath = result.project.changeFileExt(".wav")
  result.ok = true

proc removeQuietly(path: string) =
  try:
    if fileExists(path):
      removeFile(path)
  except CatchableError:
    discard

proc watchRender(ctx: var Ctx; scan: WatchScan; proj: ProjectFormat;
                 tmpPath: string): Report =
  ## Один рендер во временный файл. Успех/отказ — отчёт `render`, поэтому
  ## watch не пересказывает причину своими словами.
  renderPreparedProject(ctx, scan.project, tmpPath, proj,
                        seconds = scan.seconds,
                        tail = scan.tail,
                        sampleRate = scan.sampleRate,
                        bits = scan.bits)

proc publish(tmpPath, outPath: string): bool =
  ## Переименование после успешного рендера. `moveFile` поверх существующего
  ## файла работает на всех целевых ОС (os.moveFile).
  try:
    moveFile(tmpPath, outPath)
    true
  except CatchableError:
    false

proc renderCycle(ctx: var Ctx; scan: WatchScan; cycle: int;
                 changed: seq[string]; factsOut: var JsonNode): Report =
  ## Один цикл: чтение проекта, рендер в tmp, публикация, отчёт.
  let loaded = loadAt(scan.project)
  if not loaded.ok:
    return loaded.rep
  let started = nowMs()
  # Имя временного файла кончается на `.wav`: формат вывода определяется
  # расширением (§58), и `.tmp-123` энкодер отверг бы как неизвестный формат.
  let tmpPath = scan.outPath.changeFileExt(".tmp-" &
    $getCurrentProcessId() & ".wav")
  var rep = watchRender(ctx, scan, loaded.proj, tmpPath)
  if not rep.ok:
    removeQuietly(tmpPath)
    return rep
  if ctx.dryRun:
    removeQuietly(tmpPath)
  elif not publish(tmpPath, scan.outPath):
    removeQuietly(tmpPath)
    return envError("не удалось заменить " & scan.outPath,
                    "проверьте каталог и права")
  let elapsed = nowMs() - started
  var facts = newJObject()
  facts["cycle"] = %cycle
  facts["ms"] = %elapsed
  facts["out"] = %scan.outPath
  if rep.body != nil:
    if rep.body.hasKey("peak"):
      facts["peak"] = rep.body["peak"]
    if rep.body.hasKey("rms"):
      facts["rms"] = rep.body["rms"]
    if rep.body.hasKey("silent"):
      facts["silent"] = rep.body["silent"]
  var changedJson = newJArray()
  for path in changed:
    changedJson.add %path
  facts["changed"] = changedJson
  if ctx.mode == omJson:
    # Каждый рендер — отдельная строка NDJSON: итог придёт отдельным конвертом.
    var line = newJObject()
    line["type"] = %"render"
    for key, value in facts:
      line[key] = value
    echo $line
  factsOut = facts
  okReport(body = facts)


proc reportRenderLine(index: int; facts: JsonNode): string =
  result = "рендер " & $index & ": " & facts["out"].getStr & " за " &
    $facts["ms"].getInt & " мс"
  if facts.hasKey("peak"):
    result.add ", пик " & $facts["peak"].getFloat
  if facts.hasKey("silent") and facts["silent"].getBool:
    result.add " (тишина)"

proc runWatch*(ctx: var Ctx; args: seq[string]): Report =
  let scan = scanArgs(args)
  if not scan.ok:
    return scan.rep

  let paths = watchPaths(scan.project, scan.extras)
  let cfg = WatchConfig(debounceMs: scan.debounceMs,
                        minIntervalMs: scan.minIntervalMs)
  var state = watchStart(paths, nowMs(), cfg)
  var human = @[CliName & " watch — правка → рендер", "",
                "проект: " & scan.project,
                "output: " & scan.outPath,
                "слежу за:"]
  for path in paths:
    human.add "  " & path
  human.add "дебаунс: " & $scan.debounceMs & " мс, минимум между рендерами: " &
    $scan.minIntervalMs & " мс, опрос: " & $scan.pollMs & " мс"
  if ctx.mode == omHuman:
    for line in human:
      echo line

  var renders = 0
  var cycles = 0
  var last: JsonNode = newJObject()
  var stopped = if scan.once or ctx.dryRun: "once" else: "signal"

  # Первый рендер — сразу: команда обещает «послушал», а не «подождал правку».
  var rep = renderCycle(ctx, scan, 1, @[], last)
  if not rep.ok:
    if ctx.mode == omHuman:
      stderr.writeLine(CliName & ": " & rep.error)
    return rep
  inc renders
  if ctx.mode == omHuman:
    echo reportRenderLine(1, last)
    if not scan.once and not ctx.dryRun:
      echo "жду изменений… (Ctrl-C — выход)"

  if not scan.once and not ctx.dryRun:
    setControlCHook(proc() {.noconv.} = gWatchStop = true)
    while not gWatchStop:
      sleep(int(scan.pollMs))
      let decision = watchPoll(state, paths, nowMs(), cfg)
      inc cycles
      if decision.action != waRender:
        continue
      let cycle = state.renders + 1
      var facts: JsonNode
      let rendered = renderCycle(ctx, scan, cycle, decision.changed, facts)
      if not rendered.ok:
        # Сломанный проект не должен убивать наблюдение: пользователь правит
        # файл и ждёт следующего рендера. Причина печатается, но цикл живёт.
        if ctx.mode == omHuman:
          stderr.writeLine(CliName & ": рендер не удался: " & rendered.error)
        else:
          var line = newJObject()
          line["type"] = %"error"
          line["cycle"] = %cycle
          line["message"] = %rendered.error
          echo $line
        continue
      last = facts
      inc renders
      if ctx.mode == omHuman:
        echo reportRenderLine(cycle, facts)
    stopped = "signal"

  var watched = newJArray()
  for path in paths:
    watched.add %path
  var body = newJObject()
  body["path"] = %scan.project
  body["out"] = %scan.outPath
  body["watched"] = watched
  body["renders"] = %renders
  body["cycles"] = %cycles
  body["lastMs"] = %(if last.hasKey("ms"): last["ms"].getInt else: 0)
  body["lastChanged"] = %(if last.hasKey("changed"): last["changed"]
                          else: newJArray())
  body["stopped"] = %stopped
  body["render"] = last
  if ctx.mode == omHuman:
    echo ""
    echo "итог: рендеров " & $renders & ", опросов " & $cycles &
      ", последний за " & $body["lastMs"].getInt & " мс"
    if stopped == "signal":
      echo "остановлено: Ctrl-C (временных файлов нет, проект не изменялся)"
    elif ctx.dryRun:
      echo "не записано: --dry-run"
    else:
      echo "остановлено: --once"
  okReport(body = body)

