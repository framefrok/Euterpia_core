# tests/unit/test_diff.nim
#
# Unit-тесты сравнения (`libs/diff`, issues #337, #338).
#
# Здесь проверяется то, чего не видно из чёрного CLI-теста:
#   * перестановка ключей JSON не считается различием — свойство сравнения,
#     а не договорённость;
#   * изменение одной величины даёт РОВНО одно различие с адресом сущности
#     (а не индексом массива);
#   * добавленные/удалённые ноды, связи, ноты, точки автоматизации и
#     состояния плагинов опознаются по `id`;
#   * расхождение рендеров измеряется числом: метрики, сэмплы, первый кадр.
#
# CLI-часть (`project diff`, `render diff`, `ci check`) проверяется запуском
# бинаря в `tests/cli_test.nim`: `cli/` не входит в путь сборки unit-набора.

import std/[json, math, os, strutils, unittest]

import project
import audio_file_io
import diff

proc node(id: int; nodeType = "euterpia.osc"; name = "osc";
          freq = 220.0): JsonNode =
  %*{
    "id": id, "nodeType": nodeType, "name": name,
    "audioInCount": 0, "audioOutCount": 1,
    "ctrlInCount": 0, "ctrlOutCount": 0,
    "eventInCount": 0, "eventOutCount": 0,
    "latencyReported": 0, "latencyIntrinsic": 0, "isSubgraph": false,
    "parameters": {"freq": freq},
    "subgraphNodes": [], "subgraphConnections": [],
    "subgraphInputs": [], "subgraphOutputs": [],
  }

proc connection(src, dst: int; sigType = 0): JsonNode =
  %*{"srcNodeId": src, "srcPortIdx": 0,
     "dstNodeId": dst, "dstPortIdx": 0, "sigType": sigType}

proc document(nodes: seq[JsonNode]; connections: seq[JsonNode] = @[];
              metadata: JsonNode = nil;
              tracks: seq[JsonNode] = @[];
              lanes: seq[JsonNode] = @[];
              pluginStates: seq[JsonNode] = @[];
              resources: seq[JsonNode] = @[]): JsonNode =
  ## Документ в форме канонического JSON проекта. Тесты собирают его сами:
  ## сравнение работает с данными, а не с файлом, и это ровно то, что
  ## проверяется.
  var nodesJson = newJArray()
  for item in nodes: nodesJson.add item
  var connectionsJson = newJArray()
  for item in connections: connectionsJson.add item
  var meta = %*{"name": "Diff", "author": "", "sampleRate": 48000.0,
                "tempo": 120.0,
                "timeSignature": {"numerator": 4, "denominator": 4},
                "created": "2026-01-01T00:00:00",
                "modified": "2026-01-01T00:00:00"}
  if metadata != nil:
    meta = metadata
  var tracksJson = newJArray()
  for item in tracks: tracksJson.add item
  var lanesJson = newJArray()
  for item in lanes: lanesJson.add item
  var statesJson = newJArray()
  for item in pluginStates: statesJson.add item
  var resourcesJson = newJArray()
  for item in resources: resourcesJson.add item
  %*{
    "format": ProjectFormatName, "version": ProjectFormatVersion,
    "metadata": meta,
    "graph": {"nodes": nodesJson, "connections": connectionsJson},
    "sequencer": {"tracks": tracksJson, "automationLanes": lanesJson},
    "pluginStates": statesJson,
    "resources": resourcesJson,
  }

proc findItem(items: seq[DiffItem]; address: string): int =
  for index, item in items:
    if item.address == address:
      return index
  -1

proc clone(node: JsonNode): JsonNode =
  ## Глубокая копия JSON. `JsonNode` — ссылка, поэтому `var b = a` в тесте
  ## молча правил бы ОБА документа, и проверка «изменилось» доказывала бы
  ## саму себя.
  parseJson($node)

suite "diff: проекты (#337)":
  test "одинаковые документы не различаются":
    let a = document(@[node(1), node(2, "euterpia.gain", "out")],
                     @[connection(1, 2)])
    let b = document(@[node(1), node(2, "euterpia.gain", "out")],
                     @[connection(1, 2)])
    let d = diffProjectJson(a, b)
    check d.identical
    check d.items.len == 0

  test "перестановка ключей и порядка нод не считается различием":
    # Ключи объектов и порядок элементов массивов — не «изменение»: ноды и
    # связи опознаются по id. Именно это свойство обещает #337.
    let first = document(@[node(1, freq = 110.0),
                           node(2, "euterpia.gain", "out")],
                         @[connection(1, 2)])
    let second = document(@[node(2, "euterpia.gain", "out"),
                            node(1, freq = 110.0)],
                          @[connection(1, 2)])
    let d = diffProjectJson(first, second)
    check d.identical
    check d.items.len == 0

  test "одна изменённая величина — ровно одно различие с адресом сущности":
    let a = document(@[node(1), node(2, "euterpia.gain", "out", freq = 220.0)])
    let b = document(@[node(1), node(2, "euterpia.gain", "out", freq = 330.0)])
    let d = diffProjectJson(a, b)
    check not d.identical
    check d.items.len == 1
    let item = d.items[0]
    check item.address == "node:2.parameters.freq"
    check item.section == "graph"
    check item.kind == dkChanged
    check item.before == "220.0"
    check item.after == "330.0"

  test "добавленная и удалённая нода — по одному различию, адрес по id":
    let base = document(@[node(1)])
    let withExtra = document(@[node(1), node(3, "euterpia.delay", "echo")])
    let added = diffProjectJson(base, withExtra)
    check added.items.len == 1
    check added.items[0].kind == dkAdded
    check added.items[0].address == "node:3"
    check "euterpia.delay" in added.items[0].label

    let removed = diffProjectJson(withExtra, base)
    check removed.items.len == 1
    check removed.items[0].kind == dkRemoved
    check removed.items[0].address == "node:3"

  test "связи адресуются видом сигнала и портами, а не индексом":
    let a = document(@[node(1), node(2)], @[connection(1, 2)])
    let b = document(@[node(1), node(2)])
    let d = diffProjectJson(a, b)
    check d.items.len == 1
    check d.items[0].kind == dkRemoved
    check d.items[0].address == "connection:1.a0->2.a0"

    let control = document(@[node(1), node(2)],
                           @[connection(1, 2, sigType = 1)])
    let swapped = diffProjectJson(a, control)
    check swapped.items.len == 2  # убрана audio-связь, добавлена control-связь


  test "ноты, точки автоматизации и состояния плагинов — по id":
    let trackA = %*{"id": 1, "name": "Lead", "trackType": 0, "volume": 1.0,
                    "pan": 0.0, "mute": false, "solo": false, "armed": false,
                    "inputChannel": 0, "outputBus": 0,
                    "clips": [%*{"id": 7, "clipType": 0, "name": "A",
                                 "startTick": 0, "lengthTicks": 960,
                                 "loopEnabled": false, "audioBufferId": -1,
                                 "resourceId": -1, "offsetFrames": 0,
                                 "color": 0,
                                 "notes": [%*{"startTick": 0, "duration": 240,
                                              "pitch": 60, "velocity": 100,
                                              "channel": 0}]}]}
    var trackB = clone(trackA)
    trackB["clips"][0]["notes"][0]["velocity"] = %101
    let noteDiff = diffProjectJson(document(@[], tracks = @[trackA]),
                                   document(@[], tracks = @[trackB]))
    check noteDiff.items.len == 1
    check noteDiff.items[0].address == "track:1/clip:7/note:0:60:0.velocity"
    check noteDiff.items[0].before == "100"
    check noteDiff.items[0].after == "101"

    let laneA = %*{"paramId": 11, "nodeId": 2,
                   "points": [%*{"tick": 0, "value": 0.5, "curve": 0}]}
    var laneB = clone(laneA)
    laneB["points"][0]["value"] = %0.75
    let laneDiff = diffProjectJson(document(@[], lanes = @[laneA]),
                                   document(@[], lanes = @[laneB]))
    check laneDiff.items.len == 1
    check laneDiff.items[0].address == "lane:2:11/point:0.value"

    let stateA = %*{"nodeId": 2, "pluginId": "mock", "state": [1, 2, 3]}
    let stateB = %*{"nodeId": 2, "pluginId": "mock", "state": [1, 2, 4]}
    let stateDiff = diffProjectJson(document(@[], pluginStates = @[stateA]),
                                    document(@[], pluginStates = @[stateB]))
    check stateDiff.items.len == 1
    check stateDiff.items[0].address == "pluginState:2.state"

  test "метаданные, ресурсы и формат различаются по своим адресам":
    let metaA = %*{"name": "A", "author": "", "sampleRate": 48000.0,
                   "tempo": 120.0,
                   "timeSignature": {"numerator": 4, "denominator": 4},
                   "created": "2026-01-01T00:00:00",
                   "modified": "2026-01-01T00:00:00"}
    var metaB = clone(metaA)
    metaB["tempo"] = %130.0
    let metaDiff = diffProjectJson(document(@[], metadata = metaA),
                                   document(@[], metadata = metaB))
    check metaDiff.items.len == 1
    check metaDiff.items[0].section == "metadata"
    check metaDiff.items[0].address == "metadata.tempo"

    let resA = %*{"id": 3, "path": "a.wav", "sampleRate": 48000,
                  "channels": 2, "numFrames": 48000, "bitsPerSample": 16,
                  "isFloat": false, "copy": false}
    var resB = clone(resA)
    resB["path"] = %"b.wav"
    let resDiff = diffProjectJson(document(@[], resources = @[resA]),
                                  document(@[], resources = @[resB]))
    check resDiff.items.len == 1
    check resDiff.items[0].address == "resource:3.path"
    check resDiff.items[0].section == "resources"

    var documentB = document(@[])
    documentB["version"] = %(ProjectFormatVersion + 1)
    let versionDiff = diffProjectJson(document(@[]), documentB)
    check versionDiff.items.len == 1
    check versionDiff.items[0].section == "format"
    check versionDiff.items[0].address == "version"

  test "diffProjects сравнивает канонический JSON формата":
    var a: ProjectFormat
    a.format = ProjectFormatName
    a.version = ProjectFormatVersion
    a.metadata.name = "Same"
    a.graph.nodes = @[NodeFormat(id: 1, nodeType: "euterpia.osc", name: "osc")]
    # Отдельный документ, а не копия: `seq` в Nim делит буфер, и правка `b`
    # изменила бы `a` — тест доказывал бы сам себя.
    var b: ProjectFormat
    b.format = ProjectFormatName
    b.version = ProjectFormatVersion
    b.metadata.name = "Same"
    b.graph.nodes = @[NodeFormat(id: 1, nodeType: "euterpia.osc", name: "osc")]
    let same = diffProjects(a, b)
    check same.identical
    b.graph.nodes[0].name = "other"
    let changed = diffProjects(a, b)
    check changed.items.len == 1
    check changed.items[0].address == "node:1.name"

  test "различие превращается в человеческую строку и в JSON":
    let a = document(@[node(1, freq = 100.0)])
    let b = document(@[node(1, freq = 200.0)])
    let d = diffProjectJson(a, b)
    check d.items.len == 1
    let line = diffLine(d.items[0])
    check "node:1.parameters.freq" in line
    check "изменено" in line
    check "100.0" in line
    check "200.0" in line
    let body = projectDiffJson(d)
    check body["format"].getStr == DiffFormatName
    check body["version"].getInt == DiffFormatVersion
    check body["identical"].getBool == false
    check body["count"].getInt == 1
    check body["items"][0]["address"].getStr == "node:1.parameters.freq"


# =============================================================================
# Сравнение рендеров (#337, #338)
# =============================================================================
#
# Файлы пишутся настоящим кодеком ядра: сравнение звука проверяется на звуке,
# а не на подделке. Допуск метрик (1e-6) меньше шага 16-битного квантования,
# поэтому «тот же сигнал» обязан совпасть побайтово, а «другой» — разойтись.

const
  UnitChannels = 2
  UnitRate = 48000

proc writeWav(path: string; samples: seq[float32]; sampleRate = UnitRate;
              channels = UnitChannels; bits = 16) =
  var info = AudioFileInfo(sampleRate: int32(sampleRate),
                           channels: int16(channels),
                           bitsPerSample: int16(bits),
                           isFloat: false, format: afWav)
  var buffer = samples
  var enc = openEncoder(path, info)
  enc.writeFrames(cast[ptr UncheckedArray[float32]](addr buffer[0]),
                  int32(samples.len div channels))
  enc.close()

proc tone(frames: int; freq = 440.0; gain = 0.5;
          channels = UnitChannels): seq[float32] =
  result = newSeq[float32](frames * channels)
  for frame in 0 ..< frames:
    let value = gain * sin(2.0 * PI * float64(frame) * freq / float64(UnitRate))
    for ch in 0 ..< channels:
      result[frame * channels + ch] = float32(value)

suite "diff: рендеры (#337, #338)":
  let dir = getTempDir() / "euterpia_diff_unit"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)

  test "одинаковые файлы: ноль различий, сэмплы совпадают":
    let pathA = dir / "a.wav"
    let pathB = dir / "b.wav"
    let samples = tone(2048)
    writeWav(pathA, samples)
    writeWav(pathB, samples)
    let d = diffRenderFiles(pathA, pathB)
    check d.ok
    check d.identical
    check d.items.len == 0
    check d.differingSamples == 0
    check d.a.frames == 2048
    check d.a.channels == 2
    check d.a.sampleRate == UnitRate
    check d.a.fileSha1 == d.b.fileSha1
    check d.a.samplesSha1 == d.b.samplesSha1
    check d.a.peak > 0.0
    check d.a.bands.mid > 0.0

  test "один изменённый сэмпл — различие с номером кадра, а не «файлы разные»":
    let pathA = dir / "one-a.wav"
    let pathB = dir / "one-b.wav"
    let samples = tone(1024)
    writeWav(pathA, samples)
    var edited = samples
    let index = 300
    edited[index] = edited[index] + 0.05f
    writeWav(pathB, edited)
    let d = diffRenderFiles(pathA, pathB)
    check d.ok
    check not d.identical
    check d.differingSamples == 1
    check d.firstSample == index
    check d.firstFrame == index div UnitChannels
    check d.maxDelta > 0.04
    check findItem(d.items, "render.samples") >= 0
    check findItem(d.items, "render.file") >= 0
    # Пик и RMS могут совпасть: одиночный сэмпл в них почти не виден —
    # поэтому поштучное сравнение и существует.
    check findItem(d.items, "render.frames") < 0

  test "разная длина файла — расхождение, а не «нет данных»":
    let pathA = dir / "short.wav"
    let pathB = dir / "long.wav"
    writeWav(pathA, tone(512))
    writeWav(pathB, tone(1024))
    let d = diffRenderFiles(pathA, pathB)
    check d.ok
    check not d.identical
    check findItem(d.items, "render.frames") >= 0
    check d.differingSamples >= 512 * UnitChannels
    check d.firstFrame == 512

  test "другая частота: спектральная сводка объясняет разницу числом":
    let pathA = dir / "low.wav"
    let pathB = dir / "high.wav"
    writeWav(pathA, tone(4096, freq = 220.0))
    writeWav(pathB, tone(4096, freq = 3520.0))
    let d = diffRenderFiles(pathA, pathB)
    check d.ok
    check not d.identical
    check d.a.centroidHz < d.b.centroidHz
    check findItem(d.items, "render.centroidHz") >= 0
    check findItem(d.items, "render.band.mid") >= 0

  test "нечитаемый файл — отказ, а не «различий нет»":
    let pathA = dir / "ok.wav"
    writeWav(pathA, tone(256))
    let missing = diffRenderFiles(pathA, dir / "нет-такого.wav")
    check not missing.ok
    check missing.error.len > 0
    check not missing.identical
    let body = renderDiffJson(missing)
    check body["identical"].getBool == false
    check body["error"].getStr.len > 0

  test "машинный отчёт рендера перечисляет измерения обоих файлов":
    let pathA = dir / "json-a.wav"
    let pathB = dir / "json-b.wav"
    writeWav(pathA, tone(512))
    writeWav(pathB, tone(512, gain = 0.25))
    let d = diffRenderFiles(pathA, pathB)
    check d.ok
    let body = renderDiffJson(d)
    check body["format"].getStr == DiffFormatName
    check body["identical"].getBool == false
    check body["count"].getInt == d.items.len
    check body["a"]["frames"].getInt == 512
    check body["b"]["peak"].getFloat < body["a"]["peak"].getFloat
    check body["totalSamples"].getInt == 512 * UnitChannels
    check body["firstFrame"].getInt >= 0

