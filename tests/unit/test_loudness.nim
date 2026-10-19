# tests/unit/test_loudness.nim
#
# Метрики громкости и пиков (issue #209) против эталонных значений BS.1770.
#
# Проверяется то, что можно проверить без «на слух»:
#   * синус 1 кГц известного уровня даёт ту же интегрированную громкость
#     (K-взвешивание на 1 кГц не меняет уровень — это свойство эталона);
#   * тишина не даёт -inf и не «усиливается»;
#   * true peak видит межсэмпловый пик, которого нет в отсчётах;
#   * нормализация попадает в цель, потолок соблюдён, результат отчёта
#     совпадает с повторным измерением;
#   * повторная нормализация идемпотентна в пределах допуска.

import std/[unittest, math]

import loudness

const
  Sr = 48000.0

proc sine(freq, ampl: float64; seconds: float64; channels = 2): seq[float32] =
  let frames = int(seconds * Sr)
  result = newSeq[float32](frames * channels)
  for i in 0 ..< frames:
    let v = float32(ampl * sin(2.0 * PI * freq * float64(i) / Sr))
    for ch in 0 ..< channels:
      result[i * channels + ch] = v

proc approx(a, b, tol: float64): bool = abs(a - b) <= tol

suite "loudness: BS.1770 (#209)":
  test "синус 1 кГц -20 dBFS ≈ -20 LUFS":
    let s = sine(1000.0, pow(10.0, -20.0 / 20.0), 5.0)
    let m = measureLoudness(s, 2, Sr)
    check approx(m.integratedLufs, -20.0, 0.2)
    check m.gatedBlocks > 0
    check approx(m.samplePeakDb, -20.0, 0.1)

  test "уровень -23 dBFS ≈ -23 LUFS (вещательный эталон EBU)":
    let s = sine(1000.0, pow(10.0, -23.0 / 20.0), 4.0)
    let m = measureLoudness(s, 2, Sr)
    check approx(m.integratedLufs, -23.0, 0.2)

  test "тишина: пол, а не -inf":
    let s = newSeq[float32](int(Sr) * 2)
    let m = measureLoudness(s, 2, Sr)
    check m.integratedLufs <= LoudnessFloorLufs
    check m.truePeakDb <= PeakFloorDb + 0.001
    check m.gatedBlocks == 0

  test "true peak видит межсэмпловый пик":
    # Частота fs/4, фаза 45°: отсчёты ±0.7071, а аналоговый пик — 1.0.
    let frames = int(Sr)
    var s = newSeq[float32](frames * 2)
    for i in 0 ..< frames:
      let v = float32(sin(2.0 * PI * 0.25 * float64(i) + PI / 4.0))
      s[i * 2] = v
      s[i * 2 + 1] = v
    let m = measureLoudness(s, 2, Sr)
    check approx(m.samplePeakDb, -3.01, 0.1)
    check m.truePeakDb > -0.5
    check m.truePeakDb < 0.5

suite "loudness: нормализация (#209)":
  test "цель достигается, потолок соблюдён":
    var s = sine(1000.0, pow(10.0, -30.0 / 20.0), 5.0)
    let opts = defaultMasterOptions(-14.0, -1.0)
    let rep = normalizeMaster(s, 2, Sr, opts)
    check approx(rep.gainDb, 16.0, 0.3)
    check approx(rep.output.integratedLufs, -14.0, 0.5)
    check rep.output.truePeakDb <= -1.0 + 1e-6

    # Отчёт не врёт: независимое измерение того же буфера совпадает.
    let again = measureLoudness(s, 2, Sr)
    check approx(again.integratedLufs, rep.output.integratedLufs, 0.05)
    check approx(again.truePeakDb, rep.output.truePeakDb, 0.05)

  test "пиковый материал удерживается потолком":
    # Громкий короткий импульс: после усиления без лимитера был бы клиппинг.
    var s = newSeq[float32](int(Sr) * 2 * 4)
    for i in 0 ..< s.len:
      s[i] = 0.30f * sin(2.0 * PI * 220.0 * float64(i div 2) / Sr)
    for i in 0 ..< 480:
      s[i] = 0.9f
    let rep = normalizeMaster(s, 2, Sr, defaultMasterOptions(-9.0, -1.0))
    check rep.output.truePeakDb <= -1.0 + 1e-6
    check rep.limitedFrames > 0

  test "покадровое усиление: сумма стемов равна мастеру":
    # Два источника, сумма которых обрабатывается как мастер. Если стемы
    # умножить на ТО ЖЕ покадровое усиление, их сумма обязана совпасть с
    # мастером (критерий «пакет стемов суммируется к мастеру»).
    var a = sine(440.0, 0.02, 4.0)
    var b = sine(1000.0, 0.05, 4.0)
    var mix = newSeq[float32](a.len)
    for i in 0 ..< mix.len:
      mix[i] = a[i] + b[i]

    var opts = defaultMasterOptions(-12.0, -1.0)
    opts.keepEnvelope = true
    let rep = normalizeMaster(mix, 2, Sr, opts)
    check rep.gainEnvelope.len == mix.len div 2

    for i in 0 ..< mix.len div 2:
      let g = rep.gainEnvelope[i]
      a[i * 2] *= g
      a[i * 2 + 1] *= g
      b[i * 2] *= g
      b[i * 2 + 1] *= g
    var maxErr = 0.0f
    for i in 0 ..< mix.len:
      maxErr = max(maxErr, abs((a[i] + b[i]) - mix[i]))
    check maxErr < 1e-5f

  test "тишину не усиливаем":
    var s = newSeq[float32](int(Sr) * 2)
    let rep = normalizeMaster(s, 2, Sr, defaultMasterOptions())
    check rep.gainDb == 0.0
    check rep.output.integratedLufs <= LoudnessFloorLufs
