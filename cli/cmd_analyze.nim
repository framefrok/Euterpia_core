# cli/cmd_analyze.nim
#
# `euterpia analyze <файл.wav>` — инспектор аудио (issue #290).
#
# Зачем команда:
#   качество demo-мелодии нельзя свести к «прошло/не прошло». Команда читает
#   готовый WAV и печатает ОТЧЁТ С ЛОКАЛИЗАЦИЕЙ: где и что звучит плохо —
#   клиппинг, DC, щелчки, провалы, зависание, жужжание 50/60 Гц, признаки
#   алиасинга и резкости. Вердикт «нравится» остаётся за слушателем.
#
# Границы (§20): CLI не анализирует сэмплы сам — это Core (`core/audio_inspect`).
# CLI решает, что прочитать (WAV через `wav_codec`), что показать и что
# записать (сниппеты вокруг дефектов, спектрограмма). Тот же Core-API позже
# использует Editor (#178) — помощник, который ничего не меняет в проекте.
#
# Коды возврата (#88): 0 — чисто, 1 — дефекты достигли порога `--fail-on`,
# 2 — среда (файл не читается), 3 — внутренняя ошибка.

import std/[base64, json, math, os, strutils, terminal]

import context
import audio_inspect
import spectrum
import audio_file_io
import cli_spec

const
  WavSuffix = ".wav"
  DefaultFailOn = "error"
    ## Умолчание: падать только на очевидных дефектах. warn-режим включают
    ## явно — иначе «резкость тембра» роняла бы CI на каждом треке.
  DefaultMaxDefects = 50
    ## Потолок печатаемых дефектов: файл-катастрофа не должен заваливать
    ## stdout тысячами строк (в JSON по-прежнему всё).
  SnippetPadSeconds = 0.05
    ## Половина окна сниппета вокруг дефекта.
  MaxSnippets = 20

  AnalyzeSpec* = CommandSpec(
    name: "analyze",
    summary: "инспектор аудио: дефекты WAV с локализацией",
    aliases: @["inspect"],
    aliasesDeprecatedSince: "0.3.11",
    synopsis: "analyze <файл.wav> [ключи]",
    args: @[
      arg("файл.wav", "что слушать: записанный рендер или запись сессии"),
    ],
    options: @[
      opt("--snippets", "каталог коротких WAV вокруг дефектов", value = "каталог"),
      opt("--heatmap", "спектрограмма файла в PGM", value = "файл.pgm"),
      opt("--html", "самодостаточный HTML-отчёт: вердикт, спектр, дефекты (#346)",
          value = "файл.html"),
      switch("--no-terminal", "не печатать гистограмму и спектр в терминале"),
      opt("--fail-on", "порог для CI: при дефектах не ниже уровня код возврата 1",
          value = "info|warn|error", default = DefaultFailOn),
      opt("--fft", "размер кадра БПФ", value = "256..65536", default = "2048"),
      opt("--max-defects", "сколько дефектов печатать текстом (в --json — все)",
          value = "число", default = $DefaultMaxDefects),
    ],
    example: "euterpia analyze song.wav --fail-on warn",
    fields: @[
      field("file", "разобранный файл"),
      field("metrics", "измерения: пик, RMS, DC offset, уровень шума"),
      field("verdict", "вердикт: level (`clean`|`attention`|`fail`), текст, порог"),
      field("spectrum", "спектр в полосах: частота, уровень dBFS"),
      field("defects", "найденные дефекты с локализацией: время, кадр, уровень"),
      field("summary", "сводка по уровням дефектов"),
      field("error", "причина отказа (не WAV, нет файла)"),
      field("errorCode", "код причины отказа — по нему выбирается код возврата (#332)"),
    ],
    notes: @[
      "читает WAV и печатает отчёт с локализацией: клиппинг, DC, щелчки, " &
        "провалы, зависание, жужжание 50/60 Гц, алиасинг, резкость",
      "вердикт «нравится» остаётся за слушателем: инструмент не судит музыку, " &
        "а указывает конкретные места и причины",
      "--fail-on info|warn|error — порог для CI: код 1 при дефектах не ниже уровня",
      "--snippets <каталог> пишет короткие WAV вокруг дефектов, --heatmap <файл.pgm> — спектрограмму",
      "`--html <файл>` — самодостаточный отчёт: вердикт, спектр и список дефектов без внешних файлов (#346)",
      "вердикт одинаков в human, HTML и `--json`; `--fail-on` переносит его в код возврата (1 — дефекты достигли порога)",
      "тот же Core-API (`core/audio_inspect`) позже использует Editor (#178)",
    ])

  AnalyzeKeys* = AnalyzeSpec.optionKeys
    ## Ключи `analyze` — из спецификации (#259, #330).

type
  FailOn = enum
    foInfo, foWarn, foError

  AnalyzeScan = object
    ok: bool
    rep: Report
    path: string
    snippetsDir: string
    heatmapPath: string
    htmlPath: string
    terminalOutput: bool
    failOn: FailOn
    fftSize: int
    maxDefects: int

# ==============================================================================
# Разбор аргументов
# ==============================================================================

proc parseFailOn(text: string): tuple[ok: bool; value: FailOn; msg: string] =
  case text.strip().toLowerAscii()
  of "info": (true, foInfo, "")
  of "warn", "warning": (true, foWarn, "")
  of "error": (true, foError, "")
  else: (false, foError, "ожидается info | warn | error, получено «" & text & "»")

proc scanArgs(args: seq[string]): AnalyzeScan =
  result.failOn = foError
  result.maxDefects = DefaultMaxDefects
  result.terminalOutput = true
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--snippets":
      inc i
      if i >= args.len:
        return AnalyzeScan(ok: false, rep: usageError("--snippets: нужен каталог"))
      result.snippetsDir = args[i]
    elif a == "--heatmap":
      inc i
      if i >= args.len:
        return AnalyzeScan(ok: false, rep: usageError("--heatmap: нужен путь .pgm"))
      result.heatmapPath = args[i]
    elif a == "--html":
      inc i
      if i >= args.len:
        return AnalyzeScan(ok: false, rep: usageError("--html: нужен путь .html"))
      result.htmlPath = args[i]
    elif a == "--no-terminal":
      result.terminalOutput = false
    elif a == "--fail-on":
      inc i
      if i >= args.len:
        return AnalyzeScan(ok: false, rep: usageError("--fail-on: нужен уровень"))
      let f = parseFailOn(args[i])
      if not f.ok:
        return AnalyzeScan(ok: false, rep: usageError("--fail-on: " & f.msg))
      result.failOn = f.value
    elif a == "--fft":
      inc i
      if i >= args.len:
        return AnalyzeScan(ok: false, rep: usageError("--fft: нужно число"))
      try:
        result.fftSize = parseInt(args[i].strip())
      except ValueError:
        return AnalyzeScan(ok: false, rep: usageError("--fft: ожидается целое"))
      if result.fftSize < 256 or result.fftSize > 65536:
        return AnalyzeScan(ok: false,
          rep: usageError("--fft: от 256 до 65536, получено " & $result.fftSize))
    elif a == "--max-defects":
      inc i
      if i >= args.len:
        return AnalyzeScan(ok: false, rep: usageError("--max-defects: нужно число"))
      try:
        result.maxDefects = parseInt(args[i].strip())
      except ValueError:
        return AnalyzeScan(ok: false, rep: usageError("--max-defects: ожидается целое"))
      if result.maxDefects < 1:
        return AnalyzeScan(ok: false, rep: usageError("--max-defects: минимум 1"))
    elif a.len > 0 and a[0] == '-' and a != "-":
      return AnalyzeScan(ok: false,
        rep: usageError("неизвестный ключ `" & a & "`; ключи analyze: " &
          AnalyzeKeys.join(", ")))
    else:
      if result.path.len == 0:
        result.path = a
      else:
        return AnalyzeScan(ok: false,
          rep: usageError("лишний позиционный аргумент: " & a))
    inc i

  if result.path.len == 0:
    return AnalyzeScan(ok: false,
      rep: usageError("нужен путь к WAV-файлу: euterpia analyze out.wav"))
  result.ok = true
  result

# ==============================================================================
# Чтение WAV
# ==============================================================================

proc readWavAll(path: string; samples: var seq[float32]; channels: var int;
                sampleRate: var int32; err: var string): bool =
  ## Читает весь файл в interleaved float32. Ошибка — значением, а не
  ## исключением: битый/чужой файл — нормальный исход CLI, а не паника.
  try:
    if not fileExists(path):
      err = "файл не найден: " & path
      return false
    if not path.toLowerAscii().endsWith(WavSuffix):
      err = "ожидается WAV-файл (.wav), получено: " & path
      return false
    # Чтение — через фасад (issue #356): CLI не знает про `wav_codec` и не
    # раскладывает чтение блоками сам.
    let (data, info) = readAllAudioFile(path)
    if data.len == 0 or info.channels <= 0 or info.sampleRate <= 0:
      err = "в файле нет сэмплов или некорректный заголовок"
      return false
    samples = data
    channels = int(info.channels)
    sampleRate = info.sampleRate
    true
  except CatchableError as e:
    err = e.msg
    false

# ==============================================================================
# Отчёт
# ==============================================================================

proc defectToJson(d: InspectionDefect): JsonNode =
  result = newJObject()
  result["kind"] = %defectKindName(d.kind)
  result["severity"] = %severityName(d.severity)
  result["channel"] = %d.channel
  result["startSec"] = %d.startSec
  result["endSec"] = %d.endSec
  result["startSample"] = %d.startSample
  result["confidence"] = %d.confidence
  result["detail"] = %d.detail
  result["cause"] = %d.cause
  result["advice"] = %d.advice

proc severityCount(rep: InspectionReport): array[3, int] =
  for d in rep.defects:
    inc result[ord(d.severity)]

proc meetsThreshold(sev: Severity; fo: FailOn): bool =
  case fo
  of foInfo: true
  of foWarn: sev >= sevWarn
  of foError: sev == sevError

type
  Verdict = object
    ## Один вердикт на все представления (#346): human, HTML и `--json`
    ## печатают ЕГО, а не три независимых вывода. Поэтому «чисто» в
    ## терминале не может разойтись с HTML.
    level*: string
      ## `clean` | `attention` | `fail` — стабильные имена для агента.
    text*: string
    failing*: int

proc failOnName(fo: FailOn): string =
  case fo
  of foInfo: "info"
  of foWarn: "warn"
  of foError: "error"

proc verdictOf(rep: InspectionReport; failOn: FailOn; failing: int): Verdict =
  result.failing = failing
  if failing > 0:
    result.level = "fail"
    result.text = "дефекты: " & $failing & " ≥ порога " & failOnName(failOn)
  elif rep.defects.len > 0:
    result.level = "attention"
    result.text = "внимание: " & $rep.defects.len &
      " дефектов ниже порога " & failOnName(failOn)
  else:
    result.level = "clean"
    result.text = "чисто: дефектов не найдено"

proc verdictJson(v: Verdict; failOn: FailOn): JsonNode =
  %*{"level": v.level, "text": v.text, "failing": v.failing,
     "failOn": failOnName(failOn)}

proc colorize(text, level: string; enabled: bool): string =
  ## Цвет только при TTY (#346): в пайпе и CI escape-последовательности были
  ## бы мусором, а не оформлением.
  if not enabled:
    return text
  let code =
    case level
    of "fail": "\e[31m"
    of "attention": "\e[33m"
    else: "\e[32m"
  code & text & "\e[0m"

proc amplitudeHistogram(samples: seq[float32]; channels: int): seq[string] =
  ## Гистограмма |x|: где живёт сигнал и есть ли «стена» у нуля/единицы.
  ## Двенадцать корзин — столько читается в терминале без прокрутки.
  const Bins = 12
  const BarWidth = 36
  var counts = newSeq[int](Bins)
  var total = 0
  var peak = 0.0f
  for i in 0 ..< samples.len:
    let value = abs(samples[i])
    peak = max(peak, value)
  if peak <= 0.0f:
    return @["гистограмма |x|: тишина"]
  for i in 0 ..< samples.len:
    let norm = float64(abs(samples[i]) / peak)
    var bin = int(norm * float64(Bins))
    if bin >= Bins:
      bin = Bins - 1
    inc counts[bin]
    inc total
  var maxCount = 1
  for count in counts:
    maxCount = max(maxCount, count)
  result.add "гистограмма |x| (пик " & formatFloat(float64(peak), ffDecimal, 3) &
    "):"
  for bin in 0 ..< Bins:
    let low = float64(bin) / float64(Bins) * float64(peak)
    let high = float64(bin + 1) / float64(Bins) * float64(peak)
    let filled = int(float64(counts[bin]) / float64(maxCount) *
                     float64(BarWidth))
    result.add "  " & formatFloat(low, ffDecimal, 3) & "–" &
      formatFloat(high, ffDecimal, 3) & " " & '#'.repeat(filled) & " " &
      $counts[bin]
  discard total

proc spectrumBands(samples: seq[float32]; channels, sampleRate,
                   fftSize: int): seq[tuple[hz: float64; db: float64]] =
  ## Спектр в логарифмических полосах: 16 столбцов — это ответ «где звучит
  ## материал», а не 1024 бина, которые в терминал не влезают.
  const Bands = 16
  const MaxWindows = 64
  let frames = samples.len div max(1, channels)
  let n = nextPow2(max(256, fftSize))
  if frames < n:
    return @[]
  let hop = max(n, frames div MaxWindows)
  var win = newSeq[float32](n)
  for i in 0 ..< n:
    win[i] = hannWindow(i, n)
  var mono = newSeq[float32](n)
  var mag: seq[float32]
  var sums = newSeq[float64](Bands)
  var counts = newSeq[int](Bands)
  var pos = 0
  while pos + n <= frames:
    for i in 0 ..< n:
      var s = 0.0f
      for ch in 0 ..< channels:
        s += samples[(pos + i) * channels + ch]
      mono[i] = s / float32(channels) * win[i]
    magnitudeSpectrum(mono, mag)
    for band in 0 ..< Bands:
      let lowHz = 40.0 * pow(2.0, float64(band) * 7.0 / float64(Bands))
      let highHz = 40.0 * pow(2.0, float64(band + 1) * 7.0 / float64(Bands))
      let lowBin = int(lowHz / float64(sampleRate) * float64(n))
      let highBin = max(lowBin + 1,
        int(highHz / float64(sampleRate) * float64(n)))
      var local = 0.0f
      for bin in lowBin ..< min(highBin, mag.len):
        local = max(local, mag[bin])
      sums[band] += float64(local)
      inc counts[band]
    pos += hop
  if pos == 0:
    return @[]
  var means = newSeq[float64](Bands)
  var peakMean = 1.0e-12
  for band in 0 ..< Bands:
    if counts[band] > 0:
      means[band] = sums[band] / float64(counts[band])
    peakMean = max(peakMean, means[band])
  for band in 0 ..< Bands:
    let lowHz = 40.0 * pow(2.0, float64(band) * 7.0 / float64(Bands))
    # Уровень полосы относительно самой громкой: абсолютные единицы FFT
    # зависят от окна и размера кадра, а «где звучит» — нет.
    let db = 20.0 * log10(max(means[band] / peakMean, 1.0e-9))
    result.add (min(lowHz, float64(sampleRate) / 2.0), max(-60.0, min(0.0, db)))

proc spectrumLines(bands: seq[tuple[hz: float64; db: float64]]): seq[string] =
  ## ASCII-спектр: ширина столбца — уровень в диапазоне -60…0 дБ относительно
  ## самой громкой полосы.
  const Width = 32
  if bands.len == 0:
    return @["спектр: файл короче одного окна БПФ"]
  result.add "спектр (полосы, дБ отн.):"
  for band in bands:
    let norm = (band.db + 60.0) / 60.0
    let filled = int(max(0.0, min(1.0, norm)) * float64(Width))
    result.add "  " & $int(band.hz) & " Гц " &
      '#'.repeat(filled) & " " & formatFloat(band.db, ffDecimal, 1)

type
  SpectrogramGrid = object
    ## Кадры спектрограммы для PGM и HTML (#290, #346). Один расчёт — два
    ## представления: картинка в HTML не может разойтись с PGM.
    ok: bool
    error: string
    cols: seq[seq[float32]]
    height: int

proc spectrogramGrid(samples: seq[float32]; channels,
                     fftSize: int): SpectrogramGrid
proc spectrogramHtml(grid: SpectrogramGrid; width, height: int): string

proc htmlEscape(text: string): string =
  ## Экранирование текста для HTML: причина дефекта — данные, а не разметка.
  for ch in text:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add ch

proc writeHtmlReport(path, source: string; rep: InspectionReport;
                     verdict: Verdict; failOn: FailOn;
                     samples: seq[float32]; channels, sr, fftSize: int): string =
  ## Самодостаточный HTML: CSS и картинки внутри, внешних файлов рядом не
  ## нужно (#346). Вердикт — ТОТ ЖЕ объект, что печатает human и `--json`.
  let grid = spectrogramGrid(samples, channels, fftSize)
  let bands = spectrumBands(samples, channels, sr, fftSize)
  var html = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<title>EUTERPIA analyze — отчёт</title>
<style>
body{font-family:system-ui,sans-serif;margin:2rem;background:#111;color:#eee}
h1,h2{font-weight:600} .verdict{padding:.6rem 1rem;border-radius:.4rem;display:inline-block}
.clean{background:#1c3d25;color:#8f8} .attention{background:#3d361c;color:#ff8}
.fail{background:#3d1c1c;color:#f88} table{border-collapse:collapse;width:100%}
td,th{border-bottom:1px solid #333;padding:.25rem .5rem;text-align:left;font-size:.9rem}
.bar{background:#4a8;height:.7rem;display:inline-block;vertical-align:middle}
svg{background:#000;display:block;max-width:100%}
</style></head><body>
"""
  html.add "<h1>analyze: " & htmlEscape(source) & "</h1>\n"
  html.add "<p class=\"verdict " & htmlEscape(verdict.level) & "\">" &
    htmlEscape(verdict.text) & "</p>\n"
  html.add "<p>" & $rep.metrics.channels & " канал(ов), " &
    $rep.metrics.sampleRate & " Гц, " & $rep.metrics.seconds & " с; порог " &
    failOnName(failOn) & "</p>\n"
  html.add "<h2>Метрики</h2><table>"
  html.add "<tr><th>пик</th><td>" &
    formatFloat(20.0 * log10(max(float64(rep.metrics.peak), 1.0e-9)),
                ffDecimal, 2) & " dBFS</td></tr>"
  html.add "<tr><th>RMS</th><td>" &
    formatFloat(20.0 * log10(max(float64(rep.metrics.rms), 1.0e-9)),
                ffDecimal, 2) & " dBFS</td></tr>"
  html.add "<tr><th>crest</th><td>" & $rep.metrics.crestDb & " dB</td></tr>"
  html.add "<tr><th>spectral flatness</th><td>" &
    $rep.metrics.spectralFlatness & "</td></tr>"
  html.add "<tr><th>спектральный центроид</th><td>" &
    $rep.metrics.spectralCentroidHz & " Гц</td></tr>"
  html.add "<tr><th>клиппинг</th><td>" & $rep.metrics.clippingSamples &
    " сэмплов</td></tr></table>\n"
  html.add "<h2>Спектр</h2><svg xmlns=\"http://www.w3.org/2000/svg\" " &
    "width=\"640\" height=\"" & $(bands.len * 18 + 10) &
    "\" role=\"img\" aria-label=\"спектр по полосам\">"
  for i, band in bands:
    let width = int(max(0.0, min(1.0, (band.db + 60.0) / 60.0)) * 560.0)
    let y = 6 + i * 18
    html.add "<rect x=\"70\" y=\"" & $y & "\" width=\"" & $width &
      "\" height=\"12\" fill=\"#4a8\"/>"
    html.add "<text x=\"4\" y=\"" & $(y + 10) & "\" fill=\"#ccc\" " &
      "font-size=\"11\">" & formatFloat(band.hz, ffDecimal, 0) & " Гц</text>"
  html.add "</svg>\n"
  html.add "<h2>Спектрограмма</h2>" & spectrogramHtml(grid, 400, 160) & "\n"
  html.add "<h2>Дефекты (" & $rep.defects.len & ")</h2><table>"
  html.add "<tr><th>уровень</th><th>вид</th><th>время, с</th><th>канал</th>" &
    "<th>что</th><th>совет</th></tr>"
  for d in rep.defects:
    html.add "<tr><td>" & severityName(d.severity) & "</td><td>" &
      defectKindName(d.kind) & "</td><td>" & formatFloat(d.startSec,
        ffDecimal, 3) & "–" & formatFloat(d.endSec, ffDecimal, 3) &
      "</td><td>" & (if d.channel < 0: "all" else: $d.channel) & "</td><td>" &
      htmlEscape(d.detail) & "</td><td>" & htmlEscape(d.advice) &
      "</td></tr>"
  html.add "</table>\n</body></html>\n"
  try:
    writeFile(path, html)
  except CatchableError as e:
    return e.msg
  ""

proc buildReport(path: string; rep: InspectionReport; failOn: FailOn;
                 maxDefects: int; snippetFiles: seq[string];
                 samples: seq[float32]; channels, sampleRate, fftSize: int;
                 terminalOutput: bool; htmlPath: string): Report =
  let counts = severityCount(rep)
  let failing = block:
    var n = 0
    for d in rep.defects:
      if meetsThreshold(d.severity, failOn): inc n
    n
  let verdict = verdictOf(rep, failOn, failing)
  let bands = spectrumBands(samples, channels, sampleRate, fftSize)

  var body = newJObject()
  body["file"] = %path
  body["verdict"] = verdictJson(verdict, failOn)
  var spectrum = newJArray()
  for band in bands:
    spectrum.add %*{"hz": band.hz, "db": band.db}
  body["spectrum"] = spectrum
  var m = newJObject()
  m["sampleRate"] = %rep.metrics.sampleRate
  m["channels"] = %rep.metrics.channels
  m["frames"] = %rep.metrics.frames
  m["seconds"] = %rep.metrics.seconds
  m["peak"] = %rep.metrics.peak
  m["peakDb"] = %(20.0f * log10(max(rep.metrics.peak, 1.0e-9f)))
  m["rms"] = %rep.metrics.rms
  m["rmsDb"] = %(20.0f * log10(max(rep.metrics.rms, 1.0e-9f)))
  m["crestDb"] = %rep.metrics.crestDb
  m["truePeak"] = %rep.metrics.truePeak
  m["clippingSamples"] = %rep.metrics.clippingSamples
  m["nonFiniteSamples"] = %rep.metrics.nonFiniteSamples
  m["spectralFlatness"] = %rep.metrics.spectralFlatness
  m["spectralCentroidHz"] = %rep.metrics.spectralCentroidHz
  var dc = newJArray()
  for v in rep.metrics.dcOffset:
    dc.add %v
  m["dcOffset"] = dc
  body["metrics"] = m

  var defects = newJArray()
  for d in rep.defects:
    defects.add defectToJson(d)
  body["defects"] = defects

  var summary = newJObject()
  summary["total"] = %rep.defects.len
  summary["error"] = %counts[ord(sevError)]
  summary["warn"] = %counts[ord(sevWarn)]
  summary["info"] = %counts[ord(sevInfo)]
  summary["maxSeverity"] = %severityName(rep.maxSeverity)
  summary["failOn"] = %failOnName(failOn)
  summary["failing"] = %failing
  var snips = newJArray()
  for s in snippetFiles:
    snips.add %s
  summary["snippets"] = snips
  body["summary"] = summary

  if htmlPath.len > 0:
    # HTML пишется тем же вердиктом, что human/--json (#346); ошибка записи
    # — предупреждение, а не отказ анализа: отчёт уже есть в stdout.
    let htmlError = writeHtmlReport(htmlPath, path, rep, verdict, failOn,
                                    samples, channels, sampleRate, fftSize)
    if htmlError.len > 0:
      body["htmlError"] = %htmlError
      cliWarn("analyze: HTML-отчёт: " & htmlError)
    else:
      body["html"] = %htmlPath

  # Цвет только при TTY: в пайпе и CI escape-последовательности были бы
  # мусором, а не оформлением (#346).
  let colorEnabled = terminalOutput and isatty(stdout)
  var lines: seq[string] = @[]
  lines.add "analyze: " & path
  lines.add "  " & colorize("вердикт: " & verdict.text, verdict.level,
                            colorEnabled)
  lines.add "  " & $rep.metrics.channels & " канал(ов), " &
    $rep.metrics.sampleRate & " Гц, " &
    ($rep.metrics.seconds) & " с"
  lines.add "  peak " & $(20.0f * log10(max(rep.metrics.peak, 1.0e-9f))) &
    " dBFS, RMS " & $(20.0f * log10(max(rep.metrics.rms, 1.0e-9f))) &
    " dBFS, crest " & $rep.metrics.crestDb & " dB"
  lines.add "  шумовой пол (flatness) " & $rep.metrics.spectralFlatness &
    ", центроид " & $rep.metrics.spectralCentroidHz & " Гц"
  lines.add "  дефекты: " & $rep.defects.len &
    " (error " & $counts[ord(sevError)] &
    ", warn " & $counts[ord(sevWarn)] &
    ", info " & $counts[ord(sevInfo)] & ")"
  if terminalOutput:
    lines.add ""
    lines.add amplitudeHistogram(samples, channels)
    lines.add ""
    lines.add spectrumLines(bands)
    lines.add ""
  var shown = 0
  for d in rep.defects:
    if shown >= maxDefects:
      lines.add "  … ещё " & $(rep.defects.len - shown) & " (см. --json)"
      break
    let ch = if d.channel < 0: "all" else: $d.channel
    lines.add "  [" & severityName(d.severity) & "] " & defectKindName(d.kind) &
      " @ " & $d.startSec & "–" & $d.endSec & " с ch=" & ch & ": " & d.detail
    lines.add "      причина: " & d.cause
    lines.add "      совет:   " & d.advice
    inc shown

  let ok = failing == 0
  if ok:
    okReport(body = body, lines = lines)
  else:
    # Дефекты — не «ошибка использования», но и не успех: причина
    # `ecCheckFailed` (код 1, класс `defects`), чтобы `--fail-on` работал как
    # CI-гейт и агент отличал вердикт от неверного вызова (#332).
    checkFailedError(
      "найдено " & $failing & " дефект(ов) уровня " & failOnName(failOn),
      "порог: --fail-on; подробности в --json", lines, body,
      errorKind = "defects")


# ==============================================================================
# Артефакты: сниппеты вокруг дефектов и спектрограмма
# ==============================================================================

proc writeSnippets(dir: string; samples: seq[float32]; channels, sr: int;
                   defects: seq[InspectionDefect]):
    tuple[files: seq[string]; warnings: seq[string]] =
  ## Короткие WAV вокруг дефектов: их удобно прослушать и приложить к issue.
  if dir.len == 0:
    return
  try:
    createDir(dir)
  except CatchableError as e:
    result.warnings.add "не удалось создать каталог сниппетов: " & e.msg
    return

  let frames = samples.len div channels
  let pad = int(SnippetPadSeconds * float64(sr))
  var n = 0
  for d in defects:
    if n >= MaxSnippets:
      break
    let a = max(0, int(d.startSample) - pad)
    let b = min(frames, int(d.startSample) + 2 * pad)
    if b <= a:
      continue
    let path = dir / ("defect_" & align($n, 3, '0') & "_" &
                      defectKindName(d.kind) & ".wav")
    try:
      var slice = newSeq[float32]((b - a) * channels)
      copyMem(addr slice[0], unsafeAddr samples[a * channels],
              slice.len * sizeof(float32))
      # Запись сниппета — через фасад (issue #356).
      exportAudio(path, AudioFileInfo(
        sampleRate: int32(sr), channels: int16(channels),
        bitsPerSample: 16, isFloat: false), slice)
      result.files.add path
      inc n
    except CatchableError as e:
      result.warnings.add "сниппет " & path & ": " & e.msg

proc spectrogramGrid(samples: seq[float32]; channels, fftSize: int): SpectrogramGrid =
  let frames = samples.len div max(1, channels)
  if frames < 256:
    result.error = "слишком короткий файл для спектрограммы"
    return
  let n = nextPow2(max(256, fftSize))
  let hop = max(1, n div 4)
  let bins = n div 2 + 1
  var win = newSeq[float32](n)
  for i in 0 ..< n:
    win[i] = hannWindow(i, n)
  var mono = newSeq[float32](n)
  var mag: seq[float32]

  result.height = min(bins, 512)
  const MaxWidth = 1600
  var pos = 0
  while pos + n <= frames and result.cols.len < MaxWidth:
    for i in 0 ..< n:
      var s = 0.0f
      for ch in 0 ..< channels:
        s += samples[(pos + i) * channels + ch]
      mono[i] = s / float32(channels) * win[i]
    magnitudeSpectrum(mono, mag)
    var col = newSeq[float32](result.height)
    for j in 0 ..< result.height:
      let k = if result.height <= 1: 0
              else: int(float64(j) / float64(result.height - 1) *
                        float64(bins - 1))
      col[j] = mag[k]
    result.cols.add col
    pos += hop
  if result.cols.len == 0:
    result.error = "не удалось построить кадры спектрограммы"
    return
  result.ok = true

proc writeHeatmap(path: string; samples: seq[float32]; channels, sr,
                  fftSize: int): string =
  ## Спектрограмма в PGM (P5) — минимальный серый растр без кодировщиков.
  ## Ось X — время, ось Y — частота (снизу вверх, как принято).
  discard sr
  let grid = spectrogramGrid(samples, channels, fftSize)
  if not grid.ok:
    return grid.error
  var mx = 1.0e-9f
  for c in grid.cols:
    for v in c:
      mx = max(mx, v)

  try:
    let height = grid.height
    var buf = newSeq[byte](grid.cols.len * height)
    for x in 0 ..< grid.cols.len:
      for y in 0 ..< height:
        let v = grid.cols[x][height - 1 - y] / mx
        buf[y * grid.cols.len + x] = byte(min(255.0, max(0.0, float64(v) * 255.0)))
    var f = open(path, fmWrite)
    f.write("P5\n" & $grid.cols.len & " " & $height & "\n255\n")
    if buf.len > 0:
      discard f.writeBuffer(addr buf[0], buf.len)
    f.close()
  except CatchableError as e:
    return e.msg
  ""

proc spectrogramBase64(grid: SpectrogramGrid; width, height: int): string =
  ## Пиксели спектрограммы пакуются в base64 и рисуются `<canvas>`-ом внутри
  ## HTML. SVG из десятков тысяч `<rect>` весил бы мегабайты; canvas-вариант
  ## — десятки килобайт и всё так же не требует файлов рядом (#346).
  if not grid.ok or grid.cols.len == 0 or width <= 0 or height <= 0:
    return ""
  var mx = 1.0e-9f
  for c in grid.cols:
    for v in c:
      mx = max(mx, v)
  var raw = newSeq[byte](width * height)
  for y in 0 ..< height:
    let sourceRow = min(grid.height - 1,
      int(float64(y) / float64(height) * float64(grid.height)))
    for x in 0 ..< width:
      let sourceCol = min(grid.cols.len - 1,
        int(float64(x) / float64(width) * float64(grid.cols.len)))
      let v = grid.cols[sourceCol][grid.height - 1 - sourceRow] / mx
      raw[y * width + x] = byte(min(255.0, max(0.0, float64(v) * 255.0)))
  encode(raw)

proc spectrogramHtml(grid: SpectrogramGrid; width, height: int): string =
  ## Самодостаточный HTML-фрагмент: canvas + встроенный скрипт, без внешних
  ## файлов и без сети.
  let data = spectrogramBase64(grid, width, height)
  if data.len == 0:
    return "<p>спектрограмма недоступна</p>"
  result = "<canvas id=\"spec\" width=\"" & $width & "\" height=\"" & $height &
    "\" style=\"width:100%;image-rendering:pixelated;border:1px solid #333\">" &
    "</canvas>\n<script>(function(){var raw=atob(\"" & data &
    "\");var w=" & $width & ",h=" & $height &
    ";var c=document.getElementById('spec');var ctx=c.getContext('2d');" &
    "var img=ctx.createImageData(w,h);for(var i=0;i<w*h;i++){" &
    "var v=raw.charCodeAt(i);img.data[i*4]=v;img.data[i*4+1]=v;" &
    "img.data[i*4+2]=v;img.data[i*4+3]=255;}ctx.putImageData(img,0,0);})();" &
    "</script>"


# ==============================================================================
# Точка входа
# ==============================================================================

proc runAnalyze*(ctx: var Ctx; args: seq[string]): Report =
  let sc = scanArgs(args)
  if not sc.ok:
    return sc.rep

  var samples: seq[float32]
  var channels = 0
  var sr = 0'i32
  var err = ""
  if not readWavAll(sc.path, samples, channels, sr, err):
    return envError("не удалось прочитать файл: " & err,
      "нужен WAV PCM 16/24/32; проверьте путь и формат", errorKind = "io")

  var opts = defaultInspectionOptions()
  if sc.fftSize > 0:
    opts.fftSize = sc.fftSize
  let rep = inspectInterleaved(samples, channels, float32(sr), opts)

  var snippetFiles: seq[string] = @[]
  if not ctx.dryRun:
    if sc.snippetsDir.len > 0:
      let s = writeSnippets(sc.snippetsDir, samples, channels, int(sr),
                            rep.defects)
      snippetFiles = s.files
      for w in s.warnings:
        cliWarn("analyze: " & w)
    if sc.heatmapPath.len > 0:
      let e = writeHeatmap(sc.heatmapPath, samples, channels, int(sr),
                           opts.fftSize)
      if e.len > 0:
        cliWarn("analyze: спектрограмма: " & e)

  buildReport(sc.path, rep, sc.failOn, sc.maxDefects, snippetFiles,
              samples, channels, int(sr), opts.fftSize, sc.terminalOutput,
              sc.htmlPath)

