# tests/unit/test_codecs.nim
#
# Реальные кодеки (issue #10): FLAC, MP3, OGG Vorbis, AIFF.
#
# Фикстуры — короткий синус 440 Гц (tests/fixtures/tone.*), сгенерированы
# ffmpeg/flac из одного WAV, поэтому эталон для lossless — тот же WAV.
# Lossless (FLAC, AIFF): совпадение выборки ≤ 1e-6. Lossy (MP3, OGG):
# сравнение по RMS. Битый файл — пустой результат, а не падение.

import std/[unittest, math, os]
import audio_file_io
import codecs/decoders
import codecs/aiff

const Fixtures = "tests/fixtures"

proc fixture(name: string): string = Fixtures / name

proc rms(s: seq[float32]): float32 =
  if s.len == 0:
    return 0.0f
  var acc = 0.0'f64
  for x in s:
    acc += float64(x) * float64(x)
  sqrt(acc / float64(s.len)).float32

proc maxAbsDiff(a, b: seq[float32]): float32 =
  for i in 0 ..< min(a.len, b.len):
    let d = abs(a[i] - b[i])
    if d > result:
      result = d

suite "codecs: FLAC/MP3/OGG/AIFF (issue #10)":
  test "FLAC lossless: декод совпадает с WAV ≤ 1e-6":
    let (refSamples, info) = loadAudioFile(fixture("tone.wav"))
    var ci: CodecInfo
    check probeCodec(fixture("tone.flac"), ckFlac, ci)
    check ci.channels == int(info.channels)
    check ci.sampleRate == int(info.sampleRate)
    let got = decodeCodec(fixture("tone.flac"), ckFlac)
    check got.len == refSamples.len
    check maxAbsDiff(got, refSamples) <= 1e-6f

  test "AIFF lossless: декод совпадает с WAV ≤ 1e-6":
    let (refSamples, _) = loadAudioFile(fixture("tone.wav"))
    var ai: AiffInfo
    check probeAiff(fixture("tone.aiff"), ai)
    check ai.channels == 2
    check ai.sampleRate == 48000
    let got = readAiffAll(fixture("tone.aiff"), ai)
    check got.len == refSamples.len
    check maxAbsDiff(got, refSamples) <= 1e-6f

  test "AIFF encode → decode: круг ≤ 1/32768":
    let (refSamples, _) = loadAudioFile(fixture("tone.wav"))
    let outPath = getTempDir() / "eut_codec_rt.aiff"
    check writeAiff(outPath, 2, 48000, 16, refSamples)
    var ai: AiffInfo
    check probeAiff(outPath, ai)
    let back = readAiffAll(outPath, ai)
    check back.len == refSamples.len
    check maxAbsDiff(back, refSamples) <= (1.0f / 32768.0f + 1e-6f)
    removeFile(outPath)

  test "MP3/OGG (lossy): RMS близок к оригиналу":
    let (refSamples, _) = loadAudioFile(fixture("tone.wav"))
    let mp3 = decodeCodec(fixture("tone.mp3"), ckMp3)
    let ogg = decodeCodec(fixture("tone.ogg"), ckVorbis)
    check mp3.len > 0
    check ogg.len > 0
    let r = rms(refSamples)
    check abs(rms(mp3) - r) < 0.05f
    check abs(rms(ogg) - r) < 0.05f

  test "битый/усечённый файл — пустой результат, а не падение":
    check decodeCodec(fixture("tone_truncated.flac"), ckFlac).len == 0
    var ci: CodecInfo
    check not probeCodec(fixture("does-not-exist.flac"), ckFlac, ci)
    var ai: AiffInfo
    check not probeAiff(fixture("tone.flac"), ai)   # не AIFF
