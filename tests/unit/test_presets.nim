# tests/unit/test_presets.nim
#
# Unit-тесты заготовок (`libs/presets`, issues #341–#343).
#
# Здесь проверяется то, чего не видно из чёрного CLI-теста:
#   * форма файлов: разбор, каноническая запись, чужая версия;
#   * проверка по РЕЕСТРУ: неизвестный тип — код `not_found`, параметр вне
#     диапазона — `invalid_argument`, а не «получилось не то»;
#   * команды шаблона действительно собирают документ: ноды, связи, дорожки,
#     клипы и ноты (а не только «валидация прошла»);
#   * сет-лист обновляет существующую дорожку `clip.set`, а не добавляет
#     второй клип; сведение идёт параметрами голоса;
#   * пресет параметров несовместимого типа отвергается целиком.
#
# CLI-часть (`init --preset`, `preset …`, `setlist …`) проверяется запуском
# бинаря в `tests/cli_test.nim`: `cli/` не входит в путь сборки unit-набора.

import std/[strutils, unittest]

import project
import control/commands
import control/document
import control/query
import control/error_frame
import presets
import sdk/node_api
import sdk/node_registry
import builtin/builtin_registry

proc testRegistry(): NodeRegistry =
  result = initNodeRegistry()
  discard registerBuiltinNodes(result)

proc providerFrom(reg: NodeRegistry): NodeTypeProvider =
  ## Хозяин описаний из того же реестра, что проверяет заготовки: тест не
  ## подменяет типы второй копией.
  result = proc(nodeType: string; spec: var NodeTypeSpec): bool =
    let entry = reg.findNodeType(nodeType)
    if entry.isNil:
      return false
    let desc = entry.desc
    spec = NodeTypeSpec(
      id: readFixed(desc.id), name: readFixed(desc.name),
      audioIn: int(desc.audioInCount), audioOut: int(desc.audioOutCount),
      ctrlIn: int(desc.ctrlInCount), ctrlOut: int(desc.ctrlOutCount),
      eventIn: int(desc.eventInCount), eventOut: int(desc.eventOutCount),
      latencyFrames: int(desc.latencyFrames))
    for i in 0 ..< int(desc.paramCount):
      let p = desc.params[i]
      spec.params.add ParamSpec(
        name: readFixed(p.name), minValue: p.minValue, maxValue: p.maxValue,
        defaultValue: p.defaultValue, step: p.step,
        integerLike: (p.flags and uint32(npfInteger)) != 0 or
                     (p.flags and uint32(npfChoice)) != 0,
        automatable: (p.flags and uint32(npfAutomatable)) != 0,
        modulatable: (p.flags and uint32(npfModulatable)) != 0,
        hidden: (p.flags and uint32(npfHidden)) != 0)
    true

proc blankProject(): ProjectFormat =
  ProjectFormat(
    format: ProjectFormatName, version: ProjectFormatVersion,
    metadata: ProjectMetadata(name: "test", sampleRate: 48000, tempo: 120,
                              timeSignature: TimeSignatureFormat(
                                numerator: 4, denominator: 4),
                              created: "2026-01-01T00:00:00",
                              modified: "2026-01-01T00:00:00"))

proc documentFor(reg: NodeRegistry): Document =
  initDocument(result, blankProject(), 0xAABBCCDD'u32, providerFrom(reg))

proc indexOf(doc: Document): ProjectIndex =
  ## Индекс проекта тем же способом, что у CLI: через Query API.
  for node in doc.queryNodes().nodes:
    var params: seq[string] = @[]
    for p in node.params:
      params.add p.name
    result.addNodeTo(int32(node.id), node.nodeType, node.name, params)
  for track in doc.queryTracks():
    result.addTrackTo(track.name, track.clips.len)

proc loadTemplate(path: string): ProjectPreset =
  let frame = loadPresetFile(path, result)
  check frame.isOk()
  if not frame.isOk():
    checkpoint(frame.message)

suite "presets: шаблон проекта (#341)":
  test "файл шаблона в репозитории разбирается и проверяется":
    var preset: ProjectPreset
    let frame = loadPresetFile("presets/templates/band.preset.json", preset)
    check frame.isOk()
    if not frame.isOk():
      checkpoint(frame.message)
    check preset.name == "band"
    check preset.nodes.len == 7
    check preset.tracks.len == 3
    let validated = validatePreset(preset, testRegistry())
    check validated.isOk()
    if not validated.isOk():
      checkpoint(validated.message)

  test "каноническая запись читается обратно":
    let preset = loadTemplate("presets/templates/band.preset.json")
    let text = encodePreset(preset)
    var again: ProjectPreset
    let frame = parsePreset(text, again)
    check frame.isOk()
    check encodePreset(again) == text

  test "чужая версия отвергается, а не читается как шаблон":
    var preset: ProjectPreset
    let frame = parsePreset(
      """{"format":"euterpia.preset","version":99,"name":"x","nodes":[]}""",
      preset)
    check not frame.isOk()
    check frame.code == ecInvalidArgument
    check "новее этой сборки" in frame.message

  test "неизвестный тип отвергается кодом причины (#341)":
    var preset: ProjectPreset
    let frame = parsePreset("""{
      "format":"euterpia.preset","version":1,"name":"bad",
      "nodes":[{"type":"euterpia.nonexistent","name":"x"}]
    }""", preset)
    check frame.isOk()
    let validated = validatePreset(preset, testRegistry())
    check not validated.isOk()
    check validated.code == ecNotFound
    check "euterpia.nonexistent" in validated.message

  test "параметр вне диапазона отвергается, а не обрезается":
    var preset: ProjectPreset
    let frame = parsePreset("""{
      "format":"euterpia.preset","version":1,"name":"bad",
      "nodes":[{"type":"euterpia.gain","name":"g","params":{"gain":99}}]
    }""", preset)
    check frame.isOk()
    let validated = validatePreset(preset, testRegistry())
    check not validated.isOk()
    check validated.code == ecInvalidArgument
    check "вне диапазона" in validated.message

  test "шаблон без однозначного мастер-выхода отвергается":
    var preset: ProjectPreset
    let frame = parsePreset("""{
      "format":"euterpia.preset","version":1,"name":"two",
      "nodes":[
        {"type":"euterpia.osc","name":"a"},
        {"type":"euterpia.osc","name":"b"}]
    }""", preset)
    check frame.isOk()
    let validated = validatePreset(preset, testRegistry())
    check not validated.isOk()
    check "на мастер претендуют" in validated.message

  test "команды шаблона собирают ноды, связи, дорожки и ноты":
    let reg = testRegistry()
    let preset = loadTemplate("presets/templates/band.preset.json")
    var doc = documentFor(reg)
    let plan = doc.applyTransaction(presetCommands(preset), "шаблон band")
    check plan.frame.isOk()
    if not plan.frame.isOk():
      checkpoint(plan.frame.message)
    let nodes = doc.queryNodes().nodes
    check nodes.len == preset.nodes.len
    check doc.queryConnections().len == preset.connections.len
    let tracks = doc.queryTracks()
    check tracks.len == 3
    check tracks[0].clips.len == 1
    check doc.proj.sequencer.tracks[0].clips[0].notes.len > 0
    # Параметры из файла доехали до документа.
    var voice: NodeInfo
    for node in nodes:
      if node.name == "Lead":
        voice = node
    check voice.id > 0
    var level = 0.0f
    for p in voice.params:
      if p.name == "level":
        level = p.value
    check abs(level + 8.0f) < 1e-4f

  test "применение к непустому проекту сдвигает id нод":
    let reg = testRegistry()
    let preset = loadTemplate("presets/templates/band.preset.json")
    var doc = documentFor(reg)
    check doc.applyCommand(createNode("euterpia.gain", "existing")).isOk()
    let plan = doc.applyTransaction(
      presetCommands(preset, idBase = int32(doc.queryNodes().nodes.len)),
      "шаблон поверх проекта")
    check plan.frame.isOk()
    let ids = doc.queryNodes().nodes.len
    check ids == preset.nodes.len + 1
    # Старая нода не перетёрта: её имя на месте.
    var names: seq[string] = @[]
    for node in doc.queryNodes().nodes:
      names.add node.name
    check "existing" in names


suite "presets: сет-лист (#342)":
  test "сет-лист репозитория разбирается и применим к своему шаблону":
    var setlist: Setlist
    let frame = loadSetlistFile("presets/setlists/punk-demo.setlist.json", setlist)
    check frame.isOk()
    if not frame.isOk():
      checkpoint(frame.message)
    check setlist.name == "punk-demo"
    check setlist.preset == "band"
    check setlist.parts.len == 3
    let preset = loadTemplate("presets/templates/band.preset.json")
    let validated = validateSetlist(setlist, presetIndex(preset), testRegistry())
    check validated.isOk()
    if not validated.isOk():
      checkpoint(validated.message)

  test "пьеса, собранная сет-листом, содержит партии и сведение":
    let reg = testRegistry()
    let preset = loadTemplate("presets/templates/band.preset.json")
    var setlist: Setlist
    check loadSetlistFile("presets/setlists/punk-demo.setlist.json",
                          setlist).isOk()
    var doc = documentFor(reg)
    var index = presetIndex(preset)
    var commands = presetCommands(preset)
    commands.add setlistCommands(setlist, index)
    let plan = doc.applyTransaction(commands, "шаблон + сет-лист")
    check plan.frame.isOk()
    if not plan.frame.isOk():
      checkpoint(plan.frame.message)
    let tracks = doc.queryTracks()
    check tracks.len == 3
    check tracks[0].clips.len == 1
    check doc.proj.sequencer.tracks[0].clips[0].notes.len ==
      setlist.parts[0].notes.len
    check doc.proj.sequencer.tracks[0].clips[0].name == "punk-lead"
    var level = 0.0f
    for node in doc.queryNodes().nodes:
      if node.name == "Lead":
        for p in node.params:
          if p.name == "level":
            level = p.value
    check abs(level + 7.0f) < 1e-4f

  test "смена сет-листа обновляет клип, а не добавляет второй":
    let reg = testRegistry()
    let preset = loadTemplate("presets/templates/band.preset.json")
    var setlist: Setlist
    check loadSetlistFile("presets/setlists/punk-demo.setlist.json",
                          setlist).isOk()
    var doc = documentFor(reg)
    var index = presetIndex(preset)
    var commands = presetCommands(preset)
    commands.add setlistCommands(setlist, index)
    check doc.applyTransaction(commands, "сборка").frame.isOk()

    var second = indexOf(doc)
    let update = setlistCommands(setlist, second)
    let plan = doc.applyTransaction(update, "обновление сет-листа")
    check plan.frame.isOk()
    check doc.queryTracks()[0].clips.len == 1
    check doc.proj.sequencer.tracks[0].clips[0].notes.len ==
      setlist.parts[0].notes.len
    # Откат обновления возвращает прежние ноты — транзакция обратима.
    check plan.undo.len > 0

  test "сет-лист без голоса в проекте отвергается кодом not_found":
    var setlist: Setlist
    check loadSetlistFile("presets/setlists/punk-demo.setlist.json",
                          setlist).isOk()
    var doc = documentFor(testRegistry())
    check doc.applyCommand(createNode("euterpia.gain", "gain")).isOk()
    let validated = validateSetlist(setlist, indexOf(doc), testRegistry())
    check not validated.isOk()
    check validated.code == ecNotFound

  test "голос роли — инструмент, а не нотная нода с тем же именем":
    let preset = loadTemplate("presets/templates/band.preset.json")
    let index = presetIndex(preset)
    let voice = voiceOf(index.nodeNames, index.nodeTypes, "bass")
    check voice >= 0
    check index.nodeTypes[voice] == "euterpia.organ"
    check index.nodeNames[voice] == "Bass"

suite "presets: пресет параметров (#343)":
  test "пресет репозитория проверяется по типу":
    var preset: ParamPreset
    let frame = loadParamPresetFile("presets/params/cello-warm.params.json",
                                    preset)
    check frame.isOk()
    if not frame.isOk():
      checkpoint(frame.message)
    check preset.nodeType == "euterpia.strings"
    check validateParamPreset(preset, testRegistry()).isOk()

  test "несовместимый тип отвергается целиком":
    var preset: ParamPreset
    let frame = parseParamPreset("""{
      "format":"euterpia.param-preset","version":1,"name":"bad",
      "nodeType":"euterpia.no-such","params":{"tone":0.5}}""", preset)
    check frame.isOk()
    let validated = validateParamPreset(preset, testRegistry())
    check not validated.isOk()
    check validated.code == ecNotFound

  test "неизвестный параметр не проходит проверку":
    var preset: ParamPreset
    let frame = parseParamPreset("""{
      "format":"euterpia.param-preset","version":1,"name":"bad",
      "nodeType":"euterpia.piano","params":{"nope":0.5}}""", preset)
    check frame.isOk()
    let validated = validateParamPreset(preset, testRegistry())
    check not validated.isOk()
    check "нет параметра" in validated.message

  test "команды пресета меняют значения выбранных нод":
    let reg = testRegistry()
    var preset: ParamPreset
    check loadParamPresetFile("presets/params/piano-bright.params.json",
                              preset).isOk()
    var doc = documentFor(reg)
    check doc.applyCommand(createNode("euterpia.piano", "p")).isOk()
    let plan = doc.applyTransaction(paramPresetCommands(preset, @[1'i32]),
                                    "пресет piano-bright")
    check plan.frame.isOk()
    var tone = 0.0f
    for node in doc.queryNodes().nodes:
      for p in node.params:
        if p.name == "tone":
          tone = p.value
    check abs(tone - 0.78f) < 1e-4f

  test "пресеты находятся по имени в каталоге репозитория":
    let dirs = @["presets/params"]
    let found = findPreset(pkParams, "cello-warm", dirs)
    check found.ok
    check found.path.endsWith("cello-warm.params.json")
    let missing = findPreset(pkParams, "nope", dirs)
    check not missing.ok
    check "cello-warm" in missing.available

