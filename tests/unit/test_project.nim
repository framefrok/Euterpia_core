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

import std/[unittest, os, strutils, tables]
import project
import signal_types

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
    # v1 → v2: секции `resources` в старом файле нет, но она не обязательна —
    # миграция не нужна, поле просто пустое (issue #107).
    check p.resources.len == 0

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

  test "аудиоресурсы и audio-клип переживают round-trip (v2, #107)":
    var p = ProjectFormat(format: ProjectFormatName, version: ProjectFormatVersion)
    p.resources.add AudioResourceFormat(
      id: 1, path: "kick.wav", sampleRate: 48000, channels: 2,
      numFrames: 96000, bitsPerSample: 24, isFloat: false, copy: true)
    # Трек с audio-клипом, ссылающимся на ресурс #1.
    var track = TrackFormat(id: 1, name: "Drums", trackType: 1, volume: 1.0f)
    track.clips.add ClipFormat(
      id: 1, clipType: 1, name: "kick", startTick: 0, lengthTicks: 3840,
      resourceId: 1, offsetFrames: 0, color: 0xFFu32)
    p.sequencer.tracks.add track

    let path = getTempDir() / "euterpia_resources.json"
    defer: removeFile(path)
    check saveProject(p, path).success
    let r = loadProject(path)
    check r.success
    check r.value.version == ProjectFormatVersion
    check r.value.resources.len == 1
    let res = r.value.resources[0]
    check res.id == 1
    check res.path == "kick.wav"
    check res.sampleRate == 48000
    check res.channels == 2
    check res.numFrames == 96000
    check res.bitsPerSample == 24
    check res.copy
    check r.value.sequencer.tracks.len == 1
    let clip = r.value.sequencer.tracks[0].clips[0]
    check clip.resourceId == 1
    check clip.offsetFrames == 0
    check clip.clipType == 1

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


# =============================================================================
# issue #390: атомарная запись, канонический JSON, без молчаливого сужения
# =============================================================================

suite "project: атомарная запись (#390)":
  test "перезапись атомарна: прежняя версия уходит в .bak, tmp-мусора нет":
    let path = getTempDir() / "euterpia_atomic_390.json"
    check saveProject(makeProject(), path).success
    defer:
      removeFile(path)
      removeFile(path & ".bak")
      removeFile(path & ".tmp-" & $getCurrentProcessId())

    var p2 = makeProject()
    p2.metadata.name = "Second"
    check saveProject(p2, path).success
    check readFile(path).contains "\"Second\""
    # tmp-файл процесса не переживает запись.
    check not fileExists(path & ".tmp-" & $getCurrentProcessId())
    # Прежняя версия сохранена как .bak (страховка, best-effort).
    check fileExists(path & ".bak")
    check readFile(path & ".bak").contains "\"Demo\""
    # Итоговый файл — валидный JSON и загружается.
    let loaded = loadProject(path)
    check loaded.success
    check loaded.value.metadata.name == "Second"

  test "сбой записи в недоступный каталог -> pekIOError без побочек":
    let r = saveProject(makeProject(), "/nonexistent_dir_9f3/euterpia/x.json")
    check not r.success
    check r.error.kind == pekIOError

suite "project: канонический JSON (#390)":
  test "порядок вставки параметров не влияет на байт-поток файла":
    # Логически равные проекты (разный порядок вставки в Table) дают
    # байт-в-байт одинаковый файл — иначе мусорные git-диффы.
    let pathA = getTempDir() / "euterpia_canon_a.json"
    let pathB = getTempDir() / "euterpia_canon_b.json"
    defer:
      removeFile(pathA); removeFile(pathB)
      removeFile(pathA & ".bak"); removeFile(pathB & ".bak")

    var pa = ProjectFormat(format: ProjectFormatName, version: ProjectFormatVersion)
    var na = NodeFormat(id: 1, nodeType: "fx.gain")
    na.parameters["alpha"] = 1.0f
    na.parameters["beta"] = 2.0f
    na.parameters["gamma"] = 3.0f
    pa.graph.nodes.add na

    var pb = ProjectFormat(format: ProjectFormatName, version: ProjectFormatVersion)
    var nb = NodeFormat(id: 1, nodeType: "fx.gain")
    nb.parameters["gamma"] = 3.0f
    nb.parameters["alpha"] = 1.0f
    nb.parameters["beta"] = 2.0f
    pb.graph.nodes.add nb

    check saveProject(pa, pathA).success
    check saveProject(pb, pathB).success
    check readFile(pathA) == readFile(pathB)

    # Ключи в файле отсортированы, а не в порядке хеш-таблицы.
    let text = readFile(pathA)
    check text.find("\"alpha\"") < text.find("\"beta\"")
    check text.find("\"beta\"") < text.find("\"gamma\"")

suite "project: сужение типов отвергается (#390)":
  test "pitch: 300 -> pekInvalidFormat, а не молчаливое 44":
    let path = getTempDir() / "euterpia_pitch_300.json"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "sequencer":{"tracks":[{"id":1,"clips":[{"id":1,"notes":[
        {"startTick":0,"duration":240,"pitch":300,"velocity":80,"channel":0}]}]}]}}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check not r.success
    check r.error.kind == pekInvalidFormat
    # Ошибка называет поле и значение, а не «битый файл».
    check r.error.message.contains "pitch"
    check r.error.message.contains "300"

  test "отрицательная latency становится маркером превышения, а не 4294967295":
    let path = getTempDir() / "euterpia_latency_neg.json"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "graph":{"nodes":[{"id":1,"nodeType":"fx.gain","latencyReported":-1}]}}""")
    defer: removeFile(path)
    let r = loadProject(path)
    # #405: значение вне диапазона не заворачивается в uint32 (было бы
    # 4294967295), а помечается «заведомо больше предела»; компилятор затем
    # честно отказывает `cekLatencyOverflow`.
    check r.success
    check r.value.graph.nodes[0].latencyReported == MaxLatencyFrames + 1'u32

  test "velocity: 256 и channel: -1 тоже отвергаются":
    let path = getTempDir() / "euterpia_velocity_256.json"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "sequencer":{"tracks":[{"id":1,"clips":[{"id":1,"notes":[
        {"startTick":0,"duration":240,"pitch":60,"velocity":256,"channel":-1}]}]}]}}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check not r.success
    check r.error.kind == pekInvalidFormat
    check r.error.message.contains "velocity"

  test "значения на границе диапазона проходят":
    let path = getTempDir() / "euterpia_pitch_edge.json"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "sequencer":{"tracks":[{"id":1,"clips":[{"id":1,"notes":[
        {"startTick":0,"duration":240,"pitch":255,"velocity":0,"channel":15}]}]}]}}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check r.success
    let note = r.value.sequencer.tracks[0].clips[0].notes[0]
    check note.pitch == 255'u8
    check note.velocity == 0'u8
    check note.channel == 15'u8

  test "отсутствующие необязательные поля по-прежнему не роняют загрузку":
    # Проверка диапазона не превращается в валидацию схемы: файл без
    # необязательных полей остаётся загружаемым (совместимость вперёд).
    let path = getTempDir() / "euterpia_optional_390.json"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "graph":{"nodes":[{"id":1,"nodeType":"fx.gain"}]}}""")
    defer: removeFile(path)
    let r = loadProject(path)
    check r.success
    check r.value.graph.nodes.len == 1
    check r.value.graph.nodes[0].latencyReported == 0'u32

  test "round-trip self-made проекта с нулевым timeSignature не отклоняется":
    # TimeSignatureFormat(numerator: 0) — это «не задано» (дефолт Nim-объекта),
    # а не размер такта. Сериализация подставляет 4/4, иначе round-trip
    # отклонялся бы собственной валидацией диапазона `1..64`.
    let path = getTempDir() / "euterpia_ts_zero_390.json"
    removeFile(path); removeFile(path & ".bak")
    var p = ProjectFormat(format: ProjectFormatName, version: ProjectFormatVersion)
    p.metadata = ProjectMetadata(name: "NoSig")  # timeSignature остаётся 0/0
    check saveProject(p, path).success
    defer:
      removeFile(path)
      removeFile(path & ".bak")
    let r = loadProject(path)
    check r.success
    check r.value.metadata.timeSignature.numerator == 4
    check r.value.metadata.timeSignature.denominator == 4
# #403: порты субграфа переживают save/load
# =============================================================================

suite "project: порты субграфа (#403)":
  test "subgraphInputs/subgraphOutputs сохраняются и читаются":
    let path = getTempDir() / "euterpia_proj_subgraph.json"
    var original = makeProject()

    var sub = NodeFormat(
      id: 10, nodeType: "core.subgraph", name: "Chain",
      isSubgraph: true, audioInCount: 1, audioOutCount: 1
    )
    sub.subgraphNodes = @[
      NodeFormat(id: 100, nodeType: "fx.gain", name: "in"),
      NodeFormat(id: 101, nodeType: "fx.gain", name: "out")
    ]
    sub.subgraphInputs = @[
      SubgraphPortFormat(name: "in", localNodeId: 100, localPortIdx: 0,
                         sigType: ord(sigAudio))
    ]
    sub.subgraphOutputs = @[
      SubgraphPortFormat(name: "out", localNodeId: 101, localPortIdx: 0,
                         sigType: ord(sigAudio))
    ]
    original.graph.nodes.add sub

    let saved = saveProject(original, path)
    check saved.success
    defer: removeFile(path)

    let loaded = loadProject(path)
    check loaded.success

    var found = false
    for node in loaded.value.graph.nodes:
      if node.id == 10:
        found = true
        check node.isSubgraph
        check node.subgraphNodes.len == 2
        check node.subgraphInputs.len == 1
        check node.subgraphInputs[0].localNodeId == 100
        check node.subgraphInputs[0].localPortIdx == 0
        check node.subgraphInputs[0].sigType == ord(sigAudio)
        check node.subgraphOutputs.len == 1
        check node.subgraphOutputs[0].localNodeId == 101
    check found


# =============================================================================
# #405: latency из файла не заворачивается в uint32
# =============================================================================

suite "project: latency и предел (#405)":
  test "огромная/отрицательная latency превращается в маркер превышения":
    let path = getTempDir() / "euterpia_proj_latency.json"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "metadata":{"name":"L","sampleRate":48000,"tempo":120},
      "graph":{"nodes":[
        {"id":1,"nodeType":"fx.gain","latencyReported":-1,
         "latencyIntrinsic":999999999999},
        {"id":2,"nodeType":"fx.gain","latencyReported":128}],
        "connections":[]}}""")
    defer: removeFile(path)

    let loaded = loadProject(path)
    check loaded.success

    var node1: NodeFormat
    var node2: NodeFormat
    for node in loaded.value.graph.nodes:
      if node.id == 1: node1 = node
      if node.id == 2: node2 = node

    # Оба «плохих» значения — маркер MaxLatencyFrames+1, а не 0 и не
    # случайное маленькое число после uint32-обрезки.
    check node1.latencyReported == MaxLatencyFrames + 1'u32
    check node1.latencyIntrinsic == MaxLatencyFrames + 1'u32
    # Нормальное значение не меняется.
    check node2.latencyReported == 128'u32

