# libs/cli_spec.nim
#
# Описание команды CLI — ДАННЫМИ (issue #330).
#
# Зачем: справка (`--help`), машинная схема (`help --json`), кандидаты
# автодополнения (`__complete`) и раздел `docs/cli.md` — четыре представления
# ОДНОГО описания. Пока каждое пишется руками, они расходятся: человек
# получает справку, которая врёт, а тест #96 ловил только «команды нет в
# справочнике» — не расхождение в ключах, умолчаниях или примере.
#
# Границы (§20, §27): библиотека знает о ФОРМЕ команд CLI и ничего не знает ни
# о ядре, ни о разборе argv, ни о том, что команда делает. Тело команды
# (`CommandProc`) живёт в CLI (`cli/registry.nim`) и в спецификацию не входит:
# описание и исполнение соединены, но не смешаны. Поэтому `cliName`/`version`
# здесь — параметры генераторов, а не импорт `euterpia_version`: libs
# остаётся свободной от корня пакета.
#
# Спецификация — обычные данные, а `validateSpecs` проверяет их
# согласованность: имя, синопсис, ключи, типы значений, умолчания и пример.
# Тест «CLI: спецификация команд» (tests/cli_test.nim) прогоняет эту проверку
# по боевому реестру и сверяет справку, `--json`, автодополнение и
# `docs/cli.md` друг с другом: испорченная спецификация роняет CI, а не
# проходит молча.

import std/[json, strutils, unicode]

type
  OptionKind* = enum
    okValue   ## `--tempo 140` — ключ со значением
    okSwitch  ## `--force` — ключ без значения

  OptionSpec* = object
    ## Ключ команды. `value` — тип значения человеческим текстом
    ## (`число BPM`), а не имя типа Nim: она печатается в справке и docs.
    flag*: string
    aliases*: seq[string]
    kind*: OptionKind
    value*: string
    default*: string
      ## Умолчание как текст. Пусто — «умолчания нет» (у `--force` его нет),
      ## это не то же самое, что «пустая строка по умолчанию».
    required*: bool
    summary*: string

  ArgSpec* = object
    ## Позиционный аргумент: имя в виде, пригодном для справки, и смысл.
    name*: string
    summary*: string

  FieldSpec* = object
    ## Поле ответа `--json` верхнего уровня.
    name*: string
    summary*: string

  CommandSpec* = object
    name*: string
    summary*: string
    aliases*: seq[string]
      ## Legacy command names kept working for at least one release line
      ## (#350). Aliases are resolved by the dispatcher, never advertised in
      ## completion, and every use prints a deprecation warning to stderr.
    aliasesDeprecatedSince*: string
      ## Version that declared the aliases legacy. Required when `aliases` is
      ## not empty: policy needs a date, not a vague "old".
    deprecatedSince*: string
      ## Version that deprecated the command itself ("" = current). A
      ## deprecated command still runs; it says so and points at `replacedBy`.
    replacedBy*: string
      ## Canonical command that should be used instead.
    synopsis*: string
      ## Как команда выглядит после имени CLI: `init [файл] [ключи]`.
      ## Позиционные аргументы перечисляются ВСЕГДА: по синопсису человек и
      ## агент решают, что команда примет.
    args*: seq[ArgSpec]
    options*: seq[OptionSpec]
    subcommands*: seq[string]
      ## Позиционные варианты (`show`, `set`) — они же кандидаты
      ## автодополнения второго уровня.
    filelessSubcommands*: seq[string]
      ## Подкоманды, которым НЕ подставляется проект сессии (`open`).
      ## `render diff a.wav b.wav` работает с готовыми файлами, и дописанный
      ## `--file session.eproj` был бы чужим аргументом. Правило объявлено
      ## данными, а не проверкой `args[0] == "diff"` в диспетчере: подкоманда
      ## появляется вместе с правилом и проверяется `validateSpecs`.
    example*: string
      ## Одна рабочая командная строка целиком: `euterpia init demo.eproj`.
      ## Пример обязателен у каждой видимой команды — иначе справка
      ## показывает синтаксис, но не показывает употребление.
    fields*: seq[FieldSpec]
      ## Поля ответа `--json`. Это и есть «схема --json», которой пользуется
      ## агент вместо разбора человеческой справки (§21).
    notes*: seq[string]
      ## Проза справки: форма аргументов, умолчания, ограничения. В
      ## кандидаты автодополнения НЕ попадает — там только ключи и варианты.
    commandArgs*: bool
      ## Позиционные аргументы — имена других команд (`help doctor`).
    hidden*: bool
      ## Служебные команды (`__complete`, `__reference`) не показываются, не
      ## предлагаются и не требуют примера.

const
  CliSpecSchema* = 1
    ## Версия формы описания команд. Поднимается, когда меняется состав
    ## полей `specJson` — тот же приём, что у схемы конверта (#88).

  GlobalFlags* = [
    ("--json", "машиночитаемый вывод: ровно одна строка JSON в stdout"),
    ("--human", "человекочитаемый вывод (перекрывает настройку output=json)"),
    ("--verbose, -v", "лог Core уровня DEBUG в stderr"),
    ("--quiet, -q", "только ошибки в stderr"),
    ("--dry-run", "показать изменения, ничего не записывая на диск"),
    ("--help, -h", "справка; с командой — справка по команде"),
    ("--version", "версия CLI и ядра"),
  ]
    ## Глобальные ключи в порядке описания: один источник для `--help`,
    ## `help --json` и автодополнения.

  ExitCodeHelp* = [
    (0, "успех"),
    (1, "ошибка данных или использования"),
    (2, "ошибка среды: нет библиотеки, устройства или прав"),
    (3, "внутренняя ошибка (баг CLI)"),
  ]
    ## Коды возврата CLI. Таблица «причина → код» для ядра (#332) живёт
    ## рядом с контролем, а здесь — только то, что видит пользователь.

  ReferenceBegin* = "<!-- cli-spec:begin: генерируется `nimble cliDocs`; руками не править -->"
  ReferenceEnd* = "<!-- cli-spec:end -->"
    ## Маркеры сгенерированного раздела `docs/cli.md`. Всё между ними
    ## принадлежит `markdownReference`, всё вокруг — прозе человека.

type
  ErrorRule* = object
    ## Строка таблицы «причина → код возврата» для документации (issue #332).
    ##
    ## `cli_spec` не знает ни ядра, ни CLI: строки передаёт вызывающий
    ## (`cli/exit_codes.nim` — единственное место, где причина связана с кодом
    ## возврата), поэтому таблица в разделе собирается из того же источника,
    ## что и отказы команд.
    name*: string
      ## Имя причины (`not_found`) — то же, что в `error.kind` кадра ядра.
    number*: int
      ## Числовой код причины для агента (`errorCode` в `--json`).
    exit*: int
      ## Код возврата процесса (`exitCode` в `--json`).
    meaning*: string
      ## Что причина значит для человека.

# =============================================================================
# Конструкторы: спецификация пишется как данные
# =============================================================================

proc opt*(flag: string; summary: string; value = ""; default = "";
          required = false; aliases: seq[string] = @[]): OptionSpec =
  ## Ключ со значением: `opt("--tempo", "темп проекта", value = "число BPM",
  ## default = "120")`.
  OptionSpec(flag: flag, aliases: aliases, kind: okValue, value: value,
             default: default, required: required, summary: summary)

proc switch*(flag: string; summary: string;
             aliases: seq[string] = @[]): OptionSpec =
  ## Ключ-флаг: значение у него отсутствует по определению, поэтому
  ## `value`/`default` для него недопустимы (проверяет `validateSpecs`).
  OptionSpec(flag: flag, aliases: aliases, kind: okSwitch,
             summary: summary)

proc arg*(name: string; summary: string): ArgSpec =
  ArgSpec(name: name, summary: summary)

proc field*(name: string; summary: string): FieldSpec =
  FieldSpec(name: name, summary: summary)

# =============================================================================
# Выборки из спецификации
# =============================================================================

proc keysOf*(options: seq[OptionSpec]): seq[string] =
  ## Все формы ключей: каноническая и алиасы, в порядке объявления.
  for o in options:
    result.add o.flag
    for alias in o.aliases:
      result.add alias

proc optionKeys*(spec: CommandSpec): seq[string] =
  ## Ключи команды — то, что печатается в подсказке об ошибке и
  ## предлагается автодополнением. Команды берут свой список отсюда
  ## (`const RenderKeys* = RenderSpec.optionKeys`), а не объявляют копию.
  keysOf(spec.options)

proc commandNames*(spec: CommandSpec): seq[string] =
  ## Canonical name followed by legacy aliases. The dispatcher resolves all of
  ## them to the same `CommandDef`; completion and help show only `name`.
  result.add spec.name
  for alias in spec.aliases:
    if alias notin result:
      result.add alias

proc isDeprecated*(spec: CommandSpec): bool =
  spec.deprecatedSince.len > 0

proc deprecationText*(spec: CommandSpec; usedName: string): string =
  ## One warning line, printed to stderr. Empty for a non-deprecated command.
  ## The text is stable so scripts can assert it (#350).
  if usedName.len > 0 and usedName != spec.name:
    result = "note: `" & usedName & "` is a deprecated alias of `" &
      spec.name & "`"
    if spec.aliasesDeprecatedSince.len > 0:
      result.add " (since " & spec.aliasesDeprecatedSince & ")"
    elif spec.deprecatedSince.len > 0:
      result.add " (since " & spec.deprecatedSince & ")"
    result.add "; the alias keeps working for this release line"
    return
  if spec.deprecatedSince.len == 0:
    return
  result = "note: `" & spec.name & "` is deprecated since " &
    spec.deprecatedSince
  if spec.replacedBy.len > 0:
    result.add "; use `" & spec.replacedBy & "`"
  result.add " (still works for this release line)"

proc globalFlagKeys*(): seq[string] =
  ## Разбирает `GlobalFlags` на отдельные ключи: `--verbose` и `-v`.
  ## Нужно автодополнению и проверке «ключ в синопсисе объявлен» —
  ## поэтому разбор живёт рядом с самим списком.
  for item in GlobalFlags:
    for part in item[0].split(','):
      let key = part.strip()
      if key.len > 0:
        result.add key

proc visibleSpecs*(specs: seq[CommandSpec]): seq[CommandSpec] =
  ## Команды, которые видит пользователь: служебные не показываются.
  for spec in specs:
    if not spec.hidden:
      result.add spec

proc valueText*(o: OptionSpec): string =
  ## `--tempo <число BPM>`; у флага значения нет.
  if o.kind == okValue: "<" & o.value & ">" else: ""

proc keyText*(o: OptionSpec): string =
  ## Ключ со всеми формами: `--file <файл.eproj>` или `--sr, --sample-rate`.
  result = o.flag
  let value = valueText(o)
  if value.len > 0:
    result.add " " & value
  for alias in o.aliases:
    result.add ", " & alias

proc defaultValueText*(o: OptionSpec): string =
  ## Умолчание человеческим текстом; пусто — умолчания нет.
  if o.default.len > 0: "умолчание: " & o.default else: ""

# =============================================================================
# Справка: `--help`, `help <команда>`
# =============================================================================

proc padTo(text: string; columns: int): string =
  ## Дополняет строку пробелами до нужного числа КОЛОНОК, но ВСЕГДА
  ## оставляет видимый зазор: если текст не умещается в колонку, к нему
  ## добавляются два пробела, а не ноль.
  ##
  ## `strutils.alignLeft` считает байты, а в справке есть кириллица:
  ## «help [команда]» — это 14 символов и 20 байт, поэтому колонки
  ## разъезжались. Считаем именно символы (runeLen).
  result = text
  let width = runeLen(text)
  if width < columns:
    result.add repeat(' ', columns - width)
  else:
    result.add "  "

proc helpLines*(specs: seq[CommandSpec]; cliName, version: string): seq[string] =
  ## Общая справка. Ширина колонок фиксирована, поэтому вывод
  ## детерминирован и пригоден для сравнения байт-в-байт.
  result.add cliName & " " & version &
    " — CLI управления EUTERPIA (MANIFEST §19-21)"
  result.add ""
  result.add "Использование:"
  result.add "  " & cliName & " [глобальные ключи] <команда> [аргументы команды]"
  result.add "  " & cliName & " help [команда]"
  result.add "  " & cliName & " --version"
  result.add ""
  result.add "Глобальные ключи:"
  for item in GlobalFlags:
    result.add "  " & padTo(item[0], 16) & item[1]
  result.add ""
  result.add "Команды:"
  # Ширина колонки — под самую широкую команду (не меньше 28), поэтому
  # длинный синтаксис (`midi`, `disconnect`) не наезжает на описание.
  # Вывод остаётся детерминированным: ширина зависит только от спецификации.
  var usageWidth = 28
  for spec in visibleSpecs(specs):
    let need = runeLen(spec.synopsis) + 2
    if need > usageWidth:
      usageWidth = need
  for spec in visibleSpecs(specs):
    result.add "  " & padTo(spec.synopsis, usageWidth) & spec.summary
  result.add ""
  result.add "Коды возврата:"
  for item in ExitCodeHelp:
    result.add "  " & $item[0] & " — " & item[1]

proc commandHelpLines*(spec: CommandSpec; cliName: string): seq[string] =
  ## Справка по одной команде: чем она является, что принимает, какие ключи
  ## принадлежат ей (а не CLI целиком) и как это выглядит на деле.
  result.add "Использование: " & cliName & " " & spec.synopsis
  result.add ""
  result.add spec.summary
  if spec.subcommands.len > 0:
    result.add ""
    result.add "Аргументы:"
    result.add "  " & spec.subcommands.join(" | ")
  if spec.args.len > 0:
    result.add ""
    result.add "Позиционные аргументы:"
    var argsWidth = 8
    for a in spec.args:
      let need = runeLen(a.name) + 2
      if need > argsWidth:
        argsWidth = need
    for a in spec.args:
      result.add "  " & padTo(a.name, argsWidth) & a.summary
  if spec.options.len > 0:
    result.add ""
    result.add "Ключи команды:"
    var keysWidth = 12
    for o in spec.options:
      let need = runeLen(keyText(o)) + 2
      if need > keysWidth:
        keysWidth = need
    for o in spec.options:
      var tail = o.summary
      let details = defaultValueText(o)
      if details.len > 0:
        tail.add "; " & details
      if o.required:
        tail.add "; обязательный"
      result.add "  " & padTo(keyText(o), keysWidth) & tail
  if spec.example.len > 0:
    result.add ""
    result.add "Пример:"
    result.add "  " & spec.example
  if spec.fields.len > 0:
    result.add ""
    result.add "Поля ответа --json:"
    for f in spec.fields:
      result.add "  " & f.name & " — " & f.summary
  if spec.notes.len > 0:
    result.add ""
    result.add "Подробности:"
    for note in spec.notes:
      result.add "  " & note
  result.add ""
  result.add "Глобальные ключи работают и до, и после имени команды."
  result.add "Коды возврата:"
  for item in ExitCodeHelp:
    result.add "  " & $item[0] & " — " & item[1]

# =============================================================================
# Машинная справка: `help --json`
# =============================================================================

proc exitCodesJson*(): JsonNode
  ## Объявлена заранее: `commandHelpJson` печатает ту же таблицу кодов
  ## возврата, а Nim требует порядок объявлений.

proc globalFlagsJson*(): JsonNode
  ## Объявлена заранее по той же причине: заполняется ниже, рядом с данными.

proc optionJson*(o: OptionSpec): JsonNode =
  ## Ключ как данные: вид (`value`/`switch`), тип значения, умолчание,
  ## обязательность. По ним агент строит вызов, не разбирая текст справки.
  result = newJObject()
  result["flag"] = %o.flag
  result["kind"] = %(if o.kind == okValue: "value" else: "switch")
  result["value"] = %o.value
  result["default"] = %o.default
  result["required"] = %o.required
  result["summary"] = %o.summary
  var aliases = newJArray()
  for alias in o.aliases:
    aliases.add %alias
  result["aliases"] = aliases

proc specJson*(spec: CommandSpec): JsonNode =
  ## Команда как данные. Поле `flags` (строки) оставлено рядом с `options`:
  ## им пользуется автодополнение и внешние сверки, и менять его форму
  ## значило бы ломать клиента ради переименования (#350).
  result = newJObject()
  result["name"] = %spec.name
  result["summary"] = %spec.summary
  result["usage"] = %spec.synopsis
  var aliases = newJArray()
  for alias in spec.aliases:
    aliases.add %alias
  result["aliases"] = aliases
  result["aliasesDeprecatedSince"] = %spec.aliasesDeprecatedSince
  result["deprecatedSince"] = %spec.deprecatedSince
  result["replacedBy"] = %spec.replacedBy
  var flags = newJArray()
  for key in spec.optionKeys():
    flags.add %key
  result["flags"] = flags
  var options = newJArray()
  for o in spec.options:
    options.add optionJson(o)
  result["options"] = options
  var subs = newJArray()
  for sub in spec.subcommands:
    subs.add %sub
  result["subcommands"] = subs
  var args = newJArray()
  for a in spec.args:
    args.add(%*{"name": a.name, "summary": a.summary})
  result["args"] = args
  result["example"] = %spec.example
  var fields = newJArray()
  for f in spec.fields:
    fields.add(%*{"name": f.name, "summary": f.summary})
  result["fields"] = fields
  result["hidden"] = %spec.hidden
  result["commandArgs"] = %spec.commandArgs

proc commandHelpJson*(spec: CommandSpec; cliName: string): JsonNode =
  ## `help <команда> --json`: то же описание плюс коды возврата — чтобы
  ## ответ на «как вызвать» и «что значит код» приходил одним запросом.
  result = newJObject()
  result["helpFor"] = %spec.name
  result["usage"] = %(cliName & " " & spec.synopsis)
  result["summary"] = %spec.summary
  var aliasJson = newJArray()
  for alias in spec.aliases:
    aliasJson.add %alias
  result["aliases"] = aliasJson
  result["aliasesDeprecatedSince"] = %spec.aliasesDeprecatedSince
  result["deprecatedSince"] = %spec.deprecatedSince
  result["replacedBy"] = %spec.replacedBy
  var flags = newJArray()
  for key in spec.optionKeys():
    flags.add %key
  result["flags"] = flags
  var options = newJArray()
  for o in spec.options:
    options.add optionJson(o)
  result["options"] = options
  var subs = newJArray()
  for sub in spec.subcommands:
    subs.add %sub
  result["subcommands"] = subs
  var notes = newJArray()
  for note in spec.notes:
    notes.add %note
  result["notes"] = notes
  result["example"] = %spec.example
  var fields = newJArray()
  for f in spec.fields:
    fields.add(%*{"name": f.name, "summary": f.summary})
  result["fields"] = fields
  result["exitCodes"] = exitCodesJson()

proc registryJson*(specs: seq[CommandSpec]): JsonNode =
  ## Поверхность команд целиком: то, чем пользуется агент вместо парсинга
  ## текста справки (MANIFEST §21).
  result = newJArray()
  for spec in visibleSpecs(specs):
    result.add specJson(spec)

proc globalFlagsJson*(): JsonNode =
  result = newJArray()
  for item in GlobalFlags:
    result.add(%*{"flag": item[0], "description": item[1]})

proc exitCodesJson*(): JsonNode =
  result = newJArray()
  for item in ExitCodeHelp:
    result.add(%*{"code": item[0], "meaning": item[1]})

# =============================================================================
# Проверка спецификации
# =============================================================================

proc validateSpecs*(specs: seq[CommandSpec]): seq[string] =
  ## Проверяет согласованность описаний: имя, синопсис, ключи, типы значений,
  ## умолчания, варианты аргументов, пример и поля `--json`.
  ##
  ## Возвращает список замечаний в порядке обхода: пустой список — описание
  ## полное. Это не «линт ради линта»: ключ, которого нет в разборе, или
  ## команда без примера — это справка, которая врёт, и она видна здесь, а не
  ## через месяц у пользователя.
  var seenNames: seq[string] = @[]
  var seenAliases: seq[string] = @[]
  var allNames: seq[string] = @[]
  for known in specs:
    allNames.add known.name
  let globalKeys = globalFlagKeys()
  for spec in specs:
    let where = if spec.name.len > 0: spec.name else: "<команда без имени>"
    if spec.name.len == 0:
      result.add "команда без имени"
    else:
      if spec.name in seenNames:
        result.add where & ": имя команды повторяется"
      seenNames.add spec.name
    for alias in spec.aliases:
      if alias.len == 0:
        result.add where & ": пустой алиас команды"
      elif alias.startsWith("-"):
        result.add where & ": алиас команды начинается с дефиса: " & alias
      elif alias == spec.name:
        result.add where & ": алиас повторяет имя команды"
      elif alias in allNames or alias in seenAliases:
        result.add where & ": алиас " & alias & " уже занят другой командой"
      else:
        seenAliases.add alias
    if spec.aliases.len > 0 and spec.aliasesDeprecatedSince.len == 0:
      result.add where & ": aliases без aliasesDeprecatedSince — политика " &
        "не называет версию"
    if spec.deprecatedSince.len > 0 and spec.replacedBy.len == 0:
      result.add where & ": deprecatedSince без replacedBy — клиент не узнает замену"
    if spec.replacedBy.len > 0:
      if spec.replacedBy == spec.name:
        result.add where & ": replacedBy совпадает с именем команды"
      elif spec.replacedBy notin allNames:
        result.add where & ": replacedBy ссылается на неизвестную команду: " &
          spec.replacedBy
    if spec.summary.len == 0:
      result.add where & ": нет summary — строка в общей справке останется пустой"
    if spec.synopsis.len == 0:
      result.add where & ": нет synopsis"
    elif spec.name.len > 0 and spec.synopsis != spec.name and
        not spec.synopsis.startsWith(spec.name & " "):
      result.add where & ": synopsis не начинается с имени команды: " & spec.synopsis
    if not spec.hidden and spec.example.len == 0:
      result.add where & ": нет примера вызова"
    if spec.example.len > 0 and spec.name.len > 0 and
        not spec.example.startsWith("euterpia " & spec.name):
      result.add where & ": пример должен начинаться с «euterpia " &
        spec.name & "»: " & spec.example

    var keys: seq[string] = @[]
    for o in spec.options:
      if not o.flag.startsWith("--") or o.flag.len < 3:
        result.add where & ": ключ должен начинаться с «--»: " & o.flag
      if o.summary.len == 0:
        result.add where & ": у ключа " & o.flag & " нет описания"
      case o.kind
      of okValue:
        if o.value.len == 0:
          result.add where & ": у ключа " & o.flag & " не указан тип значения"
        if o.required and o.default.len > 0:
          result.add where & ": ключ " & o.flag &
            " обязателен и имеет умолчание — это противоречие"
      of okSwitch:
        if o.value.len > 0:
          result.add where & ": флаг " & o.flag & " не принимает значение"
        if o.default.len > 0:
          result.add where & ": у флага " & o.flag & " не может быть умолчания"
        if o.required:
          result.add where & ": флаг " & o.flag & " не может быть обязательным"
      for alias in o.aliases:
        if alias.len < 2 or not alias.startsWith("-"):
          result.add where & ": алиас " & alias & " должен начинаться с дефиса"
        elif alias == o.flag:
          result.add where & ": алиас повторяет сам ключ " & alias
      for key in keysOf(@[o]):
        if key in keys:
          result.add where & ": ключ " & key & " объявлен дважды"
        elif key in globalKeys:
          result.add where & ": ключ " & key &
            " глобальный — объявлять его в команде не нужно"
        keys.add key

    if spec.synopsis.len > 0:
      for token in spec.synopsis.split(' '):
        let clean = token.strip(chars = {'[', ']', '(', ')', ','})
        if clean.startsWith("--") and clean notin keys and clean notin globalKeys:
          result.add where & ": synopsis упоминает незаявленный ключ " & clean

    var subs: seq[string] = @[]
    for sub in spec.subcommands:
      if sub.len == 0:
        result.add where & ": пустой вариант аргумента"
      elif sub.startsWith("-"):
        result.add where & ": вариант аргумента начинается с дефиса: " & sub
      elif sub in subs:
        result.add where & ": вариант " & sub & " повторяется"
      subs.add sub

    for sub in spec.filelessSubcommands:
      if sub notin subs:
        result.add where & ": подкоманда без проекта сессии " & sub &
          " не объявлена в subcommands"

    for a in spec.args:
      if a.name.len == 0 or a.summary.len == 0:
        result.add where & ": позиционный аргумент без имени или описания"

    var fieldNames: seq[string] = @[]
    for f in spec.fields:
      if f.name.len == 0 or f.summary.len == 0:
        result.add where & ": поле --json " & f.name & " без имени или описания"
      elif f.name in fieldNames:
        result.add where & ": поле " & f.name & " описано дважды"
      fieldNames.add f.name

# =============================================================================
# Автодополнение: `__complete`
# =============================================================================

proc completionCandidates*(specs: seq[CommandSpec]; commandName, prefix: string): seq[string] =
  ## Кандидаты автодополнения — из того же описания, что справка и `--json`,
  ## поэтому шаблоны оболочек не содержат ни одного имени команды (#259).
  var index = -1
  for i, spec in specs:
    if spec.name == commandName:
      index = i
      break

  if index < 0:
    for spec in visibleSpecs(specs):
      if spec.name.startsWith(prefix):
        result.add spec.name
  else:
    let spec = specs[index]
    for key in spec.optionKeys():
      if key.startsWith(prefix):
        result.add key
    for sub in spec.subcommands:
      if sub.startsWith(prefix):
        result.add sub
    if spec.commandArgs:
      for candidate in visibleSpecs(specs):
        if candidate.name.startsWith(prefix):
          result.add candidate.name

  # Глобальные ключи подходят любой команде и работают в любом месте
  # строки (MANIFEST §21), поэтому предлагаются наравне с ключами команды.
  if prefix.startsWith("-"):
    for key in globalFlagKeys():
      if key.startsWith(prefix) and key notin result:
        result.add key

# =============================================================================
# Раздел docs/cli.md: то же описание, но Markdown
# =============================================================================

proc markdownReference*(specs: seq[CommandSpec]; cliName: string;
                        errorRules: seq[ErrorRule] = @[]): string =
  ## Справочник команд в Markdown. Печатается служебной `__reference` и
  ## вставляется в `docs/cli.md` задачей `nimble cliDocs`; тест сверяет
  ## раздел в репозитории с этим текстом байт-в-байт, поэтому справочник не
  ## может отстать от кода, а таблицы ключей и кодов ошибок — соврать.
  ##
  ## `errorRules` — таблица «причина → код возврата» (#332): она тоже
  ## генерируется, потому что написанная руками разошлась бы с кодом на первом
  ## же добавленном отказе.
  var lines: seq[string] = @[]
  for spec in visibleSpecs(specs):
    lines.add "### `" & spec.name & "` — " & spec.summary
    lines.add ""
    lines.add "```text"
    lines.add cliName & " " & spec.synopsis
    lines.add "```"
    lines.add ""
    if spec.aliases.len > 0:
      lines.add "Deprecated aliases (still work): " &
        spec.aliases.join(", ")
      if spec.aliasesDeprecatedSince.len > 0:
        lines.add "Since " & spec.aliasesDeprecatedSince & "."
      lines.add ""
    if spec.deprecatedSince.len > 0:
      var note = "**Deprecated** since " & spec.deprecatedSince
      if spec.replacedBy.len > 0:
        note.add "; use `" & spec.replacedBy & "`"
      lines.add note
      lines.add ""
    if spec.subcommands.len > 0:
      lines.add "Подкоманды: " & spec.subcommands.join(" | ")
      lines.add ""
    if spec.args.len > 0:
      lines.add "Аргументы:"
      lines.add ""
      for a in spec.args:
        lines.add "- `" & a.name & "` — " & a.summary
      lines.add ""
    if spec.options.len > 0:
      lines.add "Ключи:"
      lines.add ""
      lines.add "| Ключ | Значение | Умолчание | Смысл |"
      lines.add "|---|---|---|---|"
      for o in spec.options:
        var key = "`" & o.flag & "`"
        for alias in o.aliases:
          key.add ", `" & alias & "`"
        let value = if o.kind == okValue: o.value else: "—"
        let fallback = if o.default.len > 0: o.default else: "—"
        var sense = o.summary
        if o.required:
          sense.add " (обязательный)"
        lines.add "| " & key & " | " & value & " | " & fallback & " | " &
          sense & " |"
      lines.add ""
    if spec.example.len > 0:
      lines.add "Пример:"
      lines.add ""
      lines.add "```text"
      lines.add spec.example
      lines.add "```"
      lines.add ""
    if spec.fields.len > 0:

      lines.add "Поля ответа `--json`:"
      lines.add ""
      for f in spec.fields:
        lines.add "- `" & f.name & "` — " & f.summary
      lines.add ""
    if spec.notes.len > 0:
      lines.add "Подробности:"
      lines.add ""
      for note in spec.notes:
        lines.add "- " & note
      lines.add ""
  if errorRules.len > 0:
    lines.add "### Коды ошибок: причина → код возврата"
    lines.add ""
    lines.add "При отказе `--json` содержит класс (`error.kind`), причину числом" &
      " (`errorCode`) и код возврата процесса (`exitCode`). Таблица ниже" &
      " собирается из `cli/exit_codes.nim`: она не может разойтись с кодом," &
      " потому что генерируется."
    lines.add ""
    lines.add "| Причина | `errorCode` | `exitCode` | Что значит |"
    lines.add "|---|---|---|---|"
    for rule in errorRules:
      lines.add "| `" & rule.name & "` | " & $rule.number & " | " &
        $rule.exit & " | " & rule.meaning & " |"
    lines.add ""
  result = lines.join("\n") & "\n"

proc hasReferenceMarkers*(doc: string): bool =
  ## Есть ли в документе область, которой владеет генератор.
  let beginIdx = doc.find(ReferenceBegin)
  let endIdx = doc.find(ReferenceEnd)
  beginIdx >= 0 and endIdx > beginIdx

proc spliceReference*(doc, section: string): string =
  ## Заменяет всё между маркерами на `section`, сохраняя маркеры и прозу
  ## вокруг. Документ без маркеров возвращается как есть: дописать раздел
  ## «в конец» значило бы получить два справочника, то есть ровно то
  ## расхождение, от которого уходим.
  if not doc.hasReferenceMarkers():
    return doc
  let beginIdx = doc.find(ReferenceBegin)
  let endIdx = doc.find(ReferenceEnd)
  let head = doc[0 ..< beginIdx + ReferenceBegin.len]
  let tail = doc[endIdx .. ^1]
  head & "\n" & section & tail

proc roffEscape*(text: string): string
proc manPageFileName*(spec: CommandSpec): string
proc manHeader(title, version: string): seq[string]
proc commandManPage*(spec: CommandSpec; cliName, version: string): string

proc manPage*(specs: seq[CommandSpec]; cliName, version: string): string =
  ## Overview page (`man euterpia`): every visible command is listed, so the
  ## acceptance check "man euterpia names all registry commands" is a property
  ## of generation, not of a manually maintained list (#349).
  var lines = manHeader(cliName.toUpperAscii(), version)
  lines.add ".SH NAME"
  lines.add cliName & " \\- command line interface for EUTERPIA (MANIFEST 19-21)"
  lines.add ".SH SYNOPSIS"
  lines.add ".B " & cliName
  lines.add "[\\fIglobal options\\fR] \\fIcommand\\fR [\\fIarguments\\fR]"
  lines.add ".br"
  lines.add ".B " & cliName
  lines.add "help [\\fIcommand\\fR]"
  lines.add ".br"
  lines.add ".B " & cliName
  lines.add "\\-\\-version"
  lines.add ".SH DESCRIPTION"
  lines.add "EUTERPIA CLI creates, edits, renders and verifies project files"
  lines.add "without a GUI. Every command has a machine-readable form"
  lines.add "(--json) and is described by a single specification; help, JSON"
  lines.add "schema, shell completion, this manual and docs/cli.md are"
  lines.add "generated from it."
  lines.add ".SH COMMANDS"
  for spec in visibleSpecs(specs):
    lines.add ".TP"
    lines.add ".B " & roffEscape(spec.synopsis)
    var summary = spec.summary
    if spec.deprecatedSince.len > 0:
      summary.add " (deprecated since " & spec.deprecatedSince
      if spec.replacedBy.len > 0:
        summary.add "; use " & spec.replacedBy
      summary.add ")"
    lines.add roffEscape(summary)
    lines.add ".br"
    lines.add "See \\fB" & manPageFileName(spec) & "\\fR(1)."
  lines.add ".SH GLOBAL OPTIONS"
  for item in GlobalFlags:
    lines.add ".TP"
    lines.add ".B " & roffEscape(item[0])
    lines.add roffEscape(item[1])
  lines.add ".SH EXIT STATUS"
  for item in ExitCodeHelp:
    lines.add ".TP"
    lines.add ".B " & $item[0]
    lines.add roffEscape(item[1])
  lines.add ".SH FILES"
  lines.add ".TP"
  lines.add ".I presets/templates, presets/setlists, presets/params"
  lines.add "Project templates, set lists and parameter presets (searched"
  lines.add "next to the executable, in EUTERPIA_PRESETS and in the user"
  lines.add "configuration directory)."
  lines.add ".TP"
  lines.add ".I *.eproj, *.eut"
  lines.add "Project files; the format is identified by content, not by"
  lines.add "extension."
  lines.add ".SH SEE ALSO"
  var seeAlso: seq[string] = @[".BR " & cliName & "\\-init(1)"]
  for spec in visibleSpecs(specs):
    if spec.name != "init":
      seeAlso.add (".BR " & cliName & "\\-" & spec.name & "(1)")
  lines.add seeAlso.join(", ")
  lines.add ".SH AUTHOR"
  lines.add "EUTERPIA project."
  result = lines.join("\n") & "\n"

proc manPages*(specs: seq[CommandSpec]; cliName, version: string):
    seq[tuple[fileName, content: string]] =
  ## Overview page plus one page per visible command. Order is stable:
  ## overview first, then registry order.
  result.add (fileName: cliName & ".1",
              content: manPage(specs, cliName, version))
  for spec in visibleSpecs(specs):
    result.add (fileName: manPageFileName(spec),
                content: commandManPage(spec, cliName, version))


# =============================================================================
# man(1) pages generated from the same CommandSpec (#349)
# =============================================================================
#
# One source of truth: the man page is produced from the spec, so a new
# command appears in `man euterpia` without touching prose. `__man --check`
# (CI + cliSmoke) compares the committed `man/` directory with a fresh
# generation; a registry command without a page fails the build.
#
# Output is deterministic: no current date, no locale-dependent width. The
# header carries only the package version from `euterpia_version.nim`.

proc roffEscape*(text: string): string =
  ## Escape roff control characters. A leading `.` or `'` would otherwise be
  ## read as a macro, and `-` must render as a hyphen (not a minus sign).
  var atLineStart = true
  for ch in text:
    case ch
    of '\\': result.add "\\e"
    of '-': result.add "\\-"
    of '.':
      if atLineStart: result.add "\\&." else: result.add "."
    of '\'':
      if atLineStart: result.add "\\&'" else: result.add "'"
    of '\n':
      result.add "\n"
      atLineStart = true
      continue
    else: result.add ch
    atLineStart = false

proc manPageFileName*(spec: CommandSpec): string =
  ## `euterpia-init.1` — one page per visible command.
  "euterpia-" & spec.name & ".1"

proc manHeader(title, version: string): seq[string] =
  result.add ".\\\" Generated by `euterpia __man`; do not edit manually."
  result.add ".TH " & title & " 1 \"" & version & "\" \"EUTERPIA CLI\" \"User Commands\""

proc commandManPage*(spec: CommandSpec; cliName, version: string): string =
  ## Full manual page for one command: synopsis, arguments, options, example,
  ## exit status, and a pointer back to the overview page.
  var lines = manHeader("EUTERPIA\\-" & spec.name.toUpperAscii(), version)
  lines.add ".SH NAME"
  lines.add roffEscape(cliName & "-" & spec.name & " - " & spec.summary)
  lines.add ".SH SYNOPSIS"
  lines.add ".B " & roffEscape(cliName)
  lines.add "\\fR" & roffEscape(spec.synopsis) & "\\fR"
  lines.add ".SH DESCRIPTION"
  lines.add roffEscape(spec.summary) & "."
  if spec.aliases.len > 0:
    lines.add ".PP"
    var aliasNote = "Deprecated aliases (still work in this release line): " &
      roffEscape(spec.aliases.join(", ")) & "."
    if spec.aliasesDeprecatedSince.len > 0:
      aliasNote.add " Since " & spec.aliasesDeprecatedSince & "."
    lines.add aliasNote
  if spec.deprecatedSince.len > 0:
    lines.add ".PP"
    var note = "Deprecated since " & spec.deprecatedSince & "."
    if spec.replacedBy.len > 0:
      note.add " Use " & spec.replacedBy & " instead."
    lines.add roffEscape(note)
  if spec.subcommands.len > 0:
    lines.add ".SH ARGUMENTS"
    for sub in spec.subcommands:
      lines.add ".TP"
      lines.add ".B " & roffEscape(sub)
  if spec.args.len > 0:
    lines.add ".SH POSITIONAL ARGUMENTS"
    for a in spec.args:
      lines.add ".TP"
      lines.add ".B " & roffEscape(a.name)
      lines.add roffEscape(a.summary)
  if spec.options.len > 0:
    lines.add ".SH OPTIONS"
    for o in spec.options:
      lines.add ".TP"
      lines.add ".B " & roffEscape(keyText(o))
      var body = o.summary
      if o.default.len > 0:
        body.add " (default: " & o.default & ")"
      if o.required:
        body.add " (required)"
      lines.add roffEscape(body)
  if spec.example.len > 0:
    lines.add ".SH EXAMPLE"
    lines.add ".nf"
    lines.add roffEscape(spec.example)
    lines.add ".fi"
  if spec.notes.len > 0:
    lines.add ".SH NOTES"
    for note in spec.notes:
      lines.add ".IP \\[bu] 2"
      lines.add roffEscape(note)
  lines.add ".SH EXIT STATUS"
  for item in ExitCodeHelp:
    lines.add ".TP"
    lines.add ".B " & $item[0]
    lines.add roffEscape(item[1])
  lines.add ".SH SEE ALSO"
  lines.add ".BR " & cliName & "(1)"
  result = lines.join("\n") & "\n"

