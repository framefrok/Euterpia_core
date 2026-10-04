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

import std/[os, tables, unittest]

import signal_types
import project
import transport
import sdk/node_registry
import builtin/builtin_registry
import builtin/scene_loader
import offline_render

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

    let pipeline = detachPipeline(scene)
    check pipeline != nil
    check scene.pipeline == nil      # владение снято

    var opts = defaultRenderOptions(int32(Sr), 512, 0.4)
    opts.tempo = 200.0
    let rep = renderToWav(getTempDir() / "eut_scene_ownership.wav", pipeline, opts)
    check rep.ok

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
