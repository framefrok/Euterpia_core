# cli/cmd_config.nim
#
# `euterpia config list|get|set|unset|path` (issue #258).
#
# Что здесь важно:
# - приоритет argv > env > файл > умолчание задан типом `ConfigSource`
#   (`cli/config.nim`), а не порядком проверок в командах: команда только
#   спрашивает «какое значение действует и почему»;
# - `config set` проверяет значение ТЕМ ЖЕ кодом, что и чтение файла, поэтому
#   «set принял» гарантирует «следующий старт прочитает»;
# - запись атомарная (tmp + rename), `--dry-run` не касается диска;
# - битый файл не мешает: `config set` читает его «как есть» и валидирует
#   только известные ключи, поэтому исправление конфига возможно без
#   ручного редактирования.

import std/[json, os, strutils]

import context
import config

const
  ConfigSubcommands* = @["list", "get", "set", "unset", "path"]
    ## Подкоманды `config` — кандидаты автодополнения второго уровня (#259).

proc argvOverrides*(ctx: Ctx): seq[ConfigValue] =
  ## Ключи ТЕКУЩЕГО запуска, которые перекрывают настройки: `--json`/`--human`
  ## и `-v`/`-q`. Без этого `config get output` в JSON-режиме показывал бы
  ## значение из файла и не объяснял, почему вывод другой (#258).
  if ctx.modeExplicit:
    result.add ConfigValue(key: "output",
      value: (if ctx.mode == omJson: "json" else: "human"), source: csArgv)
  if ctx.logLevelExplicit:
    result.add ConfigValue(key: "logLevel", value: logLevelName(ctx.logLevel),
                           source: csArgv)

proc entryLine(item: ConfigValue): string =
  ## `ключ = значение (источник)`. Пустое значение печатается словами:
  ## «device = » неотличимо от сбоя вывода.
  item.key & " = " & (if item.value.len > 0: item.value else: "(не задано)") &
    " (" & sourceName(item.source) & ")"

proc unknownKeyReport(name: string): Report =
  usageError("неизвестный ключ настроек: " & name,
             "ключи: " & keyNames().join(", "))

# =============================================================================
# config list / config get
# =============================================================================

proc runConfigList*(ctx: var Ctx; args: seq[string]): Report =
  ## `config list` и `config get [ключ]`. Полный список печатает источник
  ## каждого значения: вопрос «почему 48 кГц» закрывается одной командой.
  let cfg = ctx.config
  let entries = cfg.withArgv(argvOverrides(ctx))

  if args.len > 1:
    return usageError(
      "config get принимает не больше одного ключа, получено: " & args.join(" "),
      "ключи: " & keyNames().join(", "))

  var body = newJObject()
  body["path"] = %cfg.path
  body["exists"] = %cfg.exists
  body["schema"] = %ConfigSchema

  var lines: seq[string] = @[
    "файл настроек: " & cfg.path &
      (if cfg.exists: " (есть)" else: " (нет)"),
  ]
  if args.len == 1:
    let name = args[0]
    if findKey(name) < 0:
      return unknownKeyReport(name)
    let value = entries.findValue(name)
    body["key"] = %value.key
    body["value"] = %value.value
    body["source"] = %sourceName(value.source)
    lines.add entryLine(value)
  else:
    body["entries"] = valueJson(entries)
    for item in entries:
      lines.add entryLine(item)

  okReport(body = body, lines = lines)

proc runConfigPath*(ctx: var Ctx; args: seq[string]): Report =
  ## `config path` — где CLI ищет настройки. Нужен, чтобы понять, куда писать,
  ## не читая документацию (#258).
  discard ctx
  if args.len > 0:
    return usageError("config path не принимает аргументов, получено: " &
                      args.join(" "), "например: euterpia config path")
  let path = configPath()
  okReport(
    body = %*{"path": path, "exists": fileExists(path), "schema": ConfigSchema},
    lines = @[path & (if fileExists(path): " (файл есть)" else: " (файла нет)")])

# =============================================================================
# config set / config unset
# =============================================================================

proc saveReport(cfg: var Config): tuple[ok: bool; rep: Report] =
  ## Общий хвост изменяющих подкоманд: атомарная запись либо ошибка среды
  ## (код 2) — значение верное, а файл или каталог недоступен.
  let saved = cfg.saveConfig()
  if saved.ok:
    return (true, okReport())
  (false, errReport(exEnv, "env", saved.message,
                    "проверьте права на файл и каталог: " & cfg.path))

proc runConfigSet*(ctx: var Ctx; args: seq[string]): Report =
  ## `config set <ключ> <значение>`.
  ##
  ## Значение проверяется `config.validate` — тем же кодом, что и чтение
  ## файла и env: иначе `set` мог бы записать то, что следующий старт
  ## отбросит как некорректное, и «set прошёл» перестало бы что-то значить.
  if args.len != 2:
    return usageError(
      "config set принимает ключ и значение, получено аргументов: " & $args.len,
      "например: euterpia config set sampleRate 44100")
  let name = args[0]
  let index = findKey(name)
  if index < 0:
    return unknownKeyReport(name)
  let key = ConfigKeys[index]

  let checked = validate(key, args[1])
  if not checked.ok:
    return usageError(checked.message, "справка по ключам: euterpia help config")

  var cfg = ctx.config
  let current = cfg.entry(key.name)
  var body = %*{
    "path": cfg.path,
    "key": key.name,
    "value": checked.canonical,
    "before": current.value,
    "beforeSource": sourceName(current.source),
  }

  # Значение уже лежит в файле ровно в таком виде — файл не трогаем:
  # идемпотентный `set` не должен поднимать mtime и переписывать конфиг.
  let stored = cfg.rawText(key)
  if stored.present and not stored.badType:
    let storedChecked = validate(key, stored.text)
    if storedChecked.ok and storedChecked.canonical == checked.canonical:
      body["changed"] = %false
      return okReport(body = body,
        lines = @[key.name & " = " & checked.canonical,
                  "без изменений: " & cfg.path])

  cfg.setValue(key, checked.canonical)
  body["changed"] = %true

  var lines: seq[string] = @[
    key.name & ": " &
      (if current.value.len > 0: current.value else: "(не задано)") &
      " (" & sourceName(current.source) & ") → " & checked.canonical,
  ]
  if ctx.dryRun:
    lines.add "не записан: " & cfg.path & " (--dry-run)"
    return okReport(body = body, lines = lines)

  let saved = saveReport(cfg)
  if not saved.ok:
    return saved.rep
  lines.add "записан: " & cfg.path
  okReport(body = body, lines = lines)

proc runConfigUnset*(ctx: var Ctx; args: seq[string]): Report =
  ## `config unset <ключ>` — убрать ключ из файла. Значение при этом не
  ## исчезает: его может задавать окружение или умолчание. В выводе видно,
  ## каким оно стало, — `unset` это «вернуть приоритет», а не «забыть».
  if args.len != 1:
    return usageError(
      "config unset принимает один ключ, получено аргументов: " & $args.len,
      "например: euterpia config unset backend")
  let name = args[0]
  if findKey(name) < 0:
    return unknownKeyReport(name)

  var cfg = ctx.config
  let before = cfg.entry(name)
  let removed = cfg.unsetValue(name)
  var body = %*{
    "path": cfg.path,
    "key": name,
    "removed": removed,
    "before": before.value,
    "beforeSource": sourceName(before.source),
  }

  if not removed:
    body["value"] = %before.value
    body["source"] = %sourceName(before.source)
    return okReport(body = body,
      lines = @[name & ": в файле не задан; действует " &
                sourceName(before.source)])

  if ctx.dryRun:
    return okReport(body = body,
                    lines = @["не записан: " & cfg.path & " (--dry-run)"])

  let saved = saveReport(cfg)
  if not saved.ok:
    return saved.rep

  # Значение после удаления считает тот же код, что и при старте: второй
  # реализации приоритета источников быть не должно.
  let fresh = loadConfig()
  let after = fresh.entry(name)
  body["value"] = %after.value
  body["source"] = %sourceName(after.source)
  okReport(body = body, lines = @[
    name & ": " & (if before.value.len > 0: before.value else: "(не задано)") &
      " (" & sourceName(before.source) & ") → " &
      (if after.value.len > 0: after.value else: "(не задано)") &
      " (" & sourceName(after.source) & ")",
    "записан: " & cfg.path,
  ])

# =============================================================================
# config
# =============================================================================

proc runConfig*(ctx: var Ctx; args: seq[string]): Report =
  ## `config <list|get|set|unset|path>`. `list` и `get` без ключа — одно и то
  ## же: «покажи все значения и их источники» (#258).
  if args.len == 0:
    return usageError("config требует подкоманду",
                      "подкоманды: " & ConfigSubcommands.join(", "))
  case args[0]
  of "list": runConfigList(ctx, argsTail(args))
  of "get": runConfigList(ctx, argsTail(args))
  of "set": runConfigSet(ctx, argsTail(args))
  of "unset": runConfigUnset(ctx, argsTail(args))
  of "path": runConfigPath(ctx, argsTail(args))
  else:
    usageError("неизвестная подкоманда config: " & args[0],
               "подкоманды: " & ConfigSubcommands.join(", "))
