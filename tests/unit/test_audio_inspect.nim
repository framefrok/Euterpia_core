# tests/unit/test_audio_inspect.nim
#
# Инспектор аудио (issue #290): проверка на ЭТАЛОННЫХ дефектах.
#
# Прибор, который судит звук, обязан сначала доказать, что сам умеет
# находить известные дефекты. Здесь каждый детектор проверяется на
# синтетическом сигнале с заранее известной проблемой и известным местом:
# клиппинг, DC, щелчок, жужжание 50 Гц, провал, «зависший» буфер, NaN,
# тишина. Отдельно — чистота на чистом синусе (нет ложных срабатываний)
# и детерминизм отчёта.

import std/[math, unittest]

import audio_inspect
import spectrum

const Sr = 48000.0'f32

proc sine(freq: float32; seconds: float64; amp: float32 = 0.5f;
          channels: int = 2): seq[float32] =
  let frames = int(seconds * float64(Sr))
  result = newSeq[float32](frames * channels)
  for f in 0 ..< frames:
    let v = amp * sin(2.0'f32 * PI * freq * float32(f) / Sr)
    for ch in 0 ..< channels:
      result[f * channels + ch] = v

proc hasKind(rep: InspectionReport; k: DefectKind): bool =
  for d in rep.defects:
    if d.kind == k:
      return true
  false

proc firstOf(rep: InspectionReport; k: DefectKind): int =
  ## Индекс дефекта данного типа или -1.
  for i, d in rep.defects:
    if d.kind == k:
      return i
  -1

# ----------------------------------------------------------------------------
# Примитивы
# ----------------------------------------------------------------------------

suite "spectrum: БПФ":
  test "пик спектра совпадает с частотой тона":
    var frame = newSeq[float32](2048)
    for i in 0 ..< frame.len:
      frame[i] = 0.5f * sin(2.0'f32 * PI * 1000.0f * float32(i) / Sr)
    var mag: seq[float32]
    magnitudeSpectrum(frame, mag)
    var peak = 1
    for k in 2 ..< mag.len:
      if mag[k] > mag[peak]:
        peak = k
    let hz = float32(peak) * hzPerBin(Sr, 2048)
    check abs(hz - 1000.0f) <= Sr / 2048.0f

# ----------------------------------------------------------------------------
# Эталонные дефекты
# ----------------------------------------------------------------------------

suite "audio_inspect: чистый сигнал не даёт ложных срабатываний":
  test "чистый синус: без клиппинга, жужжания и щелчков":
    let rep = inspectInterleaved(sine(1000.0f, 0.5), 2, Sr)
    check rep.maxSeverity < sevError
    check not rep.hasKind(dkClipping)
    check not rep.hasKind(dkHum)
    check not rep.hasKind(dkClick)
    check not rep.hasKind(dkDropout)
    check rep.metrics.peak > 0.4f
    check rep.metrics.spectralFlatness < 0.2f

suite "audio_inspect: технические дефекты":
  test "постоянная составляющая найдена":
    var s = sine(440.0f, 0.4)
    for i in 0 ..< s.len:
      s[i] += 0.05f
    let rep = inspectInterleaved(s, 2, Sr)
    check rep.hasKind(dkDcOffset)

  test "клиппинг найден и посчитан":
    var s = sine(200.0f, 0.4, 2.0f)
    for i in 0 ..< s.len:
      s[i] = max(-1.0f, min(1.0f, s[i]))
    let rep = inspectInterleaved(s, 2, Sr)
    check rep.hasKind(dkClipping)
    check rep.metrics.clippingSamples > 0

  test "щелчок найден в ожидаемом сэмпле":
    var s = sine(500.0f, 0.4)
    let at = 9000
    s[at * 2] += 0.8f
    s[at * 2 + 1] += 0.8f
    let rep = inspectInterleaved(s, 2, Sr)
    let idx = rep.firstOf(dkClick)
    check idx >= 0
    if idx >= 0:
      check abs(int(rep.defects[idx].startSample) - at) <= 2

  test "жужжание 50 Гц найдено (ряд гармоник)":
    var s = sine(1000.0f, 0.6, 0.4f)
    # Настоящая наводка — основная 50 Гц плюс гармоники, а не один тон.
    for f in 0 ..< s.len div 2:
      let t = float32(f) / Sr
      let h = 0.03f * sin(2.0'f32 * PI * 50.0f * t) +
              0.02f * sin(2.0'f32 * PI * 100.0f * t) +
              0.012f * sin(2.0'f32 * PI * 150.0f * t)
      s[f * 2] += h
      s[f * 2 + 1] += h
    let rep = inspectInterleaved(s, 2, Sr)
    check rep.hasKind(dkHum)

  test "провал (dropout) найден":
    var s = sine(440.0f, 0.5)
    let a = 8000
    let b = a + int(0.03 * float64(Sr))
    for i in a * 2 ..< b * 2:
      s[i] = 0.0f
    let rep = inspectInterleaved(s, 2, Sr)
    check rep.hasKind(dkDropout)

  test "зависший буфер (stall) найден":
    # Идентичные окна по 240 сэмплов (0.005 с) — признак зацикливания.
    let win = int(0.005 * float64(Sr))
    var blk = newSeq[float32](win * 2)
    for i in 0 ..< blk.len:
      blk[i] = sin(float32(i) * 0.3f) * 0.5f
    var s = newSeq[float32](blk.len * 20)
    for b in 0 ..< 20:
      for i in 0 ..< blk.len:
        s[b * blk.len + i] = blk[i]
    let rep = inspectInterleaved(s, 2, Sr)
    check rep.hasKind(dkStall)

  test "NaN найден и отмечен как error":
    var s = sine(440.0f, 0.2)
    s[1000] = NaN
    let rep = inspectInterleaved(s, 2, Sr)
    check rep.hasKind(dkNonFinite)
    check rep.maxSeverity == sevError

  test "тишина распознана, но не как «зависание»":
    let s = newSeq[float32](48000 * 2)
    let rep = inspectInterleaved(s, 2, Sr)
    check rep.hasKind(dkSilence)
    check not rep.hasKind(dkStall)

suite "audio_inspect: метрики и детерминизм":
  test "верный порядок отчёта по времени":
    var s = sine(500.0f, 0.5)
    s[2000] += 0.8f     # ранний щелчок
    s[20000] += 0.8f    # поздний щелчок
    let rep = inspectInterleaved(s, 2, Sr)
    var prev = -1'i64
    var ordered = true
    for d in rep.defects:
      if d.startSample < prev:
        ordered = false
      prev = d.startSample
    check ordered

  test "детерминизм: один вход — один отчёт":
    var s = sine(440.0f, 0.3)
    s[500] += 0.7f
    let a = inspectInterleaved(s, 2, Sr)
    let b = inspectInterleaved(s, 2, Sr)
    check a.defects.len == b.defects.len
    for i in 0 ..< a.defects.len:
      check a.defects[i].kind == b.defects[i].kind
      check a.defects[i].startSample == b.defects[i].startSample
      check a.defects[i].channel == b.defects[i].channel

