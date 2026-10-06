# cli/cmd_render.nim
#
# `euterpia render` — офлайн-рендер проекта в файл (issue #91, пример
# MANIFEST §19: `euterpia render project.eproj`).
#
# Границы (§20): CLI не компилирует граф и не крутит блоки. Он читает проект
# (Core), собирает сцену (`builtin/scene_loader` — там знание о нодах и о
# формате проекта), просит Core посчитать и записать файл (`offline_render`)
# и печатает отчёт. Единственное решение, которое принимает CLI, — «сколько
# секунд рендерить»: длина партитуры живёт в тиках, а файл измеряется
# секундами, и перевод делается по темпу проекта.
#
# Формат вывода: WAV (PCM 16 или 24 бита, стерео). MP3/OGG ядро не пишет —
# в `offline_render` нет кодировщика, и CLI не имеет права делать вид, что
# он есть: неизвестное расширение отвергается с указанием точки расширения.
#
# Длительность:
#   * `--seconds S` — ровно S секунд (явное сильнее расчётного);
#   * иначе — конец последнего нотного события + `--tail` секунд (умолчание
#     2 с): у инструментов есть хвост затухания, и обрезать его по последней
#     ноте значило бы «отрубить» релиз.
#   * проект без нотных событий требует явного `--seconds`: длину пустой
#     партитуры CLI не выдумывает.
#
# Данные для рендера берутся из проекта: темп — для перевода тиков, дорожки
# автоматизации — как есть. То, что «подозрительно, но не смертельно»
# (значение параметра вне диапазона, дорожка на ноду, которой нет),
# печатается предупреждением: рендер из-за этого не срывается.

import std/[json, math, os, strutils, terminal]

import project
import signal_types
import offline_render
import context
import config
import cmd_project
import catalog
import builtin/scene_loader
import compose/progress

const
  RenderKeys* = @["--file", "--out", "--seconds", "--tail", "--master",
                  "--sample-rate", "--block", "--bits",
                  "--progress", "--no-progress"]
    ## Ключи `render` — для справки и автодополнения (#259). `--progress` и
    ## `--no-progress` флаги, а не пары «ключ-значение» (#310).

  WavSuffix = ".wav"
    ## Признак «позиционный аргумент — файл вывода».

  DefaultTailSeconds* = 2.0
    ## Хвост по умолчанию, секунды.
  MaxRenderSeconds = 36_000.0
    ## Потолок длительности: 10 часов. Опечатка в `--seconds` не должна
    ## приводить к рендеру на терабайт данных.
  MaxSampleRate = 1_000_000
    ## Тот же потолок, что у ключа `sampleRate` в настройках (#258).
  DefaultBits = 16
  DefaultBlockSize = 512

type
  NumArg = object
    ok: bool
    value: float64
    message: string

  IntArg = object
    ok: bool
    value: int
    message: string

  RenderScan = object
    ok: bool
    rep: Report
    path: string
    outPath: string
    haveOut: bool
    seconds: float64
    haveSeconds: bool
    tail: float64
    master: int
      ## -1 — «определить по графу» (правило живёт в `scene_loader`).
    sampleRate: int
    blockSize: int
    bits: int
    progress: bool
      ## Показывать индикатор рендера (#310).
    progressSet: bool
      ## Прогресс задан явно ключом. Без ключа решение принимает среда:
      ## терминал ли stderr, не мешает ли режим вывода.

# =============================================================================
# Разбор значений
# =============================================================================

proc numArg(text, key: string; lowInclusive, highInclusive: float64): NumArg =
  ## Число в диапазоне. `NaN` и бесконечность отсекаются сравнениями: без
  ## этого `--seconds nan` дал бы рендер нулевой длины, а `--seconds inf` —
  ## бесконечный цикл, который никто не согласится ждать.
  var number: float
  try:
    number = parseFloat(text.strip())
  except ValueError:
    return NumArg(ok: false,
      message: key & ": ожидается число, получено «" & text & "»")
  if not (float64(number) >= lowInclusive) or
     not (float64(number) <= highInclusive):
    return NumArg(ok: false,
      message: key & ": ожидается число от " & $lowInclusive & " до " &
        $highInclusive & ", получено «" & text & "»")
  NumArg(ok: true, value: float64(number))

proc intArg(text, key: string; lowInclusive, highInclusive: int): IntArg =
  var number: int
  try:
    number = parseInt(text.strip())
  except ValueError:
    return IntArg(ok: false,
      message: key & ": ожидается целое число, получено «" & text & "»")
  if number < lowInclusive or number > highInclusive:
    return IntArg(ok: false,
      message: key & ": ожидается целое от " & $lowInclusive & " до " &
        $highInclusive & ", получено «" & text & "»")
  IntArg(ok: true, value: number)

# =============================================================================
# Разбор аргументов
# =============================================================================

proc scanArgs(args: seq[string]): RenderScan =
  ## Ключей мало, поэтому разбор — явный цикл. Он же принимает форму
  ## `--ключ=значение`: иначе агент, привыкший к ней по другим командам,
  ## получил бы «неизвестный ключ».
  result.path = DefaultProjectFile
  result.tail = DefaultTailSeconds
  result.master = -1
  result.bits = DefaultBits
  result.blockSize = DefaultBlockSize

  var haveFile = false
  var fileFromPositional = false
  var i = 0
  while i < args.len:
    let token = args[i]
    var key = token
    var value = ""
    var haveInline = false
    let eq = token.find('=')
    if token.startsWith("--") and eq > 0:
      key = token[0 ..< eq]
      value = token[eq + 1 .. ^1]
      haveInline = true

    if key == "--progress" or key == "--no-progress":
      # Флаги, а не пары «ключ-значение»: значение после них — позиционный
      # аргумент команды, а не «настройка прогресса» (#310).
      if haveInline:
        result.rep = usageError(key & " — флаг и не принимает значение",
          "например: euterpia render " & key)
        return
      result.progress = key == "--progress"
      result.progressSet = true
    elif key in RenderKeys:
      if not haveInline:
        if i + 1 >= args.len:
          result.rep = usageError(key & " требует значение",
                                  "например: euterpia render " & key & " …")
          return
        inc i
        value = args[i]
      case key
      of "--file":
        result.path = value
        haveFile = true
      of "--out":
        result.outPath = value
        result.haveOut = true
      of "--seconds":
        let parsed = numArg(value, key, 0.001, MaxRenderSeconds)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "например: euterpia render --seconds 30")
          return
        result.seconds = parsed.value
        result.haveSeconds = true
      of "--tail":
        let parsed = numArg(value, key, 0.0, MaxRenderSeconds)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "хвост — это добавка к длине партитуры; по умолчанию " &
            $DefaultTailSeconds & " с")
          return
        result.tail = parsed.value
      of "--master":
        let parsed = intArg(value, key, 1, high(int))
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "id ноды, подключённой к мастеру; без ключа мастер определяется по графу")
          return
        result.master = parsed.value
      of "--sample-rate":
        let parsed = intArg(value, key, 1, MaxSampleRate)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "частота дискретизации в герцах; по умолчанию — с проекта")
          return
        result.sampleRate = parsed.value
      of "--block":
        let parsed = intArg(value, key, 1, MaxBlockSize)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "размер блока в кадрах: 1 … " & $MaxBlockSize)
          return
        result.blockSize = parsed.value
      else: # --bits
        let parsed = intArg(value, key, DefaultBits, 24)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "глубина дискретизации: 16 или 24 бита")
          return
        if parsed.value != 16 and parsed.value != 24:
          result.rep = usageError("--bits принимает 16 или 24, получено: " &
                                  $parsed.value,
            "других значений у WAV PCM в ядре нет")
          return
        result.bits = parsed.value
    elif token.startsWith("-") and token.len > 1:
      result.rep = usageError("неизвестный ключ: " & token,
                              "ключи render: " & RenderKeys.join(", "))
      return
    else:
      # Позиционные аргументы опознаются по расширению — тем же правилом,
      # что у команд графа: «какой из них что» угадывать запрещено (§82).
      # Расширения проекта читает `isProjectPath` (общий список), а не копия
      # строки здесь: `.eproj` и историческое `.eut` понимают все команды.
      let lower = token.toLowerAscii()
      if isProjectPath(token):
        if haveFile or fileFromPositional:
          result.rep = usageError("путь к проекту указан дважды: " &
                                  result.path & " и " & token,
            "файл проекта задаётся либо позиционным аргументом, либо --file")
          return
        result.path = token
        fileFromPositional = true
      elif lower.endsWith(WavSuffix):
        if result.haveOut:
          result.rep = usageError("файл вывода указан дважды: " &
                                  result.outPath & " и " & token,
            "выход задаётся либо позиционным аргументом, либо --out")
          return
        result.outPath = token
        result.haveOut = true
      else:
        result.rep = usageError("непонятный аргумент: " & token,
          "ожидается проект (" & projectSuffixesHint() & ") и/или файл вывода (*" &
          WavSuffix & "); ключи: " & RenderKeys.join(", "))
        return
    inc i

  # Формат определяется расширением выхода: писать «просто файл» без
  # расширения — значит оставить пользователя в догадках о содержимом.
  if result.haveOut:
    let lower = result.outPath.toLowerAscii()
    if not lower.endsWith(WavSuffix):
      result.rep = usageError(
        "формат вывода не поддержан: " & result.outPath,
        "ядро пишет только " & OfflineFormatsSupported.join(", ") &
        " — расширение .wav; MP3/OGG появятся как адаптер-кодировщик рядом с WAV")
      return
  else:
    result.outPath = result.path.changeFileExt(WavSuffix)

  result.ok = true


# =============================================================================
# Настройки как умолчания
# =============================================================================

proc configInt(ctx: Ctx; key: string; fallback: int): int =
  ## Целое из настроек окружения (#258). Значения уже прошли проверку при
  ## чтении, поэтому здесь только перевод текста в число; пустое значение —
  ## «ключ не задан» и означает умолчание CLI.
  let text = ctx.config.entry(key).value
  if text.len == 0:
    return fallback
  var number: int
  try:
    number = parseInt(text.strip())
  except ValueError:
    return fallback
  if number <= 0: fallback else: number

# =============================================================================
# Отчёт
# =============================================================================

proc secondsText(value: float64): string =
  ## Секунды с двумя знаками. Формат фиксирован, поэтому вывод сравним
  ## между запусками (#88).
  formatFloat(value, ffDecimal, 2)

proc issuesJson(issues: seq[SceneIssue]): JsonNode =
  result = newJArray()
  for item in issues:
    result.add %*{"nodeId": item.nodeId, "what": item.what,
                  "message": item.message}

proc issueLines(issues: seq[SceneIssue]): seq[string] =
  ## Замечания загрузки в человекочитаемом виде. Порядок — тот, в котором
  ## их набрала сцена (по id ноды, затем по имени параметра), поэтому он
  ## детерминирован.
  for item in issues:
    result.add "предупреждение: нода #" & $item.nodeId & " (" & item.what &
      "): " & item.message

proc formatText(sampleRate, bits: int): string =
  ## Формат файла словами. Каналы всегда два — ядро микширует в стерео
  ## (`offline_render`), и обещать в отчёте другое нельзя.
  "WAV PCM " & $bits & " бит, стерео, " & $sampleRate & " Гц"


# =============================================================================
# render
# =============================================================================

proc runRender*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia render <проект.eproj> [выход.wav] [ключи]`.
  let scan = scanArgs(args)
  if not scan.ok:
    return scan.rep

  let loaded = loadAt(scan.path)
  if not loaded.ok:
    return loaded.rep
  let proj = loaded.proj

  # --- частота и блок: argv > проект > настройки > умолчание --------------
  var sampleRate = scan.sampleRate
  if sampleRate <= 0:
    let fromProject = int(round(float64(proj.metadata.sampleRate)))
    if fromProject > 0:
      sampleRate = fromProject
    else:
      sampleRate = configInt(ctx, "sampleRate", 48000)
  let blockSize = if scan.blockSize > 0: scan.blockSize
                  else: configInt(ctx, "blockSize", DefaultBlockSize)

  # --- сцена --------------------------------------------------------------
  # Реестр собирается на вызов: он и так статический, а общего изменяемого
  # состояния в CLI быть не должно (§72).
  var reg = builtinRegistry()
  var scene = loadScene(reg, proj, scan.master, int32(sampleRate))
  defer:
    destroyScene(scene)

  if not scene.ok:
    # Проект прочитан, но пайплайн из него не собирается: это данные, а не
    # окружение, — значит код 1, как у `graph check` (#90).
    return errReport(exUsage, "usage", scene.error,
                     hint = "проверьте граф: euterpia graph check " & scan.path)

  let tempo =
    if proj.metadata.tempo > 1.0f: float64(proj.metadata.tempo)
    else: 120.0

  # --- длительность -------------------------------------------------------
  var tailSeconds = 0.0
  var totalSeconds = 0.0
  if scan.haveSeconds:
    totalSeconds = scan.seconds
  else:
    if scene.songEndTick <= 0:
      return usageError(
        "в проекте нет нотных событий: длину рендера задаёт --seconds",
        "например: euterpia render " & scan.path & " --seconds 10")
    tailSeconds = scan.tail
    totalSeconds = sceneSeconds(scene, tempo) + tailSeconds
    if totalSeconds > MaxRenderSeconds:
      return usageError(
        "расчётная длительность " & secondsText(totalSeconds) &
        " с превышает потолок " & secondsText(MaxRenderSeconds) & " с",
        "задайте длину явно: euterpia render --seconds 600")

  if totalSeconds > MaxRenderSeconds:
    return usageError(
      "--seconds " & secondsText(totalSeconds) & " с превышает потолок " &
      secondsText(MaxRenderSeconds) & " с",
      "потолок защищает от опечатки в длительности")

  let frames = int64(totalSeconds * float64(sampleRate))
  if frames <= 0:
    return usageError("длительность рендера округлилась в ноль кадров",
                      "увеличьте --seconds")

  let scoreSeconds = sceneSeconds(scene, tempo)


  # --- план и отчёт -------------------------------------------------------
  var body = %*{
    "path": scan.path,
    "out": scan.outPath,
    "format": OfflineFormatsSupported[0],
    "formatDescription": formatText(sampleRate, scan.bits),
    "sampleRate": sampleRate,
    "blockSize": blockSize,
    "bitsPerSample": scan.bits,
    "channels": 2,
    "frames": frames,
    "seconds": totalSeconds,
    "tailSeconds": tailSeconds,
    "songEndTick": int(scene.songEndTick),
    "scoreSeconds": scoreSeconds,
    "tempo": tempo,
    "masterNodeId": scene.masterNodeId,
    "automationLanes": scene.automation.len,
    "issues": issuesJson(scene.issues),
  }
  var noteNodes = newJArray()
  for id in scene.noteNodeIds:
    noteNodes.add %id
  body["noteNodes"] = noteNodes

  var lines: seq[string] = @[
    CliName & " render — офлайн-рендер",
    "файл: " & scan.path,
    "выход: " & scan.outPath,
    "формат: " & formatText(sampleRate, scan.bits),
    "мастер: нода #" & $scene.masterNodeId,
    "нотных нод: " & $scene.noteNodeIds.len,
    "дорожек автоматизации: " & $scene.automation.len,
    "длительность: " & secondsText(totalSeconds) & " с (" & $frames &
      " кадров; партитура " & secondsText(scoreSeconds) & " с" &
      (if tailSeconds > 0.0: " + хвост " & secondsText(tailSeconds) & " с"
       else: "") & ")",
    "блок: " & $blockSize & " кадров",
  ]
  lines.add issueLines(scene.issues)

  # --- запись -------------------------------------------------------------
  # `--dry-run` показывает план и не касается диска: рендер — единственная
  # операция CLI, которая пишет сотни мегабайт, и пробовать её «на всякий
  # случай» пользователь не должен.
  if ctx.dryRun:
    lines.add "не записан: " & scan.outPath & " (--dry-run)"
    body["rendered"] = %false
    body["dryRun"] = %true
    return okReport(body = body, lines = lines)

  var opts = defaultRenderOptions(int32(sampleRate), int32(blockSize), 0.0)
  opts.totalFrames = frames
  opts.bitsPerSample = int32(scan.bits)
  opts.tempo = tempo
  opts.automation = scene.automation

  # --- индикатор прогресса (#310) -------------------------------------------
  # Показываем в stderr и только когда это уместно: stdout принадлежит
  # результату команды (MANIFEST §21), а в CI/пайпе лишний вывод ломает
  # байт-в-байт детерминизм (#88). Поэтому «по умолчанию» — терминал,
  # а ключи `--progress`/`--no-progress` решают явно.
  let autoProgress =
    (not ctx.quiet) and (ctx.mode != omJson) and terminal.isatty(stderr)
  let wantProgress =
    if scan.progressSet: scan.progress else: autoProgress

  var printer: ProgressPrinter = nil
  if wantProgress:
    printer = newProgress(float64(frames) / float64(sampleRate),
                          int32(sampleRate))
    opts.onProgress = printer.callback

  # Пайплайн переходит рендеру: движок внутри `renderToWav` забирает граф и
  # освобождает его вместе с движком. Иначе `destroyScene` (defer выше)
  # освободил бы тот же пайплайн второй раз — двойное освобождение.
  let pipeline = detachPipeline(scene)

  let rendered = renderToWav(scan.outPath, pipeline, opts)
  if not rendered.ok:
    # Недописанная строка индикатора осталась бы висеть поверх отчёта —
    # стираем её перед выходом с ошибкой.
    if printer != nil:
      printer.clear()
    # Ядро отвечает одним текстом, а CLI обязан назвать вид ошибки: сбой
    # записи файла — окружение (код 2), всё остальное — баг (код 3).
    let isIO = rendered.error.startsWith("не удалось") or
               rendered.error.startsWith("ошибка записи") or
               rendered.error.startsWith("не удалось закрыть")
    if isIO:
      return errReport(exEnv, "env", rendered.error,
                       hint = "проверьте каталог и права: " & scan.outPath)
    return errReport(exPanic, "panic", "внутренняя ошибка рендера: " &
                     rendered.error,
                     hint = "это баг: приложите вывод `euterpia --version` и команду")

  body["rendered"] = %true
  body["dryRun"] = %false
  body["peak"] = %rendered.peak
  body["rms"] = %rendered.rms
  body["silent"] = %rendered.silent

  lines.add "записано: " & rendered.path
  lines.add "кадров: " & $rendered.frames & ", длительность: " &
    secondsText(rendered.seconds) & " с"
  lines.add "пик: " & formatFloat(float64(rendered.peak), ffDecimal, 3) &
    ", RMS: " & formatFloat(float64(rendered.rms), ffDecimal, 3)

  # Тишина — не ошибка рендера (пустой граф тоже законен), но молчать о ней
  # нельзя: «команда прошла, файл без звука» — самый дорогой вид сюрприза.
  if rendered.silent:
    body["warning"] = %"выход пустой: пик равен нулю"
    lines.add "внимание: выход без звука (пик 0): проверьте связи и нотные ноды"
  elif not scan.haveSeconds and rendered.seconds < scoreSeconds:
    body["warning"] = %"файл короче партитуры"
    lines.add "внимание: файл короче партитуры (" &
      secondsText(rendered.seconds) & " с из " & secondsText(scoreSeconds) &
      " с): увеличьте --tail или задайте --seconds"

  okReport(body = body, lines = lines)

