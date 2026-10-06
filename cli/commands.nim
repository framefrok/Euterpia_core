# cli/commands.nim
#
# Реестр команд CLI и команды, которые не заслуживают отдельного модуля
# (`version`, `help`, `__complete`, `__reference`) — issue #88, #259, #330.
#
# Реестр собирается из СПЕЦИФИКАЦИЙ (`libs/cli_spec`): описание команды —
# данные, а здесь только соединение описания с телом и порядок, задающий
# `--help`. Ни одно имя команды, ни один ключ и ни один пример не пишутся
# здесь дважды: справка, `help --json`, автодополнение и раздел `docs/cli.md`
# выводятся из спецификации.
#
# Реестр живёт в изменяемой переменной, а не в константе, по одной причине:
# командам нужен доступ к реестру целиком (`help`, `__complete`), а
# константа, инициализируемая процедурами из этого же модуля, замкнула бы
# инициализацию на себя. `setupRegistry()` вызывается один раз в `main`.

import std/[json, os, strutils]
import context
import registry
import cmd_completion
import cmd_config
import cmd_doctor
import cmd_graph
import cmd_notation
import cmd_project
import cmd_render
import cmd_analyze
import cmd_midi
import cmd_history
import euterpia_version

var gCommands: seq[CommandDef]

proc allCommands*(): seq[CommandDef] =
  ## Поверхность команд текущего запуска. Пустой список — `setupRegistry`
  ## ещё не вызван; в CLI это невозможно, но пустой список лучше падения.
  gCommands

# =============================================================================
# Спецификации команд, которым отдельного модуля не нужно
# =============================================================================

const
  ReferenceProtocol* = "__reference"
    ## Служебная команда: печатает раздел `docs/cli.md` из спецификации
    ## (issue #330). Так же, как `__complete` для автодополнения, она не
    ## входит в человеческую справку: её зовёт `nimble cliDocs` и тест.

  HelpSpec* = CommandSpec(
    name: "help",
    summary: "справка по командам и ключам",
    synopsis: "help [команда]",
    commandArgs: true,
    args: @[
      arg("команда", "о какой команде рассказать; без аргумента — обо всех"),
    ],
    example: "euterpia help render",
    fields: @[
      field("usage", "как вызывать CLI целиком"),
      field("commands", "команды: синопсис, ключи, варианты, поля ответа"),
      field("globalFlags", "глобальные ключи"),
      field("exitCodes", "коды возврата"),
      field("specProblems", "замечания к описаниям команд: пусто — описания полны"),
      field("helpFor", "о какой команде справка (`help <команда> --json`)"),
    ],
    notes: @[
      "справка и `--json` собираются из одной спецификации: разойтись не могут (#96)",
      "`specProblems` — машинная проверка описаний: пустой список означает, что у каждой команды есть синопсис, ключи с типами и умолчаниями, пример и поля ответа (#330)",
    ])

  VersionSpec* = CommandSpec(
    name: "version",
    summary: "версия CLI и ядра",
    synopsis: "version",
    example: "euterpia version",
    fields: @[
      field("name", "имя программы"),
      field("version", "версия из `euterpia_version.nim` — тот же источник, что у пакета"),
      field("schema", "версия схемы JSON-конверта"),
      field("nim", "версия Nim, которой собран бинарь"),
      field("os", "ОС сборки"),
      field("arch", "архитектура сборки"),
    ],
    notes: @[
      "версия печатается из `euterpia_version.nim` — того же модуля, из которого nimble берёт версию пакета: разойтись они не могут (#88)",
      "`--version` даёт тот же ответ, что `version`",
    ])

  CompleteSpec* = CommandSpec(
    name: CompletionProtocol,
    summary: "служебная: кандидаты автодополнения",
    synopsis: CompletionProtocol & " [команда] [префикс]",
    hidden: true)

  ReferenceSpec* = CommandSpec(
    name: ReferenceProtocol,
    summary: "служебная: раздел docs/cli.md из спецификации команд",
    synopsis: ReferenceProtocol & " [--write файл.md]",
    options: @[
      opt("--write", "записать раздел в документ между маркерами", value = "файл.md"),
    ],
    hidden: true,
    notes: @[
      "без --write печатает раздел: этим тест сверяет docs/cli.md со спецификацией",
      "с --write заменяет всё между маркерами — проза вокруг остаётся рукописной",
    ])

# =============================================================================
# version
# =============================================================================

proc runVersion*(ctx: var Ctx; args: seq[string]): Report =
  ## Версия печатается из `euterpia_version.nim` — того же модуля, из
  ## которого nimble берёт версию пакета. Разойтись они не могут (#88).
  discard ctx
  if args.len > 0:
    return usageError("version не принимает аргументов, получено: " & args.join(" "))

  okReport(
    body = %*{
      "name": CliName,
      "version": EuterpiaVersion,
      "schema": CliSchema,
      "nim": NimVersion,
      "os": hostOS,
      "arch": hostCPU,
    },
    lines = @[CliName & " " & EuterpiaVersion])

# =============================================================================
# help
# =============================================================================

proc referenceErrorRules*(): seq[ErrorRule] =
  ## Таблица «причина → код возврата» в виде, который понимает `cli_spec`:
  ## из неё строится раздел `docs/cli.md` и машинное поле `errorReasons`
  ## (`help --json`). Источник один — `cli/exit_codes.nim` (#332).
  for rule in ExitRules:
    result.add ErrorRule(
      name: $rule.code,
      number: frameCodeValue(rule.code),
      exit: ord(rule.exit),
      meaning: rule.meaning)

proc helpReport*(cmds: seq[CommandDef]; requested: string): Report =
  ## Справка по одной команде или общая. Оба вида строятся из спецификаций,
  ## поэтому `--help` и `help --json` не могут разойтись (#96, #330).
  if requested.len > 0:
    let index = findCommand(cmds, requested)
    if index < 0:
      return usageError("неизвестная команда: " & requested)
    let cmd = cmds[index]
    return okReport(body = commandHelpJson(cmd), lines = commandHelpLines(cmd))

  var body = newJObject()
  body["usage"] = %(CliName & " [глобальные ключи] <команда> [аргументы команды]")
  body["commands"] = registryJson(cmds)
  body["globalFlags"] = globalFlagsJson()
  body["exitCodes"] = exitCodesJson()
  # Машинная проверка описаний: список замечаний пуст только тогда, когда у
  # каждой команды есть синопсис, ключи с типами и умолчаниями, пример и поля
  # ответа. Испорченная спецификация видна здесь, а не у пользователя.
  body["specProblems"] = %validateSpecs(specsOf(cmds))
  # Таблица «причина → код возврата» (#332): агент читает её машинно, а тест
  # сверяет с документацией и с реальными отказами команд. `exitCodeProblems`
  # — проверка самой таблицы: причина без кода возврата роняет CI.
  var reasons = newJArray()
  for rule in referenceErrorRules():
    reasons.add %*{"name": rule.name, "number": rule.number,
                   "exit": rule.exit, "meaning": rule.meaning}
  body["errorReasons"] = reasons
  body["exitCodeProblems"] = %exitRulesProblems()
  okReport(body = body, lines = helpLines(cmds))

proc runHelp*(ctx: var Ctx; args: seq[string]): Report =
  discard ctx
  if args.len > 1:
    return usageError("help принимает не больше одной команды, получено: " &
                      args.join(" "))
  helpReport(allCommands(), if args.len == 1: args[0] else: "")

# =============================================================================
# __complete — машинный источник кандидатов автодополнения
# =============================================================================

proc completeCandidates*(cmds: seq[CommandDef]; args: seq[string]): seq[string] =
  ## `__complete <префикс>` — имена команд; `__complete <команда> <префикс>` —
  ## ключи и аргументы команды. Ровно этот протокол дергают сгенерированные
  ## скрипты, поэтому список команд в шаблонах оболочек отсутствует (#259).
  ## Кандидаты собирает спецификация: дополнение показывает то же, что справка.
  var prefix = ""
  var command = ""
  case args.len
  of 0:
    discard
  of 1:
    prefix = args[0]
  of 2:
    prefix = args[1]
    command = args[0]
  else:
    return
  completionCandidates(specsOf(cmds), command, prefix)

proc runComplete*(ctx: var Ctx; args: seq[string]): Report =
  ## Служебная команда: печатает по одному кандидату в строку. Пустой
  ## ответ — не ошибка: оболочка просто ничего не дополнит.
  discard ctx
  let candidates = completeCandidates(allCommands(), args)
  okReport(
    body = %*{"candidates": %candidates},
    lines = candidates)

# =============================================================================
# __reference — раздел docs/cli.md из спецификации
# =============================================================================

proc runReference*(ctx: var Ctx; args: seq[string]): Report =
  ## Служебная команда: печатает раздел справочника, собранный из той же
  ## спецификации, что `--help` и `help --json`. `--write` заменяет всё между
  ## маркерами в документе — этим пользуется задача `nimble cliDocs`, а тест
  ## сверяет раздел в репозитории с этим же текстом байт-в-байт (#330).
  discard ctx
  let reference = markdownReference(specsOf(allCommands()), CliName,
                                  referenceErrorRules())

  var writePath = ""
  var i = 0
  while i < args.len:
    if args[i] == "--write":
      if i + 1 >= args.len:
        return usageError("--write: нужен путь к документу",
                          "например: euterpia " & ReferenceProtocol &
                          " --write docs/cli.md")
      writePath = args[i + 1]
      inc i, 2
    else:
      return usageError("__reference принимает только --write <файл>, получено: " &
                        args[i])

  if writePath.len == 0:
    return okReport(body = %*{"reference": reference},
                    lines = reference.splitLines())

  if not fileExists(writePath):
    return usageError("нет такого документа: " & writePath,
                      "раздел вставляется в существующий файл между маркерами")
  let doc = readFile(writePath)
  if not hasReferenceMarkers(doc):
    return usageError("в документе нет маркеров раздела",
                      "нужны строки " & ReferenceBegin & " и " & ReferenceEnd &
                      ": без них раздел пришлось бы дописывать вторым справочником")
  let updated = spliceReference(doc, reference)
  writeFile(writePath, updated)
  okReport(body = %*{"path": writePath, "written": true, "bytes": reference.len},
           lines = @["раздел справочника обновлён: " & writePath])

# =============================================================================
# Реестр
# =============================================================================

proc setupRegistry*() =
  ## Порядок команд задаёт порядок в `--help`: сначала то, что делает
  ## пользователь (создать проект — посмотреть — изменить), затем
  ## диагностика и справка; служебные (`__complete`, `__reference`) —
  ## в конце и скрытыми.
  ##
  ## У каждой строки видно ровно две вещи: спецификацию (что команда собой
  ## представляет) и тело (что она делает). Третьей копии описания — для
  ## справки или документации — не существует (#330).
  gCommands = @[
    CommandDef(spec: InitSpec, run: runInit),
    CommandDef(spec: ProjectSpec, run: runProject),
    CommandDef(spec: MidiSpec, run: runMidi),
    CommandDef(spec: NodeSpec, run: runNode),
    CommandDef(spec: ConnectSpec, run: runConnectCommand),
    CommandDef(spec: DisconnectSpec, run: runDisconnectCommand),
    CommandDef(spec: ParamSpec, run: runParam),
    CommandDef(spec: GraphSpec, run: runGraph),
    CommandDef(spec: UndoSpec, run: runUndo),
    CommandDef(spec: RedoSpec, run: runRedo),
    CommandDef(spec: HistorySpec, run: runHistory),
    CommandDef(spec: RenderSpec, run: runRender),
    CommandDef(spec: NotationSpec, run: runNotation),
    CommandDef(spec: AnalyzeSpec, run: runAnalyze),
    CommandDef(spec: CompletionSpec, run: runCompletion),
    CommandDef(spec: DoctorSpec, run: runDoctor),
    CommandDef(spec: ConfigSpec, run: runConfig),
    CommandDef(spec: HelpSpec, run: runHelp),
    CommandDef(spec: VersionSpec, run: runVersion),
    CommandDef(spec: CompleteSpec, run: runComplete),
    CommandDef(spec: ReferenceSpec, run: runReference),
  ]
