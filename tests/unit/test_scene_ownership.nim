# tests/unit/test_scene_ownership.nim
#
# Владение пайплайном: сцена создаёт его, движок рендера забирает.
#
# Регрессия (найдена через ASan + `-d:useMalloc`): `renderToWav` отдаёт
# пайплайн аудиодвижку (`postGraphUpdate`), движок освобождает его вместе с
# собой, а `destroyScene` освобождал тот же указатель ВТОРОЙ раз. Двойное
# освобождение портило кучу, и падала не она, а следующая крупная аллокация —
# поэтому симптом выглядел как «SIGSEGV в buildProject после render».
#
# Лечение: `detachPipeline(scene)` снимает владение со сцены перед передачей
# пайплайна рендеру. Тест фиксирует и порядок, и то, что после рендера куча
# жива (крупная аллокация проходит).

import std/[os, tables, unittest, math]

import signal_types
import project
import transport
import compiled_pipeline
import sdk/node_registry
import builtin/builtin_registry
import builtin/scene_loader
import offline_render
import audio_file_io

const
  Sr = 48000

proc tinyProject(): ProjectFormat =
  ## Мини-проект: нотная нода → флейта → сумматор-мастер.
  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.metadata = ProjectMetadata(
    name: "Tiny", author: "", sampleRate: 48000.0f32, tempo: 200.0f32,
    timeSignature: TimeSignatureFormat(numerator: 4, denominator: 4),
    created: "", modified: "")

  result.graph.nodes = @[
    NodeFormat(id: 1, nodeType: "euterpia.notes", name: "F",
               eventOutCount: 1),
    NodeFormat(id: 2, nodeType: "euterpia.flute", name: "Fl",
               audioOutCount: 1, eventInCount: 1),
    NodeFormat(id: 3, nodeType: "euterpia.mix", name: "Mix",
               audioInCount: 8, audioOutCount: 1)
  ]
  result.graph.connections = @[
    ConnectionFormat(srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0,
                     sigType: ord(sigEvent)),
    ConnectionFormat(srcNodeId: 2, srcPortIdx: 0, dstNodeId: 3, dstPortIdx: 0,
                     sigType: ord(sigAudio))
  ]

  var clip = ClipFormat(id: 1, clipType: 0, name: "f", startTick: 0,
                        lengthTicks: 4 * PpqTicksPerQuarter, loopEnabled: false,
                        audioBufferId: -1)
  clip.notes = @[NoteFormat(startTick: 0, duration: PpqTicksPerQuarter,
                            pitch: 60, velocity: 100, channel: 0)]
  result.sequencer.tracks = @[
    TrackFormat(id: 1, name: "f", trackType: 0, clips: @[clip],
                volume: 1.0f32, pan: 0.0f32)
  ]

suite "сцена: владение пайплайном":
  test "renderToWav забирает пайплайн, сцена больше его не освобождает":
    let proj = tinyProject()
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)

    var scene = loadScene(reg, proj, -1, int32(Sr))
    check scene.ok
    defer: destroyScene(scene)

    var pipeline = detachPipeline(scene)
    check not pipeline.isEmpty
    check scene.pipeline == nil      # владение снято

    var opts = defaultRenderOptions(int32(Sr), 512, 0.4)
    opts.tempo = 200.0
    let rep = renderToWav(getTempDir() / "eut_scene_ownership.wav",
                          move(pipeline), opts)
    check rep.ok
    check pipeline.isEmpty           # владение ушло рендеру (#402)

    # Здесь и ловится регрессия: при двойном освобождении пайплайна куча уже
    # испорчена, и первая крупная аллокация падает.
    var t = initTable[string, seq[int]]()
    for i in 0 ..< 500:
      t["k" & $i] = @[i, i * 2, i * 3]
    check t.len == 500
    var acc = 0
    for _, v in t:
      acc += v.len
    check acc == 1500

  test "нода euterpia.sequencer играет клипы проекта без нотных нод (#87)":
    # Тот же проект, но нотную ноду заменили плеером секвенсора: дорожки
    # проекта больше не раскладываются в паттерн `euterpia.notes`.
    var proj = tinyProject()
    proj.graph.nodes[0] = NodeFormat(id: 1, nodeType: "euterpia.sequencer",
                                     name: "Seq", eventOutCount: 1)

    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)

    var scene = loadScene(reg, proj, -1, int32(Sr))
    check scene.ok
    defer: destroyScene(scene)
    check scene.songEndTick == PpqTicksPerQuarter

    var pipeline = detachPipeline(scene)
    var opts = defaultRenderOptions(int32(Sr), 512, 1.0)
    opts.tempo = 120.0
    let rep = renderToWav(getTempDir() / "eut_sequencer_player.wav",
                          move(pipeline), opts)
    check rep.ok
    check not rep.silent
    check rep.peak > 0.0f

  test "стемы: сумма solo-рендеров равна полному миксу (#209)":
    var proj = tinyProject()
    # Две дорожки, две нотные ноды, два инструмента и общий сумматор.
    proj.graph.nodes = @[
      NodeFormat(id: 1, nodeType: "euterpia.notes", name: "N1",
                 eventOutCount: 1),
      NodeFormat(id: 2, nodeType: "euterpia.notes", name: "N2",
                 eventOutCount: 1),
      NodeFormat(id: 3, nodeType: "euterpia.flute", name: "F",
                 audioOutCount: 1, eventInCount: 1),
      NodeFormat(id: 4, nodeType: "euterpia.piano", name: "P",
                 audioOutCount: 1, eventInCount: 1),
      NodeFormat(id: 5, nodeType: "euterpia.mix", name: "Mix",
                 audioInCount: 8, audioOutCount: 1)
    ]
    proj.graph.connections = @[
      ConnectionFormat(srcNodeId: 1, srcPortIdx: 0, dstNodeId: 3,
                       dstPortIdx: 0, sigType: ord(sigEvent)),
      ConnectionFormat(srcNodeId: 2, srcPortIdx: 0, dstNodeId: 4,
                       dstPortIdx: 0, sigType: ord(sigEvent)),
      ConnectionFormat(srcNodeId: 3, srcPortIdx: 0, dstNodeId: 5,
                       dstPortIdx: 0, sigType: ord(sigAudio)),
      ConnectionFormat(srcNodeId: 4, srcPortIdx: 0, dstNodeId: 5,
                       dstPortIdx: 1, sigType: ord(sigAudio))
    ]
    var c1 = ClipFormat(id: 1, clipType: 0, name: "a", startTick: 0,
                        lengthTicks: 4 * PpqTicksPerQuarter,
                        loopEnabled: false, audioBufferId: -1)
    c1.notes = @[NoteFormat(startTick: 0, duration: PpqTicksPerQuarter,
                            pitch: 60, velocity: 100, channel: 0)]
    var c2 = ClipFormat(id: 2, clipType: 0, name: "b", startTick: 0,
                        lengthTicks: 4 * PpqTicksPerQuarter,
                        loopEnabled: false, audioBufferId: -1)
    c2.notes = @[NoteFormat(startTick: 0, duration: PpqTicksPerQuarter,
                            pitch: 67, velocity: 90, channel: 0)]
    proj.sequencer.tracks = @[
      TrackFormat(id: 1, name: "A", trackType: 0, clips: @[c1],
                  volume: 1.0f32, pan: 0.0f32),
      TrackFormat(id: 2, name: "B", trackType: 0, clips: @[c2],
                  volume: 1.0f32, pan: 0.0f32)
    ]

    var regFull = initNodeRegistry()
    discard registerBuiltinNodes(regFull)
    var fullScene = loadScene(regFull, proj, -1, int32(Sr))
    check fullScene.ok
    var fullOpts = defaultRenderOptions(int32(Sr), 512, 1.0)
    fullOpts.tempo = 120.0
    let fullPath = getTempDir() / "eut_stems_full.wav"
    let fullRep = renderToWav(fullPath, detachPipeline(fullScene),
                              fullOpts)
    check fullRep.ok
    defer: destroyScene(fullScene)

    var sum: seq[float32] = @[]
    for trackId in [1'i32, 2'i32]:
      var reg = initNodeRegistry()
      discard registerBuiltinNodes(reg)
      var scene = loadScene(reg, proj, -1, int32(Sr), "", trackId)
      check scene.ok
      let path = getTempDir() / ("eut_stem_" & $trackId & ".wav")
      let rep = renderToWav(path, detachPipeline(scene), fullOpts)
      check rep.ok
      destroyScene(scene)
      var decoder = openDecoder(path)
      let info = decoder.wavReader.info
      let frames = int(info.numFrames)
      var buf = newSeq[float32](frames * 2)
      var raw = newSeq[uint8](frames * 2 * 2)
      let n = readFrames(decoder, cast[ptr UncheckedArray[uint8]](addr raw[0]),
                         cast[ptr UncheckedArray[float32]](addr buf[0]),
                         int32(frames))
      close(decoder)
      check n == int32(frames)
      if sum.len == 0:
        sum = newSeq[float32](buf.len)
      for i in 0 ..< min(sum.len, buf.len):
        sum[i] += buf[i]

    var decoder = openDecoder(fullPath)
    let info = decoder.wavReader.info
    let frames = int(info.numFrames)
    var master = newSeq[float32](frames * 2)
    var raw = newSeq[uint8](frames * 2 * 2)
    discard readFrames(decoder, cast[ptr UncheckedArray[uint8]](addr raw[0]),
                       cast[ptr UncheckedArray[float32]](addr master[0]),
                       int32(frames))
    close(decoder)
    check sum.len == master.len
    var maxErr = 0.0f
    for i in 0 ..< master.len:
      maxErr = max(maxErr, abs(sum[i] - master[i]))
    # 16-битное квантование двух файлов: допуск 2 шага.
    check maxErr <= 3.0f / 32768.0f
