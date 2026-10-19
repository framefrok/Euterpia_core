# tests/unit/test_pipeline_ownership.nim
#
# Владение пайплайном выражено типом (issue #402, EUT-NEW-042).
#
# История double-free: движок освобождал пайплайн, а сцена освобождала его
# повторно. Лечение — move-only `OwnedPipeline`: один владелец, передача через
# `sink`, после передачи ручка пуста. Тест фиксирует контракт:
#   * копирование запрещено на этапе компиляции;
#   * `releasePipeline` — явный detach, после него ручка пуста;
#   * `postGraphUpdate` забирает владение, а повторная передача отклоняется;
#   * `detachPipeline(scene)` отдаёт владение, и `destroyScene` уже не трогает
#     пайплайн.

import std/[os, tables, unittest]

import signal_types
import project
import transport
import compiled_pipeline
import audio_engine
import sdk/node_registry
import builtin/builtin_registry
import builtin/scene_loader
import offline_render

suite "OwnedPipeline: владение как тип (#402)":
  # Копирование запрещено прагмой `{.error.}` на `=copy`/`=dup`; это
  # проверяется компилятором на реальном коде, а не через `compiles`
  # (магия `compiles` не инстанцирует хуки жизненного цикла).

  test "newOwnedPipeline -> releasePipeline: владелец ровно один":
    var owned = newOwnedPipeline()
    check not owned.isEmpty
    check not owned.borrow.isNil
    check owned.borrow.graphVersion != 0

    let raw = releasePipeline(owned)
    check raw != nil
    check owned.isEmpty
    check owned.borrow.isNil

    # Сырой указатель теперь принадлежит вызывающему.
    destroyPipeline(raw)

  test "postGraphUpdate забирает владение и отвергает повторную передачу":
    let engine = createAudioEngine(sampleRate = 48000.0f, blockSize = 128)
    check engine != nil
    defer: destroyAudioEngine(engine)

    var owned = newOwnedPipeline()
    check engine.postGraphUpdate(move(owned))
    check owned.isEmpty

    # Повторная передача той же ручки невозможна: пайплайн уже у движка.
    # API возвращает false, а не публикует nil и не освобождает дважды.
    check not engine.postGraphUpdate(move(owned))

    # Граф активируется первым блоком; движок жив.
    var outBuf: array[256, float32]
    let pout = cast[ptr UncheckedArray[float32]](addr outBuf[0])
    engine.renderBlock(nil, 0'i32, pout)
    check engine.droppedRetirementsCount() == 0'u32

    # Очистка графа — отдельная команда: пустая ручка означает «нет
    # владения», а не «снять граф».
    check engine.postGraphClear()
    engine.renderBlock(nil, 0'i32, pout)
    check engine.droppedRetirementsCount() == 0'u32

  test "отказ публикации освобождает пайплайн внутри движка (нет утечки/двойного free)":
    # null-движок: публикация отклоняется, OwnedPipeline освобождается
    # деструктором sink-параметра. Повторно освобождать нечего.
    var owned = newOwnedPipeline()
    let nilEngine: ptr AudioEngine = nil
    check not nilEngine.postGraphUpdate(move(owned))
    check owned.isEmpty

    # Куча жива: крупная аллокация после этого не падает.
    var t = initTable[string, seq[int]]()
    for i in 0 ..< 200:
      t["k" & $i] = @[i]
    check t.len == 200

# =============================================================================
# #402: сцена отдаёт владение, рендер его забирает
# =============================================================================

const
  Sr = 48000

proc tinyProject(): ProjectFormat =
  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.metadata = ProjectMetadata(
    name: "Owned", author: "", sampleRate: 48000.0f32, tempo: 200.0f32,
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

suite "сцена + рендер: владение не раздваивается (#402)":
  test "detachPipeline отдаёт OwnedPipeline, destroyScene безопасен":
    let proj = tinyProject()
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)

    var scene = loadScene(reg, proj, -1, int32(Sr))
    check scene.ok
    defer: destroyScene(scene)

    var pipeline = detachPipeline(scene)
    check not pipeline.isEmpty
    check scene.pipeline == nil

    # Сцена больше не владеет пайплайном: повторный destroyScene не трогает
    # его (проверяем на живой куче после рендера ниже).

    var opts = defaultRenderOptions(int32(Sr), 512, 0.2)
    opts.tempo = 200.0
    let rep = renderToWav(getTempDir() / "eut_owned_pipeline.wav",
                          move(pipeline), opts)
    check rep.ok
    check pipeline.isEmpty

    # Крупная аллокация: double-free проявился бы именно здесь.
    var t = initTable[string, seq[int]]()
    for i in 0 ..< 500:
      t["k" & $i] = @[i, i * 2]
    check t.len == 500
