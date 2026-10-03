# cli/main.nim
#
# Диспетчер CLI (issue #88): разбор argv, поиск команды в реестре, печать
# отчёта и код возврата.
#
# Грамматика намеренно простая и предсказуемая:
#
#   euterpia [глобальные ключи] <команда> [аргументы команды]
#   euterpia [глобальные ключи] <команда> [--] [аргументы]
#
# Глобальные ключи распознаются И до, и после имени команды (MANIFEST §21
# показывает именно `euterpia --json node list`). Всё, что не является
# глобальным ключом, уходит команде как есть: CLI не угадывает значения
# ключей за команду.
#
# Внешних зависимостей нет: только std. `std/parseopt` здесь не подходит —
# он не выражает «глобальные ключи вокруг команды» и не сохраняет исходный
# вид аргументов для команды, а CLI обязан передавать их без искажений.

import std/os
import context
import registry
import commands

proc stripGlobals(
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
        continue
      if token == "--verbose" or token == "-v":
        ctx.verbose = true
        continue
      if token == "--quiet" or token == "-q":
        ctx.quiet = true
        continue
      if token == "--dry-run":
        ctx.dryRun = true
        continue
      if token == "--help" or token == "-h":
        result.wantHelp = true
        continue
    result.rest.add token

proc dispatch(ctx: var Ctx): int =
  setupRegistry()
  let cmds = allCommands()
  let argv = commandLineParams()

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
      inc i
      continue
    if token == "--verbose" or token == "-v":
      ctx.verbose = true
      inc i
      continue
    if token == "--quiet" or token == "-q":
      ctx.quiet = true
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
      let rep = usageError("неизвестный ключ: " & token, "список ключей: euterpia --help")
      emit(ctx, rep)
      return ord(rep.code)
    command = token
    if i + 1 < argv.len:
      tail = argv[i + 1 .. ^1]
    break

  if command.len == 0:
    if wantVersion:
      ctx.command = "version"
      let rep = runVersion(ctx, @[])
      emit(ctx, rep)
      return ord(rep.code)
    if wantHelp or argv.len == 0:
      # Запуск без аргументов ничего сделать не может, а справка — может:
      # это не ошибка, а ответ на вопрос «что тут есть».
      ctx.command = "help"
      let rep = helpReport(cmds, "")
      emit(ctx, rep)
      return ord(rep.code)
    ctx.command = ""
    let rep = usageError("не указана команда")
    emit(ctx, rep)
    return ord(rep.code)

  ctx.command = command
  let stripped = stripGlobals(tail, ctx)

  if wantHelp or stripped.wantHelp:
    let rep = helpReport(cmds, command)
    emit(ctx, rep)
    return ord(rep.code)

  let index = findCommand(cmds, command)
  if index < 0:
    let rep = usageError("неизвестная команда: " & command,
                         "список команд: euterpia --help")
    emit(ctx, rep)
    return ord(rep.code)

  let rep = cmds[index].run(ctx, stripped.rest)
  emit(ctx, rep)
  ord(rep.code)

proc main*(): int =
  ## Точка входа. Единственное место, где исключение превращается в код
  ## возврата: необработанная ошибка CLI — это баг (код 3), а не ошибка
  ## данных пользователя (код 1).
  var ctx = Ctx(mode: omHuman)
  try:
    return dispatch(ctx)
  except CatchableError as e:
    let rep = errReport(exPanic, "panic", "внутренняя ошибка CLI: " & e.msg,
                        "это баг: приложите вывод `euterpia --version` и команду")
    emit(ctx, rep)
    ord(rep.code)
