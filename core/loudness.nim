# core/loudness.nim
#
# Громкость и пики для сдачи материала (issue #209).
#
# Что здесь есть и почему именно так:
#   * LUFS по ITU-R BS.1770-4 / EBU R128: K-взвешивание двумя биквадами,
#     блоки 400 мс с шагом 100 мс, абсолютный порог -70 LUFS и относительный
#     -10 LU — это не «примерно громко», а эталонная формула;
#   * short-term (3 с) и LRA: динамический диапазон нужен отчёту, чтобы
#     «нормализовали» не вслепую;
#   * true peak: передискретизация ×4 windowed-sinc FIR. Sample peak
#     недостаточно: межсэмпловый пик выше него, и именно он клиппируется в
#     DAC/кодеке;
#   * нормализация с потолком: усиление по интегрированной громкости и
#     lookahead-лимитер по true peak. После лимитера true peak проверяется
#     ещё раз, и остаточное превышение снимается общим ослаблением — отчёт
#     говорит, сколько именно пришлось снять.
#
# Всё — offline/control-path: ни аллокаций в RT, ни зависимости от времени.
# Формулы на double: float32 на длинной сумме квадратов даёт заметную ошибку.

import std/[math, algorithm]

{.push raises: [].}

const
  LoudnessFloorLufs* = -70.0
    ## Абсолютный порог BS.1770. Ниже — тишина, а не «очень тихо».
  PeakFloorDb* = -120.0
    ## Пол dB для отчёта: JSON не умеет -inf, а «нет пика» должно быть числом.
  LUFS_OFFSET = -0.691
    ## Константа BS.1770 для суммы каналов с весами 1.0 (стерео).

type
  LoudnessReport* = object
    ## Метрики трека. Все значения — уже в LUFS/dB, не в «сырых» суммах.
    integratedLufs*: float64
      ## Интегрированная громкость по гейтам.
    shortTermMaxLufs*: float64
      ## Максимум short-term (3 с) — «самое громкое место».
    loudnessRangeLu*: float64
      ## LRA: размах short-term с гейтами -70 и -20 LU.
    truePeakDb*: float64
      ## Межсэмпловый пик (×4 oversampling).
    samplePeakDb*: float64
    frames*: int64
    gatedBlocks*: int
      ## Сколько блоков прошло гейты (диагностика: 0 — тишина).

  MasterOptions* = object
    targetLufs*: float64
    ceilingDb*: float64
      ## Потолок true peak (dBTP). -1.0 — обычная сдача на площадки.
    lookaheadMs*: float64
    keepEnvelope*: bool
      ## Сохранить покадровое усиление: нужно стемам (#209), чтобы их сумма
      ## совпала с мастером, а не «примерно совпала».

  MasterReport* = object
    input*: LoudnessReport
    output*: LoudnessReport
    gainDb*: float64
      ## Усиление по интегрированной громкости (до лимитера).
    appliedGainDb*: float64
      ## Итоговое усиление с учётом лимитера и остаточной коррекции.
    ceilingCorrectionDb*: float64
      ## Сколько сняли после лимитера, чтобы true peak точно вошёл в потолок.
    limitedFrames*: int64
      ## Сколько кадров затронул лимитер.
    gainEnvelope*: seq[float32]
      ## Покадровое усиление мастера (нормализация × лимитер × коррекция).
      ## Пусто, если `MasterOptions.keepEnvelope == false`.
    targetLufs*: float64
    ceilingDb*: float64

# =============================================================================
# K-взвешивание (BS.1770)
# =============================================================================

type
  Biquad = object
    b0, b1, b2, a1, a2: float64
    x1, x2, y1, y2: float64

proc process(b: var Biquad; x: float64): float64 {.inline.} =
  ## Direct Form I: устойчив к денормалам и не требует состояния в
  ## транспонированном виде.
  let y = b.b0 * x + b.b1 * b.x1 + b.b2 * b.x2 - b.a1 * b.y1 - b.a2 * b.y2
  b.x2 = b.x1
  b.x1 = x
  b.y2 = b.y1
  b.y1 = y
  y

proc shelfCoeffs(fs: float64): Biquad =
  ## Первый каскад K-взвешивания: high shelf +4 дБ на 1681.97 Гц.
  ## Коэффициенты — из эталонной реализации (libebur128/pyloudnorm), а не
  ## «подобраны на слух».
  const
    f0 = 1681.974450955533
    gainDb = 3.999843853973347
    q = 0.7071752369554196
  let k = tan(PI * f0 / fs)
  let vh = pow(10.0, gainDb / 20.0)
  let vb = pow(vh, 0.4996667741545416)
  let a0 = 1.0 + k / q + k * k
  result.b0 = (vh + vb * k / q + k * k) / a0
  result.b1 = 2.0 * (k * k - vh) / a0
  result.b2 = (vh - vb * k / q + k * k) / a0
  result.a1 = 2.0 * (k * k - 1.0) / a0
  result.a2 = (1.0 - k / q + k * k) / a0

proc highpassCoeffs(fs: float64): Biquad =
  ## Второй каскад: high-pass 38.14 Гц (Q 0.5003).
  const
    f0 = 38.13547087602444
    q = 0.5003270373238773
  let k = tan(PI * f0 / fs)
  let a0 = 1.0 + k / q + k * k
  result.b0 = 1.0 / a0
  result.b1 = -2.0 / a0
  result.b2 = 1.0 / a0
  result.a1 = 2.0 * (k * k - 1.0) / a0
  result.a2 = (1.0 - k / q + k * k) / a0

proc weighted(samples: openArray[float32]; channels: int; fs: float64):
    seq[float64] =
  ## K-взвешенный сигнал, interleaved в том же порядке.
  result = newSeq[float64](samples.len)
  for ch in 0 ..< channels:
    var shelf = shelfCoeffs(fs)
    var hp = highpassCoeffs(fs)
    var i = ch
    while i < samples.len:
      result[i] = hp.process(shelf.process(float64(samples[i])))
      i += channels

# =============================================================================
# Громкость
# =============================================================================

proc loudnessOf(meanSquare: float64): float64 {.inline.} =
  if meanSquare <= 0.0:
    return LoudnessFloorLufs
  LUFS_OFFSET + 10.0 * log10(meanSquare)

proc blockMeanSquares(w: openArray[float64]; channels: int;
                      blockFrames, stepFrames: int): seq[float64] =
  ## Средний квадрат блоков с перекрытием: для каждого окна суммируются
  ## каналы (вес 1.0), затем делится на число кадров.
  let frames = w.len div channels
  if frames <= 0 or blockFrames <= 0:
    return
  let step = max(1, stepFrames)
  var start = 0
  while start + blockFrames <= frames:
    var sum = 0.0
    var i = start
    let stop = start + blockFrames
    while i < stop:
      let base = i * channels
      for ch in 0 ..< channels:
        let v = w[base + ch]
        sum += v * v
      inc i
    result.add sum / float64(blockFrames)
    start += step
  if result.len == 0:
    # Сигнал короче окна: один блок по всей длине.
    var sum = 0.0
    for v in w:
      sum += v * v
    result.add sum / float64(max(1, frames))

proc percentile(values: var seq[float64]; p: float64): float64 =
  if values.len == 0:
    return 0.0
  values.sort()
  let idx = clamp(int(round(p * float64(values.len - 1))), 0,
                  values.len - 1)
  values[idx]

proc measureTruePeakDb(samples: openArray[float32]; channels: int): float64 =
  ## Пик с передискретизацией ×4. FIR — windowed sinc (Blackman-Harris),
  ## 8 отсчётов на фазу; каждая фаза нормируется по DC, иначе разные фазы
  ## давали бы разный «нулевой» уровень.
  const
    Phases = 4
    Taps = 16
    ProtoLen = Phases * Taps
  var proto: array[ProtoLen, float64]
  let center = float64(ProtoLen - 1) / 2.0
  for i in 0 ..< ProtoLen:
    let x = (float64(i) - center) / float64(Phases)
    let sinc = if abs(x) < 1e-12: 1.0 else: sin(PI * x) / (PI * x)
    let t = 2.0 * PI * float64(i) / float64(ProtoLen - 1)
    let window = 0.35875 - 0.48829 * cos(t) + 0.14128 * cos(2.0 * t) -
                 0.01168 * cos(3.0 * t)
    proto[i] = sinc * window

  # Нормировка по сумме всех отсчётов: DC-усиление фильтра = 1 после
  # децимации, а не «каждая фаза сама по себе» (это давало разный уровень
  # фаз на высоких частотах).
  var total = 0.0
  for i in 0 ..< ProtoLen:
    total += proto[i]
  let scale = if abs(total) > 1e-12: float64(Phases) / total else: 1.0
  var phaseTaps: array[Phases, array[Taps, float64]]
  for p in 0 ..< Phases:
    for j in 0 ..< Taps:
      phaseTaps[p][j] = proto[j * Phases + p] * scale

  var peak = 0.0
  let frames = samples.len div channels
  for ch in 0 ..< channels:
    for n in 0 ..< frames:
      for p in 0 ..< Phases:
        var acc = 0.0
        for j in 0 ..< Taps:
          let idx = n - j
          if idx < 0:
            continue
          acc += phaseTaps[p][j] * float64(samples[idx * channels + ch])
        let a = abs(acc)
        if a > peak:
          peak = a

  if peak <= 0.0:
    return PeakFloorDb
  20.0 * log10(peak)

proc measureSamplePeakDb(samples: openArray[float32]): float64 =
  var peak = 0.0
  for v in samples:
    let a = abs(float64(v))
    if a > peak:
      peak = a
  if peak <= 0.0:
    return PeakFloorDb
  20.0 * log10(peak)

proc measureLoudness*(samples: openArray[float32]; channels: int;
                      sampleRate: float64): LoudnessReport =
  ## Полный отчёт по треку. `samples` — interleaved, как их отдаёт движок.
  result.integratedLufs = LoudnessFloorLufs
  result.shortTermMaxLufs = LoudnessFloorLufs
  result.samplePeakDb = measureSamplePeakDb(samples)
  result.truePeakDb = PeakFloorDb
  if channels <= 0 or sampleRate <= 0.0 or samples.len < channels:
    return

  let frames = samples.len div channels
  result.frames = int64(frames)
  let w = weighted(samples, channels, sampleRate)

  let blockFrames = max(1, int(round(0.4 * sampleRate)))
  let stepFrames = max(1, int(round(0.1 * sampleRate)))

  # --- интегрированная громкость -------------------------------------------
  let blockSq = blockMeanSquares(w, channels, blockFrames, stepFrames)
  var gated: seq[float64] = @[]
  for ms in blockSq:
    if loudnessOf(ms) > LoudnessFloorLufs:
      gated.add ms
  if gated.len > 0:
    var mean = 0.0
    for ms in gated:
      mean += ms
    mean /= float64(gated.len)
    let relativeGate = loudnessOf(mean) - 10.0
    var sum = 0.0
    var count = 0
    for ms in gated:
      if loudnessOf(ms) > relativeGate:
        sum += ms
        inc count
    result.gatedBlocks = count
    if count > 0:
      result.integratedLufs = loudnessOf(sum / float64(count))

  # --- short-term (3 с) и LRA ----------------------------------------------
  let shortFrames = max(1, int(round(3.0 * sampleRate)))
  let shortSq = blockMeanSquares(w, channels, shortFrames,
                                 max(1, int(round(1.0 * sampleRate))))
  var shortLoud: seq[float64] = @[]
  for ms in shortSq:
    let l = loudnessOf(ms)
    if l > result.shortTermMaxLufs:
      result.shortTermMaxLufs = l
    if l > LoudnessFloorLufs:
      shortLoud.add l

  if shortLoud.len > 0:
    var mean = 0.0
    for l in shortLoud:
      mean += l
    mean /= float64(shortLoud.len)
    let rel = mean - 20.0
    var kept: seq[float64] = @[]
    for l in shortLoud:
      if l > rel:
        kept.add l
    if kept.len > 0:
      result.loudnessRangeLu = percentile(kept, 0.95) - percentile(kept, 0.10)

  result.truePeakDb = measureTruePeakDb(samples, channels)

# =============================================================================
# Нормализация и лимитер
# =============================================================================

proc defaultMasterOptions*(targetLufs = -14.0; ceilingDb = -1.0):
    MasterOptions =
  ## Умолчания сдачи: -14 LUFS (стриминговые площадки) и -1 dBTP.
  MasterOptions(targetLufs: targetLufs, ceilingDb: ceilingDb,
                lookaheadMs: 5.0)

proc applyGain(samples: var seq[float32]; gain: float64) =
  if gain == 1.0:
    return
  let g = float32(gain)
  for i in 0 ..< samples.len:
    samples[i] *= g

proc limitPeaks(samples: var seq[float32]; channels: int; sampleRate: float64;
                ceilingDb, lookaheadMs: float64):
                tuple[gains: seq[float32]; limited: int64] =
  ## Lookahead-лимитер по sample peak. `windowMax` смотрит ВПЕРЁД на
  ## `lookahead`, поэтому усиление успевает опуститься до пика — без
  ## «прищепки» и без клика.
  ##
  ## Возвращает покадровое усиление (≤1) и число затронутых кадров.
  let frames = samples.len div channels
  result.gains = newSeq[float32](max(0, frames))
  for i in 0 ..< result.gains.len:
    result.gains[i] = 1.0f
  if frames <= 0:
    return
  let threshold = pow(10.0, ceilingDb / 20.0)
  if threshold <= 0.0:
    return

  var peak = 0.0
  var peaks = newSeq[float64](frames)
  for i in 0 ..< frames:
    var p = 0.0
    for ch in 0 ..< channels:
      let a = abs(float64(samples[i * channels + ch]))
      if a > p: p = a
    peaks[i] = p
    if p > peak:
      peak = p

  if peak <= threshold:
    return

  let window = max(1, int(round(lookaheadMs * sampleRate / 1000.0)))
  var windowMax = newSeq[float64](frames)
  var mono = newSeq[int](frames)
  var head = 0
  var tail = 0                 # [head, tail) — монотонная очередь
  var right = -1
  for i in 0 ..< frames:
    let newRight = min(frames - 1, i + window)
    while right < newRight:
      inc right
      while tail > head and peaks[mono[tail - 1]] <= peaks[right]:
        dec tail
      mono[tail] = right
      inc tail
    while tail > head and mono[head] < i:
      inc head
    windowMax[i] = peaks[mono[head]]

  let release = exp(-1.0 / (0.08 * sampleRate))
  var current = 1.0
  var limited = 0'i64
  for i in 0 ..< frames:
    let target =
      if windowMax[i] > threshold: threshold / windowMax[i]
      else: 1.0
    if target < current:
      current = target          # атака мгновенная: lookahead уже отработал
    else:
      current = release * current + (1.0 - release) * target
    if current < 0.999999:
      inc limited
    result.gains[i] = float32(current)
    if current != 1.0:
      let g = float32(current)
      for ch in 0 ..< channels:
        samples[i * channels + ch] *= g
  result.limited = limited

proc normalizeMaster*(samples: var seq[float32]; channels: int;
                      sampleRate: float64; opts: MasterOptions):
                      MasterReport =
  ## Привести трек к целевой громкости, не выходя за потолок true peak.
  ##
  ## 1. Считаем input-метрики.
  ## 2. Усиление = цель - интегрированная громкость (тишина не усиливается
  ##    до бесконечности: пол -70 LUFS).
  ## 3. Если после усиления sample peak выше потолка — лимитер.
  ## 4. True peak проверяется ещё раз: остаток снимается общим усилением,
  ##    потому что обещать «потолок соблюдён» при измеренном превышении нельзя.
  result.targetLufs = opts.targetLufs
  result.ceilingDb = opts.ceilingDb
  result.input = measureLoudness(samples, channels, sampleRate)

  if result.input.integratedLufs <= LoudnessFloorLufs:
    # Тишина: ни усиления, ни лимитера — отчёт честно скажет «нет сигнала».
    result.output = result.input
    return

  result.gainDb = opts.targetLufs - result.input.integratedLufs
  let normalGain = pow(10.0, result.gainDb / 20.0)
  applyGain(samples, normalGain)

  # Лимитер работает по sample peak с запасом 0.1 дБ: межсэмпловый пик
  # может оказаться выше, и остаток снимается на шаге 4.
  let limiter = limitPeaks(samples, channels, sampleRate,
                           opts.ceilingDb - 0.1, opts.lookaheadMs)
  result.limitedFrames = limiter.limited

  var correctionGain = 1.0
  result.output = measureLoudness(samples, channels, sampleRate)
  if result.output.truePeakDb > opts.ceilingDb:
    let correction = opts.ceilingDb - result.output.truePeakDb
    result.ceilingCorrectionDb = correction
    correctionGain = pow(10.0, correction / 20.0)
    applyGain(samples, correctionGain)
    # После общего ослабления метрики сдвигаются ровно на correction:
    # пересчитывать громкость заново не нужно, но true peak — да, его
    # значение и есть измеренное минус correction.
    result.output.integratedLufs += correction
    result.output.shortTermMaxLufs += correction
    result.output.truePeakDb += correction
    result.output.samplePeakDb += correction

  result.appliedGainDb = result.gainDb + result.ceilingCorrectionDb

  if opts.keepEnvelope:
    # Стемам нужно ровно то же усиление ПО КАЖДОМУ КАДРУ, иначе их сумма
    # разойдётся с мастером там, где работал лимитер.
    result.gainEnvelope = newSeq[float32](limiter.gains.len)
    for i in 0 ..< limiter.gains.len:
      result.gainEnvelope[i] =
        float32(normalGain * float64(limiter.gains[i]) * correctionGain)

