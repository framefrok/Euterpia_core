# cli/catalog.nim
#
# Каталог официальных нод, доступный CLI (issue #90).
#
# Зачем отдельный модуль:
#   `node add` обязан превратить имя типа из команды в ОПИСАТЕЛЬ (порты,
#   параметры, умолчания), а `param set` — проверить имя параметра и
#   диапазон ДО записи файла: иначе «команда прошла», а проект потом не
#   звучит. Оба ответа даёт реестр нод (nodes/sdk), а не догадки CLI.
#
# Границы (§20): каталог ничего не создаёт и не хранит состояния — только
# читает статические дескрипторы. Реестр собирается на вызов: общий
# изменяемый кэш в CLI был бы скрытым глобальным состоянием (§72), а
# регистрация — это запись N указателей.

import std/[algorithm, strutils]

import sdk/node_api
import sdk/node_registry
import builtin/builtin_registry

const
  PortKindNames* = ["audio", "ctrl", "event"]
    ## Имена видов портов в CLI. Порядок совпадает с SignalType
    ## (`sigAudio`, `sigControl`, `sigEvent`) — тем самым «audio» = 0.
    ## Один список для разбора, текста ошибки и справки: подсказка не может
    ## разойтись с кодом.

type
  PortKind* = enum
    pkAudio = 0, pkCtrl = 1, pkEvent = 2

  ParamInfo* = object
    id*: uint32
    name*: string
    flags*: uint32
    minValue*, maxValue*, defaultValue*, step*: float32

  NodeTypeInfo* = object
    id*, name*, category*: string
    audioIn*, audioOut*: int
    ctrlIn*, ctrlOut*: int
    eventIn*, eventOut*: int
    latencyFrames*: int
    params*: seq[ParamInfo]

# =============================================================================
# Разбор элементов описателя
# =============================================================================

proc portKindName*(kind: PortKind): string =
  PortKindNames[ord(kind)]

proc parsePortKind*(text: string; kind: var PortKind): bool =
  ## «audio» | «ctrl» | «control» | «event». Пустая строка не является видом
  ## порта: это отдельный случай, который команда решает по контексту
  ## (`NODE:out` — аудио, потому что так устроен пример MANIFEST §19).
  case text.toLowerAscii()
  of "audio": kind = pkAudio; true
  of "ctrl", "control": kind = pkCtrl; true
  of "event", "midi": kind = pkEvent; true
  else: false

proc flagNames*(flags: uint32): seq[string] =
  ## Флаги параметра человеческим языком. Порядок — как в `NodeParamFlag`.
  for flag in NodeParamFlagOrder:
    if (flags and uint32(flag)) != 0:
      case flag
      of npfAutomatable: result.add "automatable"
      of npfModulatable: result.add "modulatable"
      of npfInteger: result.add "integer"
      of npfChoice: result.add "choice"
      of npfHidden: result.add "hidden"

proc hasFlag*(p: ParamInfo; flag: NodeParamFlag): bool {.inline.} =
  (p.flags and uint32(flag)) != 0

proc paramIsInteger*(p: ParamInfo): bool {.inline.} =
  p.hasFlag(npfInteger) or p.hasFlag(npfChoice)

proc paramIsAutomatable*(p: ParamInfo): bool {.inline.} =
  p.hasFlag(npfAutomatable)

proc paramIsModulatable*(p: ParamInfo): bool {.inline.} =
  p.hasFlag(npfModulatable)

proc paramIsHidden*(p: ParamInfo): bool {.inline.} =
  p.hasFlag(npfHidden)

proc paramInfo*(p: NodeParamDesc): ParamInfo =
  ParamInfo(
    id: p.id,
    name: readFixed(p.name),
    flags: p.flags,
    minValue: p.minValue,
    maxValue: p.maxValue,
    defaultValue: p.defaultValue,
    step: p.step
  )

proc nodeTypeInfo*(desc: ptr NodeDesc): NodeTypeInfo =
  ## Описатель — единственный источник: CLI не дописывает порты «на глаз».
  result.id = readFixed(desc.id)
  result.name = readFixed(desc.name)
  result.category = readFixed(desc.category)
  result.audioIn = int(desc.audioInCount)
  result.audioOut = int(desc.audioOutCount)
  result.ctrlIn = int(desc.ctrlInCount)
  result.ctrlOut = int(desc.ctrlOutCount)
  result.eventIn = int(desc.eventInCount)
  result.eventOut = int(desc.eventOutCount)
  result.latencyFrames = int(desc.latencyFrames)
  for i in 0 ..< int(desc.paramCount):
    result.params.add paramInfo(desc.params[i])

# =============================================================================
# Каталог
# =============================================================================

proc builtinRegistry*(): NodeRegistry =
  ## Реестр официальных нод. Собирается на каждый вызов: регистрация — это
  ## запись N указателей на статические описатели, а общего изменяемого
  ## состояния в CLI быть не должно (§72).
  result = initNodeRegistry()
  discard registerBuiltinNodes(result)

proc catalog*(): seq[NodeTypeInfo] =
  ## Типы нод официального набора, по возрастанию id. Порядок задаёт CLI:
  ## порядок регистрации — деталь реализации (§81), а вывод команды обязан
  ## быть сравнимым между запусками (#88).
  for entry in builtinRegistry():
    result.add nodeTypeInfo(entry.desc)
  result.sort(proc(a, b: NodeTypeInfo): int = cmp(a.id, b.id))

proc typeIdSuffix*(id: string): string =
  ## `euterpia.osc` → `osc`. Короткая форма — для сценариев, где писать
  ## полный id долго; полный id остаётся каноническим (§84).
  let dot = id.rfind('.')
  if dot >= 0 and dot + 1 < id.len: id[dot + 1 .. ^1] else: id

proc matchesType*(info: NodeTypeInfo; query: string): bool =
  ## По чему ищется тип: полный id, короткий id, отображаемое имя. Категория
  ## НЕ участвует: «generator» — это два разных типа (Oscillator, Noise),
  ## и угадывать за пользователя запрещено (§82).
  let q = query.toLowerAscii()
  q.len > 0 and
    (info.id.toLowerAscii() == q or
     typeIdSuffix(info.id).toLowerAscii() == q or
     info.name.toLowerAscii() == q)

proc findType*(cat: seq[NodeTypeInfo]; query: string): int =
  ## Индекс типа по запросу или -1. Однозначность проверяет вызывающий:
  ## список совпадений нужен ему для текста ошибки.
  for i in 0 ..< cat.len:
    if matchesType(cat[i], query):
      return i
  -1

proc matchingTypes*(cat: seq[NodeTypeInfo]; query: string): seq[int] =
  for i in 0 ..< cat.len:
    if matchesType(cat[i], query):
      result.add i

proc typeIds*(cat: seq[NodeTypeInfo]): seq[string] =
  for info in cat:
    result.add info.id

proc findParam*(info: NodeTypeInfo; query: string): int =
  ## Параметр по имени или по числовому id (стабильная ссылка: проект,
  ## автоматизация и CLI ссылаются на id, а не на название). -1 — нет такого.
  if query.len == 0:
    return -1
  if query.allCharsInSet({'0'..'9'}):
    let numeric = parseInt(query)
    for i in 0 ..< info.params.len:
      if info.params[i].id == uint32(numeric):
        return i
  for i in 0 ..< info.params.len:
    if cmpIgnoreCase(info.params[i].name, query) == 0:
      return i
  -1

proc portCount*(info: NodeTypeInfo; kind: PortKind; isOut: bool): int =
  ## Сколько портов данного вида у ноды в данном направлении.
  case kind
  of pkAudio: result = (if isOut: info.audioOut else: info.audioIn)
  of pkCtrl: result = (if isOut: info.ctrlOut else: info.ctrlIn)
  of pkEvent: result = (if isOut: info.eventOut else: info.eventIn)
