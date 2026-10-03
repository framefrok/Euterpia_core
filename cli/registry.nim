# cli/registry.nim
#
# Реестр команд CLI — ЕДИНАЯ точка правды о поверхности команд
# (issue #88, #259).
#
# Из реестра берут текст `--help`, JSON-справку (`help --json`), кандидаты
# автодополнения (`__complete`) и подсказки `completion`. Именно поэтому
# добавление команды не требует правки шаблонов и документации: список
# команд в шаблонах дополнения просто отсутствует.
#
# Реестр — обычный `seq[CommandDef]`, порядок задаёт автор (см.
# `cli/commands.nim`), а `visible` отсекает служебные команды.

import std/[json, strutils, unicode]
import context
import euterpia_version

type
  CommandProc* = proc(ctx: var Ctx; args: seq[string]): Report {.closure.}
    ## Тело команды. Аргументы — «хвост» argv после имени команды, из
    ## которого уже вынуты глобальные ключи (`--json`, `--verbose`, …).

  CommandDef* = object
    name*: string
    summary*: string
    usage*: string
      ## Как команда выглядит в `--help`: `doctor`, `completion <shell>`.
    flags*: seq[string]
      ## Длинные ключи самой команды (для справки и автодополнения).
    subcommands*: seq[string]
      ## Позиционные варианты (`bash`, `zsh`, `fish`) — кандидаты
      ## автодополнения второго уровня.
    notes*: seq[string]
      ## Свободные строки справки: форма аргументов, умолчания, ограничения.
      ## В кандидаты автодополнения НЕ попадают — в отличие от `flags`,
      ## это проза, а не ключи.
    commandArgs*: bool
      ## Позиционные аргументы — имена других команд (`help doctor`).
      ## Дополнение таких аргументов тоже берётся из реестра, а не из
      ## списка, продублированного в шаблоне оболочки.
    hidden*: bool
      ## Служебные команды (`__complete`) не показываются и не предлагаются.
    run*: CommandProc

const
  GlobalFlags* = [
    ("--json", "машиночитаемый вывод: ровно одна строка JSON в stdout"),
    ("--human", "человекочитаемый вывод (перекрывает настройку output=json)"),
    ("--verbose, -v", "лог Core уровня DEBUG в stderr"),
    ("--quiet, -q", "только ошибки в stderr"),
    ("--dry-run", "показать изменения, ничего не записывая на диск"),
    ("--help, -h", "справка; с командой — справка по команде"),
    ("--version", "версия CLI и ядра"),
  ]
    ## Глобальные ключи в порядке описания: один источник для `--help`
    ## и для `help --json`.

  ExitCodeHelp* = [
    (0, "успех"),
    (1, "ошибка данных или использования"),
    (2, "ошибка среды: нет библиотеки, устройства или прав"),
    (3, "внутренняя ошибка (баг CLI)"),
  ]

proc findCommand*(cmds: seq[CommandDef]; name: string): int =
  ## Индекс команды по точному имени или -1.
  for i in 0 ..< cmds.len:
    if cmds[i].name == name:
      return i
  -1

proc padTo(text: string; columns: int): string =
  ## Дополняет строку пробелами до нужного числа КОЛОНОК.
  ##
  ## `strutils.alignLeft` считает байты, а в справке есть кириллица:
  ## «help [команда]» — это 14 символов и 20 байт, поэтому колонки
  ## разъезжались. Считаем именно символы (runeLen).
  result = text
  let width = runeLen(text)
  if width < columns:
    result.add repeat(' ', columns - width)

proc globalFlagKeys*(): seq[string] =
  ## Разбирает `GlobalFlags` на отдельные ключи: `"--verbose, -v"` →
  ## `--verbose`, `-v`. Нужно автодополнению — и только ему, поэтому
  ## разбор живёт рядом с самим списком, а не в шаблонах оболочек.
  for item in GlobalFlags:
    for part in item[0].split(','):
      let key = part.strip()
      if key.len > 0:
        result.add key

proc visibleCommands*(cmds: seq[CommandDef]): seq[CommandDef] =
  ## Команды, которые видит пользователь: служебные не показываются.
  for c in cmds:
    if not c.hidden:
      result.add c

proc helpLines*(cmds: seq[CommandDef]): seq[string] =
  ## Общая справка. Ширина колонок фиксирована, поэтому вывод
  ## детерминирован и пригоден для сравнения байт-в-байт.
  result.add CliName & " " & EuterpiaVersion &
    " — CLI управления EUTERPIA (MANIFEST §19-21)"
  result.add ""
  result.add "Использование:"
  result.add "  " & CliName & " [глобальные ключи] <команда> [аргументы команды]"
  result.add "  " & CliName & " help [команда]"
  result.add "  " & CliName & " --version"
  result.add ""
  result.add "Глобальные ключи:"
  for item in GlobalFlags:
    result.add "  " & padTo(item[0], 16) & item[1]
  result.add ""
  result.add "Команды:"
  for c in visibleCommands(cmds):
    result.add "  " & padTo(c.usage, 28) & c.summary
  result.add ""
  result.add "Коды возврата:"
  for item in ExitCodeHelp:
    result.add "  " & $item[0] & " — " & item[1]

proc commandHelpLines*(cmd: CommandDef): seq[string] =
  ## Справка по одной команде: чем она является, что принимает и какие
  ## ключи принадлежат ей (а не CLI целиком).
  result.add "Использование: " & CliName & " " & cmd.usage
  result.add ""
  result.add cmd.summary
  if cmd.subcommands.len > 0:
    result.add ""
    result.add "Аргументы:"
    result.add "  " & cmd.subcommands.join(" | ")
  if cmd.flags.len > 0:
    result.add ""
    result.add "Ключи команды:"
    for flag in cmd.flags:
      result.add "  " & flag
  if cmd.notes.len > 0:
    result.add ""
    result.add "Подробности:"
    for note in cmd.notes:
      result.add "  " & note
  result.add ""
  result.add "Глобальные ключи работают и до, и после имени команды."
  result.add "Коды возврата:"
  for item in ExitCodeHelp:
    result.add "  " & $item[0] & " — " & item[1]

proc registryJson*(cmds: seq[CommandDef]): JsonNode =
  ## Машинное описание поверхности команд: то, чем пользуется агент вместо
  ## парсинга текста справки (MANIFEST §21).
  result = newJArray()
  for c in visibleCommands(cmds):
    var item = newJObject()
    item["name"] = %c.name
    item["summary"] = %c.summary
    item["usage"] = %c.usage
    var flags = newJArray()
    for f in c.flags:
      flags.add %f
    item["flags"] = flags
    var subs = newJArray()
    for s in c.subcommands:
      subs.add %s
    item["subcommands"] = subs
    result.add item

proc globalFlagsJson*(): JsonNode =
  result = newJArray()
  for item in GlobalFlags:
    result.add(%*{"flag": item[0], "description": item[1]})

proc exitCodesJson*(): JsonNode =
  result = newJArray()
  for item in ExitCodeHelp:
    result.add(%*{"code": item[0], "meaning": item[1]})
