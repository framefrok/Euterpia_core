# libs/script.nim
#
# Сценарий как файл (issue #333, линия v0.3.7): последовательность команд
# control-слоя, сохранённая в данные, а не в историю Bash.
#
# Что здесь и чего здесь НЕ должно быть:
#   ЗДЕСЬ — форма сценария (версия, описание, базовый документ, переменные,
#   команды), подстановка переменных, план и применение через control-слой,
#   сводка «что изменится» и эталон рендера (#335).
#   НЕ ЗДЕСЬ — разбор argv CLI, печать, коды возврата и выбор файла проекта:
#   это дело клиента (§20). Ядро по-прежнему ничего не знает о `libs`.
#
# Почему команды — именно команды control-слоя (`ControlCommand`), а не строки
# CLI:
#   * команда уже сериализуется в JSON с версией API (`commands.toJson`),
#     поэтому сценарий переносим между версиями и между клиентами;
#   * транзакция (`Document.applyTransaction`) атомарна: отказ не оставляет
#     половины изменений (критерий #334);
#   * откат строит ядро (`planTransaction`) — сценарий не изобретает свою
#     обратную сторону и потому отменяется так же, как обычная правка (#331);
#   * Editor и CLI исполняют один и тот же код: сценарий из реестра окна и
#     сценарий из файла — это один `Script` и один `applyScript` (#148).
#
# Детерминизм (критерий #333): сценарий не выдумывает время. Отметку
# изменения документа задаёт вызывающий (часы внедряются в `Document`,
# `core/control/document`), а CLI для сценариев передаёт часы, возвращающие
# отметку из самого сценария или прежнюю отметку проекта. Поэтому один и тот
# же сценарий на одном и том же проекте даёт побайтово тот же документ —
# иначе «воспроизводимость» осталась бы словом.
#
# Версия формата (§58/§59): сценарий новой версии отвергается понятным
# кадром ошибки («обновите euterpia»), а не читается как мусор.

import std/[algorithm, json, os, sha1, strutils, tables]

import project
import control/commands
import control/document
import control/error_frame

const
  ScriptFormatName* = "euterpia.script"
    ## Имя формата внутри JSON: файл узнаётся по содержимому, а не по
    ## расширению (§19/§58).
  ScriptFormatVersion* = 1
    ## Версия формы сценария. Поднимается только при несовместимом изменении
    ## полей; сценарий новее этой сборки отвергается с подсказкой.
  ScriptSuffix* = ".eus"
    ## Расширение файла сценария. Намеренно не совпадает ни с проектом
    ## (`.eproj`/`.eut`), ни с историей (`.history`): «какой аргумент — что»
    ## решается одним списком, а не догадкой.
  BaselineFormatName* = "euterpia.script-baseline"
  BaselineFormatVersion* = 1
    ## Эталон рендера (#335): метрики и контрольные суммы, а не WAV на
    ## сотни мегабайт. Формат версионируется по тому же правилу.

  MetricTolerance* = 1e-6
    ## Допуск сравнения пика и RMS. Рендер офлайн-детерминирован, поэтому
    ## допуск нужен только на округление при записи JSON, а не «на глаз».

type
  Script* = object
    ## Разобранный сценарий. `commands` — уже команды control-слоя: после
    ## подстановки переменных и разбора JSON, но ДО применения к документу.
    version*: int
    description*: string
    stamp*: string
      ## Отметка изменения документа, которую сценарий назначает сам.
      ## Пусто — документ сохраняет прежнюю отметку проекта. Системные часы
      ## здесь не читаются: иначе повтор дал бы другой файл (критерий #333).
    project*: string
      ## Базовый документ, записанный в сценарии (метаданные, не содержимое):
      ## CLI берёт его как проект по умолчанию, если `--file` не задан.
      ## Копии проекта внутри сценария нет — проект остаётся источником правды.
    variables*: Table[string, JsonNode]
      ## Переменные как значения JSON, а не строки: `"value": "${freq}"`
      ## подставляет число, а не текст «220» — иначе числовое поле команды
      ## нельзя было бы сделать переменным.
    commands*: seq[ControlCommand]

  ScriptRun* = object
    ## Результат плана или применения: кадр, обратные команды и сводка.
    frame*: ErrorFrame
    plan*: TransactionPlan
      ## `redo`/`undo` построены ядром — история и отчёт берут их отсюда.
    changed*: bool
    before*, after*: JsonNode
      ## Снимки документа «до» и «после». Нужны для «что изменится», а не
      ## для хранения: наружу отдаётся сводка (`summary`).
    summary*: JsonNode

  Baseline* = object
    ## Эталон рендера по сценарию (#335).
    scenario*: string
    scenarioSha1*: string
      ## Контрольная сумма ТЕКСТА сценария: правка сценария обязана требовать
      ## явного обновления эталона, а не проходить молча.
    output*: string
    frames*: int
    sampleRate*: int
    bits*: int
    peak*, rms*: float
    silent*: bool
    fileSha1*: string
      ## SHA-1 байтов WAV: побайтовый детерминизм файла.
    samplesSha1*: string
      ## SHA-1 декодированных сэмплов: сравнивается при `--samples`.
    measured*: bool
      ## Метрики и сэмплы измерены (файл читался). `false` — эталон, в
      ## котором сохранены только размеры: сравнение честно скажет, что
      ## сверять нечего, а не «всё совпало».

  LossItem* = object
    ## Что текущий проект содержит, а сценарий выразить не может (#416).
    ## Сборка «с нуля» эти сущности заменит, поэтому о потере нужно сказать
    ## ДО записи, а не после.
    kind*: string
      ## `resources` | `pluginStates` | `automationLanes` — стабильные имена
      ## для `--json`.
    count*: int
    reason*: string
      ## Почему сценарий это не выражает. Текст для человека; вид — для
      ## машины.

# =============================================================================
# Переменные сценария
# =============================================================================

proc scalarText*(node: JsonNode): string =
  ## Значение переменной текстом. Объекты и массивы переменными не бывают:
  ## подстановка `"${x}"` в строку из структуры дала бы JSON внутри строки,
  ## то есть скрытую вторую форму данных.
  case node.kind
  of JString: node.getStr
  of JInt: $node.getInt
  of JFloat: $node.getFloat
  of JBool: $node.getBool
  of JNull: ""
  else: ""

proc variableValue*(text: string): JsonNode =
  ## Значение `--var имя=значение`: JSON-скаляр, если текст им является
  ## (`220`, `true`), иначе строка. Так число остаётся числом, а «220» в
  ## текстовом поле — текстом.
  try:
    let parsed = parseJson(text)
    if parsed.kind in {JString, JInt, JFloat, JBool, JNull}:
      return parsed
  except JsonParsingError:
    discard
  %text

proc expandString(text: string; vars: Table[string, JsonNode];
                  where: string; problem: var string): string =
  ## Подстановка `${имя}` в строку. Незакрытая или неизвестная подстановка —
  ## ошибка с адресом места (`commands[2].nodeType`), а не пустая строка:
  ## молча потерянная переменная превратила бы сценарий в другой сценарий.
  result = ""
  var i = 0
  while i < text.len:
    let start = text.find("${", i)
    if start < 0:
      result.add text[i .. ^1]
      break
    result.add text[i ..< start]
    let finish = text.find('}', start + 2)
    if finish < 0:
      problem = where & ": незакрытая подстановка «${»"
      return
    let name = text[start + 2 ..< finish]
    if name.len == 0:
      problem = where & ": пустое имя подстановки"
      return
    if not vars.hasKey(name):
      problem = where & ": нет значения переменной «" & name & "»"
      return
    result.add scalarText(vars[name])
    i = finish + 1

proc substitute(value: JsonNode; vars: Table[string, JsonNode];
                where: string; problem: var string): JsonNode =
  ## Рекурсивная подстановка по всем строкам значения. Ключи объектов не
  ## подставляются: имя поля — часть контракта команды, а не шаблон.
  ##
  ## Строка, состоящая РОВНО из `"${имя}"`, заменяется значением переменной
  ## вместе с типом (число остаётся числом); в остальных случаях имя
  ## подставляется текстом.
  case value.kind
  of JString:
    let text = value.getStr
    if text.len > 3 and text.startsWith("${") and text.endsWith("}"):
      let name = text[2 ..< text.len - 1]
      if name.len > 0 and not name.contains("${"):
        if not vars.hasKey(name):
          problem = where & ": нет значения переменной «" & name & "»"
          return
        return vars[name].copy
    result = %expandString(text, vars, where, problem)
  of JObject:
    result = newJObject()
    for key, item in value:
      let nested = substitute(item, vars, where & "." & key, problem)
      if problem.len > 0:
        return
      result[key] = nested
  of JArray:
    result = newJArray()
    for index, item in value:
      let nested = substitute(item, vars, where & "[" & $index & "]", problem)
      if problem.len > 0:
        return
      result.add nested
  else:
    result = value

# =============================================================================
# Разбор и запись
# =============================================================================

proc intField(node: JsonNode; key: string; fallback: int): int =
  if node.hasKey(key) and node[key].kind == JInt:
    node[key].getInt
  else:
    fallback

proc stringField(node: JsonNode; key: string): string =
  if node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else:
    ""

proc collectVariables(node: JsonNode; vars: var Table[string, JsonNode];
                      problem: var string): bool =
  ## Переменные сценария: только плоский объект скаляров. Значения приводятся
  ## к тексту, потому что подставляются в строки команд.
  if node.kind != JObject:
    problem = "variables: ожидается объект «имя: значение»"
    return false
  for name, value in node:
    if value.kind in {JObject, JArray}:
      problem = "variables." & name &
        ": переменная должна быть скаляром (строка, число, флаг)"
      return false
    vars[name] = value.copy
  true


proc parseScript*(text: string; script: var Script;
                  overrides: openArray[(string, string)] = @[]): ErrorFrame =
  ## Разобрать сценарий. `overrides` (`--var имя=значение`) сильнее значений
  ## из файла: так один сценарий переиспользуется без правки.
  ##
  ## Ошибки — кадром: битый JSON, чужой формат, будущая версия, неизвестная
  ## команда и неизвестная переменная названы по отдельности.
  var root: JsonNode
  try:
    root = parseJson(text)
  except JsonParsingError as e:
    return errFrame(ecInvalidArgument, "сценарий не разобран: " & e.msg,
                    "ожидается JSON-файл сценария (*" & ScriptSuffix & ")")
  if root.kind != JObject:
    return errFrame(ecInvalidArgument, "сценарий должен быть JSON-объектом",
                    "форма: format, version, commands")
  let format = stringField(root, "format")
  if format != ScriptFormatName:
    return errFrame(ecInvalidArgument,
                    "это не сценарий: format = «" & format & "»",
                    "ожидается format = " & ScriptFormatName)
  let version = intField(root, "version", 0)
  if version <= 0:
    return errFrame(ecInvalidArgument, "сценарий без версии формата",
                    "поле version обязательно: версии не смешиваются (§58)")
  if version > ScriptFormatVersion:
    return errFrame(ecInvalidArgument,
                    "сценарий версии " & $version & " новее этой сборки (" &
                      $ScriptFormatVersion & ")",
                    "обновите euterpia: старый формат читается, новый — нет")
  if not root.hasKey("commands") or root["commands"].kind != JArray:
    return errFrame(ecInvalidArgument, "в сценарии нет массива commands",
                    "сценарий без команд ничего не делает")

  script = Script(version: version,
                  description: stringField(root, "description"),
                  stamp: stringField(root, "stamp"),
                  project: stringField(root, "project"))
  if root.hasKey("variables"):
    var problem = ""
    if not collectVariables(root["variables"], script.variables, problem):
      return errFrame(ecInvalidArgument, "сценарий: " & problem,
                      "переменные — плоский объект скаляров")
  for item in overrides:
    script.variables[item[0]] = variableValue(item[1])

  if script.description.len > 0:
    var problem = ""
    script.description = expandString(script.description, script.variables,
                                      "description", problem)
    if problem.len > 0:
      return errFrame(ecInvalidArgument, "сценарий: " & problem)
  if script.stamp.len > 0 and script.stamp.contains("${"):
    var problem = ""
    script.stamp = expandString(script.stamp, script.variables,
                                "stamp", problem)
    if problem.len > 0:
      return errFrame(ecInvalidArgument, "сценарий: " & problem)
  if script.project.len > 0 and script.project.contains("${"):
    var problem = ""
    script.project = expandString(script.project, script.variables,
                                  "project", problem)
    if problem.len > 0:
      return errFrame(ecInvalidArgument, "сценарий: " & problem)

  var index = 0
  for item in root["commands"].items:
    var problem = ""
    let expanded = substitute(item, script.variables,
                              "commands[" & $index & "]", problem)
    if problem.len > 0:
      return errFrame(ecInvalidArgument, "сценарий: " & problem,
                      "объявите переменную в variables или задайте " &
                        "--var имя=значение")
    var cmd: ControlCommand
    var parsed = false
    try:
      parsed = expanded.fromJson(cmd)
    except CatchableError:
      parsed = false
    if not parsed:
      let kind = stringField(expanded, "kind")
      return errFrame(ecUnsupportedCommand,
                      "команда #" & $index & " не разобрана" &
                        (if kind.len > 0: ": «" & kind & "»" else: ""),
                      "команды — имена control-слоя (`node.create`, " &
                        "`param.set`, …); форму показывает `help --json`")
    if not cmd.kind.isImplemented:
      return errFrame(ecUnsupportedCommand,
                      "команда #" & $index & " («" & commandName(cmd.kind) &
                        "») объявлена, но не реализована",
                      "уберите её из сценария или обновите euterpia")
    script.commands.add cmd
    inc index

  if script.commands.len == 0:
    return errFrame(ecInvalidArgument, "сценарий без команд",
                    "пустой сценарий ничего не делает")
  okFrame()


proc loadScript*(path: string; script: var Script;
                 overrides: openArray[(string, string)] = @[]): ErrorFrame =
  ## Прочитать сценарий с диска. Нет файла/нет прав — среда (код 2),
  ## содержимое не то — данные (код 1).
  if not fileExists(path):
    return errFrame(ecEnvironment, "нет такого сценария: " & path,
                    "сценарий создаётся командой `script record` или руками")
  var text: string
  try:
    text = readFile(path)
  except CatchableError as e:
    return errFrame(ecEnvironment, "не удалось прочитать сценарий: " & e.msg,
                    "проверьте права: " & path)
  parseScript(text, script, overrides)

proc scriptJson*(script: Script; withCommands = true): JsonNode =
  ## Машинное описание сценария. Порядок полей фиксирован, переменные
  ## отсортированы — повторный вывод байт-в-байт тот же (`--json`, #88).
  result = newJObject()
  result["format"] = %ScriptFormatName
  result["version"] = %script.version
  if script.description.len > 0:
    result["description"] = %script.description
  if script.stamp.len > 0:
    result["stamp"] = %script.stamp
  if script.project.len > 0:
    result["project"] = %script.project
  if script.variables.len > 0:
    var variables = newJObject()
    var names: seq[string] = @[]
    for name in script.variables.keys:
      names.add name
    names.sort()
    for name in names:
      variables[name] = script.variables[name]
    result["variables"] = variables
  var commands = newJArray()
  if withCommands:
    for cmd in script.commands:
      commands.add cmd.toJson
  else:
    for cmd in script.commands:
      commands.add %*{"kind": commandName(cmd.kind)}
  result["commands"] = commands
  result["commandCount"] = %script.commands.len

proc encodeScript*(script: Script): string =
  ## Каноническая запись сценария: тот же JSON, что читается.
  $scriptJson(script)

proc saveScript*(path: string; script: Script): ErrorFrame =
  ## Записать сценарий атомарно (временный файл + переименование): оборванная
  ## запись не оставляет половины сценария.
  let text = encodeScript(script) & "\n"
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  try:
    writeFile(tmp, text)
  except CatchableError as e:
    return errFrame(ecEnvironment, "не удалось записать сценарий: " & e.msg,
                    "проверьте каталог и права: " & path)
  try:
    moveFile(tmp, path)
  except CatchableError as e:
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return errFrame(ecEnvironment, "не удалось заменить сценарий: " & e.msg,
                    "проверьте каталог и права: " & path)
  okFrame()

proc sha1OfText*(text: string): string =
  ## Контрольная сумма текста сценария: попадает в эталон рендера, чтобы
  ## правка сценария требовала явного `--update-baseline`.
  $secureHash(text)

proc sha1OfFile*(path: string): string =
  ## Контрольная сумма файла (WAV эталона). Ошибка чтения — пустая строка:
  ## вызывающий сам решает, ошибка это или «сверять нечего».
  try:
    $secureHash(readFile(path))
  except CatchableError:
    ""


# =============================================================================
# Сводка «что изменится»
# =============================================================================

proc itemCount(node: JsonNode; key: string): int =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JArray:
    node[key].len
  else:
    0

proc clipsCount(root: JsonNode): int =
  ## Клипов нет одним массивом: они лежат внутри дорожек. Считаем общим
  ## обходом, чтобы сводка не зависела от формы секции.
  if root.kind != JObject or not root.hasKey("sequencer"):
    return 0
  let sequencer = root["sequencer"]
  if sequencer.kind != JObject or not sequencer.hasKey("tracks"):
    return 0
  for track in sequencer["tracks"].items:
    result += itemCount(track, "clips")

proc addCounter(summary: JsonNode; name: string; before, after: int) =
  summary[name] = %*{"before": before, "after": after,
                     "delta": after - before}

proc diffSummary*(before, after: JsonNode): JsonNode =
  ## Сводка изменения проекта: счётчики сущностей и факт изменения документа.
  ## Именно её печатают `script plan` и `script run`, поэтому «что изменится»
  ## не приходится выяснять сравнением файлов руками.
  result = newJObject()
  let graphBefore =
    (if before.kind == JObject and before.hasKey("graph"): before["graph"]
     else: newJObject())
  let graphAfter =
    (if after.kind == JObject and after.hasKey("graph"): after["graph"]
     else: newJObject())
  addCounter(result, "nodes", graphBefore.itemCount("nodes"),
             graphAfter.itemCount("nodes"))
  addCounter(result, "connections", graphBefore.itemCount("connections"),
             graphAfter.itemCount("connections"))
  let seqBefore =
    (if before.kind == JObject and before.hasKey("sequencer"):
       before["sequencer"]
     else: newJObject())
  let seqAfter =
    (if after.kind == JObject and after.hasKey("sequencer"): after["sequencer"]
     else: newJObject())
  addCounter(result, "tracks", seqBefore.itemCount("tracks"),
             seqAfter.itemCount("tracks"))
  addCounter(result, "clips", clipsCount(before), clipsCount(after))
  addCounter(result, "automationLanes", seqBefore.itemCount("automationLanes"),
             seqAfter.itemCount("automationLanes"))
  addCounter(result, "pluginStates", itemCount(before, "pluginStates"),
             itemCount(after, "pluginStates"))
  addCounter(result, "resources", itemCount(before, "resources"),
             itemCount(after, "resources"))
  result["changed"] = %($before != $after)

# =============================================================================
# План и применение
# =============================================================================

proc previewScript*(doc: Document; script: Script;
                    description: string = ""): ScriptRun =
  ## План БЕЗ побочных эффектов: документ копируется, команды прогоняются на
  ## копии. Критерий #333 «plan не меняет ни файла, ни документа» держится
  ## типом: у этой процедуры нет `var Document`.
  result.before = toJson(doc.proj)
  result.plan = doc.planTransaction(script.commands, description)
  if not result.plan.frame.isOk():
    result.frame = result.plan.frame
    result.after = result.before
    result.summary = diffSummary(result.before, result.after)
    return
  var probe = doc
  let applied = probe.applyTransaction(script.commands, description)
  if not applied.frame.isOk():
    result.frame = applied.frame
    result.after = result.before
    result.summary = diffSummary(result.before, result.after)
    return
  result.frame = okFrame()
  result.after = toJson(probe.proj)
  result.changed = $result.before != $result.after
  result.summary = diffSummary(result.before, result.after)

proc applyScript*(doc: var Document; script: Script;
                  description: string = ""): ScriptRun =
  ## Применить сценарий ОДНОЙ транзакцией. Отказ не оставляет частичных
  ## изменений: до второй фазы документ не тронут (см. `applyTransaction`).
  result.before = toJson(doc.proj)
  result.plan = doc.applyTransaction(script.commands, description)
  result.frame = result.plan.frame
  result.after = toJson(doc.proj)
  result.changed = $result.before != $result.after
  result.summary = diffSummary(result.before, result.after)

# =============================================================================
# Сборка проекта «с нуля» (#416)
# =============================================================================
#
# Разница с `applyScript` принципиальная:
#   `run`  — правка текущего документа (дельты поверх него);
#   `build` — новый документ: содержимое отбрасывается, остаются метаданные.
# Поэтому «пересобрать проект» не может быть флагом `run`: это другая
# операция с другим ответом на вопрос «что станет с существующим файлом».

proc baseDocument*(tpl: ProjectFormat): ProjectFormat =
  ## Пустой документ с метаданными шаблона. Копируются ровно `format`,
  ## `version` и `metadata`; граф, секвенсор, ресурсы и состояния плагинов —
  ## НЕ копируются: иначе это была бы правка, а не сборка.
  ##
  ## `tpl` может быть пустым (`ProjectFormat()`): тогда формат и версия
  ## берутся текущие, а метаданные остаются пустыми — хозяин документа
  ## заполняет их умолчаниями `init` (CLI) или своими (Editor).
  result.format =
    (if tpl.format.len > 0: tpl.format else: ProjectFormatName)
  result.version =
    (if tpl.version > 0: tpl.version else: ProjectFormatVersion)
  result.metadata = tpl.metadata

proc lossReport*(current: ProjectFormat; script: Script): seq[LossItem] =
  ## Что текущий проект содержит, а сценарий выразить НЕ может. Сборка эти
  ## сущности заменит, поэтому клиент обязан спросить до записи (#416).
  ##
  ## Проверка смотрит на команды сценария, а не на список «что мы умеем
  ## сегодня»: когда `node.restoreState` и `resource.load` станут допустимыми
  ## в сценарии, отчёт сам перестанет считать их потерей.
  var coversStates = false
  for cmd in script.commands:
    if cmd.kind == ccRestoreNodeState:
      coversStates = true

  if current.resources.len > 0:
    result.add LossItem(
      kind: "resources",
      count: current.resources.len,
      reason: "импортированное аудио: команда `resource.load` объявлена, но не " &
              "реализована — сценарий не может создать ресурс")
  if current.pluginStates.len > 0 and not coversStates:
    result.add LossItem(
      kind: "pluginStates",
      count: current.pluginStates.len,
      reason: "состояния плагинов: сценарий не выражает их (команда " &
              "`node.restoreState` пока не принимается сценарием)")
  if current.sequencer.automationLanes.len > 0 and not coversStates:
    result.add LossItem(
      kind: "automationLanes",
      count: current.sequencer.automationLanes.len,
      reason: "автоматизация: в control-модели нет команды для линий — " &
              "CLI пишет их напрямую, сценарий их не создаёт")





# =============================================================================
# Эталон рендера (#335)
# =============================================================================

proc baselineJson*(baseline: Baseline): JsonNode =
  ## Машинный вид эталона. Порядок полей фиксирован: повторная запись даёт
  ## тот же файл, и эталон не «шумит» в git.
  result = newJObject()
  result["format"] = %BaselineFormatName
  result["version"] = %BaselineFormatVersion
  result["scenario"] = %baseline.scenario
  result["scenarioSha1"] = %baseline.scenarioSha1
  result["out"] = %baseline.output
  result["frames"] = %baseline.frames
  result["sampleRate"] = %baseline.sampleRate
  result["bits"] = %baseline.bits
  result["peak"] = %baseline.peak
  result["rms"] = %baseline.rms
  result["silent"] = %baseline.silent
  result["fileSha1"] = %baseline.fileSha1
  result["samplesSha1"] = %baseline.samplesSha1
  result["measured"] = %baseline.measured

proc encodeBaseline*(baseline: Baseline): string =
  ## Запись эталона с завершающим переводом строки: diff в git читаемый.
  $baselineJson(baseline) & "\n"

proc parseBaseline*(node: JsonNode; baseline: var Baseline): ErrorFrame =
  ## Разбор эталона. Чужой формат и будущая версия — отказ, а не «эталона
  ## нет»: иначе испорченный эталон молча отключил бы проверку.
  if node.kind != JObject:
    return errFrame(ecInvalidArgument, "эталон должен быть JSON-объектом",
                    "эталон создаётся `script render --update-baseline`")
  if stringField(node, "format") != BaselineFormatName:
    return errFrame(ecInvalidArgument, "это не эталон сценария",
                    "ожидается format = " & BaselineFormatName)
  let version = intField(node, "version", 0)
  if version <= 0 or version > BaselineFormatVersion:
    return errFrame(ecInvalidArgument,
                    "версия эталона " & $version & " не поддержана " &
                      "(эта сборка: " & $BaselineFormatVersion & ")",
                    "обновите euterpia или пересоздайте эталон")
  baseline = Baseline(
    scenario: stringField(node, "scenario"),
    scenarioSha1: stringField(node, "scenarioSha1"),
    output: stringField(node, "out"),
    frames: intField(node, "frames", 0),
    sampleRate: intField(node, "sampleRate", 0),
    bits: intField(node, "bits", 0),
    measured: (if node.hasKey("measured"): node["measured"].getBool else: false))
  if node.hasKey("peak") and node["peak"].kind in {JFloat, JInt}:
    baseline.peak = node["peak"].getFloat
  if node.hasKey("rms") and node["rms"].kind in {JFloat, JInt}:
    baseline.rms = node["rms"].getFloat
  if node.hasKey("silent"):
    baseline.silent = node["silent"].getBool
  baseline.fileSha1 = stringField(node, "fileSha1")
  baseline.samplesSha1 = stringField(node, "samplesSha1")
  okFrame()

proc readBaseline*(path: string; baseline: var Baseline): ErrorFrame =
  ## Прочитать эталон. Нет файла — среда: сравнение запросили, а сверять
  ## нечего; эталон создаётся явной командой.
  if not fileExists(path):
    return errFrame(ecEnvironment, "нет файла эталона: " & path,
                    "создайте его явно: euterpia script render … " &
                      "--update-baseline")
  var node: JsonNode
  try:
    node = parseJson(readFile(path))
  except JsonParsingError as e:
    return errFrame(ecInvalidArgument, "эталон не разобран: " & e.msg,
                    "пересоздайте эталон: --update-baseline")
  except CatchableError as e:
    return errFrame(ecEnvironment, "не удалось прочитать эталон: " & e.msg,
                    "проверьте права: " & path)
  parseBaseline(node, baseline)

proc writeBaseline*(path: string; baseline: Baseline): ErrorFrame =
  ## Записать эталон атомарно: он лежит в репозитории, и половина файла там
  ## хуже отсутствия файла.
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  try:
    writeFile(tmp, encodeBaseline(baseline))
  except CatchableError as e:
    return errFrame(ecEnvironment, "не удалось записать эталон: " & e.msg,
                    "проверьте каталог и права: " & path)
  try:
    moveFile(tmp, path)
  except CatchableError as e:
    try:
      removeFile(tmp)
    except CatchableError:
      discard
    return errFrame(ecEnvironment, "не удалось заменить эталон: " & e.msg,
                    "проверьте каталог и права: " & path)
  okFrame()

proc compareBaseline*(expected, actual: Baseline; samples: bool): seq[string] =
  ## Различия эталона и результата. Пустой список — рендер совпал.
  ##
  ## Метрики сравниваются с `MetricTolerance`: рендер детерминирован, и
  ## допуск страхует только округление JSON, а не «примерно тот же звук».
  ##
  ## Сравнивается СОДЕРЖИМОЕ сценария (sha1), а не его путь: эталон должен
  ## работать и когда проект перенесли в другой каталог.
  if expected.scenarioSha1.len > 0 and
     expected.scenarioSha1 != actual.scenarioSha1:
    result.add "сценарий изменился: sha1 " & expected.scenarioSha1 & " → " &
      actual.scenarioSha1 & " (обновите эталон явно: --update-baseline)"
  if expected.frames != actual.frames:
    result.add "кадров: " & $expected.frames & " → " & $actual.frames
  if expected.sampleRate != actual.sampleRate:
    result.add "частота: " & $expected.sampleRate & " → " & $actual.sampleRate
  if expected.bits != actual.bits:
    result.add "бит: " & $expected.bits & " → " & $actual.bits
  if expected.measured and actual.measured:
    if abs(expected.peak - actual.peak) > MetricTolerance:
      result.add "пик: " & $expected.peak & " → " & $actual.peak
    if abs(expected.rms - actual.rms) > MetricTolerance:
      result.add "RMS: " & $expected.rms & " → " & $actual.rms
    if expected.silent != actual.silent:
      result.add "тишина: " & $expected.silent & " → " & $actual.silent
    if samples:
      if expected.samplesSha1.len == 0:
        result.add "в эталоне нет суммы сэмплов: пересоздайте его с --samples"
      elif expected.samplesSha1 != actual.samplesSha1:
        result.add "сэмплы: sha1 " & expected.samplesSha1 & " → " &
          actual.samplesSha1
  elif samples:
    result.add "эталон без метрик: сверка сэмплов невозможна — " &
      "пересоздайте эталон с --update-baseline"
  elif not expected.measured:
    result.add "эталон без метрик: сверяются только размеры файла — " &
      "пересоздайте эталон с --update-baseline"

