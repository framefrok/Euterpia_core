# cli/cmd_graph.nim
#
# Граф проекта: `node`, `connect`, `disconnect`, `param` и `graph check`
# (issue #90) — команды из примера MANIFEST §19:
#
#   euterpia node add oscillator
#   euterpia connect oscillator:out filter:in
#   euterpia param set filter cutoff 1200
#   euterpia graph check
#
# Границы (§20): формат проекта — Core (`project`), каталог типов — SDK
# (`catalog`), компиляция — Core через SDK (`graph_check`). CLI не разбирает
# JSON руками и НЕ компилирует граф сам: он переводит аргументы в вызовы и
# печатает результат. Проверка «граф соберётся» живёт в SDK, потому что
# Core не знает список нод (§54), а CLI не имеет права знать компилятор.
#
# Файл проекта: `--file <путь>` или первый позиционный аргумент с расширением
# проекта (`.eproj` основное, `.eut` историческое — `ProjectSuffixes` из
# `cmd_project`; умолчание — `project.eproj`). Правило одно для всех команд
# графа, поэтому «какой файл правится» не зависит от команды.
#
# Безопасность записи — как у `project set` (#89): чтение и проверка формата
# ДО правки, атомарная запись, `--dry-run` не касается диска.

import std/[algorithm, json, math, strutils, tables]

import project
import context
import checks
import catalog
import cmd_project
import control_bridge
import control/error_frame
import control/commands
import control/document
import control/query
import sdk/graph_check
import cli_spec

const
  GraphOptions* = @[
    opt("--file", "проект: " & projectSuffixesHint() & "; по умолчанию " &
        DefaultProjectFile, value = "проект.eproj"),
    opt("--name", "имя ноды (`node add`)", value = "строка"),
    opt("--id", "явный id ноды (`node add`); занятый id — ошибка", value = "число"),
    opt("--filter", "подстрока в имени или типе (`node list`)", value = "текст"),
    opt("--type", "только ноды этого типа (`node list`)", value = "id типа"),
    opt("--limit", "сколько нод показать (`node list`)", value = "число"),
    opt("--offset", "сколько нод пропустить (`node list`)", value = "число"),
  ]
    ## Ключи команд графа (`node`, `connect`, `disconnect`, `param`, `graph`) —
    ## разбор у них общий, значит и описание общее: три копии разъехались бы.
  GraphKeys* = keysOf(GraphOptions)

  NodeSubcommands* = @["list", "types", "add", "rm", "show"]
  ParamSubcommands* = @["list", "get", "set"]
  GraphSubcommands* = @["check"]

# =============================================================================
# Спецификации команд (#330)
# =============================================================================

const
  NodeSpec* = CommandSpec(
    name: "node",
    summary: "ноды графа: список, каталог типов, добавление, удаление, показ",
    synopsis: "node <list|types|add|rm|show> [аргументы] [--file проект.eproj]",
    subcommands: NodeSubcommands,
    options: GraphOptions,
    args: @[
      arg("нода", "id, имя или адрес `node:3.1` (`show`, `rm`)"),
      arg("тип", "полный id (`euterpia.osc`), короткий (`osc`) или имя (`Oscillator`) — `node add`"),
    ],
    example: "euterpia node add osc --name osc project.eproj",
    fields: @[
      field("path", "прочитанный проект"),
      field("nodes", "ноды: id, тип, имя, порты, параметры"),
      field("connections", "связи графа"),
      field("types", "каталог типов (`node types`): id, имя, порты, задержка, параметры"),
      field("count", "сколько типов в каталоге (`node types`)"),
      field("summary", "счётчики: ноды, связи, треки, клипы"),
      field("change", "что изменила команда: добавленная или удалённая нода"),
    ],
    notes: @[
      "тип ноды — полный id (`euterpia.osc`), короткий (`osc`) или имя (`Oscillator`)",
      "порты, задержка и умолчания параметров берутся из типа: файл получает то, что умеет нода",
      "id назначается как максимум + 1; --id задаёт явно (занятый id — ошибка)",
      "node rm удаляет и связи, автоматизацию и состояния плагинов этой ноды",
      "файл проекта: --file или аргумент с расширением проекта (.eproj; " &
        "историческое .eut принимается; по умолчанию " &
        DefaultProjectFile & ")",
      "`node types` печатает каталог: id, порты, параметры — и человеческим текстом, и в --json",
    ])

  ConnectSpec* = CommandSpec(
    name: "connect",
    summary: "соединить выход одной ноды со входом другой",
    synopsis: "connect <источник> <приёмник> [--file проект.eproj]",
    options: GraphOptions,
    args: @[
      arg("источник", "нода и порт выхода: `oscillator:out`, `node:3.1`"),
      arg("приёмник", "нода и порт входа: `filter:in`, `node:4.1/audio:0`"),
    ],
    example: "euterpia connect oscillator:out filter:in project.eproj",
    fields: @[
      field("path", "прочитанный проект"),
      field("connection", "добавленная связь: ноды, порты, вид сигнала"),
      field("change", "что изменила команда: добавленная связь"),
      field("summary", "счётчики: ноды, связи, треки, клипы"),
      field("graph", "граф после правки"),
    ],
    notes: @[
      "порт: `нода:out` | `нода:in` | `нода:audio:1` | `нода:ctrl:0` | `нода:event:0`",
      "пример MANIFEST §19: euterpia connect oscillator:out filter:in",
      "виды портов обязаны совпадать; самосоединение разрешено — компиляцию проверяет `graph check`",
    ])

  DisconnectSpec* = CommandSpec(
    name: "disconnect",
    summary: "снять связь между нодами",
    synopsis: "disconnect <источник>[:порт] <приёмник>[:порт] [--file проект.eproj]",
    options: GraphOptions,
    args: @[
      arg("источник", "нода; с портом — только указанная связь"),
      arg("приёмник", "нода; с портом — только указанная связь"),
    ],
    example: "euterpia disconnect oscillator filter project.eproj",
    fields: @[
      field("path", "прочитанный проект"),
      field("removed", "сколько связей снято"),
      field("summary", "счётчики: ноды, связи, треки, клипы"),
      field("graph", "граф после правки"),
    ],
    notes: @[
      "без портов снимаются все связи между парой нод",
      "с портами — только указанная связь",
    ])

  ParamSpec* = CommandSpec(
    name: "param",
    summary: "параметры ноды: список, чтение, запись",
    synopsis: "param <list|get|set> [аргументы] [--file проект.eproj]",
    subcommands: ParamSubcommands,
    options: GraphOptions,
    args: @[
      arg("нода", "id, имя или адрес `node:3.1`"),
      arg("параметр", "имя (`cutoff`) или числовой id"),
      arg("значение", "новое значение (`param set`)"),
    ],
    example: "euterpia param set filter cutoff 1200 project.eproj",
    fields: @[
      field("path", "прочитанный проект"),
      field("node", "id ноды, у которой читали или писали параметры"),
      field("params", "параметры ноды: имя, id, значение, диапазон, флаги"),
      field("param", "один параметр (`param get`): значение и умолчание типа"),
      field("change", "что изменил `param set`: параметр, до и после"),
      field("summary", "счётчики: ноды, связи, треки, клипы"),
    ],
    notes: @[
      "пример MANIFEST §19: euterpia param set filter cutoff 1200",
      "значение проверяется по диапазону типа: вне диапазона — отказ, а не запись",
      "параметр можно назвать именем (`freq`) или числовым id (стабильная ссылка)",
      "`param get` показывает и значение из файла, и умолчание типа",
      "дробные и отрицательные значения принимаются у дробных параметров диапазона: " &
        "флаги — битовая маска, и целочисленность проверяется по флагам типа (#292)",
    ])

  GraphSpec* = CommandSpec(
    name: "graph",
    summary: "проверка графа: типы, порты, связи и компиляция",
    synopsis: "graph check [--file проект.eproj]",
    subcommands: GraphSubcommands,
    options: GraphOptions,
    example: "euterpia graph check project.eproj",
    fields: @[
      field("path", "проверенный проект"),
      field("sections", "секции проверок: структура, связи, компиляция"),
      field("summary", "сводка ok/warn/fail — она же определяет код возврата"),
      field("nodes", "сколько нод проверено"),
      field("connections", "сколько связей проверено"),
      field("compile", "результат компиляции графа: вердикт, причина, шаги"),
    ],
    notes: @[
      "проверяет структуру (типы, порты, связи, значения параметров) и компилирует граф",
      "компиляция идёт через Core: CLI не собирает пайплайн сам (§20)",
      "провал проверки — код 1; предупреждения (пустой граф, самосоединение) код не меняют",
      "отчёт — те же секции и `summary`, что у `project validate` и `doctor` (#96)",
    ])

# =============================================================================
# Разбор аргументов
# =============================================================================

type
  ArgScan = object
    ok: bool
    rep: Report
    path: string
    positionals: seq[string]
    name: string
    id: int
    haveId: bool
    filter: string
      ## `--filter`: подстрока в имени или типе (`node list`).
    nodeType: string
      ## `--type`: только ноды этого типа (`node list`).
    limit: int
      ## `--limit`: сколько нод показать; 0 — без ограничения.
    offset: int
      ## `--offset`: сколько нод пропустить.

proc looksLikeNumber(s: string): bool =
  ## true для `-12`, `-0.15`, `+3`, `1.5` — это ЗНАЧЕНИЯ, а не ключи.
  ## Без этого `param set pan -0.15` отвергался бы как «неизвестный ключ»,
  ## хотя отрицательные значения есть у половины параметров (pan, level в dB).
  if s.len == 0:
    return false
  var i = 0
  if s[0] in {'+', '-'}:
    inc i
  var digits = 0
  var dots = 0
  while i < s.len:
    let c = s[i]
    if c in {'0'..'9'}:
      inc digits
    elif c == '.':
      inc dots
    else:
      return false
    inc i
  digits > 0 and dots <= 1

proc scanArgs(args: seq[string]; what: string): ArgScan =
  ## Разбирает ключи и позиционные аргументы. Ключей мало и они не
  ## пересекаются с именами нод, поэтому разбор остаётся читаемым без
  ## библиотеки парсинга (§81).
  result.path = DefaultProjectFile
  var haveFile = false
  var i = 0
  while i < args.len:
    let token = args[i]
    var key = token
    var value = ""
    var haveInline = false
    let eq = token.find('=')
    if token.startsWith("--") and eq > 0:
      key = token[0 ..< eq]
      value = token[eq + 1 .. ^1]
      haveInline = true

    if key in GraphKeys:
      if not haveInline:
        if i + 1 >= args.len:
          result.rep = usageError(key & " требует значение",
                                  "например: euterpia " & what & " " & key & " …")
          return
        inc i
        value = args[i]
      case key
      of "--file":
        result.path = value
        haveFile = true
      of "--name":
        result.name = value
      of "--filter":
        result.filter = value
      of "--type":
        result.nodeType = value
      of "--limit":
        if value.len == 0 or not value.allCharsInSet({'0'..'9'}):
          result.rep = usageError("--limit принимает целое число, получено: " & value,
                                  "например: euterpia node list --limit 20")
          return
        result.limit = parseInt(value)
      of "--offset":
        if value.len == 0 or not value.allCharsInSet({'0'..'9'}):
          result.rep = usageError("--offset принимает целое число, получено: " & value,
                                  "например: euterpia node list --offset 20")
          return
        result.offset = parseInt(value)
      else:
        if value.len == 0 or not value.allCharsInSet({'0'..'9'}):
          result.rep = usageError("--id принимает целое число, получено: " & value,
                                  "id ноды — целое, начиная с 1")
          return
        result.id = parseInt(value)
        result.haveId = true
    elif token.startsWith("-") and token.len > 1 and not looksLikeNumber(token):
      result.rep = usageError("неизвестный ключ: " & token,
                              "ключи графа: " & GraphKeys.join(", "))
      return
    else:
      result.positionals.add token
    inc i

  # Путь к проекту можно указать и позиционным аргументом: `node list demo.eproj`
  # и `node add svf other.eut` читаются так же, как `project show demo.eproj`.
  # Правило детерминированное: файлом считается позиционный аргумент с
  # расширением проекта (`isProjectPath` — один список на все команды); два
  # таких аргумента или пара с `--file` — ошибка, потому что «какой из них
  # правим» угадывать запрещено (§82).
  var filePositions: seq[int] = @[]
  for i in 0 ..< result.positionals.len:
    if isProjectPath(result.positionals[i]):
      filePositions.add i
  if filePositions.len > 1:
    var names: seq[string] = @[]
    for i in filePositions:
      names.add result.positionals[i]
    result.rep = usageError("указано несколько файлов проекта: " & names.join(", "),
                            "оставьте один файл или задайте --file")
    return
  if filePositions.len == 1:
    if haveFile:
      result.rep = usageError("файл проекта указан дважды: --file и " &
                              result.positionals[filePositions[0]],
                              "оставьте что-то одно")
      return
    result.path = result.positionals[filePositions[0]]
    result.positionals.delete(filePositions[0])
  result.ok = true

# =============================================================================
# Ссылки: нода и порт
# =============================================================================

type
  PortRef = object
    nodeId: int
      ## Постоянный `id` ноды, а не индекс хранения: id не меняется от правок
      ## графа, поэтому адрес в отчёте остаётся годным (#143).
    kind: PortKind
    index: int

proc resolveNode(doc: Document; refText: string):
    tuple[ok: bool; node: NodeInfo; rep: Report] =
  ## Нода по адресу (`node:3.2`), id, имени или короткому имени типа.
  ##
  ## Разбор идёт через Query API (#141, #336): адрес, id и имя понимает ОДИН
  ## код ядра, поэтому CLI и Editor отвечают на `node show 3` одинаково, а коды
  ## отказа («чужой документ», «просрочен», «не тот вид сущности») приходят из
  ## ядра, а не переизобретаются клиентом (§82).
  ##
  ## Короткое имя типа (`osc`, `gain`) — удобство CLI из примера MANIFEST §19:
  ## ядро такую ссылку отвергает как двусмысленную, а клиент достраивает её по
  ## списку нод — и только если такой тип в графе ОДИН.
  if refText.len == 0:
    return (false, NodeInfo(),
            usageError("не указана нода", "список нод: euterpia node list"))
  let found = doc.queryNode(refText)
  if found.ok:
    return (true, found.node, okReport())
  if ':' notin refText and not refText.allCharsInSet({'0'..'9'}):
    let all = doc.queryNodes()
    if all.frame.isOk():
      var byType: seq[NodeInfo] = @[]
      for node in all.nodes:
        let suffix =
          if '.' in node.nodeType:
            node.nodeType[node.nodeType.rfind('.') + 1 .. ^1]
          else:
            node.nodeType
        if cmpIgnoreCase(node.nodeType, refText) == 0 or
           cmpIgnoreCase(suffix, refText) == 0:
          byType.add node
      if byType.len == 1:
        return (true, byType[0], okReport())
      if byType.len > 1:
        var ids: seq[string] = @[]
        for node in byType:
          ids.add "#" & $node.id & " " & node.name
        return (false, NodeInfo(),
                usageError("тип " & refText & " встречается несколько раз: " &
                           ids.join(", ") & ": укажите id или имя",
                           "например: euterpia node show " & $byType[0].id))
  (false, NodeInfo(), frameReport(found.frame))

proc typeIndexOf(cat: seq[NodeTypeInfo]; nodeType: string): int =
  ## Индекс типа в каталоге или -1. Отдельная функция, а не `findType`:
  ## здесь сравнивается ТОЧНЫЙ id из файла, а `findType` — запрос
  ## пользователя (короткое имя тоже допустимо).
  for i in 0 ..< cat.len:
    if cat[i].id == nodeType:
      return i
  -1

proc parsePortSpec(text: string):
    tuple[ok: bool; node: string; kind: PortKind; index: int; dir: int;
          rep: Report] =
  ## `нода:порт`, где порт — `out`, `in`, `audio`, `ctrl`, `event`, число
  ## (аудио-порт по номеру) или `вид:номер` (`comp:ctrl:1`). `dir`:
  ## 1 — «out», -1 — «in», 0 — направление задаёт место в команде.
  ## Форма с `out`/`in` взята из примера MANIFEST §19 (`oscillator:out`).
  let parts = text.split(':')
  if parts.len < 2 or parts[0].len == 0:
    return (false, "", pkAudio, 0, 0,
            usageError("порт задаётся как нода:порт, получено: " & text,
                       "например: osc:out, gain:in, comp:ctrl:1"))

  let head = parts[0]
  var kind = pkAudio
  var index = 0
  var dir = 0

  if parts.len == 2:
    let p = parts[1].toLowerAscii()
    if p == "out":
      dir = 1
    elif p == "in":
      dir = -1
    elif parsePortKind(p, kind):
      discard
    elif p.len > 0 and p.allCharsInSet({'0'..'9'}):
      index = parseInt(p)
    else:
      return (false, "", pkAudio, 0, 0,
              usageError("неизвестный порт: " & parts[1],
                         "виды портов: " & PortKindNames.join(", ") &
                         "; например: osc:out, gain:in, comp:ctrl:1"))
  elif parts.len == 3:
    let k = parts[1].toLowerAscii()
    if k == "out":
      dir = 1
    elif k == "in":
      dir = -1
    elif not parsePortKind(k, kind):
      return (false, "", pkAudio, 0, 0,
              usageError("неизвестный вид порта: " & parts[1],
                         "виды портов: " & PortKindNames.join(", ")))
    if parts[2].len == 0 or not parts[2].allCharsInSet({'0'..'9'}):
      return (false, "", pkAudio, 0, 0,
              usageError("номер порта должен быть целым, получено: " & parts[2],
                         "например: " & head & ":" & parts[1] & ":0"))
    index = parseInt(parts[2])
  else:
    return (false, "", pkAudio, 0, 0,
            usageError("порт задаётся как нода:порт, получено: " & text,
                       "например: osc:out, gain:in, comp:ctrl:1"))

  (true, head, kind, index, dir, okReport())

proc resolvePort(doc: Document; cat: seq[NodeTypeInfo];
                 text: string; isSource: bool):
    tuple[ok: bool; port: PortRef; rep: Report] =
  ## Полный разбор ссылки на порт с проверкой по описателю: нода есть, тип
  ## зарегистрирован, вид порта совпадает с ролью в команде, номер в
  ## диапазоне. Все проверки здесь, а не в `connect`: их получает и
  ## `disconnect`, и будущая маршрутизация.
  let parsed = parsePortSpec(text)
  if not parsed.ok:
    return (false, PortRef(), parsed.rep)

  let node = resolveNode(doc, parsed.node)
  if not node.ok:
    return (false, PortRef(), node.rep)

  let typeIdx = typeIndexOf(cat, node.node.nodeType)
  if typeIdx < 0:
    return (false, PortRef(),
            usageError("тип ноды " & node.node.nodeType & " не зарегистрирован",
                       "доступные типы: euterpia node types"))

  # Явное направление (`:out`/`:in`) не должно противоречить роли в команде:
  # иначе получилось бы «выход источника — вход источника».
  if parsed.dir != 0 and parsed.dir != (if isSource: 1 else: -1):
    return (false, PortRef(),
            usageError("порт " & text & " — " &
                       (if parsed.dir > 0: "выход" else: "вход") &
                       ", а в команде он " &
                       (if isSource: "источник" else: "приёмник"),
                       "например: euterpia connect osc:out gain:in"))

  let info = cat[typeIdx]
  let available = info.portCount(parsed.kind, isSource)
  if parsed.index >= available:
    return (false, PortRef(),
            usageError("у ноды " & $node.node.id & " (" & info.name &
                       ") нет порта " &
                       parsed.kind.portKindName &
                       (if isSource: "-out" else: "-in") & " с номером " &
                       $parsed.index & ": доступно " & $available,
                       "порты ноды показывает: euterpia node show " &
                       $node.node.id))
  (true, PortRef(nodeId: node.node.id, kind: parsed.kind,
                 index: parsed.index), okReport())

# =============================================================================
# Общие хелперы вывода и записи
# =============================================================================

proc sortedParamKeys(parameters: Table[string, float32]): seq[string] =
  ## Порядок ключей `Table` — деталь реализации, а вывод CLI обязан быть
  ## сравнимым между запусками (#88): печатаем параметры по имени.
  for key in parameters.keys:
    result.add key
  result.sort()

proc sortedByName(params: seq[query.ParamInfo]): seq[query.ParamInfo] =
  ## Параметры по имени: порядок описателя — контракт для правки, но в отчёте
  ## человек ищет имя, а вывод CLI обязан быть детерминированным (#88).
  ##
  ## Тип указан полным именем (`query.ParamInfo`): рядом живёт `catalog.ParamInfo`
  ## — описание параметра ТИПА ноды. Путать их (значение ноды и описание типа)
  ## нельзя, и явное имя модуля это показывает.
  result = params
  result.sort(proc(a, b: query.ParamInfo): int = cmp(a.name, b.name))

proc findParamInfo(node: NodeInfo; name: string):
    tuple[found: bool; value: float32; fromFile: bool] =
  ## Значение параметра и его источник из DTO (#336): `fromFile` различает
  ## «лежит в файле» и «умолчание типа» — это и есть поле `source` в `--json`.
  for p in node.params:
    if p.name == name:
      return (true, p.value, p.fromFile)
  (false, 0.0f, false)

proc portsSummary(info: NodeTypeInfo): JsonNode =
  ## Порты в машинном виде: одним объектом, а не шестью полями верхнего
  ## уровня — так он читается и человеком, и агентом.
  %*{
    "audio": {"in": info.audioIn, "out": info.audioOut},
    "ctrl": {"in": info.ctrlIn, "out": info.ctrlOut},
    "event": {"in": info.eventIn, "out": info.eventOut},
  }

proc portText(info: NodeTypeInfo): string =
  ## `audio 1→1, ctrl 0→0, event 1→0` — только непустые виды.
  var parts: seq[string] = @[]
  for kind in PortKind:
    let outs = info.portCount(kind, true)
    let ins = info.portCount(kind, false)
    if outs > 0 or ins > 0:
      parts.add kind.portKindName & " " & $ins & "→" & $outs
  if parts.len == 0: "портов нет" else: parts.join(", ")

proc typeJson(info: NodeTypeInfo): JsonNode =
  var params = newJArray()
  for p in info.params:
    params.add %*{
      "id": p.id, "name": p.name, "flags": flagNames(p.flags),
      "min": p.minValue, "max": p.maxValue,
      "default": p.defaultValue, "step": p.step,
    }
  %*{
    "id": info.id, "name": info.name, "category": info.category,
    "ports": portsSummary(info),
    "latencyFrames": info.latencyFrames,
    "params": params,
  }

proc commitEdit(ctx: Ctx; path: string; proj: ProjectFormat;
                body: JsonNode; lines: seq[string]): Report =
  ## Общий хвост изменяющих команд: записать атомарно или (в `--dry-run`)
  ## только сказать, что было бы записано. `metadata.modified` выставляет
  ## команда ДО сборки ответа: `--json` обязан показывать то состояние,
  ## которое записывается, а не прежнее (#89).
  if ctx.dryRun:
    return okReport(body = body,
                    lines = lines & @["не записан: " & path & " (--dry-run)"])
  let saved = writeAtomic(path, proj)
  if not saved.success:
    return saveError(saved, path)
  okReport(body = body, lines = lines & @["записан: " & path])

# =============================================================================
# Представление нод и связей
# =============================================================================

proc nodeJson(node: NodeInfo; cat: seq[NodeTypeInfo]): JsonNode =
  ## Нода в машинном виде: то, что отдал Query API, плюс то, что о типе знает
  ## каталог CLI. Поле `known` — не украшение: по нему агент отличает «нода из
  ## будущей версии/плагина» от «опечатка в типе».
  var params = newJObject()
  for p in node.params:
    # Печатаются параметры ИЗ ФАЙЛА: умолчания типа показывает `param list`
    # (там же виден источник значения) — иначе `node list` рассказывал бы о
    # файле то, чего в нём нет.
    if p.fromFile:
      params[p.name] = %p.value
  result = %*{
    "id": node.id,
    "type": node.nodeType,
    "name": node.name,
    "subgraph": node.isSubgraph,
    "latency": {"reported": int(node.latencyReported),
                "intrinsic": int(node.latencyIntrinsic)},
    "counts": {
      "audio": {"in": node.audioIn, "out": node.audioOut},
      "ctrl": {"in": node.ctrlIn, "out": node.ctrlOut},
      "event": {"in": node.eventIn, "out": node.eventOut},
    },
    "params": params,
    "connections": node.connections,
  }
  # Адрес — машинный контракт: по нему клиент возвращается к сущности после
  # правок графа, поэтому он печатается и в короткой, и в полной форме.
  result["handle"] = %node.handle
  result["handleRef"] = %node.handleRef
  let typeIdx = typeIndexOf(cat, node.nodeType)
  result["known"] = %(typeIdx >= 0)
  if typeIdx >= 0:
    result["typeName"] = %cat[typeIdx].name
    result["category"] = %cat[typeIdx].category

proc portKindOfOrd(value: int): string =
  ## Вид сигнала из файла (`sigType`) человеческим словом. Неизвестное
  ## значение печатается как есть: молча подставлять «audio» значило бы
  ## скрывать испорченные данные (§44).
  if value >= 0 and value < PortKindNames.len: PortKindNames[value]
  else: "sig" & $value

proc connectionText(conn: ConnectionInfo): string =
  ## `#1:audio:0 → #2:audio:0` — с id, потому что имена не обязаны быть
  ## уникальными, а id уникален всегда.
  "#" & $conn.srcNodeId & ":" & portKindOfOrd(conn.sigType) & ":" &
    $conn.srcPortIdx & " → #" & $conn.dstNodeId & ":" &
    portKindOfOrd(conn.sigType) & ":" & $conn.dstPortIdx

proc connectionText(conn: ConnectionFormat): string =
  ## Тот же текст связи, но из формата: им пользуется `graph check` — проверка
  ## целостности ДОКУМЕНТА, чей предмет и есть сам файл (см. guard в
  ## `tools/check_architecture.py`). Отдельная перегрузка, а не второй
  ## формат строки: текст связи в отчётах обязан совпадать.
  "#" & $conn.srcNodeId & ":" & portKindOfOrd(conn.sigType) & ":" &
    $conn.srcPortIdx & " → #" & $conn.dstNodeId & ":" &
    portKindOfOrd(conn.sigType) & ":" & $conn.dstPortIdx

# =============================================================================
# node types
# =============================================================================

proc runNodeTypes(ctx: var Ctx): Report =
  discard ctx
  let cat = catalog()
  var types = newJArray()
  for info in cat:
    types.add typeJson(info)
  var lines: seq[string] = @["типов нод: " & $cat.len]
  for info in cat:
    lines.add "  " & info.id & " — " & info.name & " (" & info.category &
      "): " & portText(info) & ", параметров: " & $info.params.len
  okReport(body = %*{"types": types, "count": cat.len}, lines = lines)

# =============================================================================
# node list
# =============================================================================

proc runNodeList(ctx: var Ctx; scan: ArgScan): Report =
  discard ctx
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let cat = catalog()
  let doc = openDocument(scan.path, loaded.proj)

  # Фильтр и окно считает Query API (#141, #336): проект на 1000 нод не
  # пересылается в CLI целиком ради двадцати строк отчёта.
  let filter = NodeFilter(text: scan.filter, nodeType: scan.nodeType,
                          offset: scan.offset, limit: scan.limit)
  let found = doc.queryNodes(filter)
  if not found.frame.isOk(): return frameReport(found.frame)

  var nodes = newJArray()
  for node in found.nodes:
    nodes.add nodeJson(node, cat)

  let conns = doc.queryConnections()
  let summary = querySummary(doc)

  var connJson = newJArray()
  for conn in conns:
    connJson.add %*{
      "srcNodeId": conn.srcNodeId, "srcPortIdx": conn.srcPortIdx,
      "dstNodeId": conn.dstNodeId, "dstPortIdx": conn.dstPortIdx,
      "sigType": conn.sigType, "kind": portKindOfOrd(conn.sigType),
    }

  var lines: seq[string] = @[
    "файл: " & scan.path,
    "нод: " & $found.nodes.len & " из " & $found.total,
  ]
  if found.offset > 0 or (found.limit > 0 and found.nodes.len < found.total):
    lines.add "  окно: offset " & $found.offset & ", limit " & $found.limit
  for node in found.nodes:
    var tail = ""
    let typeIdx = typeIndexOf(cat, node.nodeType)
    if typeIdx >= 0:
      tail = ": " & portText(cat[typeIdx])
    else:
      tail = ": тип не зарегистрирован"
    lines.add "  #" & $node.id & " " & node.name & " (" & node.nodeType & ") [" &
              node.handle & "]" & tail
  if found.nodes.len == 0:
    lines.add "  (ничего не найдено)"
  lines.add "связей: " & $summary.connections
  for conn in conns:
    lines.add "  " & connectionText(conn)

  var body = %*{"path": scan.path, "nodes": nodes,
                "connections": connJson,
                "summary": summarize(summary)}
  # Счётчики окна печатаются только когда окно не «всё»: иначе вывод
  # `node list` без ключей менял бы форму без причины.
  if found.offset > 0 or found.limit > 0:
    body["window"] = %*{"offset": found.offset, "limit": found.limit,
                        "total": found.total, "shown": found.nodes.len}
  okReport(body = body, lines = lines)

# =============================================================================
# node add
# =============================================================================

proc runNodeAdd(ctx: var Ctx; scan: ArgScan): Report =
  if scan.positionals.len != 1:
    return usageError("node add принимает тип ноды, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia node add oscillator")

  let cat = catalog()
  let query = scan.positionals[0]
  let matches = matchingTypes(cat, query)
  if matches.len == 0:
    return usageError("неизвестный тип ноды: " & query,
                      "доступные типы: " & typeIds(cat).join(", "))
  if matches.len > 1:
    var ids: seq[string] = @[]
    for i in matches:
      ids.add cat[i].id
    return usageError("тип " & query & " неоднозначен: " & ids.join(", "),
                      "укажите полный id типа")
  let info = cat[matches[0]]

  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  var doc = openDocument(scan.path, loaded.proj)

  # Проверки «занятый id» и «неизвестный тип» живут в control-слое: клиент
  # переводит аргументы в команду и показывает ответ, а не решает сам (#139).
  let requestedId = (if scan.haveId: int32(scan.id) else: 0'i32)
  let frame = doc.applyCommand(createNode(info.id, scan.name, requestedId))
  if not frame.isOk(): return frameReport(frame)

  # Что добавилось, читает Query API: id назначает control-слой (максимум + 1),
  # и клиент не повторяет это правило у себя (#336).
  let all = doc.queryNodes()
  if not all.frame.isOk(): return frameReport(all.frame)
  let newId = all.nodes[^1].id
  let added = doc.queryNode($newId)
  if not added.ok: return frameReport(added.frame)

  var body = projectBody(doc, scan.path)
  body["node"] = nodeJson(added.node, cat)
  body["change"] = %*{"action": "node.add", "id": newId,
                      "type": info.id, "name": added.node.name}
  commitEdit(ctx, scan.path, doc.proj, body, @[
    "файл: " & scan.path,
    "добавлена нода #" & $newId & " " & added.node.name & " (" & info.id & ") [" &
      added.node.handle & "]",
    "порты: " & portText(info),
    "параметров: " & $info.params.len & " (умолчания типа)",
  ])

# =============================================================================
# node rm
# =============================================================================

proc runNodeRm(ctx: var Ctx; scan: ArgScan): Report =
  if scan.positionals.len != 1:
    return usageError("node rm принимает одну ноду, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia node rm 2")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let cat = catalog()
  var doc = openDocument(scan.path, loaded.proj)

  let found = resolveNode(doc, scan.positionals[0])
  if not found.ok: return found.rep
  let node = found.node

  # Каскадное удаление (связи, автоматизация, состояния плагинов) — забота
  # control-слоя (#139): CLI считает, ЧТО исчезнет, чтобы честно сказать об этом
  # в отчёте, но не решает, что именно удалять.
  var removedConns = 0
  for conn in doc.queryConnections():
    if conn.srcNodeId == node.id or conn.dstNodeId == node.id:
      inc removedConns
  var removedLanes = 0
  for lane in doc.queryAutomationLanes():
    if int(lane.nodeId) == node.id:
      inc removedLanes
  var removedStates = 0
  for state in doc.queryPluginStates():
    if state.nodeId == node.id:
      inc removedStates

  let frame = doc.applyCommand(deleteNode(int32(node.id)))
  if not frame.isOk(): return frameReport(frame)

  var body = projectBody(doc, scan.path)
  body["removed"] = %*{
    "action": "node.rm", "id": node.id, "type": node.nodeType,
    "name": node.name, "connections": removedConns,
    "automationLanes": removedLanes, "pluginStates": removedStates,
  }
  commitEdit(ctx, scan.path, doc.proj, body, @[
    "файл: " & scan.path,
    "удалена нода #" & $node.id & " " & node.name & " (" & node.nodeType & ")",
    "удалено связей: " & $removedConns,
    "удалено дорожек автоматизации: " & $removedLanes,
    "удалено состояний плагинов: " & $removedStates,
  ])

# =============================================================================
# node show
# =============================================================================

proc runNodeShow(ctx: var Ctx; scan: ArgScan): Report =
  discard ctx
  if scan.positionals.len != 1:
    return usageError("node show принимает одну ноду, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia node show 1")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let cat = catalog()
  let doc = openDocument(scan.path, loaded.proj)

  let found = resolveNode(doc, scan.positionals[0])
  if not found.ok: return found.rep
  let node = found.node
  let typeIdx = typeIndexOf(cat, node.nodeType)

  var lines: seq[string] = @[
    "файл: " & scan.path,
    "#" & $node.id & " " & node.name & " — " & node.nodeType,
    "  связей: " & $node.connections,
  ]
  var body = nodeJson(node, cat)

  if typeIdx >= 0:
    let info = cat[typeIdx]
    lines.add "  тип: " & info.name & " (" & info.category & ")"
    lines.add "  порты: " & portText(info)
    lines.add "  задержка: " & $info.latencyFrames & " кадров"
    lines.add "  параметры:"
    for p in info.params:
      # Значение и источник — из DTO: параметр с `fromFile` лежит в файле,
      # остальные показывают умолчание типа (одно правило для всех команд).
      let current = findParamInfo(node, p.name)
      let value = if current.found: current.value else: p.defaultValue
      var note = if current.found and current.fromFile: "файл" else: "умолчание"
      let flags = flagNames(p.flags)
      if flags.len > 0:
        note.add ", " & flags.join("+")
      lines.add "    " & p.name & " = " & $value & " (" & note &
        "; " & $p.minValue & "…" & $p.maxValue & ")"
  else:
    # Тип неизвестен (нода будущей версии или плагин): показываем то, что
    # есть в файле, и не выдаём выдуманные порты и диапазоны.
    lines.add "  тип не зарегистрирован: порты и диапазоны неизвестны"
    for p in sortedByName(node.params):
      lines.add "    " & p.name & " = " & $p.value

  okReport(body = body, lines = lines)

# =============================================================================
# connect
# =============================================================================

proc runConnect(ctx: var Ctx; scan: ArgScan): Report =
  if scan.positionals.len != 2:
    return usageError("connect принимает источник и приёмник, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia connect osc:out gain:in")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let cat = catalog()
  var doc = openDocument(scan.path, loaded.proj)

  let src = resolvePort(doc, cat, scan.positionals[0], isSource = true)
  if not src.ok: return src.rep
  let dst = resolvePort(doc, cat, scan.positionals[1], isSource = false)
  if not dst.ok: return dst.rep

  # Виды портов, повтор связи и существование порта проверяет control-слой:
  # те же правила должен применять и Editor (#139). CLI разбирает аргументы,
  # а не решает, что можно соединить.
  #
  # Самосоединение и цикл здесь не запрещаются: обратная связь через ноду
  # задержки — законный приём, а собирается ли граф — решает `graph check`
  # и компилятор (#90), а не догадка CLI.
  let frame = doc.applyCommand(connect(
    port(int32(src.port.nodeId), controlPortKind(src.port.kind),
         int32(src.port.index)),
    port(int32(dst.port.nodeId), controlPortKind(dst.port.kind),
         int32(dst.port.index))))
  if not frame.isOk(): return frameReport(frame)

  # Добавленную связь читает Query API: она последняя в списке документа, а
  # не «угаданная» клиентом по своим аргументам (#336).
  let conns = doc.queryConnections()
  let conn = conns[^1]

  var body = projectBody(doc, scan.path)
  body["connection"] = %*{
    "srcNodeId": conn.srcNodeId, "srcPortIdx": conn.srcPortIdx,
    "dstNodeId": conn.dstNodeId, "dstPortIdx": conn.dstPortIdx,
    "sigType": conn.sigType, "kind": src.port.kind.portKindName,
  }
  body["change"] = %*{"action": "connect", "applied": true}
  commitEdit(ctx, scan.path, doc.proj, body, @[
    "файл: " & scan.path,
    "соединено: " & connectionText(conn),
    "связей: " & $conns.len,
  ])

# =============================================================================
# disconnect
# =============================================================================

proc runDisconnect(ctx: var Ctx; scan: ArgScan): Report =
  if scan.positionals.len != 2:
    return usageError("disconnect принимает источник и приёмник, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia disconnect osc:out gain:in")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  var doc = openDocument(scan.path, loaded.proj)

  # Порт можно не указывать (`disconnect osc gain`) — тогда снимаются все
  # связи между этими двумя нодами. Указание порта сужает выбор до одной.
  var srcId = -1
  var dstId = -1
  var srcIndex = 0
  var dstIndex = 0
  var kind = controlPortKind(pkAudio)
  var portSpecified = false

  if ':' in scan.positionals[0]:
    let parsed = parsePortSpec(scan.positionals[0])
    if not parsed.ok: return parsed.rep
    let node = resolveNode(doc, parsed.node)
    if not node.ok: return node.rep
    srcId = node.node.id
    kind = controlPortKind(parsed.kind)
    srcIndex = parsed.index
    portSpecified = true
  else:
    let node = resolveNode(doc, scan.positionals[0])
    if not node.ok: return node.rep
    srcId = node.node.id

  if ':' in scan.positionals[1]:
    let parsed = parsePortSpec(scan.positionals[1])
    if not parsed.ok: return parsed.rep
    let node = resolveNode(doc, parsed.node)
    if not node.ok: return node.rep
    dstId = node.node.id
    dstIndex = parsed.index
    portSpecified = true
  else:
    let node = resolveNode(doc, scan.positionals[1])
    if not node.ok: return node.rep
    dstId = node.node.id

  # Что именно снимется — считаем ДО команды: после неё связей уже нет, а
  # отчёт обязан перечислить снятое (клиент считает, ядро решает).
  var removed: seq[ConnectionInfo] = @[]
  for conn in doc.queryConnections():
    if conn.srcNodeId == srcId and conn.dstNodeId == dstId and
       (not portSpecified or (conn.sigType == ord(kind) and
                              conn.srcPortIdx == srcIndex and
                              conn.dstPortIdx == dstIndex)):
      removed.add conn

  let frame = doc.applyCommand(disconnect(
    port(int32(srcId), kind, int32(srcIndex)),
    port(int32(dstId), kind, int32(dstIndex)), portSpecified))
  if not frame.isOk(): return frameReport(frame)

  var removedJson = newJArray()
  for conn in removed:
    removedJson.add %*{
      "srcNodeId": conn.srcNodeId, "srcPortIdx": conn.srcPortIdx,
      "dstNodeId": conn.dstNodeId, "dstPortIdx": conn.dstPortIdx,
      "sigType": conn.sigType,
    }
  let remaining = doc.queryConnections()
  var body = projectBody(doc, scan.path)
  body["removed"] = %*{"action": "disconnect", "connections": removedJson}
  var lines: seq[string] = @[
    "файл: " & scan.path,
    "снято связей: " & $removed.len,
  ]
  for conn in removed:
    lines.add "  " & connectionText(conn)
  lines.add "осталось связей: " & $remaining.len
  commitEdit(ctx, scan.path, doc.proj, body, lines)

# =============================================================================
# param: разбор значения и параметра
# =============================================================================

proc parseParamValue(text: string): tuple[ok: bool; value: float32; message: string] =
  ## Значение параметра — число. `1e3`, `-6`, `0.5` допустимы; всё остальное
  ## отвергается с текстом «что именно не так» (§44).
  try:
    let parsed = parseFloat(text)
    if parsed != parsed:   # NaN
      return (false, 0.0f, "значение параметра не может быть NaN: " & text)
    (true, float32(parsed), "")
  except ValueError:
    (false, 0.0f, "значение параметра должно быть числом, получено: " & text)

proc paramJson(p: query.ParamInfo; cat: seq[NodeTypeInfo];
               nodeType: string): JsonNode =
  ## Один параметр целиком: значение и источник — из DTO Query API, диапазон,
  ## шаг, флаги и id описателя — из каталога CLI (типы знает клиент, а не
  ## ядро — §54). Агент решает по этим полям, а не по тексту.
  let typeIdx = typeIndexOf(cat, nodeType)
  var flags = newJArray()
  var paramId = uint32(max(0, p.index))
  if typeIdx >= 0 and p.index >= 0 and p.index < cat[typeIdx].params.len:
    let info = cat[typeIdx].params[p.index]
    paramId = info.id
    for name in flagNames(info.flags):
      flags.add %name
  %*{
    "id": paramId, "name": p.name,
    "handle": p.handle,
    "value": p.value,
    "source": (if p.fromFile: "file" else: "default"),
    "default": p.defaultValue,
    "min": p.minValue, "max": p.maxValue, "step": p.step,
    "flags": flags,
  }

# =============================================================================
# param list
# =============================================================================

proc runParamList(ctx: var Ctx; scan: ArgScan): Report =
  discard ctx
  if scan.positionals.len != 1:
    return usageError("param list принимает одну ноду, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia param list 1")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let cat = catalog()
  let doc = openDocument(scan.path, loaded.proj)

  let found = resolveNode(doc, scan.positionals[0])
  if not found.ok: return found.rep
  let node = found.node
  let typeIdx = typeIndexOf(cat, node.nodeType)

  var params = newJArray()
  var lines: seq[string] = @["файл: " & scan.path]
  if typeIdx >= 0:
    let info = cat[typeIdx]
    lines.add "#" & $node.id & " " & node.name & " (" & info.id & "): параметров " &
      $info.params.len
    # Порядок — описателя типа: он устойчив к переименованию параметров.
    for p in node.params:
      params.add paramJson(p, cat, node.nodeType)
      lines.add "  " & p.name & " = " & $p.value &
        " (" & (if p.fromFile: "файл" else: "умолчание") &
        "; " & $p.minValue & "…" & $p.maxValue & ") [" & p.handle & "]"
  else:
    lines.add "#" & $node.id & " " & node.name &
      ": тип не зарегистрирован, показаны только значения из файла"
    for p in sortedByName(node.params):
      params.add paramJson(p, cat, node.nodeType)
      lines.add "  " & p.name & " = " & $p.value

  okReport(body = %*{"path": scan.path, "node": node.id,
                     "params": params}, lines = lines)

# =============================================================================
# param get
# =============================================================================

proc runParamGet(ctx: var Ctx; scan: ArgScan): Report =
  discard ctx
  if scan.positionals.len != 2:
    return usageError("param get принимает ноду и параметр, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia param get 1 freq")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let cat = catalog()
  let doc = openDocument(scan.path, loaded.proj)

  let node = resolveNode(doc, scan.positionals[0])
  if not node.ok: return node.rep
  let typeIdx = typeIndexOf(cat, node.node.nodeType)
  if typeIdx < 0:
    return usageError("тип ноды " & node.node.nodeType & " не зарегистрирован",
                      "доступные типы: euterpia node types")

  let found = doc.queryParam(scan.positionals[0], scan.positionals[1])
  if not found.ok: return frameReport(found.frame)
  let p = found.param
  let info = cat[typeIdx]
  let pInfo = info.params[p.index]

  var lines: seq[string] = @[
    "файл: " & scan.path,
    "#" & $node.node.id & " " & node.node.name & " — " & p.name & " = " &
      $p.value &
      " (" & (if p.fromFile: "файл" else: "умолчание") & ")",
  ]
  var flags = flagNames(pInfo.flags)
  lines.add "  диапазон: " & $p.minValue & "…" & $p.maxValue &
    ", шаг: " & $p.step
  if flags.len > 0:
    lines.add "  флаги: " & flags.join("+")
  okReport(body = %*{"path": scan.path, "node": node.node.id,
                     "nodeType": node.node.nodeType,
                     "param": paramJson(p, cat, node.node.nodeType)},
           lines = lines)

# =============================================================================
# param set
# =============================================================================

proc runParamSet(ctx: var Ctx; scan: ArgScan): Report =
  if scan.positionals.len != 3:
    return usageError("param set принимает ноду, параметр и значение, получено аргументов: " &
                      $scan.positionals.len,
                      "например: euterpia param set 1 freq 220")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let cat = catalog()
  var doc = openDocument(scan.path, loaded.proj)

  let node = resolveNode(doc, scan.positionals[0])
  if not node.ok: return node.rep
  let typeIdx = typeIndexOf(cat, node.node.nodeType)
  if typeIdx < 0:
    return usageError("тип ноды " & node.node.nodeType & " не зарегистрирован",
                      "доступные типы: euterpia node types")
  let info = cat[typeIdx]

  let found = doc.queryParam(scan.positionals[0], scan.positionals[1])
  if not found.ok: return frameReport(found.frame)
  let p = found.param
  let pInfo = info.params[p.index]

  let parsed = parseParamValue(scan.positionals[2])
  if not parsed.ok:
    return usageError(parsed.message, "число с точкой или экспонентой, например 1200 или 1e3")
  let value = parsed.value
  let before = p.value

  # Диапазон и целостность проверяет control-слой по описателю типа (#139):
  # «команда прошла» не должно означать «в проекте лежит значение, которого
  # нода не понимает», и проверять это должен один код — тот же, что у Editor.
  # Клиент знает только, что параметр найден, — этого достаточно для отчёта.
  let frame = doc.applyCommand(setParameter(int32(node.node.id), value, p.name))
  if not frame.isOk(): return frameReport(frame)

  # Отчёт читает то, что записано: значение приходит из Query API, а не из
  # переменной запроса — иначе отчёт мог бы разойтись с проектом (#336).
  let after = doc.queryParam(scan.positionals[0], scan.positionals[1])
  var body = projectBody(doc, scan.path)
  body["node"] = %node.node.id
  body["param"] = paramJson((if after.ok: after.param else: p), cat,
                            node.node.nodeType)
  body["change"] = %*{
    "action": "param.set", "node": node.node.id,
    "param": p.name, "id": pInfo.id,
    "before": before,
    "after": value,
    "applied": true,
  }
  commitEdit(ctx, scan.path, doc.proj, body, @[
    "файл: " & scan.path,
    "#" & $node.node.id & " " & p.name & ": " & $before & " → " & $value &
      " [" & p.handle & "]",
  ])

# =============================================================================
# graph check
# =============================================================================

proc nodeIndexById(proj: ProjectFormat; id: int): int =
  ## Индекс ноды по id или -1. Нужен там, где на входе id из связи, а не
  ## ссылка пользователя (у `resolveNode` другая задача — разобрать текст).
  for i in 0 ..< proj.graph.nodes.len:
    if proj.graph.nodes[i].id == id:
      return i
  -1

type
  GraphAnalysis = object
    sections: seq[Section]
    structuralFails: bool
      ## Структурные ошибки (типы, связи, порты). Пока они есть, компиляцию
      ## запускать бессмысленно: вердикт зависел бы от испорченных данных.
    specs: seq[GraphNodeSpec]
    conns: seq[GraphConnSpec]

proc analyzeGraph(proj: ProjectFormat; cat: seq[NodeTypeInfo]): GraphAnalysis =
  ## Структурный разбор графа: идентификаторы, типы, параметры, связи.
  ## Он идёт до компиляции: компилятор не должен получать заведомо битые
  ## данные (и не должен объяснять пользователю то, что видно из файла).
  # --- идентификаторы --------------------------------------------------------
  var seen: seq[int] = @[]
  var duplicates: seq[int] = @[]
  for node in proj.graph.nodes:
    if node.id in seen and node.id notin duplicates:
      duplicates.add node.id
    seen.add node.id
  var nodeSection = Section(id: "nodes", title: "graph: ноды")
  var idLines: seq[string] = @["нод: " & $proj.graph.nodes.len]
  for id in duplicates:
    idLines.add "повтор id: " & $id
  nodeSection.checks.add mkCheck("node-ids", "идентификаторы нод уникальны",
    (if duplicates.len == 0: csOk else: csFail),
    lines = idLines,
    advice = (if duplicates.len == 0: ""
              else: "повтор id делает ноду неразличимой для связей и автоматизации"),
    body = %*{"nodes": proj.graph.nodes.len, "duplicates": %duplicates})
  nodeSection.checks.add mkCheck("node-count", "в графе есть ноды",
    (if proj.graph.nodes.len == 0: csWarn else: csOk),
    lines = @["нод: " & $proj.graph.nodes.len],
    advice = (if proj.graph.nodes.len == 0:
                "добавьте ноду: euterpia node add oscillator"
              else: ""),
    body = %*{"nodes": proj.graph.nodes.len})

  # --- типы и параметры ------------------------------------------------------
  var unknownTypes: seq[string] = @[]
  var portMismatch: seq[string] = @[]
  var unknownParams: seq[string] = @[]
  var outOfRangeParams: seq[string] = @[]
  for node in proj.graph.nodes:
    let typeIdx = typeIndexOf(cat, node.nodeType)
    if typeIdx < 0:
      if node.nodeType notin unknownTypes:
        unknownTypes.add node.nodeType
      continue
    let info = cat[typeIdx]
    if node.audioInCount != info.audioIn or node.audioOutCount != info.audioOut or
       node.ctrlInCount != info.ctrlIn or node.ctrlOutCount != info.ctrlOut or
       node.eventInCount != info.eventIn or node.eventOutCount != info.eventOut:
      portMismatch.add "#" & $node.id & " " & node.nodeType
    for key in sortedParamKeys(node.parameters):
      let paramIdx = findParam(info, key)
      if paramIdx < 0:
        unknownParams.add "#" & $node.id & "." & key
      else:
        let p = info.params[paramIdx]
        let value = node.parameters[key]
        if value < p.minValue or value > p.maxValue:
          outOfRangeParams.add "#" & $node.id & "." & key & " = " & $value

  var typeLines: seq[string] = @["известных типов в каталоге: " & $cat.len]
  for nodeType in unknownTypes:
    typeLines.add "тип не зарегистрирован: " & nodeType
  for item in portMismatch:
    typeLines.add "порты в файле не совпадают с типом: " & item
  nodeSection.checks.add mkCheck("node-types", "типы нод известны CLI",
    (if unknownTypes.len > 0: csFail
     elif portMismatch.len > 0: csWarn else: csOk),
    lines = typeLines,
    advice = (if unknownTypes.len > 0:
                "нода плагина или новой версии: без типа её состояние не создаётся"
              elif portMismatch.len > 0:
                "порты правятся пересозданием ноды: euterpia node rm / node add"
              else: ""),
    body = %*{"unknownTypes": %unknownTypes, "portMismatch": %portMismatch})

  var paramLines: seq[string] = @[]
  for item in unknownParams:
    paramLines.add "параметр не объявлен типом: " & item
  for item in outOfRangeParams:
    paramLines.add "значение вне диапазона: " & item
  if paramLines.len == 0:
    paramLines.add "значения параметров в диапазонах типов"
  nodeSection.checks.add mkCheck("node-params", "значения параметров допустимы",
    (if unknownParams.len > 0 or outOfRangeParams.len > 0: csWarn else: csOk),
    lines = paramLines,
    advice = (if unknownParams.len > 0 or outOfRangeParams.len > 0:
                "исправьте значение: euterpia param set <нода> <параметр> <значение>"
              else: ""),
    body = %*{"unknown": %unknownParams, "outOfRange": %outOfRangeParams})
  result.sections.add nodeSection

  # --- связи -----------------------------------------------------------------
  var connSection = Section(id: "connections", title: "graph: связи")
  var dangling: seq[string] = @[]
  var outOfRange: seq[string] = @[]
  var kindMismatch: seq[string] = @[]
  var selfLoops: seq[string] = @[]
  for conn in proj.graph.connections:
    let srcIdx = nodeIndexById(proj, conn.srcNodeId)
    let dstIdx = nodeIndexById(proj, conn.dstNodeId)
    let text = connectionText(conn)
    if srcIdx < 0 or dstIdx < 0:
      dangling.add text
      continue
    if conn.sigType < 0 or conn.sigType > ord(PortKind.high):
      kindMismatch.add text
      continue
    let kind = cast[PortKind](conn.sigType)
    let srcType = typeIndexOf(cat, proj.graph.nodes[srcIdx].nodeType)
    let dstType = typeIndexOf(cat, proj.graph.nodes[dstIdx].nodeType)
    if srcType >= 0 and conn.srcPortIdx >= cat[srcType].portCount(kind, true):
      outOfRange.add text
    if dstType >= 0 and conn.dstPortIdx >= cat[dstType].portCount(kind, false):
      outOfRange.add text
    if conn.srcNodeId == conn.dstNodeId:
      selfLoops.add text

  var connLines: seq[string] = @["связей: " & $proj.graph.connections.len]
  for item in dangling:
    connLines.add "нет такой ноды: " & item
  for item in kindMismatch:
    connLines.add "неизвестный вид сигнала: " & item
  for item in outOfRange:
    connLines.add "порт вне диапазона типа: " & item
  for item in selfLoops:
    connLines.add "нода соединена сама с собой: " & item
  let connBad = dangling.len > 0 or kindMismatch.len > 0 or outOfRange.len > 0
  connSection.checks.add mkCheck("connections",
    "связи ссылаются на существующие ноды и порты",
    (if connBad: csFail elif selfLoops.len > 0: csWarn else: csOk),
    lines = connLines,
    advice = (if connBad: "исправьте связь: euterpia disconnect … / euterpia connect …"
              elif selfLoops.len > 0:
                "самосоединение компилируется только через ноду задержки"
              else: ""),
    body = %*{"connections": proj.graph.connections.len,
              "dangling": %dangling, "outOfRange": %outOfRange,
              "kindMismatch": %kindMismatch, "selfLoops": %selfLoops})
  result.sections.add connSection
  result.structuralFails = result.structuralFails or connBad

  # --- данные для компиляции -------------------------------------------------
  # Спецификации собираются тем же обходом данных, что и проверки: отдельного
  # «второго мнения» о графе нет, поэтому проверка и компиляция не разойдутся.
  if not result.structuralFails:
    for node in proj.graph.nodes:
      result.specs.add GraphNodeSpec(id: node.id, nodeType: node.nodeType)
    for conn in proj.graph.connections:
      result.conns.add GraphConnSpec(
        srcNodeId: conn.srcNodeId, srcPortIdx: conn.srcPortIdx,
        dstNodeId: conn.dstNodeId, dstPortIdx: conn.dstPortIdx,
        sigType: conn.sigType
      )

# =============================================================================
# graph check: команда
# =============================================================================

proc runGraphCheck(ctx: var Ctx; scan: ArgScan): Report =
  if scan.positionals.len > 0:
    return usageError("graph check не принимает позиционных аргументов, получено: " &
                      scan.positionals.join(" "),
                      "например: euterpia graph check")
  let loaded = loadAt(scan.path)
  if not loaded.ok: return loaded.rep
  let proj = loaded.proj
  let cat = catalog()
  let analysis = analyzeGraph(proj, cat)

  var sections = analysis.sections
  var compileFacts: JsonNode
  var compileCheck: Check
  if analysis.structuralFails:
    # Компилятор не должен получать заведомо битые данные, а пользователь —
    # вердикт, зависящий от них: сначала структура, потом компиляция.
    compileFacts = %*{"verdict": "skipped", "reason": "structuralErrors"}
    compileCheck = mkCheck("compile", "граф компилируется", csWarn,
      lines = @["не проверялась: структурные ошибки выше"],
      advice = "сначала исправьте ошибки структуры",
      body = compileFacts)
  else:
    let verdict = verifyGraph(builtinRegistry(), analysis.specs, analysis.conns)
    compileFacts = %*{
      "verdict": verdictName(verdict.kind),
      "reason": describe(verdict),
      "steps": int(verdict.stepCount),
      "nodeType": verdict.nodeType,
    }
    compileCheck = mkCheck("compile", "граф компилируется",
      (if verdict.kind == gvCompiles: csOk else: csFail),
      lines = @[describe(verdict)],
      advice = (case verdict.kind
                of gvCompiles: ""
                of gvCycle, gvPdcCycle:
                  "разорвите цикл или добавьте в него ноду задержки (euterpia.delay)"
                of gvUnknownType, gvInstantiateFailed:
                  "euterpia node types — какие типы доступны этой сборке"
                of gvAllocationFailed:
                  "граф слишком велик для этой сборки: разбейте его на подграфы"),
      body = compileFacts)
  sections.add Section(id: "compile", title: "graph: компиляция",
                       checks: @[compileCheck])

  var sectionsJson = newJArray()
  for section in sections:
    sectionsJson.add sectionJson(section)
  let total = counts(sections)

  var body = newJObject()
  body["path"] = %scan.path
  body["compile"] = compileFacts
  body["sections"] = sectionsJson
  body["summary"] = summaryJson(sections)
  body["nodes"] = %proj.graph.nodes.len
  body["connections"] = %proj.graph.connections.len

  var lines: seq[string] = @[
    CliName & " graph check — проверка графа",
    "файл: " & scan.path,
    "",
  ]
  lines.add renderHuman(sections, ctx.verbose)
  lines.add ""
  lines.add "провалов: " & $total.fail & ", предупреждений: " & $total.warn

  if total.fail > 0:
    return checkFailedError(
      "граф не прошёл проверку: провалов " & $total.fail,
      "подробности: euterpia graph check --verbose",
      lines = lines, body = body)
  okReport(body = body, lines = lines)

# =============================================================================
# Диспетчеры команд
# =============================================================================

proc runNode*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia node <list|types|add|rm|show> [аргументы] [--file проект.eproj]`.
  if args.len == 0:
    return usageError("node требует подкоманду",
                      "подкоманды: " & NodeSubcommands.join(", "))
  let sub = args[0]
  let scan = scanArgs(argsTail(args), "node " & sub)
  if not scan.ok: return scan.rep
  case sub
  of "list": runNodeList(ctx, scan)
  of "types":
    if scan.positionals.len > 0:
      return usageError("node types не принимает аргументов, получено: " &
                        scan.positionals.join(" "),
                        "каталог типов: euterpia node types")
    runNodeTypes(ctx)
  of "add": runNodeAdd(ctx, scan)
  of "rm": runNodeRm(ctx, scan)
  of "show": runNodeShow(ctx, scan)
  else:
    usageError("неизвестная подкоманда node: " & sub,
               "подкоманды: " & NodeSubcommands.join(", "))

proc runParam*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia param <list|get|set> …`.
  if args.len == 0:
    return usageError("param требует подкоманду",
                      "подкоманды: " & ParamSubcommands.join(", "))
  let sub = args[0]
  let scan = scanArgs(argsTail(args), "param " & sub)
  if not scan.ok: return scan.rep
  case sub
  of "list": runParamList(ctx, scan)
  of "get": runParamGet(ctx, scan)
  of "set": runParamSet(ctx, scan)
  else:
    usageError("неизвестная подкоманда param: " & sub,
               "подкоманды: " & ParamSubcommands.join(", "))

proc runConnectCommand*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia connect <источник> <приёмник>` (MANIFEST §19).
  let scan = scanArgs(args, "connect")
  if not scan.ok: return scan.rep
  runConnect(ctx, scan)

proc runDisconnectCommand*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia disconnect <источник> <приёмник>`.
  let scan = scanArgs(args, "disconnect")
  if not scan.ok: return scan.rep
  runDisconnect(ctx, scan)

proc runGraph*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia graph <check>`.
  if args.len == 0:
    return usageError("graph требует подкоманду",
                      "подкоманды: " & GraphSubcommands.join(", "))
  let sub = args[0]
  let scan = scanArgs(argsTail(args), "graph " & sub)
  if not scan.ok: return scan.rep
  case sub
  of "check": runGraphCheck(ctx, scan)
  else:
    usageError("неизвестная подкоманда graph: " & sub,
               "подкоманды: " & GraphSubcommands.join(", "))
