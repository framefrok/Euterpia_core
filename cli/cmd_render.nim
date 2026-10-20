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
# Формат вывода: WAV (PCM 16, 24 или 32 бита, стерео). MP3/OGG ядро не пишет —
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
import std/cmdline

import signal_types
import offline_render
import context
import config
import control/query
import control_bridge
import plugin_host
import cmd_project
import project
import catalog
import builtin/scene_loader
import cli_spec
import compose/progress

# =============================================================================
# Спецификация команды (#330)
# =============================================================================

const
  DefaultTailSeconds* = 2.0
    ## Хвост по умолчанию, секунды.
  MaxRenderSeconds = 36_000.0
    ## Потолок длительности: 10 часов. Опечатка в `--seconds` не должна
    ## приводить к рендеру на терабайт данных.
  MaxSampleRate = 1_000_000
    ## Тот же потолок, что у ключа `sampleRate` в настройках (#258).
  DefaultBits = 16
  DefaultBlockSize = 512

  RenderSpec* = CommandSpec(
    name: "render",
    summary: "офлайн-рендер проекта в WAV без аудиоустройства",
    synopsis: "render [проект.eproj] [выход.wav] [ключи]",
    args: @[
      arg("проект.eproj", "что рендерить; историческое `.eut` принимается"),
      arg("выход.wav", "куда писать; без аргумента — рядом с проектом"),
    ],
    options: @[
      opt("--file", "проект, если он не задан позиционно", value = "проект.eproj"),
      opt("--out", "файл вывода, если он не задан позиционно", value = "файл.wav"),
      opt("--seconds", "длительность рендера; без ключа — конец последней ноты плюс --tail",
          value = "секунды"),
      opt("--tail", "добавка после последней ноты, секунды", value = "секунды",
          default = $int(DefaultTailSeconds)),
      opt("--master", "id ноды, подключённой к мастеру; без ключа мастер определяется по графу",
          value = "id ноды"),
      opt("--solo-track", "рендерить только эту дорожку (стем, #209)",
          value = "id дорожки"),
      opt("--stems", "стемы: по WAV на дорожку в указанный каталог (#108)",
          value = "каталог"),
      opt("--name-template", "шаблон имён стемов: {track}, {name}, {index}",
          value = "шаблон", default = "{track}_{name}.wav"),
      opt("--batch", "список проектов для последовательного рендера (#108)",
          value = "файл"),
      opt("--sample-rate", "частота дискретизации; без ключа — из проекта, затем настройки",
          value = "Гц"),
      opt("--block", "размер блока обработки", value = "кадры",
          default = $DefaultBlockSize),
      opt("--bits", "глубина дискретизации WAV", value = "16, 24 или 32",
          default = $DefaultBits),
      switch("--progress", "показывать прогресс в stderr (по умолчанию — только если stderr это терминал)"),
      switch("--no-progress", "не показывать прогресс"),
    ],
    example: "euterpia render project.eproj song.wav --seconds 30",
    fields: @[
      field("path", "отрендеренный проект"),
      field("out", "записанный WAV (или план при `--dry-run`)"),
      field("format", "формат вывода: `wav`"),
      field("formatDescription", "расшифровка формата"),
      field("channels", "число каналов (стерео)"),
      field("sampleRate", "частота дискретизации рендера"),
      field("blockSize", "размер блока обработки"),
      field("bitsPerSample", "глубина дискретизации"),
      field("seconds", "итоговая длительность"),
      field("scoreSeconds", "длительность партитуры без хвоста"),
      field("tailSeconds", "добавленный хвост"),
      field("tempo", "темп, по которому считались тики"),
      field("songEndTick", "конец песни в тиках"),
      field("frames", "кадров на канал"),
      field("rendered", "отрендерено кадров"),
      field("dryRun", "план без записи"),
      field("masterNodeId", "нода, выбранная мастером"),
      field("soloTrack", "id дорожки для стема (0 — мастер-микс)"),
      field("noteNodes", "ноды с нотными событиями"),
      field("automationLanes", "дорожки автоматизации, попавшие в рендер"),
      field("issues", "замечания рендера (не ошибки)"),
      field("peak", "пиковый уровень записанного WAV"),
      field("rms", "среднеквадратичный уровень"),
      field("silent", "запись тишины — предупреждение, а не ошибка"),
      field("stems", "стемы: `track`, `name`, `file`, `frames`, `ok` (#108)"),
      field("stemsFailed", "сколько стемов не отрендерилось"),
      field("batch", "результаты батча: `project`, `out`, `ok`, `exitCode`"),
      field("batchFailed", "сколько проектов батча не отрендерилось"),
    ],
    notes: @[
      "пример MANIFEST §19: euterpia render project.eproj",
      "вывод — WAV (PCM 16, 24 или 32 бита, стерео); MP3/OGG требуют кодировщика и в ядре отсутствуют",
      "проект без нотных событий требует --seconds: длину пустой партитуры CLI не выдумывает",
      "частота и блок: argv > метаданные проекта > настройки > умолчание",
      "--stems <каталог>: по WAV на дорожку; имена из --name-template ({track}, {name}, {index})",
      "стемы рендерятся тем же путём, что и мастер, с --solo-track; mute/solo дорожек учитываются",
      "--batch <файл>: строки «проект [выход][ --seconds N]», # — комментарий; --out задаёт каталог",
      "батч идёт последовательно: сцена и движок освобождаются после каждого проекта",
      "если хоть один стем/проект упал — ненулевой код, отчёт перечисляет удачные и неудачные",
      "--dry-run печатает план рендера и не пишет файл",
      "индикатор прогресса идёт в stderr: проценты, прошлое, осталось и скорость (×REALTIME)",
      "по умолчанию он включается, только если stderr — терминал: в CI и пайпах вывод остаётся байт-в-байт тем же",
      "--progress / --no-progress решают явно; -q отключает",
      "тихая или оборванная запись — предупреждение, а не ошибка: код 2 только у сбоя записи",
    ])

  RenderKeys* = RenderSpec.optionKeys
    ## Ключи `render` — из спецификации: справка, автодополнение и текст
    ## ошибки читают одно описание (#259, #330).

  WavSuffix = ".wav"
    ## Признак «позиционный аргумент — файл вывода».

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
    soloTrack: int32
      ## -1 — полный микс; иначе только эта дорожка (стем, #209).
    stemsDir: string
      ## Непусто — рендер стемов по дорожкам (#108).
    nameTemplate: string
      ## Шаблон имён стемов: `{track}`, `{name}`, `{index}`.
    batchPath: string
      ## Непусто — батч по списку проектов (#108).
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
  result.soloTrack = -1'i32
  result.bits = DefaultBits
  result.blockSize = DefaultBlockSize
  result.nameTemplate = "{track}_{name}.wav"

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
      of "--solo-track":
        let parsed = intArg(value, key, 1, high(int))
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "id дорожки, чей стем нужно отрендерить (#209)")
          return
        result.soloTrack = int32(parsed.value)
      of "--stems":
        result.stemsDir = value
      of "--name-template":
        if value.strip().len == 0:
          result.rep = usageError("--name-template: пустой шаблон",
            "например: --name-template \"{track}_{name}.wav\"")
          return
        result.nameTemplate = value
      of "--batch":
        result.batchPath = value
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
        let parsed = intArg(value, key, DefaultBits, 32)
        if not parsed.ok:
          result.rep = usageError(parsed.message,
            "глубина дискретизации: 16, 24 или 32 бита")
          return
        if parsed.value notin [16, 24, 32]:
          result.rep = usageError("--bits принимает 16, 24 или 32, получено: " &
                                  $parsed.value,
            "32 — целочисленный PCM; он нужен мастеру для точной обработки (#209)")
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

  # Режимы исключают друг друга: «стемы» и «батч» — разные ответы на вопрос
  # «что рендерить», и выбирать за пользователя между ними нельзя.
  if result.stemsDir.len > 0 and result.batchPath.len > 0:
    result.rep = usageError("--stems и --batch несовместимы",
      "стемы одного проекта и список проектов — разные режимы")
    return
  if result.stemsDir.len > 0 and result.soloTrack >= 0:
    result.rep = usageError("--stems и --solo-track несовместимы",
      "стемы рендерят ВСЕ дорожки; один стем — это --solo-track")
    return
  if result.batchPath.len > 0 and result.stemsDir.len > 0:
    result.rep = usageError("--batch не поддерживает --stems",
      "батч рендерит проекты целиком; стемы — отдельный запуск")
    return

  if result.stemsDir.len > 0:
    # --stems задаёт каталог сам; --out с другим путём — противоречие.
    if result.haveOut and result.outPath != result.stemsDir:
      result.rep = usageError("--stems и --out указывают разные каталоги",
        "каталог стемов задаётся ключом --stems")
      return
    result.outPath = result.stemsDir
    result.haveOut = true
    if not result.nameTemplate.toLowerAscii().endsWith(WavSuffix):
      result.nameTemplate.add(WavSuffix)
    result.ok = true
    return

  if result.batchPath.len > 0:
    # У батча --out — каталог, а не файл: имя каждому проекту даёт список.
    if not result.haveOut:
      result.outPath = "."
    result.ok = true
    return

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

proc renderProject(ctx: var Ctx; scan: RenderScan; proj: ProjectFormat;
                   meta: MetadataInfo): Report =
  ## Один проект: сцена → рендер → отчёт. Вызывается и обычным `render`,
  ## и (`#108`) каждым стемом/строкой батча — чтобы мастер и стемы шли
  ## ОДНИМ путём, а не двумя похожими.
  # --- частота и блок: argv > проект > настройки > умолчание --------------
  var sampleRate = scan.sampleRate
  if sampleRate <= 0:
    let fromProject = int(round(float64(meta.sampleRate)))
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
  # Плагины проекта (issue #95): типы-обёртки регистрируются до загрузки
  # сцены, иначе загрузчик отвергнет `plugin:<id>` как неизвестный тип.
  let doc = openDocument(scan.path, proj)
  var pluginErr = ""
  discard registerProjectPlugins(reg, doc, pluginErr)
  if pluginErr.len > 0:
    return usageError("плагины проекта не загружены: " & pluginErr,
      "проверьте путь и `euterpia plugin scan`, затем повторите рендер")
  var scene = loadScene(reg, proj, scan.master, int32(sampleRate),
                        parentDir(scan.path), scan.soloTrack,
                        pluginStateHookFor(doc))
  defer:
    destroyScene(scene)

  if not scene.ok:
    # Проект прочитан, но пайплайн из него не собирается: это данные, а не
    # окружение, — значит код 1, как у `graph check` (#90).
    return usageError(scene.error,
                      hint = "проверьте граф: euterpia graph check " & scan.path)

  let tempo =
    if meta.tempo > 1.0f: float64(meta.tempo)
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
    "soloTrack": int(scan.soloTrack),
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
  # освобождает его вместе с движком. `detachPipeline` отдаёт move-only
  # `OwnedPipeline` (#402), поэтому повторно освободить его невозможно.
  var pipeline = detachPipeline(scene)

  let rendered = renderToWav(scan.outPath, move(pipeline), opts)
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
      return envError(rendered.error,
                      "проверьте каталог и права: " & scan.outPath)
    return panicError("внутренняя ошибка рендера: " & rendered.error,
                      "это баг: приложите вывод `euterpia --version` и команду")

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


proc renderPreparedProject*(ctx: var Ctx; path, outPath: string;
                            proj: ProjectFormat;
                            seconds: float64 = 0.0;
                            tail: float64 = DefaultTailSeconds;
                            master: int = -1;
                            sampleRate: int = 0;
                            blockSize: int = 0;
                            bits: int = DefaultBits): Report =
  ## Рендер проекта, который уже находится в памяти: сценарий применяется к
  ## документу и рендерится БЕЗ промежуточного файла проекта (#335).
  ##
  ## Это тот же путь, что у `render`: сцена, движок и WAV — одни и те же;
  ## меняется только источник модели. Поэтому эталонный прогон сценария
  ## проверяет настоящий рендер, а не «похожий на него».
  ##
  ## `path` нужен для относительных путей плагинов и ресурсов (они считаются
  ## от проекта), `outPath` — файл результата.
  var scan = RenderScan(path: path, outPath: outPath, haveOut: true,
                        tail: tail, master: master, soloTrack: -1'i32,
                        bits: bits, blockSize: blockSize,
                        sampleRate: sampleRate,
                        nameTemplate: "{track}_{name}.wav")
  if seconds > 0.0:
    scan.seconds = seconds
    scan.haveSeconds = true
  let meta = queryMetadata(openDocument(path, proj))
  renderProject(ctx, scan, proj, meta)


# =============================================================================
# Стемы и батч (#108)
# =============================================================================

proc sanitizeStemName(text: string): string =
  ## Имя файла без сюрпризов: буквы/цифры/`-_.` остаются, остальное — `_`.
  for ch in text:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.'}:
      result.add ch
    else:
      result.add '_'
  if result.len == 0:
    result = "track"

proc stemFileName(pattern: string; track: TrackInfo; index: int): string =
  result = pattern
  result = result.replace("{track}", $track.id)
  result = result.replace("{name}", sanitizeStemName(track.name))
  result = result.replace("{index}", $index)
  if result.len == 0:
    result = $track.id & "_" & sanitizeStemName(track.name) & ".wav"

proc runStems(ctx: var Ctx; scan: RenderScan; proj: ProjectFormat;
              meta: MetadataInfo): Report =
  ## Стемы — это те же рендеры, что мастер, но с `--solo-track` на каждую
  ## дорожку. Отдельный путь не нужен и опасен: сумма стемов сходится с
  ## мастером именно потому, что обработка одна.
  let doc = openDocument(scan.path, proj)
  let tracks = queryTracks(doc)
  var anySolo = false
  for track in tracks:
    if track.solo:
      anySolo = true

  var targets: seq[TrackInfo] = @[]
  for track in tracks:
    if track.clips.len == 0:
      continue
    # При solo на любой дорожке остальные в мастер не попадают — стемы
    # обязаны вести себя так же, иначе их сумма перестанет быть мастером.
    if anySolo and not track.solo:
      continue
    targets.add track

  if targets.len == 0:
    return usageError("в проекте нет дорожек с клипами: стемы не из чего делать",
      "добавьте клипы/ноты: euterpia notation import … или project show")

  if not dirExists(scan.stemsDir):
    try:
      createDir(scan.stemsDir)
    except CatchableError:
      return envError("каталог стемов недоступен: " & scan.stemsDir,
        "проверьте права и путь", errorKind = "io")

  var stems = newJArray()
  var lines: seq[string] = @[
    CliName & " render --stems — по файлу на дорожку",
    "файл: " & scan.path,
    "каталог: " & scan.stemsDir,
    "шаблон: " & scan.nameTemplate,
  ]
  var failed = 0
  var used: seq[string] = @[]

  for index, track in targets:
    var one = scan
    one.stemsDir = ""
    one.soloTrack = track.id
    var name = stemFileName(scan.nameTemplate, track, index)
    var candidate = scan.stemsDir / name
    # Одинаковые имена (шаблон без {track}) не должны затирать друг друга.
    var bump = 1
    while candidate in used:
      let ext = splitFile(name).ext
      let base = name[0 ..< name.len - ext.len]
      candidate = scan.stemsDir / (base & "_" & $bump & ext)
      inc bump
    name = extractFilename(candidate)
    used.add candidate
    one.outPath = candidate

    let rep = renderProject(ctx, one, proj, meta)
    var item = %*{
      "track": track.id,
      "name": track.name,
      "file": candidate,
      "ok": rep.ok,
      "error": rep.error,
    }
    if rep.ok and rep.body != nil:
      item["frames"] = rep.body{"frames"}
      item["seconds"] = rep.body{"seconds"}
      item["peak"] = rep.body{"peak"}
      item["rms"] = rep.body{"rms"}
    stems.add item

    if rep.ok:
      lines.add "  дорожка #" & $track.id & " «" & track.name & "» → " & name
    else:
      inc failed
      lines.add "  дорожка #" & $track.id & " «" & track.name & "»: ОШИБКА: " &
                rep.error

  let body = %*{
    "path": scan.path,
    "stemsDir": scan.stemsDir,
    "nameTemplate": scan.nameTemplate,
    "stems": stems,
    "stemsFailed": failed,
    "dryRun": ctx.dryRun,
  }
  if failed > 0:
    let message = $failed & " из " & $targets.len & " стемов не отрендерились"
    return errReport(exUsage, "usage", message,
      hint = "причины — в поле `stems`; мастер-рендер мог упасть по данным проекта",
      lines = lines, body = body)
  lines.add "итого: " & $targets.len & " стемов" &
    (if anySolo: " (режим solo)" else: "")
  okReport(body = body, lines = lines)


proc runBatch(ctx: var Ctx; scan: RenderScan): Report =
  ## Батч — последовательность независимых рендеров. Проекты не держатся
  ## одновременно: после каждого `renderProject` сцена и движок освобождены,
  ## поэтому RSS не растёт линейно с числом строк (#108).
  if not fileExists(scan.batchPath):
    return envError("список батча не найден: " & scan.batchPath,
      "нужен текстовый файл: строка — проект, # — комментарий",
      errorKind = "io")
  var outDir = if scan.outPath.len == 0: "." else: scan.outPath
  if not dirExists(outDir):
    try:
      createDir(outDir)
    except CatchableError:
      return envError("каталог батча недоступен: " & outDir,
        "проверьте права и путь", errorKind = "io")

  var content = ""
  try:
    content = readFile(scan.batchPath)
  except CatchableError as e:
    return envError("не удалось прочитать список батча: " & e.msg,
      "проверьте файл " & scan.batchPath, errorKind = "io")

  var results = newJArray()
  var lines: seq[string] = @[
    CliName & " render --batch — последовательный рендер",
    "список: " & scan.batchPath,
    "каталог вывода: " & outDir,
  ]
  var total = 0
  var failed = 0
  var anyEnv = false

  for raw in content.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let tokens = parseCmdLine(line)
    if tokens.len == 0:
      continue
    inc total

    var item = scanArgs(tokens)
    if not item.ok:
      inc failed
      var rec = %*{"line": total, "project": tokens[0], "ok": false,
                   "exitCode": int(item.rep.code), "error": item.rep.error}
      rec["out"] = %""
      results.add rec
      lines.add "  #" & $total & ": отказ разбора — " & item.rep.error
      continue

    if item.stemsDir.len > 0 or item.batchPath.len > 0:
      inc failed
      results.add %*{"line": total, "project": item.path, "out": "",
                     "ok": false, "exitCode": int(exUsage),
                     "error": "в строке батча нельзя --stems/--batch"}
      lines.add "  #" & $total & ": вложенный режим --stems/--batch запрещён"
      continue

    if not item.haveOut:
      item.outPath = outDir / changeFileExt(extractFilename(item.path),
                                                   WavSuffix)
    elif not item.outPath.isAbsolute and parentDir(item.outPath) in ["", "."]:
      # Имя без каталога в строке батча — относительно --out, иначе
      # «--out dir» молча игнорировался бы.
      item.outPath = outDir / item.outPath

    let loaded = loadAt(item.path)
    if not loaded.ok:
      inc failed
      if loaded.rep.code == exEnv:
        anyEnv = true
      results.add %*{"line": total, "project": item.path, "out": item.outPath,
                     "ok": false, "exitCode": int(loaded.rep.code),
                     "error": loaded.rep.error}
      lines.add "  #" & $total & " " & item.path & ": " & loaded.rep.error
      continue

    let meta = queryMetadata(openDocument(item.path, loaded.proj))
    let rep = renderProject(ctx, item, loaded.proj, meta)
    if not rep.ok:
      inc failed
      if rep.code == exEnv:
        anyEnv = true
    results.add %*{"line": total, "project": item.path, "out": item.outPath,
                   "ok": rep.ok, "exitCode": int(rep.code),
                   "error": rep.error}
    if rep.ok:
      lines.add "  #" & $total & " " & item.path & " → " & item.outPath
    else:
      lines.add "  #" & $total & " " & item.path & ": " & rep.error
    if not ctx.quiet:
      cliWarn("батч: " & $total & " обработан, ошибок: " & $failed)

  let body = %*{
    "batchPath": scan.batchPath,
    "outDir": outDir,
    "batch": results,
    "batchTotal": total,
    "batchFailed": failed,
    "dryRun": ctx.dryRun,
  }
  if total == 0:
    return usageError("список батча пуст: " & scan.batchPath,
      "строка — проект; пустые строки и # — комментарии",
      lines = lines, body = body)
  if failed > 0:
    lines.add "итого: " & $(total - failed) & " из " & $total &
      " проектов отрендерено, ошибок: " & $failed
    let message = $failed & " из " & $total & " проектов батча не отрендерились"
    if anyEnv:
      return errReport(exEnv, "env", message,
        hint = "причины — в поле `batch`", lines = lines, body = body)
    return errReport(exUsage, "usage", message,
      hint = "причины — в поле `batch`", lines = lines, body = body)
  lines.add "итого: " & $total & " проектов"
  okReport(body = body, lines = lines)


# =============================================================================
# Точка входа
# =============================================================================

proc runRender*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia render <проект.eproj> [выход.wav] [ключи]`.
  ##
  ## Режимы (#108): обычный рендер, `--stems` (все дорожки одного проекта)
  ## и `--batch` (список проектов). Загрузка проекта и метаданные — общие,
  ## чтобы «откуда темп/частота» не разъезжались между режимами.
  let scan = scanArgs(args)
  if not scan.ok:
    return scan.rep

  if scan.batchPath.len > 0:
    return runBatch(ctx, scan)

  let loaded = loadAt(scan.path)
  if not loaded.ok:
    return loaded.rep
  let proj = loaded.proj
  # Метаданные — через Query API (#336): темп и частота берутся из того же
  # описания, что показывает `project show`, а не обходом формата.
  let meta = queryMetadata(openDocument(scan.path, proj))

  if scan.stemsDir.len > 0:
    return runStems(ctx, scan, proj, meta)

  renderProject(ctx, scan, proj, meta)

