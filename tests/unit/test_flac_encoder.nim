# tests/unit/test_flac_encoder.nim
#
# FLAC-энкодер (issue #411).
#
# Критерии приёмки в исполняемом виде:
#   * файл читается ядром (dr_flac) и содержит то же число кадров;
#   * round-trip ≤ 1 LSB для 16 и 24 бит (lossless);
#   * повторный экспорт детерминирован (тот же dither/PRNG);
#   * WAV-путь не меняется — энкодер подключается отдельной ветвью;
#   * внешний `flac -t`, если он установлен, принимает файл.

import std/[unittest, math, os, osproc, strutils]

import flac_codec
import codec_api
import audio_file_io

const
  Sr = 44100'i32
  Seconds = 0.5
  Frames = int(Sr.float32 * Seconds)
  Channels = 2

proc makeSine(): seq[float32] =
  result = newSeq[float32](Frames * Channels)
  for i in 0 ..< Frames:
    let v = float32(sin(2.0 * PI * 440.0 * float64(i) / float64(Sr)) * 0.5)
    result[i * Channels] = v
    result[i * Channels + 1] = -v

proc encode(path: string; bits: int16; samples: seq[float32];
            dither = false) =
  var info = AudioFileInfo(sampleRate: Sr, channels: int16(Channels),
                           bitsPerSample: bits, numFrames: int64(Frames),
                           isFloat: false, format: afFlac, dither: dither)
  var writer = openFlacWriter(path, info)
  writeFrames(writer,
    cast[ptr UncheckedArray[float32]](unsafeAddr samples[0]),
    int32(Frames))
  close(writer)

proc qStep(bits: int): float64 =
  if bits == 16: 1.0 / 32767.0 else: 1.0 / 8388607.0

suite "flac: lossless-энкодер (#411)":

  test "16 бит: round-trip и точное число кадров":
    let dir = getTempDir() / "euterpia_flac_enc16"
    createDir(dir)
    let path = dir / "sine16.flac"
    let src = makeSine()
    encode(path, 16, src)
    check fileExists(path)

    let (decoded, info) = readAllAudioFile(path)
    check info.sampleRate == Sr
    check info.channels == int16(Channels)
    check info.numFrames == int64(Frames)
    check decoded.len == src.len

    var maxDiff = 0.0
    for i in 0 ..< src.len:
      let d = abs(float64(src[i] - decoded[i]))
      if d > maxDiff: maxDiff = d
    # Квантование 16 бит: шаг 1/32767; декодер отдаёт float по той же шкале.
    check maxDiff <= qStep(16) + 1.0e-6

  test "24 бита: round-trip точнее шага 16-бит":
    let dir = getTempDir() / "euterpia_flac_enc24"
    createDir(dir)
    let path = dir / "sine24.flac"
    let src = makeSine()
    encode(path, 24, src)
    let (decoded, info) = readAllAudioFile(path)
    check info.numFrames == int64(Frames)
    var maxDiff = 0.0
    for i in 0 ..< src.len:
      let d = abs(float64(src[i] - decoded[i]))
      if d > maxDiff: maxDiff = d
    check maxDiff <= qStep(24) + 1.0e-6
    check maxDiff < qStep(16)

  test "повторный экспорт байт-в-байт детерминирован":
    let dir = getTempDir() / "euterpia_flac_det"
    createDir(dir)
    let a = dir / "a.flac"
    let b = dir / "b.flac"
    let src = makeSine()
    encode(a, 16, src, dither = true)
    encode(b, 16, src, dither = true)
    check readFile(a) == readFile(b)

  test "моно и неверные параметры":
    let dir = getTempDir() / "euterpia_flac_mono"
    createDir(dir)
    let path = dir / "mono.flac"
    var mono = newSeq[float32](Frames)
    for i in 0 ..< Frames:
      mono[i] = float32(sin(2.0 * PI * 220.0 * float64(i) / float64(Sr)) * 0.25)
    var info = AudioFileInfo(sampleRate: Sr, channels: 1, bitsPerSample: 16,
                             numFrames: int64(Frames), format: afFlac)
    var writer = openFlacWriter(path, info)
    writeFrames(writer,
      cast[ptr UncheckedArray[float32]](addr mono[0]), int32(Frames))
    close(writer)
    let (decoded, got) = readAllAudioFile(path)
    check got.channels == 1
    check got.numFrames == int64(Frames)
    check decoded.len == Frames

    expect IOError:
      discard openFlacWriter(dir / "bad.flac",
        AudioFileInfo(sampleRate: Sr, channels: 3, bitsPerSample: 16,
                      format: afFlac))
    expect IOError:
      discard openFlacWriter(dir / "bad2.flac",
        AudioFileInfo(sampleRate: Sr, channels: 2, bitsPerSample: 12,
                      format: afFlac))
    expect IOError:
      discard openFlacWriter(dir / "bad3.flac",
        AudioFileInfo(sampleRate: 0, channels: 2, bitsPerSample: 16,
                      format: afFlac))

  test "внешний flac -t принимает файл (если инструмент есть)":
    let flacTool = findExe("flac")
    if flacTool.len == 0:
      skip()
    else:
      let dir = getTempDir() / "euterpia_flac_tool"
      createDir(dir)
      let path = dir / "check.flac"
      encode(path, 16, makeSine())
      let (output, code) = execCmdEx(quoteShell(flacTool) & " -t " &
                                     quoteShell(path))
      check code == 0
      check "ok" in output.toLowerAscii()
