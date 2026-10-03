# cli/context.nim
#
# Контекст CLI (issue #88): режимы вывода, коды возврата, отчёт команды
# и логгер Core.
#
# Правила, зафиксированные здесь:
# - stdout — ТОЛЬКО результат команды: либо человекочитаемые строки, либо
#   ровно одна строка JSON. Логи Core и сообщения об ошибках идут в stderr:
#   иначе `--json` перестал бы быть парсируемым (MANIFEST §21);
# - коды возврата: 0 — успех, 1 — ошибка данных/использования, 2 — ошибка
#   среды (нет библиотеки, устройства, прав), 3 — внутренняя ошибка (баг);
# - инвариант `ok == (exitCode == 0)`: агенту достаточно одного поля;
# - в выводе нет ни времени, ни случайных значений — повторный запуск даёт
#   байт-в-байт тот же результат (критерий приёмки #88).

import std/json
import logger
import euterpia_version
import config

# Версия пакета реэкспортируется: её печатают `--version`, справка и
# `doctor`, и каждому модулю CLI не нужно помнить об отдельном импорте.
export euterpia_version

const
  CliSchema* = 1
    ## Версия схемы JSON-конверта. Меняется только при несовместимом
    ## изменении полей: агент обязан видеть, что схема другая.
  CliName* = "euterpia"

type
  OutputMode* = enum
    omHuman, omJson

  ExitCode* = enum
    exOk = 0,
      ## Успех.
    exUsage = 1,
      ## Ошибка данных или использования: неизвестная команда/ключ,
      ## лишний аргумент, невалидное значение.
    exEnv = 2,
      ## Ошибка среды: нет библиотеки/устройства/прав. Данные верны,
      ## окружение не позволяет выполнить команду.
    exPanic = 3
      ## Внутренняя ошибка CLI (баг). Пользователь в ней не виноват.

  Ctx* = object
    ## Контекст одного запуска CLI. Живёт на control-path, копируется
    ## свободно: это обычное значение, а не разделяемое состояние.
    mode*: OutputMode
    modeExplicit*: bool
      ## Режим вывода задан ключом argv (`--json`/`--human`). Нужен
      ## `config get`: иначе непонятно, почему вывод не такой, как в файле
      ## настроек (argv сильнее — #258).
    verbose*: bool
    quiet*: bool
    logLevel*: LogLevel
      ## Порог логов. Складывается из настроек (argv > env > файл >
      ## умолчание, `cli/config.nim`) ещё до выполнения команды, поэтому
      ## логгеру не нужно знать про источники.
    logLevelExplicit*: bool
      ## Порог задан ключом argv (`-v`/`-q`).
    dryRun*: bool
    command*: string
    config*: Config
      ## Настройки окружения, прочитанные один раз при старте (#258).
      ## Команды читают их отсюда: перечитывать файл на каждую команду
      ## значило бы, что два запуска в одном процессе видят разное.

  Report* = object
    ## Результат команды в терминах CLI, а не в терминах конкретного
    ## вывода: печать и код возврата — ответственность `emit`.
    ok*: bool
    code*: ExitCode
    lines*: seq[string]
      ## Человекочитаемый результат (stdout в режиме `omHuman`).
    body*: JsonNode
      ## Машинная нагрузка. Поля кладутся в конверт верхнего уровня.
    error*: string
    errorKind*: string
      ## `usage` | `env` | `panic` — стабильные значения для агента.
    hint*: string

# =============================================================================
# Вывод
# =============================================================================

proc writeStdout(line: string) =
  ## Сломанный пайп (`euterpia doctor --json | head -1`) — не паника CLI:
  ## получатель закрыл поток раньше, это не ошибка команды.
  try:
    stdout.writeLine(line)
  except CatchableError:
    discard

proc writeStderr(line: string) =
  try:
    stderr.writeLine(line)
  except CatchableError:
    discard

proc cliLogSink(user: pointer; level: LogLevel; msg: cstring)
    {.cdecl, raises: [], gcsafe.} =
  ## Sink для `core/logger`. Core сам в stdout не пишет (§6, §43), поэтому
  ## его вывод уходит в stderr и не может испортить `--json`.
  ##
  ## Формат строки фиксирован и не содержит времени: логи CLI должны быть
  ## сравнимыми между запусками.
  discard user
  try:
    stderr.writeLine("[" & $levelName(level) & "] " & $msg)
  except CatchableError:
    discard

proc cliLogger*(ctx: Ctx): Logger =
  ## Логгер Core, поднятый в CLI. Порог уже разрешён с учётом приоритета
  ## argv > env > файл > умолчание (`cli/main.nim`, `cli/config.nim`),
  ## поэтому здесь нет ни условий, ни знания про источники настроек.
  logger(nil, cliLogSink, ctx.logLevel)

proc cliWarn*(line: string) =
  ## Предупреждение CLI в stderr. Единственный публичный способ написать
  ## в stderr: stdout принадлежит результату команды, иначе `--json`
  ## перестал бы быть парсируемым (§21).
  writeStderr(line)

proc argsTail*(args: seq[string]): seq[string] =
  ## Аргументы после имени команды или подкоманды. Отдельная функция вместо
  ## среза `args[1 .. ^1]`: на пустом хвосте срез читается как ошибка, а не
  ## как «аргументов нет».
  if args.len <= 1: @[] else: args[1 .. ^1]

# =============================================================================
# Отчёты
# =============================================================================

proc okReport*(
  body: JsonNode = nil;
  lines: seq[string] = @[]
): Report =
  Report(ok: true, code: exOk, body: body, lines: lines)

proc errReport*(
  code: ExitCode;
  errorKind, error: string;
  hint: string = "";
  lines: seq[string] = @[];
  body: JsonNode = nil
): Report =
  Report(ok: false, code: code, errorKind: errorKind, error: error,
         hint: hint, lines: lines, body: body)

proc usageError*(msg: string; hint: string = "список команд: euterpia --help"): Report =
  errReport(exUsage, "usage", msg, hint)

proc envelope*(ctx: Ctx; rep: Report): JsonNode =
  ## Машинный ответ: версионированный конверт + плоская нагрузка.
  ## Поля нагрузки лежат рядом с `schema`/`ok`/`exitCode`, а не внутри
  ## вложенного объекта: агент читает их без «ныряния» (§21).
  result = newJObject()
  result["schema"] = %CliSchema
  result["ok"] = %rep.ok
  result["command"] = %ctx.command
  result["exitCode"] = %int(ord(rep.code))

  if rep.body != nil:
    if rep.body.kind == JObject:
      for key, value in rep.body:
        result[key] = value
    else:
      result["result"] = rep.body

  if not rep.ok:
    var e = newJObject()
    e["kind"] = %rep.errorKind
    e["message"] = %rep.error
    if rep.hint.len > 0:
      e["hint"] = %rep.hint
    result["error"] = e

proc emit*(ctx: Ctx; rep: Report) =
  ## Печатает отчёт и ничего не решает про код возврата: вызывающий берёт
  ## его из `rep.code` (`ord`), поэтому печать и статус не могут разойтись.
  if ctx.mode == omJson:
    writeStdout($envelope(ctx, rep))
    return

  for line in rep.lines:
    writeStdout(line)

  if not rep.ok:
    writeStderr(CliName & ": " & rep.error)
    if rep.hint.len > 0:
      writeStderr(rep.hint)
