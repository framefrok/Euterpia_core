# tests/unit/test_audio_file_io.nim
#
# commons/audio_file_io.nim — фасад чтения/записи аудиофайлов (issue #57).
#
# Модуль — единственная точка, где осталась зависимость Commons -> Core
# (issue #5). Здесь это не проверяется; проверяется поведение фасада:
#   - round-trip WAV для 16/24/32-bit (int и float), стерео, порядок каналов;
#   - диспетчер форматов: неподдерживаемое расширение -> IOError;
#   - отсутствующий файл -> IOError;
#   - getInfo отдаёт корректные метаданные.

import std/[unittest, os, math]
import audio_file_io
import wav_codec

proc writeWav(path: string; info: AudioFileInfo; samples: seq[float32]) =
  var enc = openEncoder(path, info)
  var buf = samples
  let frames = int32(samples.len div int(info.channels))
  enc.writeFrames(cast[ptr UncheckedArray[float32]](addr buf[0]), frames)
  enc.close()

proc sineSeq(frames, channels: int; freq: float32): seq[float32] =
  result = newSeq[float32](frames * channels)
  for f in 0 ..< frames:
    for c in 0 ..< channels:
      result[f * channels + c] = sin(2.0f * PI * float32(f) * freq / 48000.0f) * 0.5f

proc info(bits: int16; channels: int16; isFloat: bool): AudioFileInfo =
  AudioFileInfo(
    sampleRate: 48000'i32, channels: channels,
    bitsPerSample: bits, isFloat: isFloat, format: afWav)

suite "audio_file_io: round-trip":
  test "16-bit PCM сохраняет форму сигнала":
    let path = getTempDir() / "euterpia_afio_16.wav"
    let src = sineSeq(512, 1, 1000.0f)
    writeWav(path, info(16, 1, false), src)
    defer: removeFile(path)

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.sampleRate == 48000
    check gotInfo.channels == 1
    check gotInfo.numFrames == 512
    check got.len == 512

    var maxErr = 0.0f
    for i in 0 ..< src.len:
      maxErr = max(maxErr, abs(got[i] - src[i]))
    # Квантование 16 бит: шаг ~ 1/32768.
    check maxErr < 1e-3f

  test "32-bit float точен":
    let path = getTempDir() / "euterpia_afio_32f.wav"
    let src = sineSeq(256, 1, 440.0f)
    writeWav(path, info(32, 1, true), src)
    defer: removeFile(path)

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.isFloat
    check gotInfo.numFrames == 256
    for i in 0 ..< src.len:
      check abs(got[i] - src[i]) < 1e-6f

  test "стерео 24-bit: каналы не перепутаны":
    let path = getTempDir() / "euterpia_afio_24.wav"
    # Левый = +0.25, правый = -0.25 константой.
    var src = newSeq[float32](128 * 2)
    for f in 0 ..< 128:
      src[f * 2] = 0.25f
      src[f * 2 + 1] = -0.25f
    writeWav(path, info(24, 2, false), src)
    defer: removeFile(path)

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.channels == 2
    check gotInfo.numFrames == 128
    for f in 0 ..< 128:
      check abs(got[f * 2] - 0.25f) < 1e-5f
      check abs(got[f * 2 + 1] + 0.25f) < 1e-5f

suite "audio_file_io: диспетчер форматов и ошибки":
  test "openDecoder отвергает неподдерживаемое расширение":
    expect IOError:
      discard openDecoder("track.mp3")
    expect IOError:
      discard openDecoder("track.flac")
    expect IOError:
      discard openDecoder("track.ogg")
    expect IOError:
      discard openDecoder("track.aiff")

  test "openEncoder отвергает неподдерживаемое расширение":
    expect IOError:
      discard openEncoder("mix.flac", info(16, 2, false))

  test "расширение распознаётся без учёта регистра":
    let path = getTempDir() / "euterpia_afio_upper.WAV"
    writeWav(path, info(16, 1, false), sineSeq(64, 1, 500.0f))
    defer: removeFile(path)
    var dec = openDecoder(path)
    check dec.getInfo().numFrames == 64
    dec.close()

  test "loadAudioFile на отсутствующем файле бросает IOError":
    expect IOError:
      discard loadAudioFile(getTempDir() / "euterpia_afio_missing.wav")

  test "getInfo отдаёт метаданные и duration":
    let path = getTempDir() / "euterpia_afio_info.wav"
    writeWav(path, info(32, 2, true), sineSeq(4800, 2, 200.0f))
    defer: removeFile(path)

    var dec = openDecoder(path)
    let gi = dec.getInfo()
    check gi.sampleRate == 48000
    check gi.channels == 2
    check gi.bitsPerSample == 32
    check gi.isFloat
    check gi.format == afWav
    check gi.numFrames == 4800
    check abs(gi.duration - 0.1) < 1e-9     # 4800 сэмплов при 48 кГц
    dec.close()

