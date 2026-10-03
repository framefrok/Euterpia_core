# cli/commands.nim
#
# Реестр команд CLI и команды, которые не заслуживают отдельного модуля
# (`version`, `help`, `__complete`) — issue #88, #259.
#
# Реестр живёт в изменяемой переменной, а не в константе, по одной причине:
# командам нужен доступ к реестру целиком (`help`, `__complete`), а
# константа, инициализируемая процедурами из этого же модуля, замкнула бы
# инициализацию на себя. `setupRegistry()` вызывается один раз в `main`.

import std/[json, strutils]
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
import config
import euterpia_version

var gCommands: seq[CommandDef]

proc allCommands*(): seq[CommandDef] =
  ## Поверхность команд текущего запуска. Пустой список — `setupRegistry`
  ## ещё не вызван; в CLI это невозможно, но пустой список лучше падения.
  gCommands

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

proc helpReport*(cmds: seq[CommandDef]; requested: string): Report =
  ## Справка по одной команде или общая. Оба вида строятся из реестра,
  ## поэтому `--help` и `help --json` не могут разойтись (#96).
  if requested.len > 0:
    let index = findCommand(cmds, requested)
    if index < 0:
      return usageError("неизвестная команда: " & requested)
    let cmd = cmds[index]
    var flags = newJArray()
    for flag in cmd.flags:
      flags.add %flag
    var subs = newJArray()
    for sub in cmd.subcommands:
      subs.add %sub
    var notes = newJArray()
    for note in cmd.notes:
      notes.add %note
    return okReport(
      body = %*{
        "helpFor": requested,
        "usage": CliName & " " & cmd.usage,
        "summary": cmd.summary,
        "flags": flags,
        "subcommands": subs,
        "notes": notes,
        "exitCodes": exitCodesJson(),
      },
      lines = commandHelpLines(cmd))

  var body = newJObject()
  body["usage"] = %(CliName & " [глобальные ключи] <команда> [аргументы команды]")
  body["commands"] = registryJson(cmds)
  body["globalFlags"] = globalFlagsJson()
  body["exitCodes"] = exitCodesJson()
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
  var prefix = ""
  var commandIndex = -1

  case args.len
  of 0:
    discard
  of 1:
    prefix = args[0]
  of 2:
    prefix = args[1]
    commandIndex = findCommand(cmds, args[0])
  else:
    return

  if commandIndex < 0:
    for cmd in visibleCommands(cmds):
      if cmd.name.startsWith(prefix):
        result.add cmd.name
  else:
    let cmd = cmds[commandIndex]
    for flag in cmd.flags:
      if flag.startsWith(prefix):
        result.add flag
    for sub in cmd.subcommands:
      if sub.startsWith(prefix):
        result.add sub
    if cmd.commandArgs:
      for candidate in visibleCommands(cmds):
        if candidate.name.startsWith(prefix):
          result.add candidate.name

  # Глобальные ключи подходят любой команде и работают в любом месте
  # строки (MANIFEST §21), поэтому предлагаются наравне с ключами команды.
  if prefix.startsWith("-"):
    for key in globalFlagKeys():
      if key.startsWith(prefix) and key notin result:
        result.add key

proc runComplete*(ctx: var Ctx; args: seq[string]): Report =
  ## Служебная команда: печатает по одному кандидату в строку. Пустой
  ## ответ — не ошибка: оболочка просто ничего не дополнит.
  discard ctx
  let candidates = completeCandidates(allCommands(), args)
  okReport(
    body = %*{"candidates": %candidates},
    lines = candidates)

# =============================================================================
# Реестр
# =============================================================================

proc setupRegistry*() =
  ## Порядок команд задаёт порядок в `--help`: сначала то, что делает
  ## пользователь (создать проект — посмотреть — изменить), затем
  ## диагностика и справка; служебные (`__complete`) — в конце и скрытыми.
  ##
  ## `notes` — проза для `--help`/`help <команда> --json` (форма аргументов,
  ## умолчания). В кандидаты автодополнения они не попадают: там только
  ## `flags` и `subcommands`.
  gCommands = @[
    CommandDef(
      name: "init",
      summary: "создать проект: метаданные и пустой граф",
      usage: "init [файл] [ключи]",
      flags: InitFlags,
      notes: @[
        "файл по умолчанию: " & DefaultProjectFile &
          " (расширение `.eut` — из примера MANIFEST §19)",
        "--tempo " & $int(DefaultTempo) & " BPM, --sr " &
          $int(DefaultSampleRate) & " Гц, --ts " &
          $DefaultTimeSigNumerator & "/" & $DefaultTimeSigDenominator &
          " — умолчания",
        "--name и --author задают метаданные; без --name имя берётся из имени файла",
        "граф создаётся пустым: ноды добавляет `euterpia node add` (#90)",
        "существующий файл не затирается: перезапись требует --force",
      ],
      run: runInit),
    CommandDef(
      name: "project",
      summary: "показать, изменить или проверить файл проекта",
      usage: "project <show|set|validate>",
      subcommands: ProjectSubcommands,
      notes: @[
        "project show [файл] — метаданные, граф, треки/клипы, автоматизация, состояния плагинов",
        "project set [файл] <поле> <значение> — поля: " &
          ProjectFields.join(", "),
        "project set пишет атомарно (tmp + rename) и обновляет metadata.modified",
        "project validate [файл] — отчёт о формате и целостности: провал проверки даёт код 1",
        "без файла команды работают с `" & DefaultProjectFile &
          "` — как в примере MANIFEST §19",
      ],
      run: runProject),
    CommandDef(
      name: "node",
      summary: "ноды графа: список, каталог типов, добавление, удаление, показ",
      usage: "node <list|types|add|rm|show> [аргументы] [--file проект.eut]",
      subcommands: NodeSubcommands,
      flags: GraphKeys,
      notes: @[
        "тип ноды — полный id (`euterpia.osc`), короткий (`osc`) или имя (`Oscillator`)",
        "порты, задержка и умолчания параметров берутся из типа: файл получает то, что умеет нода",
        "id назначается как максимум + 1; --id задаёт явно (занятый id — ошибка)",
        "node rm удаляет и связи, автоматизацию и состояния плагинов этой ноды",
        "файл проекта: --file или аргумент с расширением .eut (по умолчанию " &
          DefaultProjectFile & ")",
        "`node types` печатает каталог: id, порты, параметры — и человеческим текстом, и в --json",
      ],
      run: runNode),
    CommandDef(
      name: "connect",
      summary: "соединить выход одной ноды со входом другой",
      usage: "connect <источник> <приёмник> [--file проект.eut]",
      flags: GraphKeys,
      notes: @[
        "порт: `нода:out` | `нода:in` | `нода:audio:1` | `нода:ctrl:0` | `нода:event:0`",
        "пример MANIFEST §19: euterpia connect oscillator:out filter:in",
        "виды портов обязаны совпадать; самосоединение разрешено — компиляцию проверяет `graph check`",
      ],
      run: runConnectCommand),
    CommandDef(
      name: "disconnect",
      summary: "снять связь между нодами",
      usage: "disconnect <источник>[:порт] <приёмник>[:порт] [--file проект.eut]",
      flags: GraphKeys,
      notes: @[
        "без портов снимаются все связи между парой нод",
        "с портами — только указанная связь",
      ],
      run: runDisconnectCommand),
    CommandDef(
      name: "param",
      summary: "параметры ноды: список, чтение, запись",
      usage: "param <list|get|set> [аргументы] [--file проект.eut]",
      subcommands: ParamSubcommands,
      flags: GraphKeys,
      notes: @[
        "пример MANIFEST §19: euterpia param set filter cutoff 1200",
        "значение проверяется по диапазону типа: вне диапазона — отказ, а не запись",
        "параметр можно назвать именем (`freq`) или числовым id (стабильная ссылка)",
        "`param get` показывает и значение из файла, и умолчание типа",
      ],
      run: runParam),
    CommandDef(
      name: "graph",
      summary: "проверка графа: типы, порты, связи и компиляция",
      usage: "graph check [--file проект.eut]",
      subcommands: GraphSubcommands,
      flags: GraphKeys,
      notes: @[
        "проверяет структуру (типы, порты, связи, значения параметров) и компилирует граф",
        "компиляция идёт через Core: CLI не собирает пайплайн сам (§20)",
        "провал проверки — код 1; предупреждения (пустой граф, самосоединение) код не меняют",
        "отчёт — те же секции и `summary`, что у `project validate` и `doctor` (#96)",
      ],
      run: runGraph),
    CommandDef(
      name: "render",
      summary: "офлайн-рендер проекта в WAV без аудиоустройства",
      usage: "render [проект.eut] [выход.wav] [ключи]",
      flags: RenderKeys,
      notes: @[
        "пример MANIFEST §19: euterpia render project.eut",
        "вывод — WAV (PCM 16 или 24 бита, стерео); MP3/OGG требуют кодировщика и в ядре отсутствуют",
        "длительность: --seconds, иначе конец последней ноты + --tail (умолчание " &
          $int(DefaultTailSeconds) & " с)",
        "проект без нотных событий требует --seconds: длину пустой партитуры CLI не выдумывает",
        "частота и блок: argv > метаданные проекта > настройки > умолчание",
        "--dry-run печатает план рендера и не пишет файл",
        "тихая или оборванная запись — предупреждение, а не ошибка: код 2 только у сбоя записи",
      ],
      run: runRender),
    CommandDef(
      name: "notation",
      summary: "текстовая нотация: проверка файла и импорт в проект",
      usage: "notation <check|import> <файл.notes> [ключи]",
      subcommands: NotationSubcommands,
      flags: NotationKeys,
      notes: @[
        "notation check — разбор с указанием «строка:колонка»; ошибка разбора даёт код 1",
        "notation import — партитура становится клипом дорожки проекта; дорожка и клип создаются при необходимости",
        "файл задаёт клип целиком: повторный импорт той же партитуры даёт тот же проект",
        "длина клипа округляется вверх до целого такта размера проекта; --length задаёт её явно",
        "ключи check: " & CheckKeys.join(", "),
        "нотация: " & NotationHint,
      ],
      run: runNotation),
    CommandDef(
      name: "analyze",
      summary: "инспектор аудио: дефекты WAV с локализацией",
      usage: "analyze <файл.wav> [ключи]",
      flags: AnalyzeKeys,
      notes: @[
        "читает WAV и печатает отчёт с локализацией: клиппинг, DC, щелчки, " &
          "провалы, зависание, жужжание 50/60 Гц, алиасинг, резкость",
        "вердикт «нравится» остаётся за слушателем: инструмент не судит музыку, " &
          "а указывает конкретные места и причины",
        "--fail-on info|warn|error — порог для CI: код 1 при дефектах не ниже уровня (умолчание error)",
        "--snippets <каталог> пишет короткие WAV вокруг дефектов, --heatmap <файл.pgm> — спектрограмму",
        "--fft <N> задаёт размер кадра БПФ (256..65536; умолчание 2048)",
        "тот же Core-API (`core/audio_inspect`) позже использует Editor (#178)",
      ],
      run: runAnalyze),
    CommandDef(
      name: "completion",
      summary: "скрипт автодополнения оболочки",
      usage: "completion <bash|zsh|fish>",
      subcommands: Shells,
      run: runCompletion),
    CommandDef(
      name: "doctor",
      summary: "самодиагностика окружения: устройства, плагины, права",
      usage: "doctor",
      run: runDoctor),
    CommandDef(
      name: "config",
      summary: "настройки окружения: умолчания для команд",
      usage: "config <list|get|set|unset|path>",
      subcommands: ConfigSubcommands,
      notes: @[
        "приоритет значения: argv > env (EUTERPIA_*) > файл настроек > умолчание CLI",
        "где файл: `config path`; переопределение пути — EUTERPIA_CONFIG",
        "ключи: " & keyNames().join(", "),
        "`config get` печатает источник каждого значения: argv, env, file, default или none",
        "битый или неверный конфиг — предупреждение в stderr, команда работает на источнике ниже",
      ],
      run: runConfig),
    CommandDef(
      name: "help",
      summary: "справка по командам и ключам",
      usage: "help [команда]",
      commandArgs: true,
      run: runHelp),
    CommandDef(
      name: "version",
      summary: "версия CLI и ядра",
      usage: "version",
      run: runVersion),
    CommandDef(
      name: CompletionProtocol,
      summary: "служебная: кандидаты автодополнения",
      usage: CompletionProtocol & " [команда] [префикс]",
      hidden: true,
      run: runComplete),
  ]
