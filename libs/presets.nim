# libs/presets.nim
#
# Шаблоны, сет-листы и пресеты параметров как ДАННЫЕ (issues #341–#343).
#
# Зачем библиотека:
#   Собрать рабочий проект с нуля — это десятки команд, и они каждый раз
#   пишутся заново. Заготовки («гитара + бас + ударные + сведение», «как
#   обычно звучит панк», «тёплый виолончельный») повторяются от пьесы к пьесе,
#   но жили в примерах `compositions/`, то есть в коде, а не в данных.
#
# Границы (§20):
#   ЗДЕСЬ — форма трёх файлов, их проверка по реестру нод и превращение в
#   команды control-слоя. НЕ ЗДЕСЬ — разбор argv, печать, поиск файла проекта
#   и запись истории: это дело клиента. Библиотека не читает `cli/`.
#
# Почему результат — команды, а не готовый `ProjectFormat`:
#   * применение к существующему проекту обязано быть транзакцией (#341), а
#     транзакция принимает именно команды (`Document.applyTransaction`);
#   * `init --preset` — тот же `script build`, где шаблон поставляет команды,
#     а не второй путь сборки (#416): один путь — один звук;
#   * шаблон проверяется реестром ДО применения, поэтому «половины шаблона» не
#     бывает: неизвестный тип назван кодом причины, а не превращается в
#     «получилось не то».
#
# Формат файла узнаётся по содержимому (`format`), а не по расширению
# (§19/§58): расширения — подпись для человека, версия — контракт.
#
# Связь ролей: дорожка и её голос связаны ИМЕНЕМ (дорожка `lead` → ноты
# `lead` → инструмент `Lead`). Так партия попадает в звук через секвенсор,
# а пресет параметров находит голос по роли и типу, не угадывая граф.

import std/[algorithm, json, os, strutils, tables]

import project
import control/commands
import control/error_frame
import script
import sdk/node_api
import sdk/node_registry

const
  PresetFormatName* = "euterpia.preset"
  PresetFormatVersion* = 1
    ## Шаблон проекта: ноды с параметрами, связи, дорожки и необязательная
    ## партитура. Версия поднимается только при несовместимом изменении полей.

  SetlistFormatName* = "euterpia.setlist"
  SetlistFormatVersion* = 1
    ## Сет-лист: базовая партия поверх шаблона — состав пьесы, а не копия
    ## проекта.

  ParamPresetFormatName* = "euterpia.param-preset"
  ParamPresetFormatVersion* = 1
    ## Пресет параметров: «одна настройка на набор нот» — роль/тип ноды →
    ## значения параметров.

  PresetSuffix* = ".preset.json"
  SetlistSuffix* = ".setlist.json"
  ParamPresetSuffix* = ".params.json"
    ## Расширения не совпадают ни с проектом, ни со сценарием: «какой
    ## аргумент — что» решается одним списком, а не догадкой.

  NotesNodeType* = "euterpia.notes"
    ## Нода, которую секвенсор наполняет событиями клипа. Тип стабилен: по
    ## нему проверяется, что партия дорожки вообще попадёт в звук.

  SignalNames* = ["audio", "ctrl", "event"]
    ## Те же имена и тот же порядок, что у `SignalType` и `cli/catalog`:
    ## файл шаблона читается человеком, а не только программой.

  DefaultPresetsDir* = "presets"
    ## Каталог заготовок в репозитории и в поставке.
  PresetsEnv* = "EUTERPIA_PRESETS"
    ## Дополнительный каталог поиска (поставка, чужие наборы).

type
  PresetKind* = enum
    pkTemplate, pkSetlist, pkParams
      ## Вид файла: шаблон, сет-лист, пресет параметров.

  PresetParam* = object
    ## Значение параметра в шаблоне/пресете.
    name*: string
    value*: float32

  PresetNode* = object
    ## Нода шаблона. `id` не хранится: порядок в массиве — это и есть id
    ## (1..N). Так файл нельзя испортить повторяющимся id, а применение к
    ## существующему проекту всё равно пересчитывает id (`idBase`).
    nodeType*: string
    name*: string
    params*: seq[PresetParam]

  PresetConnection* = object
    ## Связь по ИМЕНАМ нод: файл читается человеком, а id назначает сборка.
    srcNode*, dstNode*: string
    srcPort*, dstPort*: int
    sigType*: int
      ## 0 — audio, 1 — ctrl, 2 — event (`SignalType`).

  PresetClip* = object
    name*: string
    lengthTicks*: int32
    loopEnabled*: bool
    notes*: seq[NoteFormat]

  PresetTrack* = object
    ## Дорожка шаблона. Имя дорожки = роль: по нему секвенсор находит ноду
    ## `euterpia.notes`, а пресет параметров — голос.
    name*: string
    clip*: PresetClip

  ProjectPreset* = object
    ## Разобранный шаблон проекта.
    name*, description*: string
    tempo*, sampleRate*: float32
    tsNum*, tsDen*: int32
    nodes*: seq[PresetNode]
    connections*: seq[PresetConnection]
    tracks*: seq[PresetTrack]

  SetlistPart* = object
    ## Партия сет-листа: дорожка (она же роль), клип и типичное сведение.
    track*: string
    clipName*: string
    lengthTicks*: int32
    loopEnabled*: bool
    notes*: seq[NoteFormat]
    mix*: seq[PresetParam]
      ## Сведение голоса этой партии: `level`, `pan` и что ещё знает тип.

  Setlist* = object
    ## Разобранный сет-лист: шаблон + партии.
    name*, description*: string
    preset*: string
      ## Имя шаблона, поверх которого собирается пьеса.
    parts*: seq[SetlistPart]

  ParamPreset* = object
    ## Разобранный пресет параметров.
    name*, description*: string
    nodeType*: string
      ## К какому типу применим. Несовместимый тип — отказ, а не «наполовину».
    role*: string
      ## Необязательная роль: пусто — все ноды типа, иначе только голос
      ## дорожки с этим именем.
    params*: seq[PresetParam]

  PresetSummary* = object
    ## Краткое описание файла для `preset list`/`setlist list`.
    name*, description*, path*: string
    nodes*, tracks*, parts*, params*: int

  ProjectIndex* = object
    ## Срез проекта (или шаблона), по которому сет-лист решает «что добавить,
    ## а что обновить». Собирается клиентом через Query API; библиотека не
    ## читает документ сама — иначе она зависела бы от сессии.
    trackNames*: seq[string]
    trackClips*: seq[int]
    nodeIds*: seq[int32]
    nodeTypes*: seq[string]
    nodeNames*: seq[string]
    nodeParams*: seq[seq[string]]
# =============================================================================
# Ошибки и мелкие проверки
# =============================================================================

proc presetError(message: string; hint = "";
                 code = ecInvalidArgument): ErrorFrame =
  ## Ошибка данных пресета. Код причины различает «тип неизвестен» и «поле не
  ## то» — агент не разбирает текст.
  errFrame(code, message, hint)

proc typeHint(): string =
  "типы нод: `euterpia node types`; параметры: `euterpia node params <тип>`"

proc describeValue(value: float32): string =
  ## Число в сообщении без «1.2345678»: значение из файла показывается так,
  ## как его увидит человек.
  $value

# =============================================================================
# JSON: разбор
# =============================================================================

proc parseNotes(node: JsonNode; notes: var seq[NoteFormat];
                where: string): ErrorFrame =
  ## Ноты клипа: `start`, `duration`, `pitch`, `velocity`, `channel`.
  ## Имена полей человеческие, а не `startTick`: файл читает человек.
  if node.isNil:
    return okFrame()
  if node.kind != JArray:
    return presetError(where & ": ожидается массив нот")
  var index = 0
  for item in node:
    if item.kind != JObject:
      return presetError(where & "[" & $index & "]: нота должна быть объектом")
    var note = NoteFormat()
    try:
      note.startTick = int32(item{"start"}.getInt(0))
      note.duration = int32(item{"duration"}.getInt(0))
      note.pitch = uint8(item{"pitch"}.getInt(60))
      note.velocity = uint8(item{"velocity"}.getInt(100))
      note.channel = uint8(item{"channel"}.getInt(0))
    except CatchableError:
      return presetError(where & "[" & $index & "]: поля ноты должны быть целыми",
                         "ожидаются start, duration, pitch, velocity, channel")
    if note.duration <= 0:
      return presetError(where & "[" & $index & "].duration: должно быть > 0")
    if note.startTick < 0:
      return presetError(where & "[" & $index & "].start: должно быть >= 0")
    if note.pitch > 127:
      return presetError(where & "[" & $index & "].pitch: MIDI-нота 0..127")
    if note.velocity > 127:
      return presetError(where & "[" & $index & "].velocity: 0..127")
    notes.add note
    inc index
  okFrame()

proc parseParams(node: JsonNode; params: var seq[PresetParam];
                 where: string): ErrorFrame =
  ## Параметры — объект «имя: число»: в файле видно, что именно настраивается.
  if node.isNil:
    return okFrame()
  if node.kind != JObject:
    return presetError(where & ": параметры задаются объектом «имя: число»")
  for name, value in node:
    if value.kind notin {JInt, JFloat}:
      return presetError(where & "." & name & ": ожидается число")
    params.add PresetParam(name: name, value: float32(value.getFloat))
  # Порядок в файле не должен влиять на документ: параметры — множество, а не
  # последовательность. Сортировка делает сборку воспроизводимой.
  params.sort(proc(a, b: PresetParam): int = cmp(a.name, b.name))
  okFrame()

proc parseFormat(node: JsonNode; expected: string; version: int;
                 what: string): ErrorFrame =
  ## Проверка «это файл нужного вида и не новее сборки». Текст ошибки называет
  ## файл, а не «неверный JSON»: иначе ошибка в шаблоне выглядит как сбой.
  if node.kind != JObject:
    return presetError(what & ": ожидается JSON-объект")
  let format = node{"format"}.getStr("")
  if format != expected:
    return presetError(what & ": это не " & what & " (format = " &
                       (if format.len > 0: format else: "пусто") & ")",
                       "ожидается format «" & expected & "»")
  let found = node{"version"}.getInt(0)
  if found > version:
    return presetError(what & ": версия формата " & $found &
                       " новее этой сборки (" & $version & ")",
                       "обновите euterpia")
  if found <= 0:
    return presetError(what & ": не указана версия формата",
                       "ожидается version = " & $version)
  okFrame()


proc parsePresetNode(node: JsonNode; outNode: var PresetNode;
                     where: string): ErrorFrame =
  if node.kind != JObject:
    return presetError(where & ": нода должна быть объектом")
  outNode.nodeType = node{"type"}.getStr("")
  outNode.name = node{"name"}.getStr("")
  if outNode.nodeType.len == 0:
    return presetError(where & ".type: не указан тип ноды", typeHint())
  if outNode.name.len == 0:
    return presetError(where & ".name: не указано имя ноды",
                       "имя нужно связям и роли дорожки")
  parseParams(node{"params"}, outNode.params, where & ".params")

proc parsePresetJson*(node: JsonNode; preset: var ProjectPreset): ErrorFrame =
  ## Разобрать шаблон из уже разобранного JSON.
  let format = parseFormat(node, PresetFormatName, PresetFormatVersion, "шаблон")
  if not format.isOk():
    return format
  preset.name = node{"name"}.getStr("")
  preset.description = node{"description"}.getStr("")
  if preset.name.len == 0:
    return presetError("шаблон: не указано имя (`name`)",
                       "имя — то, что пишут в `init --preset`")
  preset.tempo = float32(node{"tempo"}.getFloat(0.0))
  preset.sampleRate = float32(node{"sampleRate"}.getFloat(0.0))
  let ts = node{"timeSignature"}
  if not ts.isNil and ts.kind == JObject:
    preset.tsNum = int32(ts{"numerator"}.getInt(0))
    preset.tsDen = int32(ts{"denominator"}.getInt(0))

  let nodes = node{"nodes"}
  if nodes.isNil or nodes.kind != JArray or nodes.len == 0:
    return presetError("шаблон " & preset.name & ": нет нод",
                       "шаблон без нод не создаёт проект")
  var index = 0
  for item in nodes:
    var parsed: PresetNode
    let err = parsePresetNode(item, parsed, "nodes[" & $index & "]")
    if not err.isOk():
      return err
    preset.nodes.add parsed
    inc index

  let connections = node{"connections"}
  if not connections.isNil and connections.kind != JArray:
    return presetError("шаблон " & preset.name & ".connections: ожидается массив")
  index = 0
  if not connections.isNil:
    for item in connections:
      if item.kind != JObject:
        return presetError("connections[" & $index & "]: связь должна быть объектом")
      var conn = PresetConnection()
      let src = item{"from"}
      let dst = item{"to"}
      if src.isNil or dst.isNil or src.kind != JObject or dst.kind != JObject:
        return presetError("connections[" & $index & "]: ожидаются `from` и `to`",
                           "например: {\"from\":{\"node\":\"lead\",\"port\":0}, …}")
      conn.srcNode = src{"node"}.getStr("")
      conn.dstNode = dst{"node"}.getStr("")
      conn.srcPort = src{"port"}.getInt(0)
      conn.dstPort = dst{"port"}.getInt(0)
      conn.sigType = item{"signal"}.getInt(0)
      if conn.srcNode.len == 0 or conn.dstNode.len == 0:
        return presetError("connections[" & $index & "]: не указана нода")
      preset.connections.add conn
      inc index

  let tracks = node{"tracks"}
  if not tracks.isNil and tracks.kind != JArray:
    return presetError("шаблон " & preset.name & ".tracks: ожидается массив")
  index = 0
  if not tracks.isNil:
    for item in tracks:
      if item.kind != JObject:
        return presetError("tracks[" & $index & "]: дорожка должна быть объектом")
      var track = PresetTrack()
      track.name = item{"name"}.getStr("")
      if track.name.len == 0:
        return presetError("tracks[" & $index & "].name: не указано имя дорожки")
      let clip = item{"clip"}
      if not clip.isNil and clip.kind == JObject:
        track.clip.name = clip{"name"}.getStr(track.name)
        track.clip.lengthTicks = int32(clip{"lengthTicks"}.getInt(0))
        track.clip.loopEnabled = clip{"loop"}.getBool(false)
        let err = parseNotes(clip{"notes"}, track.clip.notes,
                             "tracks[" & $index & "].clip.notes")
        if not err.isOk():
          return err
      preset.tracks.add track
      inc index
  okFrame()

proc parsePreset*(text: string; preset: var ProjectPreset): ErrorFrame =
  ## Разобрать шаблон из текста файла.
  var node: JsonNode
  try:
    node = parseJson(text)
  except JsonParsingError as e:
    return presetError("шаблон не разобран: " & e.msg,
                       "файл шаблона — JSON с полем format")
  except CatchableError as e:
    return presetError("шаблон не разобран: " & e.msg)
  parsePresetJson(node, preset)


proc parseSetlistJson*(node: JsonNode; setlist: var Setlist): ErrorFrame =
  ## Разобрать сет-лист.
  let format = parseFormat(node, SetlistFormatName, SetlistFormatVersion,
                           "сет-лист")
  if not format.isOk():
    return format
  setlist.name = node{"name"}.getStr("")
  setlist.description = node{"description"}.getStr("")
  setlist.preset = node{"preset"}.getStr("")
  if setlist.name.len == 0:
    return presetError("сет-лист: не указано имя (`name`)")
  if setlist.preset.len == 0:
    return presetError("сет-лист " & setlist.name & ": не указан шаблон (`preset`)",
                       "сет-лист собирается поверх шаблона: init --preset …")
  let parts = node{"parts"}
  if parts.isNil or parts.kind != JArray or parts.len == 0:
    return presetError("сет-лист " & setlist.name & ": нет партий (`parts`)")
  var index = 0
  for item in parts:
    if item.kind != JObject:
      return presetError("parts[" & $index & "]: партия должна быть объектом")
    var part = SetlistPart()
    part.track = item{"track"}.getStr("")
    part.clipName = item{"clip"}.getStr(part.track)
    part.lengthTicks = int32(item{"lengthTicks"}.getInt(0))
    part.loopEnabled = item{"loop"}.getBool(false)
    if part.track.len == 0:
      return presetError("parts[" & $index & "].track: не указана роль дорожки")
    let notes = item{"notes"}
    if not notes.isNil and notes.kind == JArray:
      let err = parseNotes(notes, part.notes, "parts[" & $index & "].notes")
      if not err.isOk():
        return err
    let mix = item{"mix"}
    let err = parseParams(mix, part.mix, "parts[" & $index & "].mix")
    if not err.isOk():
      return err
    setlist.parts.add part
    inc index
  okFrame()

proc parseSetlist*(text: string; setlist: var Setlist): ErrorFrame =
  var node: JsonNode
  try:
    node = parseJson(text)
  except JsonParsingError as e:
    return presetError("сет-лист не разобран: " & e.msg)
  except CatchableError as e:
    return presetError("сет-лист не разобран: " & e.msg)
  parseSetlistJson(node, setlist)

proc parseParamPresetJson*(node: JsonNode; preset: var ParamPreset): ErrorFrame =
  ## Разобрать пресет параметров.
  let format = parseFormat(node, ParamPresetFormatName,
                           ParamPresetFormatVersion, "пресет параметров")
  if not format.isOk():
    return format
  preset.name = node{"name"}.getStr("")
  preset.description = node{"description"}.getStr("")
  preset.nodeType = node{"nodeType"}.getStr("")
  preset.role = node{"role"}.getStr("")
  if preset.name.len == 0:
    return presetError("пресет параметров: не указано имя (`name`)")
  if preset.nodeType.len == 0:
    return presetError("пресет " & preset.name & ": не указан тип ноды (`nodeType`)",
                       typeHint())
  let err = parseParams(node{"params"}, preset.params, "params")
  if not err.isOk():
    return err
  if preset.params.len == 0:
    return presetError("пресет " & preset.name & ": нет параметров")
  okFrame()

proc parseParamPreset*(text: string; preset: var ParamPreset): ErrorFrame =
  var node: JsonNode
  try:
    node = parseJson(text)
  except JsonParsingError as e:
    return presetError("пресет параметров не разобран: " & e.msg)
  except CatchableError as e:
    return presetError("пресет параметров не разобран: " & e.msg)
  parseParamPresetJson(node, preset)


# =============================================================================
# JSON: запись
# =============================================================================
# Порядок полей фиксирован, параметры отсортированы: повторная запись того же
# шаблона даёт байт-в-байт тот же файл (#88). Файлы шаблонов лежат в
# репозитории, и шум от перестановки ключей мешал бы ревью.

proc notesJson(notes: seq[NoteFormat]): JsonNode =
  result = newJArray()
  for note in notes:
    var item = newJObject()
    item["start"] = %note.startTick
    item["duration"] = %note.duration
    item["pitch"] = %note.pitch
    item["velocity"] = %note.velocity
    if note.channel != 0:
      item["channel"] = %note.channel
    result.add item

proc paramsJson(params: seq[PresetParam]): JsonNode =
  result = newJObject()
  var sorted = params
  sorted.sort(proc(a, b: PresetParam): int = cmp(a.name, b.name))
  for param in sorted:
    result[param.name] = %param.value

proc presetJson*(preset: ProjectPreset): JsonNode =
  result = newJObject()
  result["format"] = %PresetFormatName
  result["version"] = %PresetFormatVersion
  result["name"] = %preset.name
  if preset.description.len > 0:
    result["description"] = %preset.description
  if preset.tempo > 0.0:
    result["tempo"] = %preset.tempo
  if preset.sampleRate > 0.0:
    result["sampleRate"] = %preset.sampleRate
  if preset.tsNum > 0 and preset.tsDen > 0:
    result["timeSignature"] = %*{"numerator": preset.tsNum,
                                 "denominator": preset.tsDen}
  # Ноды — массивом: порядок задаёт id, и он же виден в файле.
  var nodes = newJArray()
  for node in preset.nodes:
    var item = newJObject()
    item["type"] = %node.nodeType
    item["name"] = %node.name
    if node.params.len > 0:
      item["params"] = paramsJson(node.params)
    nodes.add item
  result["nodes"] = nodes
  var connections = newJArray()
  for conn in preset.connections:
    connections.add %*{
      "from": {"node": conn.srcNode, "port": conn.srcPort},
      "to": {"node": conn.dstNode, "port": conn.dstPort},
      "signal": conn.sigType,
    }
  result["connections"] = connections
  var tracks = newJArray()
  for track in preset.tracks:
    var item = newJObject()
    item["name"] = %track.name
    var clip = newJObject()
    if track.clip.name.len > 0:
      clip["name"] = %track.clip.name
    clip["lengthTicks"] = %track.clip.lengthTicks
    if track.clip.loopEnabled:
      clip["loop"] = %true
    clip["notes"] = notesJson(track.clip.notes)
    item["clip"] = clip
    tracks.add item
  result["tracks"] = tracks

proc encodePreset*(preset: ProjectPreset): string =
  ## Каноническая запись шаблона: тот же JSON, что читается.
  $presetJson(preset)


proc setlistJson*(setlist: Setlist): JsonNode =
  result = newJObject()
  result["format"] = %SetlistFormatName
  result["version"] = %SetlistFormatVersion
  result["name"] = %setlist.name
  if setlist.description.len > 0:
    result["description"] = %setlist.description
  result["preset"] = %setlist.preset
  var parts = newJArray()
  for part in setlist.parts:
    var item = newJObject()
    item["track"] = %part.track
    item["clip"] = %part.clipName
    item["lengthTicks"] = %part.lengthTicks
    if part.loopEnabled:
      item["loop"] = %true
    item["notes"] = notesJson(part.notes)
    if part.mix.len > 0:
      item["mix"] = paramsJson(part.mix)
    parts.add item
  result["parts"] = parts

proc encodeSetlist*(setlist: Setlist): string =
  $setlistJson(setlist)

proc paramPresetJson*(preset: ParamPreset): JsonNode =
  result = newJObject()
  result["format"] = %ParamPresetFormatName
  result["version"] = %ParamPresetFormatVersion
  result["name"] = %preset.name
  if preset.description.len > 0:
    result["description"] = %preset.description
  result["nodeType"] = %preset.nodeType
  if preset.role.len > 0:
    result["role"] = %preset.role
  result["params"] = paramsJson(preset.params)

proc encodeParamPreset*(preset: ParamPreset): string =
  $paramPresetJson(preset)

# =============================================================================
# Чтение файлов и поиск по каталогам
# =============================================================================

proc readTextFile(path, what: string; text: var string): ErrorFrame =
  ## Нет файла — данные (неверное имя), нет прав — среда. Разделение то же,
  ## что у `libs/script`: пользователь должен видеть «не тот путь» и «нет
  ## доступа» разными кодами.
  if not fileExists(path):
    return errFrame(ecNotFound, "нет такого " & what & ": " & path,
                    "список: `euterpia preset list`")
  try:
    text = readFile(path)
  except CatchableError as e:
    return errFrame(ecEnvironment, "не удалось прочитать " & what & ": " & e.msg,
                    "проверьте права: " & path)
  okFrame()

proc loadPresetFile*(path: string; preset: var ProjectPreset): ErrorFrame =
  var text = ""
  let read = readTextFile(path, "шаблона", text)
  if not read.isOk():
    return read
  parsePreset(text, preset)

proc loadSetlistFile*(path: string; setlist: var Setlist): ErrorFrame =
  var text = ""
  let read = readTextFile(path, "сет-листа", text)
  if not read.isOk():
    return read
  parseSetlist(text, setlist)

proc loadParamPresetFile*(path: string; preset: var ParamPreset): ErrorFrame =
  var text = ""
  let read = readTextFile(path, "пресета параметров", text)
  if not read.isOk():
    return read
  parseParamPreset(text, preset)

proc suffixOf*(kind: PresetKind): string =
  case kind
  of pkTemplate: PresetSuffix
  of pkSetlist: SetlistSuffix
  of pkParams: ParamPresetSuffix

proc kindName*(kind: PresetKind): string =
  case kind
  of pkTemplate: "шаблон"
  of pkSetlist: "сет-лист"
  of pkParams: "пресет параметров"

proc kindDir*(kind: PresetKind): string =
  ## Подкаталог внутри `presets/`: по нему файлы ищутся без полного пути.
  case kind
  of pkTemplate: "templates"
  of pkSetlist: "setlists"
  of pkParams: "params"


proc presetSearchDirs*(kind: PresetKind): seq[string] =
  ## Где искать файлы: текущий каталог (репозиторий), каталог рядом с бинарём
  ## (поставка), `EUTERPIA_PRESETS` и пользовательский каталог настроек.
  ## Один список на все команды: `preset list` и `init --preset` видят одно и
  ## то же, иначе «в списке есть, а применить нельзя».
  var dirs: seq[string] = @[]
  proc addUnique(dir: string) =
    if dir.len > 0 and dir notin dirs:
      dirs.add dir
  let sub = kindDir(kind)
  addUnique(DefaultPresetsDir / sub)
  addUnique(getAppDir() / DefaultPresetsDir / sub)
  let envDir = getEnv(PresetsEnv)
  if envDir.len > 0:
    for part in envDir.split(PathSep):
      if part.len > 0:
        addUnique(part / sub)
        addUnique(part)
  let xdg = getEnv("XDG_CONFIG_HOME")
  let configHome = if xdg.len > 0: xdg else: getHomeDir() / ".config"
  addUnique(configHome / "euterpia" / DefaultPresetsDir / sub)
  result = dirs

type
  PresetCatalog* = object
    ## Найденные файлы одного вида и файлы, которые не разобрались. Второе
    ## показывается списком, а не прячется: сломанный шаблон в репозитории —
    ## это находка, а не повод молча его пропустить.
    items*: seq[PresetSummary]
    problems*: seq[string]

proc summaryOf*(kind: PresetKind; path: string): tuple[ok: bool;
                                                       summary: PresetSummary;
                                                       problem: string] =
  ## Разобрать файл ради списка. Имя — из файла, а если файл не разобрался —
  ## из имени файла: пользователь должен узнать «что именно сломано».
  let stem = extractFilename(path)
  result.summary = PresetSummary(
    name: stem[0 ..< max(0, stem.len - suffixOf(kind).len)],
    path: path)
  try:
    let text = readFile(path)
    var node: JsonNode
    try:
      node = parseJson(text)
    except CatchableError as e:
      result.problem = path & ": не разобран: " & e.msg
      return
    case kind
    of pkTemplate:
      var preset: ProjectPreset
      let err = parsePresetJson(node, preset)
      if not err.isOk():
        result.problem = path & ": " & err.message
        return
      result.summary.name = preset.name
      result.summary.description = preset.description
      result.summary.nodes = preset.nodes.len
      result.summary.tracks = preset.tracks.len
    of pkSetlist:
      var setlist: Setlist
      let err = parseSetlistJson(node, setlist)
      if not err.isOk():
        result.problem = path & ": " & err.message
        return
      result.summary.name = setlist.name
      result.summary.description = setlist.description
      result.summary.parts = setlist.parts.len
    of pkParams:
      var preset: ParamPreset
      let err = parseParamPresetJson(node, preset)
      if not err.isOk():
        result.problem = path & ": " & err.message
        return
      result.summary.name = preset.name
      result.summary.description = preset.description
      result.summary.params = preset.params.len
  except CatchableError as e:
    result.problem = path & ": не прочитан: " & e.msg
    return
  result.ok = true

proc catalogOf*(kind: PresetKind; dirs: seq[string]): PresetCatalog =
  ## Все файлы вида в каталогах поиска. Порядок — по имени: вывод команды
  ## обязан быть сравнимым между запусками (#88).
  let suffix = suffixOf(kind)
  var seen: seq[string] = @[]
  for dir in dirs:
    if not dirExists(dir):
      continue
    for path in walkFiles(dir / ("*" & suffix)):
      let absolute = absolutePath(path)
      if absolute in seen:
        continue
      seen.add absolute
      let parsed = summaryOf(kind, absolute)
      if parsed.ok:
        result.items.add parsed.summary
      else:
        result.problems.add parsed.problem
  result.items.sort(proc(a, b: PresetSummary): int =
    result = cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
    if result == 0:
      result = cmp(a.path, b.path))

proc availableNames*(kind: PresetKind; dirs: seq[string]): seq[string] =
  for item in catalogOf(kind, dirs).items:
    result.add item.name

proc findPreset*(kind: PresetKind; nameOrPath: string;
                 dirs: seq[string]):
    tuple[ok: bool; path: string; available: seq[string]] =
  ## Файл по имени или пути. Путь сильнее имени: `preset apply ./my.preset.json`
  ## работает даже без каталога поиска. Возвращает список доступных имён —
  ## подсказка об ошибке перечисляет настоящий набор, а не «не найдено».
  result.available = availableNames(kind, dirs)
  if nameOrPath.len == 0:
    return
  if fileExists(nameOrPath):
    result.ok = true
    result.path = nameOrPath
    return
  # Имя без расширения и с расширением — одна и та же заготовка.
  let suffix = suffixOf(kind)
  let plain =
    if nameOrPath.toLowerAscii().endsWith(suffix):
      nameOrPath[0 ..< nameOrPath.len - suffix.len]
    else:
      nameOrPath
  for dir in dirs:
    if not dirExists(dir):
      continue
    let direct = dir / (plain & suffix)
    if fileExists(direct):
      result.ok = true
      result.path = direct
      return
  for item in catalogOf(kind, dirs).items:
    if cmpIgnoreCase(item.name, plain) == 0:
      result.ok = true
      result.path = item.path
      return


# =============================================================================
# Проверка по реестру нод
# =============================================================================
# Проверка идёт ДО применения: шаблон не может «наполовину» создать проект.
# Неизвестный тип — отдельный код причины (`ecNotFound`), а не «поле не то»:
# агент по коду отличает «обновите euterpia/плагин» от «исправьте значение».

proc typeDesc(reg: NodeRegistry; nodeType: string): ptr NodeDesc =
  let entry = reg.findNodeType(nodeType)
  if entry.isNil: nil else: entry.desc

proc portCountOf(desc: ptr NodeDesc; sigType: int; isOut: bool): int =
  if desc.isNil or sigType < 0 or sigType > 2:
    return -1
  case sigType
  of 0: (if isOut: int(desc.audioOutCount) else: int(desc.audioInCount))
  of 1: (if isOut: int(desc.ctrlOutCount) else: int(desc.ctrlInCount))
  else: (if isOut: int(desc.eventOutCount) else: int(desc.eventInCount))

proc findParam(desc: ptr NodeDesc; name: string): int =
  if desc.isNil:
    return -1
  for i in 0 ..< int(desc.paramCount):
    if readFixed(desc.params[i].name) == name:
      return i
  -1

proc checkParams(desc: ptr NodeDesc; params: seq[PresetParam]; owner: string;
                 typeName: string): ErrorFrame =
  ## Параметры: имя есть у типа и значение в диапазоне. Значение вне диапазона
  ## — отказ, а не молчаливый clamp: иначе шаблон звучал бы не так, как
  ## написано, и никто бы не узнал.
  for param in params:
    let index = findParam(desc, param.name)
    if index < 0:
      return presetError(owner & ": у типа " & typeName &
                         " нет параметра «" & param.name & "»", typeHint())
    let low = desc.params[index].minValue
    let high = desc.params[index].maxValue
    if param.value < low or param.value > high:
      return presetError(owner & "." & param.name & ": значение " &
                         describeValue(param.value) & " вне диапазона " &
                         describeValue(low) & "…" & describeValue(high),
                         "исправьте значение в файле заготовки")
  okFrame()

proc masterCandidates(preset: ProjectPreset; reg: NodeRegistry): seq[string] =
  ## Ноды, претендующие на мастер: аудиовыход есть, исходящей аудиосвязи нет.
  ## Загрузчик сцены отказывает, если претендентов не один — значит, шаблон с
  ## двумя «выходами» не прошёл бы рендер без правок.
  var used: seq[string] = @[]
  for conn in preset.connections:
    if conn.sigType == 0:
      used.add conn.srcNode
  for node in preset.nodes:
    let desc = typeDesc(reg, node.nodeType)
    if desc.isNil or int(desc.audioOutCount) <= 0:
      continue
    if node.name notin used:
      result.add node.name


proc validatePreset*(preset: ProjectPreset; reg: NodeRegistry): ErrorFrame =
  ## Шаблон целиком: типы, параметры, связи, дорожки и мастер-выход.
  if preset.name.len == 0:
    return presetError("шаблон: не указано имя")
  if preset.nodes.len == 0:
    return presetError("шаблон " & preset.name & ": нет нод")
  if preset.tempo < 0.0 or preset.tempo > 1000.0:
    return presetError("шаблон " & preset.name & ": темп вне 0…1000 BPM")
  if preset.sampleRate < 0.0 or preset.sampleRate > 1_000_000.0:
    return presetError("шаблон " & preset.name & ": частота вне 0…1000000 Гц")
  if (preset.tsNum > 0) != (preset.tsDen > 0):
    return presetError("шаблон " & preset.name &
                       ": числитель и знаменатель размера задаются вместе")
  if preset.tsNum > 0:
    if preset.tsNum > 64:
      return presetError("шаблон " & preset.name & ": размер больше 64 долей")
    let den = preset.tsDen
    if den <= 0 or (den and (den - 1)) != 0:
      return presetError("шаблон " & preset.name &
                         ": знаменатель размера должен быть степенью двойки")

  var names: seq[string] = @[]
  for node in preset.nodes:
    if node.name in names:
      return presetError("шаблон " & preset.name & ": имя ноды «" & node.name &
                         "» повторяется",
                         "связи ссылаются на имя — оно обязано быть уникальным")
    names.add node.name
    let desc = typeDesc(reg, node.nodeType)
    if desc.isNil:
      return presetError("шаблон " & preset.name & ": неизвестный тип ноды «" &
                         node.nodeType & "»", typeHint(), ecNotFound)
    let params = checkParams(desc, node.params, "нода " & node.name, node.nodeType)
    if not params.isOk():
      return params

  for index, conn in preset.connections:
    if conn.srcNode notin names:
      return presetError("шаблон " & preset.name & ": связь " & $index &
                         " ссылается на ноду «" & conn.srcNode &
                         "», которой нет")
    if conn.dstNode notin names:
      return presetError("шаблон " & preset.name & ": связь " & $index &
                         " ссылается на ноду «" & conn.dstNode &
                         "», которой нет")
    if conn.sigType < 0 or conn.sigType > 2:
      return presetError("шаблон " & preset.name & ": связь " & $index &
                         " — неизвестный вид сигнала " & $conn.sigType,
                         "виды: " & SignalNames.join(", "))
    let srcDesc = typeDesc(reg, preset.nodes[names.find(conn.srcNode)].nodeType)
    let dstDesc = typeDesc(reg, preset.nodes[names.find(conn.dstNode)].nodeType)
    let srcCount = portCountOf(srcDesc, conn.sigType, true)
    if conn.srcPort < 0 or conn.srcPort >= srcCount:
      return presetError("шаблон " & preset.name & ": у «" & conn.srcNode &
                         "» нет " & SignalNames[conn.sigType] & "-выхода " &
                         $conn.srcPort, "порты: euterpia node show " & conn.srcNode)
    let dstCount = portCountOf(dstDesc, conn.sigType, false)
    if conn.dstPort < 0 or conn.dstPort >= dstCount:
      return presetError("шаблон " & preset.name & ": у «" & conn.dstNode &
                         "» нет " & SignalNames[conn.sigType] & "-входа " &
                         $conn.dstPort, "порты: euterpia node show " & conn.dstNode)

  let masters = masterCandidates(preset, reg)
  if masters.len == 0:
    return presetError("шаблон " & preset.name &
                       ": нет мастер-выхода (нода с аудиовыходом без связей)",
                       "рендер не поймёт, какой выход главный")
  if masters.len > 1:
    return presetError("шаблон " & preset.name & ": на мастер претендуют " &
                       $masters.len & " ноды (" & masters.join(", ") & ")",
                       "оставьте один выход — как в проектах `compositions/`")


  var trackNames: seq[string] = @[]
  for track in preset.tracks:
    if track.name in trackNames:
      return presetError("шаблон " & preset.name & ": дорожка «" & track.name &
                         "» повторяется")
    trackNames.add track.name
    if track.clip.notes.len == 0:
      continue
    if track.clip.lengthTicks <= 0:
      return presetError("шаблон " & preset.name & ": у клипа дорожки «" &
                         track.name & "» нет длины", "lengthTicks > 0")
    var endTick = 0'i32
    for note in track.clip.notes:
      endTick = max(endTick, note.startTick + note.duration)
    if endTick > track.clip.lengthTicks:
      return presetError("шаблон " & preset.name & ": ноты дорожки «" &
                         track.name & "» выходят за клип (" & $endTick & " > " &
                         $track.clip.lengthTicks & " тиков)",
                         "увеличьте lengthTicks или укоротите ноты")
    var notesNodes = 0
    for node in preset.nodes:
      if node.name == track.name and node.nodeType == NotesNodeType:
        inc notesNodes
    if notesNodes == 0:
      return presetError("шаблон " & preset.name & ": у партии «" & track.name &
                         "» нет ноды " & NotesNodeType & " с тем же именем",
                         "секвенсор наполняет событиями ноду с именем дорожки")
  okFrame()

proc voiceOf*(nodeNames, nodeTypes: seq[string]; role: string): int =
  ## Голос роли: нода с именем роли, но не нотная. Нотная нода носит то же имя
  ## (по ней играет секвенсор), поэтому тип — часть правила, а не догадка.
  for i in 0 ..< min(nodeNames.len, nodeTypes.len):
    if cmpIgnoreCase(nodeNames[i], role) == 0 and nodeTypes[i] != NotesNodeType:
      return i
  -1

proc validateSetlist*(setlist: Setlist; index: ProjectIndex;
                      reg: NodeRegistry): ErrorFrame =
  ## Сет-лист применим к ЭТОМУ проекту: у каждой партии есть голос, параметры
  ## сведения известны его типу, а ноты помещаются в клип.
  if setlist.name.len == 0:
    return presetError("сет-лист: не указано имя")
  if setlist.preset.len == 0:
    return presetError("сет-лист " & setlist.name & ": не указан шаблон")
  if setlist.parts.len == 0:
    return presetError("сет-лист " & setlist.name & ": нет партий")
  var seen: seq[string] = @[]
  for part in setlist.parts:
    if part.track.len == 0:
      return presetError("сет-лист " & setlist.name & ": партия без роли")
    if part.track in seen:
      return presetError("сет-лист " & setlist.name & ": партия «" & part.track &
                         "» повторяется", "одна дорожка — одна партия")
    seen.add part.track
    if part.lengthTicks <= 0:
      return presetError("сет-лист " & setlist.name & ": у партии «" &
                         part.track & "» нет длины клипа (lengthTicks)")
    var endTick = 0'i32
    for note in part.notes:
      endTick = max(endTick, note.startTick + note.duration)
    if endTick > part.lengthTicks:
      return presetError("сет-лист " & setlist.name & ": ноты партии «" &
                         part.track & "» выходят за клип (" & $endTick & " > " &
                         $part.lengthTicks & " тиков)")
    if part.notes.len == 0:
      return presetError("сет-лист " & setlist.name & ": у партии «" &
                         part.track & "» нет нот",
                         "партия без нот ничего не играет")
    var hasNotesNode = false
    for i in 0 ..< min(index.nodeNames.len, index.nodeTypes.len):
      if index.nodeNames[i] == part.track and
         index.nodeTypes[i] == NotesNodeType:
        hasNotesNode = true
    if not hasNotesNode:
      return presetError("сет-лист " & setlist.name & ": в проекте нет ноды " &
                         NotesNodeType & " «" & part.track & "»",
                         "сначала примените шаблон: euterpia init --preset …",
                         ecNotFound)
    let voice = voiceOf(index.nodeNames, index.nodeTypes, part.track)
    if voice < 0:
      return presetError("сет-лист " & setlist.name & ": у роли «" &
                         part.track & "» нет голоса (инструмента)",
                         "шаблон должен содержать инструмент с именем роли",
                         ecNotFound)
    let desc = typeDesc(reg, index.nodeTypes[voice])
    if desc.isNil:
      return presetError("сет-лист " & setlist.name & ": тип голоса «" &
                         index.nodeTypes[voice] & "» неизвестен этой сборке",
                         typeHint(), ecNotFound)
    let checked = checkParams(desc, part.mix,
                              "сет-лист " & setlist.name & " / " & part.track,
                              index.nodeTypes[voice])
    if not checked.isOk():
      return checked
  okFrame()

proc validateParamPreset*(preset: ParamPreset; reg: NodeRegistry): ErrorFrame =
  ## Несовместимый тип отвергается целиком, а не «наполовину».
  if preset.name.len == 0:
    return presetError("пресет параметров: не указано имя")
  let desc = typeDesc(reg, preset.nodeType)
  if desc.isNil:
    return presetError("пресет " & preset.name & ": неизвестный тип ноды «" &
                       preset.nodeType & "»", typeHint(), ecNotFound)
  if preset.params.len == 0:
    return presetError("пресет " & preset.name & ": нет параметров")
  checkParams(desc, preset.params, "пресет " & preset.name, preset.nodeType)


# =============================================================================
# Индекс проекта и команды control-слоя
# =============================================================================

proc emptyIndex*(): ProjectIndex =
  ProjectIndex()

proc addTrackTo*(index: var ProjectIndex; name: string; clips: int = 0) =
  ## Дорожка в индексе. Индекс — не модель: он нужен только для решения
  ## «добавить или обновить», поэтому хранит имена и счётчики.
  index.trackNames.add name
  index.trackClips.add clips

proc addNodeTo*(index: var ProjectIndex; id: int32; nodeType, name: string;
                params: seq[string] = @[]) =
  index.nodeIds.add id
  index.nodeTypes.add nodeType
  index.nodeNames.add name
  index.nodeParams.add params

proc nodeIdOf*(index: ProjectIndex; name: string): int32 =
  ## id ноды по имени (первое совпадение). Связи шаблона разрешаются именами,
  ## а проекту нужны id: перевод — здесь, один на все применения.
  for i in 0 ..< index.nodeNames.len:
    if index.nodeNames[i] == name:
      return index.nodeIds[i]
  -1

proc presetIndex*(preset: ProjectPreset; idBase: int32 = 0): ProjectIndex =
  ## Индекс шаблона: id нод — по порядку, дорожки — с числом клипов, которые
  ## создаст сам шаблон. По нему сет-лист решает «клип обновить или добавить».
  for i, node in preset.nodes:
    var params: seq[string] = @[]
    for param in node.params:
      params.add param.name
    result.addNodeTo(idBase + int32(i) + 1, node.nodeType, node.name, params)
  for track in preset.tracks:
    let hasClip = track.clip.lengthTicks > 0 or track.clip.notes.len > 0
    result.addTrackTo(track.name, if hasClip: 1 else: 0)

proc presetCommands*(preset: ProjectPreset; idBase: int32 = 0;
                     trackBase: int = 0): seq[ControlCommand] =
  ## Шаблон → команды. `idBase` сдвигает id нод (применение к непустому
  ## проекту), `trackBase` — номер первой добавляемой дорожки.
  var ids = initTable[string, int32]()
  for i, node in preset.nodes:
    let nodeId = idBase + int32(i) + 1
    ids[node.name] = nodeId
    var params = initTable[string, float32]()
    for param in node.params:
      params[param.name] = param.value
    result.add createNode(node.nodeType, node.name, newNodeId = nodeId,
                          parameters = params)
  for conn in preset.connections:
    let srcId = ids[conn.srcNode]
    let dstId = ids[conn.dstNode]
    result.add connect(port(srcId, ControlPortKind(conn.sigType), int32(conn.srcPort)),
                       port(dstId, ControlPortKind(conn.sigType), int32(conn.dstPort)))
  for i, track in preset.tracks:
    let trackIndex = int32(trackBase + i)
    result.add addTrack(track.name)
    if track.clip.lengthTicks > 0 or track.clip.notes.len > 0:
      result.add addClip(trackIndex, 0, track.clip.name, 0,
                         track.clip.lengthTicks, track.clip.loopEnabled)
      if track.clip.notes.len > 0:
        result.add setClip(trackIndex, 0, track.clip.notes,
                           track.clip.lengthTicks, track.clip.loopEnabled,
                           track.clip.name, nameSpecified = true)

proc presetScript*(preset: ProjectPreset; description = ""): Script =
  ## Шаблон как сценарий: `init --preset` идёт тем же `script build`, что и
  ## проект из файла сценария (#416). Второго пути сборки нет.
  Script(
    version: ScriptFormatVersion,
    description: (if description.len > 0: description
                  else: "шаблон: " & preset.name),
    variables: initTable[string, JsonNode](),
    commands: presetCommands(preset))

proc setlistCommands*(setlist: Setlist; index: var ProjectIndex): seq[ControlCommand] =
  ## Сет-лист → команды поверх индекса. Существующая дорожка получает
  ## `clip.set` (транзакция обновления), отсутствующая — `track.add` +
  ## `clip.add`. Сведение идёт параметрами голоса: отдельной команды «микс
  ## дорожки» в control-слое нет, и выдумывать её здесь значило бы завести
  ## второй источник правды.
  for part in setlist.parts:
    var trackIndex = index.trackNames.find(part.track)
    if trackIndex < 0:
      trackIndex = index.trackNames.len
      result.add addTrack(part.track)
      index.addTrackTo(part.track, 0)
    let clipIndex = if index.trackClips[trackIndex] > 0: 0 else: -1
    if clipIndex < 0:
      result.add addClip(int32(trackIndex), 0, part.clipName, 0,
                         part.lengthTicks, part.loopEnabled)
      index.trackClips[trackIndex] = 1
    result.add setClip(int32(trackIndex), 0, part.notes, part.lengthTicks,
                       part.loopEnabled, part.clipName, nameSpecified = true)
    let voice = voiceOf(index.nodeNames, index.nodeTypes, part.track)
    if voice >= 0:
      for param in part.mix:
        result.add setParameter(index.nodeIds[voice], param.value, param.name)

proc paramPresetCommands*(preset: ParamPreset;
                          nodeIds: seq[int32]): seq[ControlCommand] =
  ## Пресет параметров → команды для выбранных нод. Выбор нод — дело клиента
  ## (он знает Query API), библиотека только превращает значения в команды.
  for nodeId in nodeIds:
    for param in preset.params:
      result.add setParameter(nodeId, param.value, param.name)

