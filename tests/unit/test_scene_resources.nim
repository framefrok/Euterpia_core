# tests/unit/test_scene_resources.nim
#
# Аудиоресурсы сцены (issue #389, EUT-NEW-018/019):
#   - слот клипа получает метаданные ИЗ ФАЙЛА, а не из JSON проекта;
#   - расхождение метаданных — явное замечание загрузки;
#   - SR файла ≠ SR сцены — фатальная ошибка, а не тихое ускорение.

import std/[os, strutils, unittest]
import project
import signal_types
import transport
import audio_file_io
import sdk/node_registry
import builtin/builtin_registry
import builtin/scene_loader

const
  Sr = 48000

proc writeWav(path: string; sampleRate: int32; channels: int16;
              frames: int) =
  ## WAV-файл заданной формы: моно/стерео, константная амплитуда.
  let info = AudioFileInfo(
    sampleRate: sampleRate, channels: channels,
    bitsPerSample: 16, numFrames: int64(frames), isFloat: false,
    format: afWav)
  var samples = newSeq[float32](frames * int(channels))
  for i in 0 ..< samples.len:
    samples[i] = 0.25f
  exportAudio(path, info, samples)

proc clipProject(wavPath: string; declaredSR, declaredCh: int32;
                 declaredFrames: int64): ProjectFormat =
  ## Проект с одной audio-дорожкой: clip (id 1) → gain (id 2, мастер).
  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.metadata = ProjectMetadata(
    name: "ClipRes", author: "", sampleRate: float32(Sr), tempo: 120.0f,
    timeSignature: TimeSignatureFormat(numerator: 4, denominator: 4),
    created: "", modified: "")

  result.graph.nodes = @[
    NodeFormat(id: 1, nodeType: "euterpia.clip", name: "Clip",
               audioOutCount: 1),
    NodeFormat(id: 2, nodeType: "euterpia.gain", name: "Master",
               audioInCount: 1, audioOutCount: 1)
  ]
  result.graph.connections = @[
    ConnectionFormat(srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0,
                     sigType: ord(sigAudio))
  ]

  result.resources.add AudioResourceFormat(
    id: 1, path: wavPath, sampleRate: declaredSR, channels: declaredCh,
    numFrames: declaredFrames, bitsPerSample: 16, isFloat: false, copy: false)

  var track = TrackFormat(id: 1, name: "Audio", trackType: 1,
                          volume: 1.0f, pan: 0.0f)
  track.clips.add ClipFormat(
    id: 1, clipType: 1, name: "clip", startTick: 0,
    lengthTicks: 4 * PpqTicksPerQuarter, resourceId: 1, offsetFrames: 0)
  result.sequencer.tracks.add track

suite "сцена: аудиоресурсы (#389)":
  test "SR файла ≠ SR сцены — фатальная ошибка с указанием частот":
    let wav = getTempDir() / "eut_scene_res_44k.wav"
    writeWav(wav, 44100'i32, 1'i16, 256)
    defer: removeFile(wav)

    # Проект объявляет ресурс 48k, но файл — 44.1k: раньше клип молча играл
    # выше и короче (тик → сэмпл считался по 48k).
    let proj = clipProject(wav, 48000, 1, 256)
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)

    var scene = loadScene(reg, proj, -1, int32(Sr))
    check not scene.ok
    check "44100" in scene.error
    check "48000" in scene.error
    check scene.pipeline == nil
    destroyScene(scene)

  test "расхождение метаданных проекта и файла — замечание, слот верен":
    let wav = getTempDir() / "eut_scene_res_meta.wav"
    writeWav(wav, int32(Sr), 1'i16, 512)
    defer: removeFile(wav)

    # В проекте ресурс объявлен как 2 канала и 999999 кадров — файл другой.
    # Раньше слот получал объявленные значения: индексация выходила за
    # пределы реально загруженного буфера.
    let proj = clipProject(wav, int32(Sr), 2, 999999)
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)

    var scene = loadScene(reg, proj, -1, int32(Sr))
    check scene.ok
    check scene.issues.len > 0
    var foundMismatch = false
    for issue in scene.issues:
      if "не совпадают" in issue.message:
        foundMismatch = true
        check "999999" in issue.message   # названы метаданные проекта
        check "512" in issue.message      # названы фактические данные файла
    check foundMismatch
    check scene.clipNodeIds.len == 1
    destroyScene(scene)

  test "корректный файл без расхождений — сцена собирается без замечаний":
    let wav = getTempDir() / "eut_scene_res_ok.wav"
    writeWav(wav, int32(Sr), 2'i16, 128)
    defer: removeFile(wav)

    let proj = clipProject(wav, int32(Sr), 2, 128)
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)

    var scene = loadScene(reg, proj, -1, int32(Sr))
    check scene.ok
    for issue in scene.issues:
      check "не совпадают" notin issue.message
    destroyScene(scene)
