# cli/cmd_ci.nim
#
# `euterpia ci check <проект>` — единый вход для проверки проекта в CI
# (issue #340).
#
# Зачем команда:
#   В CI уже есть отдельные `project validate`, `graph check`, `render`,
#   `analyze`, и «прогнать проект целиком» — это руками собранная строка,
#   которую никто не проверяет на правильность. Забыли шаг, не так поняли
#   код, потеряли вывод при провале — класс ошибок, которого не должно быть.
#   Здесь шаги названы в одном месте, идут по порядку и оставляют отчёт:
#   какой шаг не прошёл, с каким кодом и с каким выводом.
#
# Границы (§20):
#   Команда НЕ реализует проверки заново. Каждый шаг — вызов существующей
#   команды CLI (`runProjectValidate`, `runGraph`, `runRender`, `runAnalyze`),
#   поэтому «ci check упал» и «project validate упал» — один и тот же код и
#   одно и то же сообщение, а не две похожие правды.
#
# Коды возврата (#88):
#   0 — все шаги прошли; 1 — провал данных (валидация, граф, дефекты аудио);
#   2 — среда (не читается файл, нет кодека/устройства); 3 — баг.
#   Код берётся у УПАВШЕГО шага: CI обязан видеть ту же причину, что и
#   человек, запустивший шаг руками.
#
# Время: `--seconds` (по умолчанию 1 с) ограничивает фрагмент рендера, поэтому
# прогон укладывается в измеримое время. Анализа нет в `--fast`: быстрый гейт
# для правок, где звук не менялся.

import std/[json, os, strutils]

import context
import cli_spec
import cmd_project
import cmd_graph
import cmd_render
import cmd_analyze

const
  CiSubcommands* = @["check"]
    ## Подкоманды `ci` — они же кандидаты автодополнения.

  DefaultCiSeconds* = 1.0
    ## Длина фрагмента для `analyze`. Секунда, а не весь микс: CI проверяет
    ## «звук не сломался», а не мастерит сдачу; полный рендер — дело `master`.

  CiSpec* = CommandSpec(
    name: "ci",
    summary: "проверка проекта одной командой: validate → graph → render → analyze",
    synopsis: "ci check [проект.eproj] [ключи]",
    subcommands: CiSubcommands,
    args: @[
      arg("проект.eproj", "что проверить: " & projectSuffixesHint() &
        "; по умолчанию " & DefaultProjectFile),
    ],
    options: @[
      switch("--strict", "строгий режим: lint проекта и порог анализа warn"),
      switch("--fast", "без рендера и анализа: только validate и graph check"),
      opt("--seconds", "длина фрагмента рендера для анализа, секунды",
          value = "секунды", default = $DefaultCiSeconds),
      opt("--out", "куда писать WAV фрагмента", value = "файл.wav"),
    ],
    example: "euterpia ci check project.eproj",
    fields: @[
      field("path", "проверенный проект"),
      field("steps", "шаги: имя, статус, код возврата, вывод"),
      field("failedStep", "шаг, который не прошёл (пусто — прошли все)"),
      field("strict", "строгий режим включён"),
      field("fast", "рендер и анализ пропущены"),
      field("out", "WAV фрагмента, который смотрел инспектор"),
      field("passed", "сколько шагов прошло"),
      field("total", "сколько шагов выполнено (включая пропущенные)"),
    ],
    notes: @[
      "шаги по порядку: validate → graph check → render → analyze",
      "каждый шаг — существующая команда CLI: код и сообщение те же, что при ручном запуске",
      "--strict: `project validate --strict` и `analyze --fail-on warn`",
      "--fast: только validate и graph check (без рендера и инспектора)",
      "--seconds N: длина фрагмента для инспектора (по умолчанию " &
        $DefaultCiSeconds & " с)",
      "вывод шагов сохраняется в отчёте и при провале: `steps` в `--json`",
      "код возврата — код упавшего шага: 1 — данные, 2 — среда, 3 — баг",
    ])

  CiKeys* = CiSpec.optionKeys

# =============================================================================
# Разбор аргументов
# =============================================================================

type
  StepResult = object
    ## Один шаг проверки. `lines` сохраняются ВСЕГДА, а не только при
    ## провале: CI должен видеть, что именно проверялось, даже когда всё
    ## прошло (`--json` — единственный способ увидеть это машинно).
    name: string
    status: string
      ## `ok` | `fail` | `skip`.
    exitCode: int
    message: string
    lines: seq[string]

  CiScan = object
    ok: bool
    rep: Report
    path: string
    strict: bool
    fast: bool
    seconds: float64
    outPath: string

proc numberArg(text, key: string; lowInclusive, highInclusive: float64):
    tuple[ok: bool; value: float64; message: string] =
  var number: float
  try:
    number = parseFloat(text.strip())
  except ValueError:
    return (false, 0.0, key & ": ожидается число, получено «" & text & "»")
  if not (float64(number) >= lowInclusive) or
     not (float64(number) <= highInclusive):
    return (false, 0.0,
      key & ": ожидается число от " & $lowInclusive & " до " &
      $highInclusive & ", получено «" & text & "»")
  (true, float64(number), "")

proc scanArgs(args: seq[string]): CiScan =
  ## Разбор `ci check [проект] [ключи]`. Форма `--ключ=значение` принимается
  ## так же, как в остальных командах: агент не должен угадывать, где она
  ## работает, а где нет.
  result.ok = true
  result.path = DefaultProjectFile
  result.seconds = DefaultCiSeconds
  var havePath = false
  var i = 0
  while i < args.len:
    let token = args[i]
    var key = token
    var value = ""
    var haveInline = false
    let eq = token.find('=')
    if token.startsWith("--") and eq > 0:
      key = token[0 ..< eq]
      value = token[eq + 1 .. ^1]
      haveInline = true

    if key == "--strict" or key == "--fast":
      if haveInline:
        result.ok = false
        result.rep = usageError(key & " — флаг и не принимает значение",
          "например: euterpia ci check " & DefaultProjectFile & " " & key)
        return
      if key == "--strict": result.strict = true
      else: result.fast = true
    elif key == "--seconds" or key == "--out":
      if not haveInline:
        if i + 1 >= args.len:
          result.ok = false
          result.rep = usageError(key & " требует значение",
            "ключи: " & CiKeys.join(", "))
          return
        inc i
        value = args[i]
      if key == "--seconds":
        let parsed = numberArg(value, key, 0.001, 36_000.0)
        if not parsed.ok:
          result.ok = false
          result.rep = usageError(parsed.message,
            "фрагмент для инспектора: например --seconds 2")
          return
        result.seconds = parsed.value
      else:
        result.outPath = value
    elif token.startsWith("-") and token.len > 1:
      result.ok = false
      result.rep = usageError("неизвестный ключ: " & token,
                              "ключи: " & CiKeys.join(", "))
      return
    elif havePath:
      result.ok = false
      result.rep = usageError("ci check принимает один проект, получено: " &
                              result.path & " и " & token,
        "например: euterpia ci check " & DefaultProjectFile)
      return
    else:
      result.path = token
      havePath = true
    inc i


# =============================================================================
# Шаги
# =============================================================================

proc stepOf(name: string; rep: Report): StepResult =
  ## Шаг из отчёта команды: статус, код и вывод берутся у неё, а не
  ## пересчитываются — иначе `ci check` и ручной запуск могли бы разойтись.
  StepResult(name: name,
             status: (if rep.ok: "ok" else: "fail"),
             exitCode: int(ord(rep.code)),
             message: rep.error,
             lines: rep.lines)

proc skipped(name, reason: string): StepResult =
  StepResult(name: name, status: "skip", message: reason)

proc stepsJson(steps: seq[StepResult]): JsonNode =
  result = newJArray()
  for step in steps:
    var lines = newJArray()
    for line in step.lines:
      lines.add %line
    result.add %*{
      "name": step.name, "status": step.status, "exitCode": step.exitCode,
      "message": step.message, "lines": lines,
    }

proc indented(lines: seq[string]): seq[string] =
  for line in lines:
    result.add "    " & line


# =============================================================================
# ci check
# =============================================================================

proc runCiCheck*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia ci check [проект] [--strict] [--fast]`.
  ##
  ## Шаги идут ПО ПОРЯДКУ и останавливаются на первом провале: следующий шаг
  ## на сломанном проекте дал бы второе сообщение о той же причине и спрятал
  ## первую. Отчёт при этом содержит и пройденные, и пропущенные шаги.
  let scan = scanArgs(args)
  if not scan.ok:
    return scan.rep

  var outPath = scan.outPath
  if outPath.len == 0:
    # Фрагмент живёт в каталоге временных файлов: `ci check` не должен
    # оставлять WAV рядом с проектом. `--out` называет место явно.
    let stem = extractFilename(scan.path).changeFileExt("")
    outPath = getTempDir() / ("euterpia-ci-" & stem & ".wav")

  var stepCtx = ctx
  # Шаги — это команды CLI, и в их отчётах `command` должен быть их
  # собственным: машинный отчёт показывает, ЧТО именно упало.
  var steps: seq[StepResult] = @[]
  var failed = -1

  template runStep(name: string; call: untyped) =
    ## Выполнить шаг, если предыдущие прошли. Тело — вызов существующей
    ## команды: `ci` не переписывает проверки и не подменяет коды.
    if failed < 0:
      stepCtx.command = name
      let rep = call
      steps.add stepOf(name, rep)
      if not rep.ok:
        failed = steps.len - 1

  var validateArgs: seq[string] = @[scan.path]
  if scan.strict:
    validateArgs.add "--strict"
  runStep("validate"):
    runProjectValidate(stepCtx, validateArgs)

  runStep("graph"):
    runGraph(stepCtx, @["check", scan.path])

  if not scan.fast and failed < 0:
    let renderArgs = @[scan.path, outPath, "--seconds", $scan.seconds]
    runStep("render"):
      runRender(stepCtx, renderArgs)
    if ctx.dryRun:
      # `--dry-run` не пишет файл: инспектору нечего читать, и делать вид,
      # что анализ прошёл, нельзя.
      steps.add skipped("analyze", "--dry-run: файл фрагмента не записан")
    else:
      let threshold = if scan.strict: "warn" else: "error"
      runStep("analyze"):
        runAnalyze(stepCtx, @[outPath, "--fail-on", threshold])
  elif scan.fast:
    steps.add skipped("render", "--fast: рендер не нужен")
    steps.add skipped("analyze", "--fast: анализ не нужен")

  var passed = 0
  for step in steps:
    if step.status == "ok":
      inc passed
  let body = %*{
    "path": scan.path,
    "strict": scan.strict,
    "fast": scan.fast,
    "out": outPath,
    "steps": stepsJson(steps),
    "failedStep": (if failed >= 0: steps[failed].name else: ""),
    "passed": passed,
    "total": steps.len,
  }

  var lines: seq[string] = @[
    CliName & " ci check — " & scan.path,
    "",
  ]
  for step in steps:
    var line = "[" & step.status & "] " & step.name
    if step.status == "fail":
      line.add " — код " & $step.exitCode
    elif step.status == "skip":
      line.add " — " & step.message
    lines.add line

  if failed >= 0:
    let failing = steps[failed]
    lines.add ""
    lines.add "шаг " & failing.name & " не прошёл: " & failing.message
    lines.add indented(failing.lines)
    # Код возврата берётся у упавшего шага: CI обязан видеть ту же причину,
    # что и человек, запустивший этот шаг руками (1 — данные, 2 — среда).
    let code = (if failing.exitCode in 1 .. 3: ExitCode(failing.exitCode)
                else: exUsage)
    let errorKind = (case code
                     of exEnv: "env"
                     of exPanic: "panic"
                     else: "usage")
    let reason = (case code
                  of exEnv: ecEnvironment
                  of exPanic: ecInternal
                  else: ecCheckFailed)
    return errReport(code, errorKind,
      "шаг " & failing.name & " не прошёл: " & failing.message,
      hint = "исправьте причину и повторите: подробности выше и в `--json`",
      lines = lines, body = body, errorCode = frameCodeValue(reason))

  lines.add ""
  lines.add "итог: " & $passed & " из " & $steps.len & " шагов прошли"
  if scan.fast:
    lines.add "режим --fast: рендер и инспектор пропущены"
  okReport(body = body, lines = lines)


# =============================================================================
# Точка входа
# =============================================================================

proc runCi*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia ci <check> [аргументы]`.
  if args.len == 0:
    return usageError("ci требует подкоманду",
                      "подкоманды: " & CiSubcommands.join(", "))
  if args[0] != "check":
    return usageError("неизвестная подкоманда ci: " & args[0],
                      "подкоманды: " & CiSubcommands.join(", "))
  runCiCheck(ctx, argsTail(args))

