# cli/config.nim
#
# Настройки окружения CLI (issue #258): умолчания, которые иначе пришлось бы
# повторять флагами в каждой команде.
#
# Приоритет значения (сверху вниз):
#   1. ключи командной строки (`--json`/`--human`, `-v`/`-q`, а в будущем —
#      `--backend` и прочие флаги команд);
#   2. переменные окружения `EUTERPIA_*`;
#   3. файл настроек: `$XDG_CONFIG_HOME/euterpia/config.json` (Linux),
#      `~/Library/Application Support/euterpia/config.json` (macOS),
#      `%APPDATA%\euterpia\config.json` (Windows); путь переопределяется
#      `EUTERPIA_CONFIG` — это нужно и тестам, и изолированным прогонам;
#   4. умолчание CLI (`fallback` в таблице ключей ниже).
#
# Почему так (MANIFEST §21): сценарии и агентские прогоны должны быть
# воспроизводимы на другой машине, а вопрос «почему 48 кГц» не должен требовать
# чтения документации — `config get <ключ>` печатает ещё и ИСТОЧНИК значения.
#
# Отсутствие файла — не ошибка. Битый, нечитаемый или семантически неверный
# файл — предупреждение (в stderr) и работа на источнике ниже по приоритету:
# настройки не имеют права делать CLI неработающим.

import std/[json, os, strutils]

import logger
import signal_types   # MaxBlockSize: предел размера блока задаёт ядро
import probe          # доступность внешних библиотек (PortAudioLibs)

const
  ConfigSchema* = 1
    ## Версия схемы файла настроек. Меняется только при несовместимом
    ## изменении набора или типов ключей: агент обязан видеть, что схема другая.
  ConfigDirName* = "euterpia"
  ConfigFileName* = "config.json"
  ConfigPathEnv* = "EUTERPIA_CONFIG"
    ## Переопределение пути к файлу настроек.
  ConfigEnvPrefix* = "EUTERPIA_"

type
  KeyKind* = enum
    kkText, kkInt, kkPaths, kkChoice, kkBackend
      ## kkText — строка; kkInt — целое число; kkPaths — список каталогов
      ## через `PathSep`; kkChoice — значение из фиксированного набора;
      ## kkBackend — имя аудио-бэкенда: набор известных имён зависит от
      ## машины, поэтому проверяется не таблицей, а функцией.

  ConfigKey* = object
    name*: string
    env*: string
    kind*: KeyKind
    fallback*: string
      ## Умолчание CLI. Пусто — «значение не задано» (источник `none`):
      ## выдумывать умолчание там, где его определяет будущая команда
      ## (#92, #95), нельзя.
    choices*: seq[string]
    maxValue*: int
      ## Верхняя граница для `kkInt` (0 — граница не задана). Нижняя всегда
      ## «больше нуля»: ноль и отрицательное вырождают расчёт в ядре.
    hint*: string

  ConfigSource* = enum
    csNone, csDefault, csFile, csEnv, csArgv
      ## Порядок — от слабейшего источника к сильнейшему: приоритет #258
      ## выражен самим типом, а не порядком проверок в коде.

  ConfigValue* = object
    key*: string
    value*: string
    source*: ConfigSource

  Config* = object
    path*: string
    exists*: bool
    raw*: JsonNode
      ## Содержимое файла «как есть». Незнакомые ключи сохраняются: файл
      ## мог быть записан более новой сборкой CLI, и терять их нельзя
      ## (совместимость вперёд, §59).
    entries*: seq[ConfigValue]
      ## Действующие значения БЕЗ учёта argv: argv применяется в командах,
      ## которые знают, какие ключи были у текущего запуска.
    warnings*: seq[string]
      ## Проблемы чтения и некорректные значения. Печатаются в stderr
      ## (`cli/main.nim`), поэтому не портят `--json` в stdout.

const
  ConfigKeys* = [
    ConfigKey(name: "backend", env: ConfigEnvPrefix & "BACKEND",
      kind: kkBackend, fallback: "miniaudio",
      hint: "аудио-бэкенд живого режима (#92): miniaudio собран в CLI статически"),
    ConfigKey(name: "device", env: ConfigEnvPrefix & "DEVICE", kind: kkText,
      hint: "устройство по имени; пусто — устройство по умолчанию (#92)"),
    ConfigKey(name: "sampleRate", env: ConfigEnvPrefix & "SAMPLE_RATE",
      kind: kkInt, fallback: "48000", maxValue: 1_000_000,
      hint: "частота дискретизации проекта, Гц (умолчание как у initTransport)"),
    ConfigKey(name: "blockSize", env: ConfigEnvPrefix & "BLOCK_SIZE",
      kind: kkInt, maxValue: MaxBlockSize,
      hint: "размер блока, кадров (1 … " & $MaxBlockSize &
            "); не задан — выберет backend manager (#92)"),
    ConfigKey(name: "grid", env: ConfigEnvPrefix & "GRID", kind: kkInt,
      hint: "шаг сетки в тиках для команд редактирования (#111, #114)"),
    ConfigKey(name: "pluginPaths", env: ConfigEnvPrefix & "PLUGIN_PATHS",
      kind: kkPaths,
      hint: "каталоги поиска плагинов через «" &
            (when defined(windows): ";" else: ":") & "» (#95)"),
    ConfigKey(name: "cacheDir", env: ConfigEnvPrefix & "CACHE_DIR",
      kind: kkText, hint: "каталог кэша (пики, снимки); пусто — рядом с проектом"),
    ConfigKey(name: "recordDir", env: ConfigEnvPrefix & "RECORD_DIR",
      kind: kkText, hint: "каталог записей (#94); пусто — рядом с проектом"),
    ConfigKey(name: "output", env: ConfigEnvPrefix & "OUTPUT", kind: kkChoice,
      fallback: "human", choices: @["human", "json"],
      hint: "режим вывода; глобальные --json и --human перекрывают значение"),
    ConfigKey(name: "logLevel", env: ConfigEnvPrefix & "LOG_LEVEL",
      kind: kkChoice, fallback: "warn",
      choices: @["error", "warn", "info", "debug"],
      hint: "порог логов CLI в stderr; -q и -v перекрывают значение"),
  ]

proc configPath*(): string =
  ## Путь к файлу настроек. `EUTERPIA_CONFIG` перекрывает всё остальное: это
  ## единственный способ изолировать прогон от домашнего каталога.
  let override = getEnv(ConfigPathEnv)
  if override.len > 0:
    return override
  getConfigDir() / ConfigDirName / ConfigFileName

proc findKey*(name: string): int =
  ## Индекс ключа в таблице или -1.
  for i in 0 ..< ConfigKeys.len:
    if ConfigKeys[i].name == name:
      return i
  -1

proc keyNames*(): seq[string] =
  for key in ConfigKeys:
    result.add key.name

proc knownBackends*(): seq[string] =
  ## Имена аудио-бэкендов, о которых CLI знает НА ЭТОЙ машине: miniaudio
  ## собран в CLI статически (доступен всегда), portaudio подключается
  ## динамически — обещать его можно только при видимой библиотеке (#52).
  result = @["miniaudio"]
  if dynlibProbe(PortAudioLibs).found:
    result.add "portaudio"

proc validate*(
  key: ConfigKey;
  value: string
): tuple[ok: bool; message: string; canonical: string] =
  ## Проверяет значение и возвращает канонический вид.
  ##
  ## Проверка ОДНА на все пути: `config set`, чтение файла и переменные
  ## окружения. Иначе значение, которое `set` не принял бы, могло бы попасть
  ## в работу через файл, и `config set` перестал бы быть гарантией.
  case key.kind
  of kkText:
    (true, "", value.strip())
  of kkInt:
    var number: int
    try:
      number = parseInt(value.strip())
    except ValueError:
      return (false, key.name & ": ожидается целое, получено «" & value & "»", "")
    if number <= 0:
      return (false, key.name & ": ожидается значение больше нуля, получено «" &
              value & "»", "")
    if key.maxValue > 0 and number > key.maxValue:
      return (false, key.name & ": максимум " & $key.maxValue &
              ", получено «" & value & "»", "")
    (true, "", $number)
  of kkPaths:
    var parts: seq[string] = @[]
    for part in value.split(PathSep):
      let trimmed = part.strip()
      if trimmed.len > 0:
        parts.add trimmed
    if parts.len == 0:
      return (false, key.name & ": ожидается непустой список каталогов", "")
    (true, "", parts.join($PathSep))
  of kkChoice:
    if value notin key.choices:
      return (false, key.name & ": ожидается одно из " & key.choices.join(", ") &
              ", получено «" & value & "»", "")
    (true, "", value)
  of kkBackend:
    let known = knownBackends()
    if value notin known:
      return (false, key.name & ": неизвестный бэкенд «" & value &
              "»; доступны: " & known.join(", "), "")
    (true, "", value)

proc rawText*(cfg: Config; key: ConfigKey):
    tuple[present, badType: bool; text: string] =
  ## Значение ключа из файла «как есть». Пустая строка — тоже значение
  ## (`device: ""` означает «устройство по умолчанию»), поэтому отдельно
  ## возвращается признак наличия ключа. `badType` — ключ есть, но тип не
  ## поддерживается (объект, null): такое значение нельзя истолковать.
  if cfg.raw == nil or cfg.raw.kind != JObject or not cfg.raw.hasKey(key.name):
    return (false, false, "")
  let node = cfg.raw[key.name]
  case node.kind
  of JString: (true, false, node.getStr)
  of JInt: (true, false, $node.getInt)
  of JFloat: (true, false, $node.getFloat)
  of JBool: (true, false, $node.getBool)
  of JArray:
    var parts: seq[string] = @[]
    for item in node:
      if item.kind == JString:
        parts.add item.getStr
    (true, false, parts.join($PathSep))
  else: (true, true, "")

proc loadConfig*(): Config =
  ## Читает файл и окружение ОДИН раз при старте CLI (control-path).
  ##
  ## Некорректные значения не игнорируются молча: причина уходит в
  ## `warnings`, а значение берётся из источника ниже по приоритету — неверный
  ## ключ в конфиге не имеет права ломать команду (§21).
  result.path = configPath()
  result.raw = newJObject()

  if fileExists(result.path):
    result.exists = true
    var text = ""
    try:
      text = readFile(result.path)
    except CatchableError as e:
      result.warnings.add("не удалось прочитать " & result.path & ": " & e.msg)
    if text.len > 0:
      var parsed: JsonNode = nil
      try:
        parsed = parseJson(text)
      except CatchableError as e:
        result.warnings.add("не разобран JSON (" & result.path & "): " & e.msg)
      if parsed != nil and parsed.kind == JObject:
        result.raw = parsed
      elif parsed != nil:
        result.warnings.add("в корне " & result.path &
                            " ожидается объект; файл проигнорирован")

  for key in ConfigKeys:
    var item = ConfigValue(key: key.name, value: key.fallback,
      source: (if key.fallback.len > 0: csDefault else: csNone))

    # 3. файл (сильнее умолчания)
    let fromFile = rawText(result, key)
    if fromFile.badType:
      result.warnings.add("ключ " & key.name &
        ": ожидается строка, число или список; значение проигнорировано")
    elif fromFile.present:
      let checked = validate(key, fromFile.text)
      if checked.ok:
        item.value = checked.canonical
        item.source = csFile
      else:
        result.warnings.add(result.path & ": " & checked.message &
                            "; используется источник ниже")

    # 2. окружение (сильнее файла)
    let fromEnv = getEnv(key.env)
    if fromEnv.len > 0:
      let checked = validate(key, fromEnv)
      if checked.ok:
        item.value = checked.canonical
        item.source = csEnv
      else:
        result.warnings.add(key.env & ": " & checked.message &
                            "; используется источник ниже")

    result.entries.add item

proc entry*(cfg: Config; key: string): ConfigValue =
  ## Действующее значение ключа без учёта argv. Неизвестный ключ даёт пустое
  ## значение с источником `none` — вызывающий сам решает, ошибка это или нет.
  for item in cfg.entries:
    if item.key == key:
      return item
  ConfigValue(key: key, value: "", source: csNone)

proc withArgv*(cfg: Config; overrides: seq[ConfigValue]): seq[ConfigValue] =
  ## Значения с учётом ключей текущего запуска: argv сильнее env и файла
  ## (§258). Порядок ключей сохраняется — он же задаёт порядок в `config list`.
  result = cfg.entries
  for override in overrides:
    for i in 0 ..< result.len:
      if result[i].key == override.key:
        result[i] = override

proc sourceName*(source: ConfigSource): string =
  ## Стабильные имена источников для агента (`argv` | `env` | `file` |
  ## `default` | `none`).
  case source
  of csNone: "none"
  of csDefault: "default"
  of csFile: "file"
  of csEnv: "env"
  of csArgv: "argv"

proc findValue*(entries: seq[ConfigValue]; key: string): ConfigValue =
  ## Значение известного ключа из уже собранного списка (например, с учётом
  ## argv текущего запуска). Неизвестный ключ даёт пустое значение `none`.
  for item in entries:
    if item.key == key:
      return item
  ConfigValue(key: key, value: "", source: csNone)

proc valueJson*(entries: seq[ConfigValue]): JsonNode =
  ## Машинный вид списка значений. Незнакомые ключи файла сюда не попадают:
  ## это значения ИЗВЕСТНЫХ ключей, а не содержимое файла.
  result = newJArray()
  for item in entries:
    result.add %*{
      "key": item.key,
      "value": item.value,
      "source": sourceName(item.source),
    }

proc setValue*(cfg: var Config; key: ConfigKey; canonical: string) =
  ## Кладёт значение в JSON тем типом, который ждёт читатель: числа — числами,
  ## список — массивом (иначе фильтры по конфигу вроде `jq .sampleRate`
  ## ломались бы на строке «44100»).
  case key.kind
  of kkInt:
    cfg.raw[key.name] = %parseInt(canonical)
  of kkPaths:
    var arr = newJArray()
    for part in canonical.split(PathSep):
      if part.len > 0:
        arr.add %part
    cfg.raw[key.name] = arr
  else:
    cfg.raw[key.name] = %canonical

proc unsetValue*(cfg: var Config; key: string): bool =
  ## Убирает ключ из файла. false — ключа там не было (это не ошибка:
  ## `unset` идемпотентен).
  if cfg.raw == nil or not cfg.raw.hasKey(key):
    return false
  cfg.raw.delete(key)
  true

proc saveConfig*(cfg: var Config): tuple[ok: bool; message: string] =
  ## Пишет файл настроек АТОМАРНО (tmp + rename): обрыв процесса не оставит
  ## полуконфиг, из которого CLI стартовал бы с мусором.
  cfg.raw["version"] = %ConfigSchema
  let dir = parentDir(cfg.path)
  try:
    if dir.len > 0 and not dirExists(dir):
      createDir(dir)
  except CatchableError as e:
    return (false, "не удалось создать каталог " & dir & ": " & e.msg)

  let tmp = cfg.path & ".tmp-" & $getCurrentProcessId()
  try:
    writeFile(tmp, pretty(cfg.raw) & "\n")
    moveFile(tmp, cfg.path)
  except CatchableError as e:
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return (false, "не удалось записать " & cfg.path & ": " & e.msg)
  cfg.exists = true
  (true, "")

proc logLevelFromName*(value: string): LogLevel =
  ## Порог логов из строки конфига. Значение уже проверено `validate`;
  ## ветка `else` — страховка от рассинхрона таблицы ключей и этого разбора.
  case value
  of "error": llError
  of "warn": llWarn
  of "info": llInfo
  of "debug": llDebug
  else: llWarn

proc logLevelName*(level: LogLevel): string =
  ## Обратное преобразование: печатается в `config get logLevel`, когда
  ## значение пришло из argv (`-v`/`-q`).
  case level
  of llError: "error"
  of llWarn: "warn"
  of llInfo: "info"
  of llDebug: "debug"
