# core/audio_inspect.nim
#
# Инспектор аудио (issue #290): пассивный анализ сигнала на дефекты.
#
# Назначение и границы
# --------------------
# Инструмент отвечает на вопрос «где и что звучит плохо», а не «красиво ли».
# Он не меняет ни сигнал, ни проект и не встраивается в путь создания музыки:
# это чистая функция над уже готовым PCM-буфером, дающая отчёт с локализацией
# каждого дефекта (время, канал, тип, серьёзность, уверенность, причина,
# рекомендация). Тот же API позже используют CLI (`euterpia analyze`) и
# Editor (#178), поэтому здесь нет ни знания о нодах, ни о CLI, ни о realtime.
#
# Слои анализа (по убыванию объективности)
# ----------------------------------------
#   * техническая чистота: NaN/Inf, клиппинг, DC offset, щелчки/разрывы,
#     провалы, «зависший» повтор буфера;
#   * спектр/тембр: узкополосное жужжание (сеть/наводка), алиасинг, шумовой
#     пол, резкость;
#   * музыкальная логика — вынесена в отдельную линию (пока не здесь).
#
# Честность отчёта: алгоритм не говорит «шедевр» или «мусор». Он указывает
# конкретные места и причины, а решение остаётся за человеком (см. §«Что не
# умеет» в конце файла).

import std/[algorithm, math]

import spectrum

{.push raises: [].}

# ==============================================================================
# Типы отчёта
# ==============================================================================

type
  DefectKind* = enum
    dkNonFinite       ## NaN/Inf в сигнале — нода выпустила битый сэмпл
    dkClipping        ## сэмплы у полной шкалы, «плоские полки»
    dkDcOffset        ## постоянная составляющая (смещение нуля)
    dkClick           ## резкий разрыв первой производной (щелчок/глитч)
    dkDropout         ## провал в тишину внутри звучащего участка
    dkStall           ## повтор идентичных блоков (зависший буфер)
    dkHum             ## узкополосное жужжание (наводка/сеть)
    dkAliasing        ## энергия у Найквиста не из гармонического ряда
    dkRoughness       ## шероховатость/резкость («пердящий» тембр)
    dkSilence         ## канал/файл пуст там, где ожидался звук

  Severity* = enum
    sevInfo, sevWarn, sevError
      ## info — наблюдение; warn — стоит проверить; error — очевидный дефект.

  Channel* = int
    ## -1 — «все каналы», иначе номер канала (0 — левый).

  InspectionDefect* = object
    startSample*: int64
    startSec*, endSec*: float64
    channel*: Channel
    kind*: DefectKind
    severity*: Severity
    confidence*: float32
      ## 0..1: насколько детектор уверен. Отдельно от severity намеренно:
      ## уверенно найденная мелочь — это warn, а не error.
    detail*: string
      ## Измеренное значение: «peak 4 сэмпла @ -0.02 dBFS».
    cause*: string
      ## Гипотеза причины: «перегрузка шины», «наводка 50 Гц».
    advice*: string
      ## Что сделать: «снять 6 дБ», «проверить антиалиасинг».

  InspectionMetrics* = object
    sampleRate*: int
    channels*: int
    frames*: int64
    seconds*: float64
    peak*: float32
    rms*: float32
    crestDb*: float32
    truePeak*: float32
      ## Оценка межсэмплового пика (линейная интерполяция ×4).
    dcOffset*: seq[float32]
      ## По каналу.
    clippingSamples*: int
    nonFiniteSamples*: int
    spectralFlatness*: float32
      ## 0 — тонально, 1 — шум/шершаво.
    spectralCentroidHz*: float32

  InspectionOptions* = object
    fftSize*: int           ## размер кадра БПФ (степень двойки)
    hop*: int               ## шаг STFT
    clipThreshold*: float32 ## порог «полной шкалы»
    dcWarn*: float32        ## |DC| выше — предупреждение
    glitchK*: float32       ## порог щелчка: median + k·MAD
    humFreqs*: seq[float32] ## частоты сети
    humDbOverFloor*: float32
      ## насколько узкий пик должен превышать локальный пол, дБ
    dropoutRatio*: float32  ## тишина ниже этой доли глобального RMS

  InspectionReport* = object
    metrics*: InspectionMetrics
    defects*: seq[InspectionDefect]
    maxSeverity*: Severity

proc defaultInspectionOptions*(): InspectionOptions =
  ## Умолчания подобраны под 48 кГц и музыку: кадр 2048 даёт ~23 Гц по бину
  ## (достаточно, чтобы отделить 50/60 Гц от соседей), шаг 512 — ~10 мс
  ## (щелчок длиной в сэмпл не теряется).
  InspectionOptions(
    fftSize: 2048,
    hop: 512,
    clipThreshold: 0.9995f,
    dcWarn: 0.002f,
    glitchK: 12.0f,
    humFreqs: @[50.0f, 60.0f],
    humDbOverFloor: 18.0f,
    dropoutRatio: 1.0e-4f
  )

# ==============================================================================
# Общие помощники
# ==============================================================================

proc linToDb(x: float32): float32 {.inline.} =
  if x <= 1.0e-9f: -180.0f else: 20.0f * log10(x)

proc addDefect(rep: var InspectionReport; d: InspectionDefect) =
  rep.defects.add d
  if d.severity > rep.maxSeverity:
    rep.maxSeverity = d.severity

proc sampleToSec(sample: int64; sampleRate: float32): float64 {.inline.} =
  if sampleRate <= 0.0f: 0.0
  else: float64(sample) / float64(sampleRate)

proc medianOf(values: var seq[float32]): float32 =
  ## Медиана разрушает выборку (сортирует): для больших данных это
  ## недопустимо, но здесь вызывающий передаёт копию производной.
  if values.len == 0:
    return 0.0f
  values.sort()
  let mid = values.len shr 1
  if values.len mod 2 == 1:
    values[mid]
  else:
    (values[mid - 1] + values[mid]) * 0.5f

proc channelOffset(ch: int; channels: int): int {.inline.} =
  ## Смещение канала в interleaved-буфере: канал `ch` идёт первым в своём
  ## фрейме. Отдельная функция — чтобы не путать `ch` и физический индекс.
  discard channels
  ch

proc channelSample(samples: openArray[float32]; frame, ch, channels: int): float32 {.inline.} =
  samples[frame * channels + channelOffset(ch, channels)]


# ==============================================================================
# Временной слой: метрики, NaN, клиппинг, DC, щелчки, провалы, зависание
# ==============================================================================

proc computeTimeMetrics(samples: openArray[float32]; channels, sr: int):
    tuple[peak, rms, truePeak: float32; dc: seq[float32];
          clipping, nonFinite: int] =
  ## Беглые метрики и грубые счётчики. Локализацию дефектов делают
  ## отдельные сканеры — здесь только «сколько и насколько».
  let frames = if channels > 0: samples.len div channels else: 0
  result.dc = newSeq[float32](channels)
  if frames <= 0:
    return

  var sumSq = 0.0'f64
  var dcAcc = newSeq[float64](channels)
  for f in 0 ..< frames:
    for ch in 0 ..< channels:
      let v = channelSample(samples, f, ch, channels)
      if v != v or v > 3.4e38f or v < -3.4e38f:
        inc result.nonFinite
        continue
      let a = abs(v)
      if a > result.peak:
        result.peak = a
      sumSq += float64(v) * float64(v)
      dcAcc[ch] += float64(v)
      if a >= 0.9995f:
        inc result.clipping
      # Межсэмпловый пик: линейная интерполяция соседей ловит «провал»
      # между двумя сэмплами, который сэмпловый пик не видит.
      if f > 0:
        let prev = channelSample(samples, f - 1, ch, channels)
        let mid = (prev + v) * 0.5f
        if abs(mid) > abs(result.truePeak):
          result.truePeak = mid

  result.rms = sqrt(sumSq / float64(frames * channels)).float32
  if abs(result.truePeak) < result.peak:
    result.truePeak = result.peak
  for ch in 0 ..< channels:
    result.dc[ch] = (dcAcc[ch] / float64(frames)).float32

proc scanNonFinite(rep: var InspectionReport; samples: openArray[float32];
                   channels, sr: int) =
  let frames = samples.len div channels
  var firstSample = -1'i64
  for f in 0 ..< frames:
    for ch in 0 ..< channels:
      let v = channelSample(samples, f, ch, channels)
      if v != v or v > 3.4e38f or v < -3.4e38f:
        if firstSample < 0:
          firstSample = int64(f)
        break
  if firstSample >= 0:
    rep.addDefect InspectionDefect(
      startSample: firstSample, startSec: sampleToSec(firstSample, sr.float32),
      endSec: sampleToSec(firstSample, sr.float32), channel: -1,
      kind: dkNonFinite, severity: sevError, confidence: 1.0f,
      detail: "первый NaN/Inf в сэмпле " & $firstSample &
        ", всего " & $rep.metrics.nonFiniteSamples,
      cause: "нода выпустила не-число (деление на 0, exp/log от негатива, " &
        "неинициализированная память)",
      advice: "найти ноду-источник (трассировка по графу) и защитить ядро")

proc scanClipping(rep: var InspectionReport; samples: openArray[float32];
                  channels, sr: int; opts: InspectionOptions) =
  let frames = samples.len div channels
  if frames == 0:
    return
  for ch in 0 ..< channels:
    var i = 0
    while i < frames:
      if abs(channelSample(samples, i, ch, channels)) >= opts.clipThreshold:
        let start = i
        var count = 0
        var peak = 0.0f
        while i < frames and abs(channelSample(samples, i, ch, channels)) >= opts.clipThreshold:
          peak = max(peak, abs(channelSample(samples, i, ch, channels)))
          inc count
          inc i
        # Одиночный сэмпл на полной шкале — уже перегрузка, но не «полка».
        let sev = if count >= 3 or rep.metrics.clippingSamples > 8: sevError
                  else: sevWarn
        rep.addDefect InspectionDefect(
          startSample: int64(start), startSec: sampleToSec(int64(start), sr.float32),
          endSec: sampleToSec(int64(i), sr.float32), channel: ch,
          kind: dkClipping, severity: sev,
          confidence: min(1.0f, 0.4f + 0.2f * float32(count)),
          detail: $count & " сэмпл(ов) у полной шкалы (peak " &
            $linToDb(peak) & " dBFS)",
          cause: "клиппинг на выходе (сумма инструментов/шина без запаса)",
          advice: "опустить уровень шины/мастера на 3–6 дБ или добавить " &
            "ограничитель")
      else:
        inc i

proc scanDc(rep: var InspectionReport; sr: int; opts: InspectionOptions) =
  for ch, dc in rep.metrics.dcOffset:
    if abs(dc) > opts.dcWarn:
      rep.addDefect InspectionDefect(
        startSample: 0, startSec: 0.0,
        endSec: rep.metrics.seconds, channel: ch,
        kind: dkDcOffset, severity: sevWarn,
        confidence: min(1.0f, abs(dc) / (opts.dcWarn * 5.0f)),
        detail: "DC offset " & $dc & " (" & $linToDb(abs(dc)) & " dBFS) по всему файлу",
        cause: "постоянная составляющая: несбалансированный микшер, " &
          "асимметричный waveshaper, утечка огибающей",
        advice: "поставить DC-blocking ФВЧ (~5–20 Гц) на проблемной шине")

proc scanClick(rep: var InspectionReport; samples: openArray[float32];
               channels, sr: int; opts: InspectionOptions) =
  ## Щелчок/глитч: выброс первой производной над устойчивым порогом.
  ## Порог по медиане и MAD, а не по среднему и σ: громкие атаки и широкий
  ## динамический диапазон размывают σ и прячут настоящий щелчок.
  let frames = samples.len div channels
  if frames < 8:
    return
  for ch in 0 ..< channels:
    var diffs = newSeq[float32](frames - 1)
    for f in 1 ..< frames:
      diffs[f - 1] = abs(channelSample(samples, f, ch, channels) -
                         channelSample(samples, f - 1, ch, channels))

    var devs = newSeq[float32](diffs.len)
    var sorted = diffs
    let med = medianOf(sorted)
    for i in 0 ..< diffs.len:
      devs[i] = abs(diffs[i] - med)
    let mad = max(medianOf(devs), 1.0e-6f)
    let thr = med + opts.glitchK * mad

    var i = 0
    while i < diffs.len:
      if diffs[i] > thr:
        let start = i
        var peakDiff = diffs[i]
        while i < diffs.len and diffs[i] > thr:
          peakDiff = max(peakDiff, diffs[i])
          inc i
        let ratio = peakDiff / thr
        rep.addDefect InspectionDefect(
          startSample: int64(start + 1),
          startSec: sampleToSec(int64(start + 1), sr.float32),
          endSec: sampleToSec(int64(i + 1), sr.float32), channel: ch,
          kind: dkClick, severity: sevWarn,
          confidence: min(1.0f, max(0.2f, (ratio - 1.0f) / 6.0f)),
          detail: "скачок " & $peakDiff & " (порог " & $thr &
            ", ×" & $ratio & ")",
          cause: "разрыв сигнала: старт/стоп голоса без микро-фейда, " &
            "смена параметра ступенью, склейка буфера",
          advice: "добавить микро-фейд (≤2 мс) на границе или сгладить " &
            "параметр")
      else:
        inc i

proc scanDropout(rep: var InspectionReport; samples: openArray[float32];
                 channels, sr: int; opts: InspectionOptions) =
  ## Провал в тишину внутри звучащего участка: оконный RMS падает ниже доли
  ## глобального, а соседи при этом звучат.
  let frames = samples.len div channels
  let win = max(1, int(0.010 * float64(sr)))
  let globalRms = max(rep.metrics.rms, 1.0e-6f)
  let floor = opts.dropoutRatio * globalRms * globalRms
  if frames < win * 3 or rep.metrics.peak <= 1.0e-6f:
    return

  for ch in 0 ..< channels:
    var w = win
    while w + win <= frames:
      var acc = 0.0'f64
      for f in w ..< w + win:
        let v = channelSample(samples, f, ch, channels)
        acc += float64(v) * float64(v)
      let wr = acc / float64(win)   # мощность окна
      if wr < floor:
        # Проверяем, что вокруг (в пределах 3 окон) есть звук.
        let lo = max(0, w - 3 * win)
        let hi = min(frames, w + win + 3 * win)
        var surroundings = 0.0'f64
        for f in lo ..< hi:
          let v = channelSample(samples, f, ch, channels)
          surroundings += float64(v) * float64(v)
        let surroundingRms = sqrt(surroundings / float64(hi - lo))
        if surroundingRms > 5.0f * sqrt(max(wr, 0.0)) and surroundingRms > 1.0e-3:
          rep.addDefect InspectionDefect(
            startSample: int64(w), startSec: sampleToSec(int64(w), sr.float32),
            endSec: sampleToSec(int64(w + win), sr.float32), channel: ch,
            kind: dkDropout, severity: sevError, confidence: 0.7f,
            detail: "провал " & $linToDb(sqrt(max(wr, 1.0e-12))) &
              " dB против соседей " & $linToDb(surroundingRms) & " dB",
            cause: "недостача сэмплов (dropout): перегрузка планировщика, " &
              "обрыв кольцевого буфера, неинициализированный блок",
            advice: "проверить реальное время и размер блока; искать узел, " &
              "бросивший буфер")
      w += win

proc stallDefect(runStart, runEnd, count: int; sr: int): InspectionDefect =
  ## Один дефект «зависшего буфера»: вынесен отдельно, потому что прогон
  ## отчитывается и при обрыве, и по концу файла.
  InspectionDefect(
    startSample: int64(runStart),
    startSec: sampleToSec(int64(runStart), sr.float32),
    endSec: sampleToSec(int64(runEnd), sr.float32), channel: -1,
    kind: dkStall, severity: sevError, confidence: 0.9f,
    detail: $count & " идентичных окон подряд",
    cause: "буфер не обновляется: зацикливание, остановка воркера, " &
      "повтор одного и того же блока",
    advice: "проверить планировщик и владение буфером; искать ноду, " &
      "не пишущую выход")

proc scanStall(rep: var InspectionReport; samples: openArray[float32];
               channels, sr: int) =
  ## «Зависший» буфер: несколько подряд окон сэмпл-в-сэмпл равны предыдущему.
  ## Живой сигнал (даже тишина) так себя не ведёт; это признак зацикливания.
  let frames = samples.len div channels
  let win = max(1, int(0.005 * float64(sr)))
  if frames < win * 12:
    return

  var identical = 0
  var runStart = 0
  var w = win
  while w + win <= frames:
    var same = true
    var winMax = 0.0f
    for f in 0 ..< win:
      for ch in 0 ..< channels:
        let v = channelSample(samples, w + f, ch, channels)
        winMax = max(winMax, abs(v))
        if v != channelSample(samples, w - win + f, ch, channels):
          same = false
          break
      if not same:
        break
    # Тишина не считается «зависанием»: одинаковые нулевые окна — это
    # пауза, а не зацикливание. Требуем ненулевой энергии в окне.
    if same and winMax <= 1.0e-6f:
      same = false
    if same:
      if identical == 0:
        runStart = w
      inc identical
    else:
      if identical >= 8:
        rep.addDefect stallDefect(runStart, w, identical, sr)
      identical = 0
    w += win
  # Прогон, дотянувшийся до конца файла, обязан быть отчитан так же, как
  # оборванный: иначе «зависание до конца трека» не находилось бы вовсе.
  if identical >= 8:
    rep.addDefect stallDefect(runStart, w, identical, sr)


# ==============================================================================
# Спектральный слой: шумовой пол, центроид, жужжание, алиасинг, резкость
# ==============================================================================

proc analyzeSpectrum(rep: var InspectionReport; samples: openArray[float32];
                     channels, sr: int; opts: InspectionOptions) =
  ## Один проход STFT: усреднённый спектр (для узкополосных пиков) и
  ## покадровые метрики (шумовой пол, центроид, спектральный поток).
  let frames = samples.len div channels
  if frames < 256 or sr <= 0:
    return
  let n = nextPow2(max(256, opts.fftSize))
  let hop = if opts.hop > 0: opts.hop else: max(1, n div 4)
  let bins = n div 2 + 1
  let binHz = float64(sr) / float64(n)

  var window = newSeq[float32](n)
  for i in 0 ..< n:
    window[i] = hannWindow(i, n)

  var acc = newSeq[float64](bins)
  var mono = newSeq[float32](n)
  var spec: seq[float32]
  var prevMag: seq[float32]
  var flatSum = 0.0'f64
  var centroidSum = 0.0'f64
  var fluxSum = 0.0'f64
  var fluxSq = 0.0'f64
  var count = 0
  var pos = 0
  while pos + n <= frames:
    for i in 0 ..< n:
      var s = 0.0f
      for ch in 0 ..< channels:
        s += channelSample(samples, pos + i, ch, channels)
      mono[i] = s / float32(channels) * window[i]
    magnitudeSpectrum(mono, spec)

    var total = 0.0
    var weighted = 0.0
    var logSum = 0.0
    var flux = 0.0
    for k in 0 ..< spec.len:
      let m = float64(spec[k])
      acc[k] += m
      total += m
      weighted += m * float64(k) * binHz
      logSum += ln(m + 1.0e-9)
      if prevMag.len == spec.len:
        let d = m - float64(prevMag[k])
        if d > 0.0:
          flux += d
    let arith = total / float64(spec.len)
    if arith > 1.0e-9:
      flatSum += exp(logSum / float64(spec.len)) / arith
    if total > 0.0:
      centroidSum += weighted / total
    fluxSum += flux
    fluxSq += flux * flux
    prevMag = spec
    inc count
    pos += hop

  if count == 0:
    return
  rep.metrics.spectralFlatness = (flatSum / float64(count)).float32
  rep.metrics.spectralCentroidHz = (centroidSum / float64(count)).float32

  # --- узкополосное жужжание (сеть/наводка) --------------------------------
  for humHz in opts.humFreqs:
    if humHz <= 0.0f or humHz >= float32(sr) * 0.5f:
      continue
    var present = 0
    var fundamentalOk = false
    var fundamentalBin = 0
    var maxRatioDb = 0.0f
    var h = 1
    while h <= 10:
      let f = humHz * float32(h)
      if f >= float32(sr) * 0.47f:
        break
      let center = binForHz(f, sr.float32, n)
      if center >= 2 and center < bins - 2:
        let peak = max(float64(acc[center - 1]),
                       max(float64(acc[center]), float64(acc[center + 1])))
        # Локальный пол: медиана ±10 бинов без самих пиков и без DC (бин 0).
        var band: seq[float32]
        for k in max(2, center - 10) .. min(bins - 1, center + 10):
          if abs(k - center) > 1:
            band.add float32(acc[k])
        let floorMag = float32(medianOf(band))
        if floorMag > 0.0f:
          let ratioDb = 20.0f * log10(float32(peak) / floorMag)
          if ratioDb > opts.humDbOverFloor:
            inc present
            if h == 1:
              fundamentalOk = true
              fundamentalBin = center
            maxRatioDb = max(maxRatioDb, ratioDb)
      inc h
    # Настоящая наводка — это РЯД гармоник от основной частоты. Одиночный
    # узкий пик, совпавший с музыкальной нотой (например, нота у 250 Гц
    # против 5×50 Гц), наводкой не является: без основной 50/60 Гц энергия
    # «сетевого ряда» случайна. Поэтому требуем и основную, и хотя бы одну
    # старшую гармонику.
    if fundamentalOk and present >= 2:
      let f = float32(fundamentalBin) * float32(binHz)
      rep.addDefect InspectionDefect(
        startSample: 0, startSec: 0.0, endSec: rep.metrics.seconds, channel: -1,
        kind: dkHum, severity: sevWarn, confidence: min(1.0f, maxRatioDb / 40.0f),
        detail: "ряд из " & $present & " гармоник сетевой частоты " & $humHz &
          " Гц (до " & $maxRatioDb & " дБ над полом; основная " & $f & " Гц)",
        cause: "наводка сети/питания, синхронная помеха, алиас известного тона",
        advice: "проверить заземление/питание, поставить узкорез 50/60 Гц или " &
          "найти источник в тракте")

  # --- алиасинг (эвристика) -------------------------------------------------
  # Доказать алиасинг без знания исходного сигнала нельзя; здесь ловится
  # характерный признак: тональный сигнал с подозрительно большой энергией
  # в верхней октаве. Низкая уверенность — сигнал к ручной проверке.
  let totalAcc = block:
    var s = 0.0
    for v in acc: s += v
    s
  if totalAcc > 0.0 and rep.metrics.spectralFlatness < 0.35f:
    let topStart = binForHz(float32(sr) * 0.45f, sr.float32, n)
    var topEnergy = 0.0
    for k in max(0, topStart) ..< bins:
      topEnergy += acc[k]
    let ratio = topEnergy / totalAcc
    if ratio > 0.18:
      rep.addDefect InspectionDefect(
        startSample: 0, startSec: 0.0, endSec: rep.metrics.seconds, channel: -1,
        kind: dkAliasing, severity: sevWarn, confidence: 0.35f,
        detail: $((ratio * 100.0)) & "% энергии выше 0.45·Nyquist при тональном " &
          "сигнале (шумовой пол " & $rep.metrics.spectralFlatness & ")",
        cause: "недостаточный антиалиасинг: наивная пила/меандр, FM без " &
          "ограничения индекса, передискретизация без фильтра",
        advice: "проверить генераторы на polyBLEP/BLIT и ограничить индекс " &
          "модуляции; спектр — самый надёжный арбитр")

  # --- резкость/шероховатость ----------------------------------------------
  let meanFlux = fluxSum / float64(count)
  let varFlux = max(0.0, fluxSq / float64(count) - meanFlux * meanFlux)
  if meanFlux > 0.0 and rep.metrics.spectralCentroidHz > 3500.0f:
    let irregularity = sqrt(varFlux) / meanFlux
    if irregularity > 2.5:
      rep.addDefect InspectionDefect(
        startSample: 0, startSec: 0.0, endSec: rep.metrics.seconds, channel: -1,
        kind: dkRoughness, severity: sevWarn, confidence: 0.4f,
        detail: "неровный спектральный поток (×" & $irregularity &
          ") при центроиде " & $rep.metrics.spectralCentroidHz & " Гц",
        cause: "шероховатый/резкий тембр: интермодуляция, широкополосный шум, " &
          "жёсткая нелинейность",
        advice: "сгладить нелинейность, ограничить ВЧ, проверить резонанс " &
          "100–400 Гц")


# ==============================================================================
# Имена для отчёта (общие для CLI и будущего Editor)
# ==============================================================================

proc defectKindName*(k: DefectKind): string =
  case k
  of dkNonFinite: "non_finite"
  of dkClipping:  "clipping"
  of dkDcOffset:  "dc_offset"
  of dkClick:     "click"
  of dkDropout:   "dropout"
  of dkStall:     "stall"
  of dkHum:       "hum"
  of dkAliasing:  "aliasing"
  of dkRoughness: "roughness"
  of dkSilence:   "silence"

proc severityName*(s: Severity): string =
  case s
  of sevInfo:  "info"
  of sevWarn:  "warn"
  of sevError: "error"

# ==============================================================================
# Точка входа
# ==============================================================================

proc inspectInterleaved*(samples: openArray[float32]; channels: int;
                         sampleRate: float32;
                         options: InspectionOptions = defaultInspectionOptions()):
    InspectionReport =
  ## Инспекция interleaved PCM. Единственная точка входа: WAV-путь в CLI,
  ## Editor и тесты приводят свой сигнал к этому виду.
  ##
  ## `samples.len` обязан делиться на `channels`; «хвост» неполного фрейма
  ## игнорируется (файл битый — это отдельное наблюдение, а не сигнал).
  var opts = options
  opts.fftSize = nextPow2(max(256, opts.fftSize))
  if opts.hop <= 0:
    opts.hop = max(1, opts.fftSize div 4)

  let ch = if channels > 0: channels else: 1
  let sr = int(sampleRate)
  if sr > 0:
    result.metrics.sampleRate = sr
    result.metrics.channels = ch
  let frames = samples.len div ch
  result.metrics.frames = int64(frames)
  if sr > 0:
    result.metrics.seconds = float64(frames) / float64(sr)

  let tm = computeTimeMetrics(samples, ch, sr)
  result.metrics.peak = tm.peak
  result.metrics.rms = tm.rms
  result.metrics.truePeak = tm.truePeak
  result.metrics.dcOffset = tm.dc
  result.metrics.clippingSamples = tm.clipping
  result.metrics.nonFiniteSamples = tm.nonFinite
  if tm.rms > 0.0f:
    result.metrics.crestDb = linToDb(tm.peak) - linToDb(tm.rms)

  if frames == 0:
    result.addDefect InspectionDefect(
      kind: dkSilence, severity: sevError, confidence: 1.0f,
      detail: "нет сэмплов", cause: "пустой файл/буфер",
      advice: "проверить, что рендер вообще писал данные")
    return result

  scanNonFinite(result, samples, ch, sr)
  scanClipping(result, samples, ch, sr, opts)
  scanDc(result, sr, opts)
  scanClick(result, samples, ch, sr, opts)
  scanDropout(result, samples, ch, sr, opts)
  scanStall(result, samples, ch, sr)
  analyzeSpectrum(result, samples, ch, sr, opts)

  if tm.peak <= 1.0e-6f:
    result.addDefect InspectionDefect(
      startSample: 0, startSec: 0.0, endSec: result.metrics.seconds, channel: -1,
      kind: dkSilence, severity: sevError, confidence: 1.0f,
      detail: "весь файл — тишина (peak " & $tm.peak & ")",
      cause: "граф не выдал сигнал или партитура пуста",
      advice: "проверить граф (`graph check`) и наличие нот")

  # Детерминированный порядок: отчёт не должен зависеть от порядка обхода.
  result.defects.sort(proc(a, b: InspectionDefect): int =
    result = cmp(a.startSample, b.startSample)
    if result == 0:
      result = cmp(ord(a.kind), ord(b.kind))
    if result == 0:
      result = cmp(a.channel, b.channel))
  result

proc inspectMono*(samples: openArray[float32]; sampleRate: float32;
                  options: InspectionOptions = defaultInspectionOptions()):
    InspectionReport =
  inspectInterleaved(samples, 1, sampleRate, options)

{.pop.}

