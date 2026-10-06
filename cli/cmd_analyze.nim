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

import std/[json, math, os, strutils]

import context
import audio_inspect
import spectrum
import wav_codec
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
    synopsis: "analyze <файл.wav> [ключи]",
    args: @[
      arg("файл.wav", "что слушать: записанный рендер или запись сессии"),
    ],
    options: @[
      opt("--snippets", "каталог коротких WAV вокруг дефектов", value = "каталог"),
      opt("--heatmap", "спектрограмма файла в PGM", value = "файл.pgm"),
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
    var r = openWavReader(path)
    channels = int(r.info.channels)
    sampleRate = r.info.sampleRate
    let frames = r.info.numFrames
    if frames <= 0 or channels <= 0 or r.info.sampleRate <= 0:
      r.close()
      err = "в файле нет сэмплов или некорректный заголовок"
      return false
    let total = int(frames) * channels
    samples = newSeq[float32](total)
    var raw = newSeq[uint8](total * 4 + 8)
    let got = readFrames(r,
      cast[ptr UncheckedArray[uint8]](addr raw[0]),
      cast[ptr UncheckedArray[float32]](addr samples[0]),
      int32(frames))
    r.close()
    if got <= 0:
      err = "не удалось прочитать сэмплы"
      return false
    if int(got) < int(frames):
      samples.setLen(int(got) * channels)
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

proc buildReport(path: string; rep: InspectionReport; failOn: FailOn;
                 maxDefects: int; snippetFiles: seq[string]): Report =
  let counts = severityCount(rep)
  let failing = block:
    var n = 0
    for d in rep.defects:
      if meetsThreshold(d.severity, failOn): inc n
    n

  var body = newJObject()
  body["file"] = %path
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
  summary["failOn"] = %($failOn).toLowerAscii()
  summary["failing"] = %failing
  var snips = newJArray()
  for s in snippetFiles:
    snips.add %s
  summary["snippets"] = snips
  body["summary"] = summary

  var lines: seq[string] = @[]
  lines.add "analyze: " & path
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
      "найдено " & $failing & " дефект(ов) уровня " & ($failOn).toLowerAscii(),
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
      var w = openWavWriter(path, AudioFileInfo(
        sampleRate: int32(sr), channels: int16(channels),
        bitsPerSample: 16, isFloat: false))
      writeFrames(w, cast[ptr UncheckedArray[float32]](addr slice[0]),
                  int32(b - a))
      close(w)
      result.files.add path
      inc n
    except CatchableError as e:
      result.warnings.add "сниппет " & path & ": " & e.msg

proc writeHeatmap(path: string; samples: seq[float32]; channels, sr,
                  fftSize: int): string =
  ## Спектрограмма в PGM (P5) — минимальный серый растр без кодировщиков.
  ## Ось X — время, ось Y — частота (снизу вверх, как принято).
  let frames = samples.len div channels
  if frames < 256:
    return "слишком короткий файл для спектрограммы"
  let n = nextPow2(max(256, fftSize))
  let hop = max(1, n div 4)
  let bins = n div 2 + 1
  var win = newSeq[float32](n)
  for i in 0 ..< n:
    win[i] = hannWindow(i, n)
  var mono = newSeq[float32](n)
  var mag: seq[float32]

  let height = min(bins, 512)
  const MaxWidth = 1600
  var cols: seq[seq[float32]]
  var pos = 0
  while pos + n <= frames and cols.len < MaxWidth:
    for i in 0 ..< n:
      var s = 0.0f
      for ch in 0 ..< channels:
        s += samples[(pos + i) * channels + ch]
      mono[i] = s / float32(channels) * win[i]
    magnitudeSpectrum(mono, mag)
    var col = newSeq[float32](height)
    for j in 0 ..< height:
      let k = if height <= 1: 0
              else: int(float64(j) / float64(height - 1) * float64(bins - 1))
      col[j] = mag[k]
    cols.add col
    pos += hop
  if cols.len == 0:
    return "не удалось построить кадры спектрограммы"

  var mx = 1.0e-9f
  for c in cols:
    for v in c:
      mx = max(mx, v)

  try:
    var buf = newSeq[byte](cols.len * height)
    for x in 0 ..< cols.len:
      for y in 0 ..< height:
        let v = cols[x][height - 1 - y] / mx
        buf[y * cols.len + x] = byte(min(255.0, max(0.0, float64(v) * 255.0)))
    var f = open(path, fmWrite)
    f.write("P5\n" & $cols.len & " " & $height & "\n255\n")
    if buf.len > 0:
      discard f.writeBuffer(addr buf[0], buf.len)
    f.close()
  except CatchableError as e:
    return e.msg
  ""

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

  buildReport(sc.path, rep, sc.failOn, sc.maxDefects, snippetFiles)

