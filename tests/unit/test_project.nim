# tests/unit/test_project.nim
#
# core/project.nim — сериализация проекта (НЕ runtime-состояние).
#
# Что проверяется (критерии #57):
#   - round-trip save/load сохраняет метаданные, граф, секвенсор и
#     автоматизацию байт-в-байт по значениям;
#   - версии формата: чужая версия -> pekUnsupportedVersion,
#     чужой format -> pekInvalidFormat, не-объект в корне -> pekInvalidFormat;
#   - отсутствующий файл -> pekFileNotFound, битый JSON -> pekJsonParseError,
#     невозможная запись -> pekIOError;
#   - ProjectResult не бросает исключений наружу.

import std/[unittest, os, tables]
import project

proc makeProject(): ProjectFormat =
  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.metadata = ProjectMetadata(
    name: "Demo", author: "Tester",
    sampleRate: 48000.0f, tempo: 128.0f,
    timeSignature: TimeSignatureFormat(numerator: 3, denominator: 4),
    created: "2026-01-01", modified: "2026-01-02"
  )

  var n1 = NodeFormat(
    id: 1, nodeType: "fx.gain", name: "Gain",
    audioInCount: 1, audioOutCount: 1,
    ctrlInCount: 2, ctrlOutCount: 0,
    latencyReported: 5'u32, latencyIntrinsic: 2'u32
  )
  n1.parameters["gain"] = 0.75f
  n1.parameters["pan"] = -0.25f

  let n2 = NodeFormat(
    id: 2, nodeType: "io.output", name: "Out",
    audioInCount: 1, audioOutCount: 0
  )

  result.graph.nodes = @[n1, n2]
  result.graph.connections.add ConnectionFormat(
    srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0, sigType: 0)

  var track = TrackFormat(
    id: 1, name: "Track 1", trackType: 0,
    volume: 0.8f, pan: 0.1f, mute: false, solo: true, armed: false,
    inputChannel: 0, outputBus: 0
  )
  var clip = ClipFormat(
    id: 1, clipType: 0, name: "Clip 1",
    startTick: 0, lengthTicks: 960, loopEnabled: true,
    audioBufferId: -1, color: 0xFF6B6B'u32
  )
  clip.notes.add NoteFormat(
    startTick: 0, duration: 240, pitch: 60, velocity: 100, channel: 0)
  clip.notes.add NoteFormat(
    startTick: 240, duration: 240, pitch: 64, velocity: 80, channel: 1)
  track.clips.add clip
  result.sequencer.tracks.add track

  var lane = AutomationLaneFormat(paramId: 7'u32, nodeId: 1)
  lane.points.add AutomationPointFormat(tick: 0, value: 0.0f, curve: 0)
  lane.points.add AutomationPointFormat(tick: 960, value: 1.0f, curve: 2)
  result.sequencer.automationLanes.add lane

# =============================================================================
# Round-trip
# =============================================================================

suite "project: round-trip":
  test "save/load сохраняет метаданные, граф, секвенсор и автоматизацию":
    let path = getTempDir() / "euterpia_proj_roundtrip.json"
    let original = makeProject()

    let saved = saveProject(original, path)
    check saved.success
    check fileExists(path)

    let loaded = loadProject(path)
    check loaded.success
    defer: removeFile(path)

    let p = loaded.value
    check p.format == original.format
    check p.version == original.version

    # metadata
    check p.metadata.name == "Demo"
    check p.metadata.author == "Tester"
    check p.metadata.sampleRate == 48000.0f
    check p.metadata.tempo == 128.0f
    check p.metadata.timeSignature.numerator == 3
    check p.metadata.timeSignature.denominator == 4
    check p.metadata.created == "2026-01-01"
    check p.metadata.modified == "2026-01-02"

    # graph
    check p.graph.nodes.len == 2
    check p.graph.nodes[0].nodeType == "fx.gain"
    check p.graph.nodes[0].name == "Gain"
    check p.graph.nodes[0].parameters["gain"] == 0.75f
    check p.graph.nodes[0].parameters["pan"] == -0.25f
    check p.graph.nodes[0].latencyReported == 5'u32
    check p.graph.nodes[0].latencyIntrinsic == 2'u32
    check p.graph.nodes[0].ctrlInCount == 2
    check p.graph.connections.len == 1
    check p.graph.connections[0].dstNodeId == 2
    check p.graph.connections[0].sigType == 0

    # sequencer
    check p.sequencer.tracks.len == 1
    check p.sequencer.tracks[0].name == "Track 1"
    check p.sequencer.tracks[0].volume == 0.8f
    check p.sequencer.tracks[0].pan == 0.1f
    check p.sequencer.tracks[0].solo
    check not p.sequencer.tracks[0].mute
    check p.sequencer.tracks[0].clips.len == 1
    let clip = p.sequencer.tracks[0].clips[0]
    check clip.name == "Clip 1"
    check clip.loopEnabled
    check clip.audioBufferId == -1
    check clip.color == 0xFF6B6B'u32
    check clip.notes.len == 2
    check clip.notes[1].pitch == 64
    check clip.notes[1].channel == 1
    check clip.notes[1].velocity == 80

    # automation
    check p.sequencer.automationLanes.len == 1
    check p.sequencer.automationLanes[0].paramId == 7'u32
    check p.sequencer.automationLanes[0].nodeId == 1
    check p.sequencer.automationLanes[0].points.len == 2
    check p.sequencer.automationLanes[0].points[1].value == 1.0f
    check p.sequencer.automationLanes[0].points[1].curve == 2

  test "pluginStates: непрозрачные блобы сохраняются байт-в-байт":
    let path = getTempDir() / "euterpia_proj_pluginstate.json"
    var proj = makeProject()
    proj.pluginStates.add PluginStateFormat(
      nodeId: 7, pluginId: "com.euterpia.mock.gain",
      state: @[byte 0, byte 1, byte 255, byte 128, byte 42])
    proj.pluginStates.add PluginStateFormat(
      nodeId: 9, pluginId: "euterpia.eut.v1", state: @[])

    check saveProject(proj, path).success
    defer: removeFile(path)

    let loaded = loadProject(path)
    check loaded.success
    check loaded.value.pluginStates.len == 2
    check loaded.value.pluginStates[0].nodeId == 7
    check loaded.value.pluginStates[0].pluginId == "com.euterpia.mock.gain"
    check loaded.value.pluginStates[0].state ==
      @[byte 0, byte 1, byte 255, byte 128, byte 42]
    check loaded.value.pluginStates[1].nodeId == 9
    check loaded.value.pluginStates[1].state.len == 0



# =============================================================================
# Ошибки формата и I/O (через ProjectResult, без исключений наружу)
# =============================================================================

suite "project: ошибки":
  test "отсутствующий файл -> pekFileNotFound":
    let r = loadProject(getTempDir() / "euterpia_missing_98765.json")
    check not r.success
    check r.error.kind == pekFileNotFound

  test "битый JSON -> pekJsonParseError":
    let path = getTempDir() / "euterpia_bad_json.json"
    writeFile(path, "{ это не json")
    defer: removeFile(path)
    let r = loadProject(path)
    check not r.success
    check r.error.kind == pekJsonParseError

  test "корень не объект -> pekInvalidFormat":
    let path = getTempDir() / "euterpia_array_root.json"
    writeFile(path, "[1,2,3]")
    defer: removeFile(path)
    let r = loadProject(path)
    check not r.success
    check r.error.kind == pekInvalidFormat

  test "чужой format -> pekInvalidFormat":
    let path = getTempDir() / "euterpia_bad_format.json"
    writeFile(path, """{"format":"something-else","version":1}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check not r.success
    check r.error.kind == pekInvalidFormat

  test "неподдерживаемая версия -> pekUnsupportedVersion":
    let path = getTempDir() / "euterpia_bad_version.json"
    writeFile(path, """{"format":"euterpia-project","version":999}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check not r.success
    check r.error.kind == pekUnsupportedVersion

  test "отсутствующие секции не роняют парсер (совместимость вперёд)":
    let path = getTempDir() / "euterpia_minimal.json"
    writeFile(path, """{"format":"euterpia-project","version":1}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check r.success
    let p = r.value
    check p.graph.nodes.len == 0
    check p.sequencer.tracks.len == 0
    check p.sequencer.automationLanes.len == 0
    # Дефолты метаданных совпадают с initTransport, а не вырождаются в 0.
    check p.metadata.sampleRate == 48000.0f
    check p.metadata.tempo == 120.0f
    check p.metadata.timeSignature.numerator == 4
    check p.metadata.timeSignature.denominator == 4
    check p.pluginStates.len == 0

  test "отсутствующий timeSignature внутри metadata -> 4/4 по умолчанию":
    # Именно этот fallback опирается на safeInt(..., "numerator", 4).
    let path = getTempDir() / "euterpia_no_timesig.json"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "metadata":{"name":"X","sampleRate":44100,"tempo":100}}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check r.success
    check r.value.metadata.name == "X"
    check r.value.metadata.sampleRate == 44100.0f
    check r.value.metadata.tempo == 100.0f
    check r.value.metadata.timeSignature.numerator == 4
    check r.value.metadata.timeSignature.denominator == 4

  test "запись в недоступный каталог -> pekIOError":
    let r = saveProject(makeProject(), "/nonexistent_dir_9f3/euterpia/x.json")
    check not r.success
    check r.error.kind == pekIOError

  test "не-объекты в массивах пропускаются, а не дают мусорные ноды (#75)":
    let path = getTempDir() / "euterpia_junk_arrays.json"
    # Повреждённый файл: в массивах объектов встречаются числа и null.
    writeFile(path, """{"format":"euterpia-project","version":1,
      "graph":{
        "nodes":[42, {"id":1,"nodeType":"fx.gain"}, null, "x"],
        "connections":[7, {}, null]
      },
      "sequencer":{
        "tracks":[1, {"id":1,"name":"T","clips":[null, {"id":1,"notes":[9, {}]}]}],
        "automationLanes":[null, {"paramId":1,"nodeId":1,"points":[3]}]
      }}""")
    defer: removeFile(path)

    let r = loadProject(path)
    check r.success
    let p = r.value

    # Не-объекты отброшены: раньше вместо них появлялись «мусорные» ноды
    # с дефолтами (id: 0, nodeType: "").
    check p.graph.nodes.len == 1
    check p.graph.nodes[0].nodeType == "fx.gain"
    check p.graph.nodes[0].id == 1

    # Объект без нужных полей — валидный элемент с дефолтами, он остаётся.
    check p.graph.connections.len == 1
    check p.graph.connections[0].srcNodeId == 0

    check p.sequencer.tracks.len == 1
    check p.sequencer.tracks[0].clips.len == 1
    # notes=[9, {}]: число отброшено, объект остался.
    check p.sequencer.tracks[0].clips[0].notes.len == 1

    check p.sequencer.automationLanes.len == 1
    check p.sequencer.automationLanes[0].points.len == 0

