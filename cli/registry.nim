# cli/registry.nim
#
# Реестр команд CLI: соединение ОПИСАНИЯ (`libs/cli_spec`, issue #330) с
# ИСПОЛНЕНИЕМ (тело команды).
#
# Описание команды живёт в спецификации (`CommandSpec`), а не в текстах:
# из неё собираются `--help`, `help --json`, кандидаты автодополнения
# (`__complete`) и раздел `docs/cli.md`. Здесь остаётся то, чем спецификация
# не является: само тело команды (`run`) и поиск по реестру.
#
# Поэтому добавление команды больше не требует правок в трёх местах: одна
# спецификация рядом со своим разбором аргументов плюс одна строка в
# `cli/commands.nim`. Справка, схема `--json`, дополнение и справочник —
# следствия, а не копии (MANIFEST §21).
#
# `CliName`/`EuterpiaVersion` подставляются здесь: `libs/cli_spec` не знает
# корня пакета и получает их параметрами.

import std/json
import cli_spec
import context
import euterpia_version

export cli_spec

type
  CommandProc* = proc(ctx: var Ctx; args: seq[string]): Report {.closure.}
    ## Тело команды. Аргументы — «хвост» argv после имени команды, из
    ## которого уже вынуты глобальные ключи (`--json`, `--verbose`, …).

  CommandDef* = object
    spec*: CommandSpec
      ## Что команда собой представляет: для справки, `--json`,
      ## автодополнения и документации.
    run*: CommandProc
      ## Что команда делает. Реестр связывает одно с другим, но не
      ## смешивает: спецификацию можно прочитать, не исполняя код.

proc findCommand*(cmds: seq[CommandDef]; name: string): int =
  ## Индекс команды по точному имени или -1.
  for i in 0 ..< cmds.len:
    if cmds[i].spec.name == name:
      return i
  -1

proc visibleCommands*(cmds: seq[CommandDef]): seq[CommandDef] =
  ## Команды, которые видит пользователь: служебные не показываются.
  for c in cmds:
    if not c.spec.hidden:
      result.add c

proc specsOf*(cmds: seq[CommandDef]): seq[CommandSpec] =
  ## Описания реестра — вход генераторов (справка, `--json`, Markdown).
  for c in cmds:
    result.add c.spec

proc helpLines*(cmds: seq[CommandDef]): seq[string] =
  ## Общая справка — из описаний, поэтому совпадает с `help --json`.
  cli_spec.helpLines(specsOf(cmds), CliName, EuterpiaVersion)

proc commandHelpLines*(cmd: CommandDef): seq[string] =
  ## Справка по одной команде.
  cli_spec.commandHelpLines(cmd.spec, CliName)

proc registryJson*(cmds: seq[CommandDef]): JsonNode =
  ## Машинное описание поверхности команд (MANIFEST §21).
  cli_spec.registryJson(specsOf(cmds))

proc commandHelpJson*(cmd: CommandDef): JsonNode =
  ## `help <команда> --json`.
  cli_spec.commandHelpJson(cmd.spec, CliName)
