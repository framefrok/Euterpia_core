# cli/dispatch.nim
#
# Исполнение ОДНОЙ командной строки CLI (#88, #334).
#
# Вынесено из `cli/main.nim`, потому что «строка argv → отчёт» нужна не только
# точке входа: пакетный режим (`--script`), REPL и перенаправленный stdin
# исполняют те же строки В ОДНОМ процессе (#97). Если бы разбор остался в
# `main`, этим трём режимам пришлось бы либо запускать бинарь заново, либо
# повторять разбор — и «одна команда» и «сценарий» начали бы понимать argv
# по-разному.
#
# Границы: здесь только разбор argv и поиск команды в реестре. Что команда
# делает — в её модуле, как её описывать — в `libs/cli_spec`.

import std/strutils

import context
import logger
import registry
import commands
import cli_spec
import cmd_project

proc stripGlobals*(
  tokens: seq[string];
  ctx: var Ctx
): tuple[rest: seq[string]; wantHelp: bool] =
  ## Вынимает глобальные ключи из хвоста argv (после имени команды) и
  ## возвращает аргументы команды в исходном виде.
  ##
  ## `--` прекращает разбор ключей: дальше могут идти значения, которые
  ## начинаются с дефиса (`__complete doctor --`, префикс `-x`).
  var passthrough = false
  for token in tokens:
    if not passthrough:
      if token == "--":
        passthrough = true
        continue
      if token == "--json":
        ctx.mode = omJson
        ctx.modeExplicit = true
        continue
      if token == "--human":
        # Ключ argv сильнее настройки `output` (#258).
        ctx.mode = omHuman
        ctx.modeExplicit = true
        continue
      if token == "--verbose" or token == "-v":
        ctx.verbose = true
        ctx.logLevel = llDebug
        ctx.logLevelExplicit = true
        continue
      if token == "--quiet" or token == "-q":
        ctx.quiet = true
        ctx.logLevel = llError
        ctx.logLevelExplicit = true
        continue
      if token == "--dry-run":
        ctx.dryRun = true
        continue
      if token == "--help" or token == "-h":
        result.wantHelp = true
        continue
    result.rest.add token

proc takesProjectOption(spec: CommandSpec): bool =
  ## Есть ли у команды ключ `--file`. По нему решается, подставлять ли проект
  ## сессии: команде без такого ключа подстановка была бы чужим аргументом.
  for option in spec.options:
    if option.flag == "--file":
      return true
  false

proc mentionsProject(tokens: seq[string]): bool =
  ## Назван ли проект явно: ключом `--file` (в любой форме) или позиционным
  ## аргументом с расширением проекта. Только тогда проект сессии молчит —
  ## явный аргумент всегда сильнее (приоритет как у argv > настроек, #258).
  for token in tokens:
    if token == "--file" or token.startsWith("--file="):
      return true
    if not token.startsWith("-") and isProjectPath(token):
      return true
  false

proc withSessionProject(ctx: Ctx; spec: CommandSpec;
                        tokens: seq[string]): seq[string] =
  ## Подстановка «текущего проекта» сессии (#334): `open demo.eproj` один раз,
  ## дальше `node add osc` правит именно его. Правило одно и живёт здесь, а не
  ## в каждой команде: иначе `--script` и REPL начали бы расходиться.
  ##
  ## Исключение — подкоманды, объявленные `filelessSubcommands` (`render diff`):
  ## они работают с готовыми файлами, и проект сессии им не аргумент.
  result = tokens
  if ctx.sessionProject.len == 0 or not spec.takesProjectOption:
    return
  if tokens.len > 0 and tokens[0] in spec.filelessSubcommands:
    return
  if tokens.mentionsProject:
    return
  result.add "--file"
  result.add ctx.sessionProject

proc executeArgv*(ctx: var Ctx; argv: seq[string]): Report =
  ## Разбор одной командной строки и вызов команды. Печать и код возврата —
  ## дело вызывающего (`emit`), поэтому один и тот же вызов годится и для
  ## одиночного режима, и для сценария, и для REPL.
  setupRegistry()
  let cmds = allCommands()

  var command = ""
  var tail: seq[string] = @[]
  var wantHelp = false
  var wantVersion = false

  # Голова argv: глобальные ключи и имя команды.
  var i = 0
  while i < argv.len:
    let token = argv[i]
    if token == "--":
      if i + 1 < argv.len:
        command = argv[i + 1]
        if i + 2 < argv.len:
          tail = argv[i + 2 .. ^1]
      break
    if token == "--help" or token == "-h":
      wantHelp = true
      inc i
      continue
    if token == "--version":
      wantVersion = true
      inc i
      continue
    if token == "--json":
      ctx.mode = omJson
      ctx.modeExplicit = true
      inc i
      continue
    if token == "--human":
      # Ключ argv сильнее настройки `output` (#258).
      ctx.mode = omHuman
      ctx.modeExplicit = true
      inc i
      continue
    if token == "--verbose" or token == "-v":
      ctx.verbose = true
      ctx.logLevel = llDebug
      ctx.logLevelExplicit = true
      inc i
      continue
    if token == "--quiet" or token == "-q":
      ctx.quiet = true
      ctx.logLevel = llError
      ctx.logLevelExplicit = true
      inc i
      continue
    if token == "--dry-run":
      ctx.dryRun = true
      inc i
      continue
    if token.len > 0 and token[0] == '-':
      # Неизвестный ключ ДО команды: списать его на команду нельзя, она ещё
      # не названа — значит это ошибка использования.
      ctx.command = ""
      return usageError("неизвестный ключ: " & token,
                        "список ключей: euterpia --help")
    command = token
    if i + 1 < argv.len:
      tail = argv[i + 1 .. ^1]
    break

  if command.len == 0:
    if wantVersion:
      ctx.command = "version"
      return runVersion(ctx, @[])
    if wantHelp or argv.len == 0:
      # Запуск без аргументов ничего сделать не может, а справка — может:
      # это не ошибка, а ответ на вопрос «что тут есть».
      ctx.command = "help"
      return helpReport(cmds, "")
    ctx.command = ""
    return usageError("не указана команда")

  ctx.command = command
  let stripped = stripGlobals(tail, ctx)

  if wantHelp or stripped.wantHelp:
    return helpReport(cmds, command)

  let index = findCommand(cmds, command)
  if index < 0:
    return usageError("неизвестная команда: " & command,
                      "список команд: euterpia --help")

  let args = withSessionProject(ctx, cmds[index].spec, stripped.rest)
  cmds[index].run(ctx, args)
