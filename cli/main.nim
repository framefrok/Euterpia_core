# cli/main.nim
#
# Точка входа CLI (issue #88, #334): какой режим выбрать и как завершиться.
#
# Три режима, и выбор между ними — правило, а не догадка:
#
#   euterpia <команда> …        одна команда (прежнее поведение);
#   euterpia --script <файл>    сценарий строк-команд в ОДНОМ процессе;
#   euterpia                    без аргументов: TTY → REPL,
#                               перенаправленный stdin → строки-команды,
#                               пустой stdin → справка (это ответ, не ошибка).
#
# Почему режимы различаются по `isatty`, а не по «есть ли аргументы»:
#   агент и CI перенаправляют stdin; если бы CLI ждал ввода, прогон «завис»
#   (#97). А пустой перенаправленный stdin — это не сессия, а «ничего не
#   просили»: печатается справка, как и раньше.
#
# Грамматика argv намеренно простая:
#
#   euterpia [глобальные ключи] <команда> [аргументы команды]
#   euterpia [глобальные ключи] <команда> [--] [аргументы]
#   euterpia [глобальные ключи] --script <файл|-> [--keep-going]
#
# Внешних зависимостей нет: только std. `std/parseopt` здесь не подходит — он
# не выражает «глобальные ключи вокруг команды» и не сохраняет исходный вид
# аргументов для команды, а CLI обязан передавать их без искажений.

import std/[os, strutils, terminal]

import context
import logger
import config
import commands
import dispatch
import batch

type
  BatchOptions = object
    ok: bool
    rep: Report
    scriptPath: string
    keepGoing: bool
    rest: seq[string]

proc takeBatchOptions(argv: seq[string]): BatchOptions =
  ## Вынимает `--script <файл|->` и `--keep-going` из argv. Остальное
  ## возвращается как есть: разбор команд — дело `dispatch`.
  var i = 0
  while i < argv.len:
    let token = argv[i]
    if token == "--script":
      if i + 1 >= argv.len:
        result.rep = usageError("--script: нужен файл сценария",
          "например: euterpia --script demo.txt")
        return
      inc i
      result.scriptPath = argv[i]
    elif token.startsWith("--script="):
      result.scriptPath = token["--script=".len .. ^1]
      if result.scriptPath.len == 0:
        result.rep = usageError("--script=: пустой путь",
          "например: euterpia --script=demo.txt")
        return
    elif token == "--keep-going":
      result.keepGoing = true
    else:
      result.rest.add token
    inc i
  result.ok = true

proc readStdinLines(): seq[string] =
  ## Строки stdin до EOF. Чтение обязано закончиться само: агент закрывает
  ## поток, а не нажимает Ctrl-D (#97).
  var line = ""
  while stdin.readLine(line):
    result.add line

proc loadSettings(ctx: var Ctx) =
  ## Настройки читаются ОДИН раз при старте и задают УМОЛЧАНИЯ; ключи argv
  ## разбираются позже и потому сильнее (приоритет #258). Предупреждения о
  ## конфиге идут в stderr: stdout — результат команды (§21).
  ctx.config = loadConfig()
  for warning in ctx.config.warnings:
    cliWarn(CliName & ": конфиг: " & warning)
  ctx.mode =
    if ctx.config.entry("output").value == "json": omJson else: omHuman
  ctx.logLevel = logLevelFromName(ctx.config.entry("logLevel").value)

proc emitAndCode(ctx: var Ctx; rep: Report): int =
  ## Печать и код возврата в одном месте: разойтись они не могут.
  emit(ctx, rep)
  ord(rep.code)


proc main*(): int =
  ## Точка входа. Единственное место, где исключение превращается в код
  ## возврата: необработанная ошибка CLI — это баг (код 3), а не ошибка
  ## данных пользователя (код 1).
  var ctx = Ctx(mode: omHuman, logLevel: llWarn)
  try:
    loadSettings(ctx)
    let options = takeBatchOptions(commandLineParams())
    if not options.ok:
      return emitAndCode(ctx, options.rep)

    # Глобальные ключи применяются ДО выбора режима: `--json --script demo.txt`
    # обязан дать NDJSON, а не человеческий вывод (критерий #334).
    let globals = stripGlobals(options.rest, ctx)
    var commandTokens: seq[string] = @[]
    var beforeCommand = true
    for token in globals.rest:
      if beforeCommand:
        if token == "--version":
          commandTokens.add token
          continue
        if token == "--":
          beforeCommand = false
          commandTokens.add token
          continue
        if token.len > 0 and token[0] == '-':
          return emitAndCode(ctx, usageError("неизвестный ключ: " & token,
            "список ключей: euterpia --help"))
        beforeCommand = false
      commandTokens.add token

    if options.scriptPath.len > 0:
      # `--script` не совмещается с командой: что из двух исполнять — вопрос
      # без ответа, и угадывать его CLI не будет.
      if commandTokens.len > 0:
        return emitAndCode(ctx, usageError(
          "--script не совмещается с командой: " & commandTokens[0],
          "или сценарий, или команда: euterpia --script demo.txt"))
      if options.scriptPath == "-":
        return runBatchLines(ctx, readStdinLines(), options.keepGoing,
                             "<stdin>")
      if not fileExists(options.scriptPath):
        return emitAndCode(ctx, envError(
          "нет такого сценария: " & options.scriptPath,
          "строка сценария — команда CLI без `euterpia`: `node add osc`"))
      var lines: seq[string] = @[]
      try:
        lines = readFile(options.scriptPath).splitLines()
      except CatchableError as e:
        return emitAndCode(ctx, envError(
          "не удалось прочитать сценарий: " & e.msg,
          "проверьте права: " & options.scriptPath))
      return runBatchLines(ctx, lines, options.keepGoing, options.scriptPath)

    if options.keepGoing:
      return emitAndCode(ctx, usageError(
        "--keep-going имеет смысл только в пакетном режиме",
        "используйте: euterpia --script demo.txt --keep-going"))

    # Одна команда: разбор argv и исполнение — как раньше.
    if commandTokens.len > 0:
      return emitAndCode(ctx, executeArgv(ctx, options.rest))

    # Без команды: TTY — интерактивная сессия, иначе строки stdin. Пустой
    # stdin означает «ничего не просили» — это справка, а не пустой сеанс.
    if globals.wantHelp:
      return emitAndCode(ctx, executeArgv(ctx, options.rest))
    if isatty(stdin):
      return runRepl(ctx)
    let lines = readStdinLines()
    if lines.len == 0:
      return emitAndCode(ctx, helpReport(allCommands(), ""))
    return runBatchLines(ctx, lines, options.keepGoing, "<stdin>")
  except CatchableError as e:
    let rep = panicError("внутренняя ошибка CLI: " & e.msg,
                         "это баг: приложите вывод `euterpia --version` и команду")
    emit(ctx, rep)
    ord(rep.code)

