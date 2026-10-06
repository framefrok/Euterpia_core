# core/offline_render.nim
#
# Офлайн-рендер пайплайна в WAV — то, что делает `euterpia render` и любой
# экспорт: граф считается быстрее реального времени, без аудиоустройства.
#
# Почему это Core, а не CLI:
#   рендер — это «прогнать пайплайн через Audio Engine и сохранить блоки».
#   Ни списка нод, ни формата проекта здесь не нужно: на вход приходит уже
#   собранный `CompiledPipeline`, а на выход — файл. Всё, что знает о нодах
#   (какие бывают, как собрать из проекта), остаётся в слое Nodes.
#
# Что делает движок в офлайне:
#   `renderOffline` крутит блоки с `forceAdvance = true`, то есть транспорт
#   идёт вперёд даже без команды `play`. Команда `postPlay` всё равно
#   отправляется: без неё состояние транспорта в контексте нод было бы
#   «stopped», а источник событий (нотный секвенсор) обязан видеть именно
#   `pfTransportPlaying` — иначе он молчит, и рендер выходит тишиной.
#
# Автоматизация:
#   параметры нод — это то, что в проекте лежит отдельными дорожками
#   (`AutomationLaneFormat`). Здесь они применяются на границах ЧАНКОВ через
#   обычный `postSetParam`: тот же путь, что у живой автоматизации в
#   реальном времени. Чанк — четверть секунды, поэтому «на слух»
#   интерполяция неотличима от пошаговой по блокам, а команд в очереди
#   в тысячи раз меньше.
#
# Формат вывода — WAV (PCM 16 или 24 бита), стерео: ровно то, что умеет
# `wav_codec`. MP3/OGG в ядре не пишутся — см. `OfflineFormatsSupported`.

import std/math
import
  codec_api,
  signal_types,
  transport,
  compiled_pipeline,
  audio_engine,
  sequencer,
  wav_codec

{.push raises: [].}

const
  OfflineFormatsSupported* = @["wav"]
    ## Форматы, в которые ядро умеет писать САМО. MP3 и OGG отсутствуют
    ## намеренно: кодировщиков в проекте нет, а тянуть внешний энкодер
    ## (lame/oggenc) — это зависимость среды, а не библиотека ядра.
    ## Расширение — точка подключения: сюда добавляется формат, когда
    ## появится адаптер-кодировщик, а `RenderOptions` получает поле
    ## `format` — вызывающий код при этом не меняется.

  DefaultChunkSeconds = 0.25
    ## Гранулярность автоматизации: как часто пересчитываются значения
    ## параметров во время рендера.

  ProgressIntervalSeconds = 1.0
    ## Как часто колбэк прогресса получает кадры. Чанк — четверть секунды,
    ## то есть четыре вызова на секунду аудио: для часовой пьесы это 14 тысяч
    ## вызовов, а при рендере быстрее реального времени — 120 вызовов в
    ## секунду экранного времени, и терминал только мигает. Секунда аудио —
    ## компромисс: обновление достаточно частое, чтобы человек видел
    ## движение, и достаточно редкое, чтобы перерисовка стоила копейки.

type
  RenderProgressProc* = proc(framesDone, totalFrames: int64) {.closure, gcsafe, raises: [].}
    ## Колбэк прогресса офлайн-рендера.
    ##
    ## Вызывается НЕ чаще раза в `ProgressIntervalSeconds` секунд аудио и
    ## обязательно на последнем кадре. `nil` — не вызывается вовсе: рендер из
    ## тестов и CI ничего не платит за отсутствие прогресса (#88).
    ##
    ## Контракт намеренно узкий — два целых числа. Время, проценты и вид
    ## строки — дело вызывающего (CLI или `libs/compose`): Core не знает, как
    ## выглядит терминал.

  OfflineAutomationPoint* = object
    ## Точка автоматизации в тиках. Это не `AutomationPointFormat` из
    ## формата проекта: Core-рендер не знает про файл проекта и принимает
    ## данные уже разобранными.
    tick*: int32
    value*: float32
    curve*: AutomationCurve

  OfflineAutomationLane* = object
    nodeId*: int32
    paramId*: uint32
    points*: seq[OfflineAutomationPoint]

  OfflineRenderOptions* = object
    sampleRate*: int32
    blockSize*: int32
    totalFrames*: int64
    bitsPerSample*: int32
      ## 16 или 24. 16 — умолчание: файл вдвое меньше, а разница на
      ## материале с суммой инструментов на слух не критична.
    tempo*: float64
      ## Нужен только для автоматизации: тики переводятся в кадры той же
      ## формулой, что у транспорта.
    automation*: seq[OfflineAutomationLane]
      ## Пустой список — рендер без автоматизации (частый случай).
    onProgress*: RenderProgressProc
      ## Колбэк прогресса или `nil` (по умолчанию) — не вызывать вовсе.

  OfflineRenderReport* = object
    ok*: bool
    error*: string
      ## Заполнено только при `ok == false`.
    frames*: int64
    seconds*: float64
    peak*: float32
    rms*: float32
    silent*: bool
      ## `peak == 0`: полезно как проверка «граф не выдал тишину».
    path*: string

proc defaultRenderOptions*(sampleRate: int32 = 48000; blockSize: int32 = 512;
                           seconds: float64 = 10.0): OfflineRenderOptions =
  ## Умолчания рендера: 48 кГц, блок 512, 16 бит. Отдельная процедура,
  ## чтобы CLI и примеры не расходились в значениях.
  let sr = if sampleRate > 0: sampleRate else: 48000'i32
  let bs = if blockSize > 0: blockSize else: 512'i32
  OfflineRenderOptions(
    sampleRate: sr,
    blockSize: bs,
    totalFrames: int64(max(0.0, seconds) * float64(sr)),
    bitsPerSample: 16,
    tempo: 120.0
  )

proc automationValueAt*(lane: OfflineAutomationLane; tick: float64): float32 =
  ## Значение дорожки на тике. Вне диапазона точек — крайние значения
  ## (параметр держится, а не «прыгает в ноль»), между точками — по кривой:
  ## ступенькой, линейно или сглаженно.
  ##
  ## `acBezier` считается сглаженно: кривые Безье из редактора задают форму
  ## между точками, но на рендере разница со сглаживанием — на уровне
  ## слышимости только у длинных переходов, а лишняя математика в этом
  ## цикле не нужна.
  if lane.points.len == 0:
    return 0.0f
  if tick <= float64(lane.points[0].tick):
    return lane.points[0].value
  let last = lane.points.len - 1
  if tick >= float64(lane.points[last].tick):
    return lane.points[last].value

  var i = 0
  while i < last:
    let a = lane.points[i]
    let b = lane.points[i + 1]
    if tick >= float64(a.tick) and tick < float64(b.tick):
      let span = float64(b.tick - a.tick)
      if span <= 0.0:
        return b.value
      let t = (tick - float64(a.tick)) / span
      case a.curve
      of acStep:
        return a.value
      of acLinear:
        return float32(float64(a.value) + (float64(b.value) - float64(a.value)) * t)
      of acSmooth, acBezier:
        let s = t * t * (3.0 - 2.0 * t)
        return float32(float64(a.value) + (float64(b.value) - float64(a.value)) * s)
    inc i
  lane.points[last].value

# ==============================================================================
# Рендер
#
# Запись файла — I/O: `wav_codec` бросает IOError/OSError, поэтому этот
# участок выходит из `raises: []`. Исключение не «протекает» наружу: оно
# ловится и возвращается в отчёте — вызывающему (CLI) нужен код возврата
# и текст ошибки, а не стек.
# ==============================================================================

{.pop.}

proc renderToWav*(path: string; p: ptr CompiledPipeline;
                  opts: OfflineRenderOptions): OfflineRenderReport =
  ## Считает пайплайн офлайн и пишет WAV.
  ##
  ## ВЛАДЕНИЕ — важное: пайплайн ПЕРЕХОДИТ этой функции. Движок забирает
  ## его себе (`postGraphUpdate`) и освобождает вместе с движком
  ## (`destroyAudioEngine`); если передать граф не удалось, освобождаем сами.
  ##
  ## Раньше здесь было написано «пайплайн остаётся собственностью
  ## вызывающего» — и это было неправдой: движок освобождал его, а сцена
  ## потом освобождала повторно (двойное освобождение; ловится только
  ## ASan/ASan+useMalloc, а в обычной сборке портит кучу и падает через
  ## несколько аллокаций). Поэтому вызывающий обязан «забыть» указатель:
  ## `scene.pipeline = nil` (или `detachPipeline(scene)`) до вызова.
  result.ok = false
  result.path = path

  if p.isNil:
    result.error = "пайплайн не собран"
    return
  if opts.sampleRate <= 0:
    result.error = "частота дискретизации должна быть положительной"
    return
  if opts.blockSize <= 0 or opts.blockSize > signal_types.MaxBlockSize:
    result.error = "размер блока вне диапазона 1.." & $signal_types.MaxBlockSize
    return
  if opts.totalFrames <= 0:
    result.error = "длина рендера должна быть положительной"
    return
  if opts.bitsPerSample notin [16, 24]:
    result.error = "глубина — 16 или 24 бита, получено: " & $opts.bitsPerSample
    return

  # Пайплайн теперь наш: движок освободит его сам. Если до передачи графа
  # что-то не сложилось — освобождаем здесь, чтобы память не текла.
  var handedOver = false
  defer:
    if not handedOver:
      destroyPipeline(p)

  let tempo = if opts.tempo > 1.0: opts.tempo else: 120.0
  let samplesPerTick =
    float64(opts.sampleRate) * 60.0 / (tempo * float64(PpqTicksPerQuarter))

  let engine = createAudioEngine(float32(opts.sampleRate), opts.blockSize)
  if engine.isNil:
    result.error = "не удалось создать аудиодвижок"
    return
  defer:
    destroyAudioEngine(engine)

  if not engine.postGraphUpdate(p):
    result.error = "движок не принял граф"
    return
  handedOver = true
  discard engine.postSetTempo(tempo)
  discard engine.postPlay()

  let channels = 2
  let blockFrames = int64(opts.blockSize)

  # Чанк кратен блоку: иначе `renderOffline` тратил бы на «хвост» целый
  # блок, а мы бы получили лишнюю работу на каждом чанке.
  var chunkFrames = int64(float64(opts.sampleRate) * DefaultChunkSeconds)
  chunkFrames = (chunkFrames div blockFrames) * blockFrames
  if chunkFrames < blockFrames:
    chunkFrames = blockFrames

  var chunk = newSeq[float32](int(chunkFrames) * channels)
  var scratch = newSeq[float32](int(blockFrames) * channels)

  var writer: WavWriter
  try:
    writer = openWavWriter(
      path,
      AudioFileInfo(
        sampleRate: opts.sampleRate,
        channels: int16(channels),
        bitsPerSample: int16(opts.bitsPerSample),
        isFloat: false
      )
    )
  except CatchableError as e:
    result.error = "не удалось создать файл: " & e.msg
    return

  var done: int64 = 0
  var peak = 0.0f
  var sumSquares = 0.0'f64

  # Шаг прогресса в кадрах — не меньше блока и не меньше секунды аудио.
  var progressStep = int64(float64(opts.sampleRate) * ProgressIntervalSeconds)
  if progressStep < blockFrames:
    progressStep = blockFrames
  var nextProgressFrame = 0'i64

  try:
    while done < opts.totalFrames:
      let remaining = opts.totalFrames - done
      let framesThis = int32(min(chunkFrames, remaining))

      # Автоматизация применяется к началу чанка: значение на границе —
      # именно то, с которым чанк и должен звучать.
      if opts.automation.len > 0:
        let tick = float64(done) / samplesPerTick
        for lane in opts.automation:
          if lane.points.len == 0:
            continue
          discard engine.postSetParam(
            lane.nodeId, lane.paramId, automationValueAt(lane, tick)
          )

      renderOffline(engine, int64(framesThis),
                    cast[ptr UncheckedArray[float32]](addr chunk[0]),
                    cast[ptr UncheckedArray[float32]](addr scratch[0]))

      var i = 0
      let samples = int(framesThis) * channels
      while i < samples:
        let v = chunk[i]
        let a = abs(v)
        if a > peak:
          peak = a
        sumSquares += float64(v) * float64(v)
        inc i

      writeFrames(writer,
                  cast[ptr UncheckedArray[float32]](addr chunk[0]),
                  framesThis)
      done += int64(framesThis)

      # Прогресс — после записи чанка, чтобы показывать действительно
      # посчитанное (файл-то уже содержит эти кадры).
      if opts.onProgress != nil:
        if done >= nextProgressFrame or done >= opts.totalFrames:
          opts.onProgress(done, opts.totalFrames)
          nextProgressFrame = done + progressStep
  except CatchableError as e:
    result.error = "ошибка записи файла: " & e.msg
    try:
      close(writer)
    except CatchableError:
      discard
    return

  try:
    close(writer)
  except CatchableError as e:
    result.error = "не удалось закрыть файл: " & e.msg
    return

  result.ok = true
  result.frames = done
  result.seconds = float64(done) / float64(opts.sampleRate)
  result.peak = peak
  result.silent = peak <= 0.0f
  if done > 0:
    result.rms = float32(sqrt(sumSquares / float64(done * channels)))

