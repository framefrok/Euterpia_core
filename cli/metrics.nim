# cli/metrics.nim
#
# Поток метрик во время рендера и записи (issue #345).
#
# Зачем отдельный модуль:
#   `EngineMetric` уже есть, но до релиза он был виден только в финальном
#   отчёте: во время длинного рендера перегрузку замечали по факту. Поток —
#   это ФОРМАТ и ПРАВИЛА (интервал, событие, округление), и они должны быть
#   одни для `render`, `record` и `play`.
#
# Что здесь и чего здесь НЕТ:
#   ЗДЕСЬ — агрегация чанков в интервал, решение «печатать/молчать»,
#   детерминированная строка NDJSON и короткая человеческая строка.
#   НЕ ЗДЕСЬ — рендер, запись и печать: stdout/stderr выбирает команда.
#
# Детерминизм:
#   В офлайн-рендере `t` — время АУДИО, а не стенных часов: один и тот же
#   рендер даёт тот же поток байт-в-байт, поэтому `--metrics` годится для
#   сравнения в CI. В живом режиме `t` — прошедшие миллисекунды сеанса.
#
# «После события»:
#   `--metrics-event` печатает строку только когда событие произошло (новый
#   пик или новый xrun). Для CI этого достаточно: нет событий — нет потока,
#   а не «N одинаковых строк».

import std/[json, math, strutils]

const
  DefaultMetricsIntervalMs* = 1000
    ## Один снимок в секунду: видно движение и не заливается stdout.
  MetricsType* = "metric"
    ## Поле `type` каждой строки: агент отличает метрику от ошибки и итога.

type
  MetricsMode* = enum
    mmInterval, mmEvent
      ## `mmInterval` — раз в интервал; `mmEvent` — только на событии.

  MetricSample* = object
    ## Снимок метрик одного интервала. Поля — те же, что у `EngineMetric`
    ## (core/ipc_bus) плюс вычисляемая латентность, а не второй набор смыслов.
    tMs*: int64
    peakL*, peakR*, rmsL*, rmsR*: float32
    cpu*: float32
    xruns*: uint32
    transport*: string
    voices*: int32
    latencyMs*: float64
    graphVersion*: uint64
    inputPeakL*, inputPeakR*: float32
    inputXruns*: uint32

  MetricsStream* = object
    ## Состояние потока: накопитель интервала и решение «пора».
    enabled*: bool
    mode*: MetricsMode
    intervalMs*: int64
    nextAt*: int64
      ## Время (в тех же мс), когда интервал закрывается.
    seqNo*: int
    emitted*: int
    prevPeak*: float32
      ## Для `mmEvent`: максимальный пик, о котором уже сказали.
    prevXruns*: uint32
    accumPeakL*, accumPeakR*: float32
    accumSumL*, accumSumR*: float64
    accumFrames*: int64
    last*: MetricSample
      ## Последний напечатанный снимок: итог команды не считает его заново.

proc newMetricsStream*(enabled: bool;
                       intervalMs = DefaultMetricsIntervalMs;
                       eventMode = false): MetricsStream =
  result.enabled = enabled
  result.mode = if eventMode: mmEvent else: mmInterval
  result.intervalMs = max(1'i64, intervalMs)
  result.nextAt = 0
  result.seqNo = 0
  result.emitted = 0

proc parseMetricsEvent*(text: string; eventMode: var bool): string =
  ## `peak` | `xrun` | пусто. Ошибка — текстом, чтобы команда назвала ключ.
  case text.toLowerAscii()
  of "", "off", "none":
    eventMode = false
    ""
  of "peak", "xrun", "xruns":
    eventMode = true
    ""
  else:
    "ожидается peak | xrun, получено «" & text & "»"

proc round6(value: float32): float64 =
  ## Шесть знаков: float32 в JSON иначе печатается «0.1540912687778473», и
  ## строка перестаёт быть читаемой, не становясь точнее.
  round(float64(value) * 1e6) / 1e6

proc db(value: float32): float64 =
  ## dBFS с тремя знаками. Ноль — тишина, а не -inf: JSON не знает
  ## бесконечности.
  round(20.0 * log10(max(float64(value), 1.0e-9)) * 1e3) / 1e3

proc pushChunk*(s: var MetricsStream; sample: MetricSample;
                frames: int64): bool =
  ## Добавить чанк/снимок и решить, печатать ли строку.
  ##
  ## `true` — клиент выводит `metricsLine(s.last, s.seqNo - 1)`.
  if not s.enabled:
    return false
  s.accumPeakL = max(s.accumPeakL, sample.peakL)
  s.accumPeakR = max(s.accumPeakR, sample.peakR)
  s.accumSumL += float64(sample.rmsL) * float64(sample.rmsL) *
                 float64(max(1'i64, frames))
  s.accumSumR += float64(sample.rmsR) * float64(sample.rmsR) *
                 float64(max(1'i64, frames))
  s.accumFrames += max(1'i64, frames)

  var due = false
  case s.mode
  of mmInterval:
    due = sample.tMs >= s.nextAt
    if due:
      s.nextAt = sample.tMs + s.intervalMs
  of mmEvent:
    let newPeak = max(sample.peakL, sample.peakR) > s.prevPeak + 1.0e-6
    let newXrun = sample.xruns > s.prevXruns
    due = newPeak or newXrun
    s.prevPeak = max(s.prevPeak, max(sample.peakL, sample.peakR))
    s.prevXruns = max(s.prevXruns, sample.xruns)
  if not due:
    return false

  var emitted = sample
  let framesF = float64(max(1'i64, s.accumFrames))
  emitted.peakL = s.accumPeakL
  emitted.peakR = s.accumPeakR
  if s.accumFrames > 0:
    emitted.rmsL = float32(sqrt(s.accumSumL / framesF))
    emitted.rmsR = float32(sqrt(s.accumSumR / framesF))
  s.last = emitted
  s.accumPeakL = 0.0f
  s.accumPeakR = 0.0f
  s.accumSumL = 0.0
  s.accumSumR = 0.0
  s.accumFrames = 0
  inc s.seqNo
  inc s.emitted
  true

proc metricsJson*(sample: MetricSample; seqNo: int): JsonNode =
  ## Машинная строка. Порядок полей фиксирован, числа округлены — повтор
  ## одного рендера даёт ту же строку.
  result = newJObject()
  result["type"] = %MetricsType
  result["seq"] = %seqNo
  result["t"] = %(round(float64(sample.tMs) / 1000.0 * 1e3) / 1e3)
  result["peak"] = %round6(max(sample.peakL, sample.peakR))
  result["peakL"] = %round6(sample.peakL)
  result["peakR"] = %round6(sample.peakR)
  result["rms"] = %round6(max(sample.rmsL, sample.rmsR))
  result["rmsL"] = %round6(sample.rmsL)
  result["rmsR"] = %round6(sample.rmsR)
  result["peakDb"] = %db(max(sample.peakL, sample.peakR))
  result["rmsDb"] = %db(max(sample.rmsL, sample.rmsR))
  result["latencyMs"] = %(round(sample.latencyMs * 1e3) / 1e3)
  result["xruns"] = %sample.xruns
  result["cpu"] = %round6(sample.cpu)
  result["transport"] = %sample.transport
  result["voices"] = %sample.voices
  result["graphVersion"] = %sample.graphVersion
  result["inputPeakL"] = %round6(sample.inputPeakL)
  result["inputPeakR"] = %round6(sample.inputPeakR)
  result["inputXruns"] = %sample.inputXruns

proc metricsLine*(sample: MetricSample; seqNo: int): string =
  ## NDJSON: одна строка на снимок, разбирается без обёртки.
  $metricsJson(sample, seqNo)

proc metricsHuman*(sample: MetricSample): string =
  ## Короткая строка прогресса для stderr: stdout остаётся отчётом.
  let peak = max(sample.peakL, sample.peakR)
  let rms = max(sample.rmsL, sample.rmsR)
  "метрики: t=" & formatFloat(float64(sample.tMs) / 1000.0, ffDecimal, 2) &
    " с, peak " & formatFloat(db(peak), ffDecimal, 1) & " dBFS, RMS " &
    formatFloat(db(rms), ffDecimal, 1) & " dBFS, xruns " & $sample.xruns &
    ", транспорт " & sample.transport

proc latencyMs*(blockSize, sampleRate: int): float64 =
  ## Задержка офлайн-рендера: один блок обработки. Это не «латентность
  ## устройства», а время, за которое команда отдаёт кадр, — но именно оно
  ## объясняет шаг метрик и одинаково у render и record.
  if sampleRate <= 0:
    return 0.0
  float64(max(0, blockSize)) / float64(sampleRate) * 1000.0

