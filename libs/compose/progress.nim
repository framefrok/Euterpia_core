# libs/compose/progress.nim
#
# Индикатор офлайн-рендера: проценты, прошедшее/осталось, скорость и
# «вращающаяся палочка» (issue #310).
#
# Зачем он нужен: рендер идёт быстрее реального времени, и часовая пьеса
# считается за пару минут. Без обратной связи «идёт быстро» и «зависло»
# выглядят одинаково — а это худший вид молчания для инструмента.
#
# Правила, которые здесь зафиксированы:
#   * прогресс идёт в stderr, а НЕ в stdout: stdout принадлежит результату
#     команды, иначе `--json` перестал бы быть парсируемым (MANIFEST §21);
#   * молчим, если stderr — не терминал: в CI и в пайпах лишних строк нет,
#     а вывод остаётся байт-в-байт детерминированным (критерий #88);
#   * рисуем не чаще 10 раз в секунду экранного времени: колбэк ядра приходит
#     раз в секунду АУДИО, то есть при быстром рендере чаще, чем нужно;
#   * формат строки один и тот же для CLI и для `nim r generate.nim` —
#     одна реализация вместо двух почти одинаковых.
#
# Слой: верхний (libs). Зависит только от std и контракта Core
# (`RenderProgressProc`), Core о модуле не знает.

import std/[strutils, terminal, times]

import offline_render

type
  ProgressPrinter* = ref object
    ## Состояние одного показания прогресса. `ref`, а не значение: колбэк
    ## ядра живёт дольше вызова-конструктора, и состояние (время последней
    ## перерисовки, кадр «палочки») должно быть общим для всех вызовов.
    totalSeconds*: float64
    sampleRate*: int32
    startedAt*: float64
      ## `epochTime()` на момент создания — от него считается «прошло».
    lastDraw*: float64
    frame*: int
    drawn*: bool

const
  SpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    ## Брайль-точки: одна колонка по ширине, заметно сменяются кадром.
    ## ASCII-версия (`|/-\`) на некоторых шрифтах сливается в рябь.

  MinDrawInterval = 0.1
    ## Секунд экранного времени между перерисовками.

  EraseToEndOfLine = "\e[K"
    ## ANSI «стереть до конца строки» — работает во всех нормальных
    ## терминалах; иначе пришлось бы дополнять пробелами до фиксированной
    ## ширины, и строка «прыгала» при смене разрядов.

proc durationText*(seconds: float64): string =
  ## Время как `м:сс` или `ч:мм:сс`. Формат фиксирован — сравним между
  ## запусками; плавающая ширина сломала бы выравнивание строки прогресса.
  let total = int(max(0.0, seconds))
  let h = total div 3600
  let m = (total mod 3600) div 60
  let s = total mod 60
  if h > 0:
    # Часы без дополнения: «1:00:00» читается лучше «01:00:00», а
    # минуты и секунды — фиксированной ширины (intToStr, не align: тот
    # дописывает пробелы СПРАВА, и время выходило бы как «0: 0»).
    result = $h & ":" & intToStr(m, 2) & ":" & intToStr(s, 2)
  else:
    result = $m & ":" & intToStr(s, 2)

proc newProgress*(totalSeconds: float64; sampleRate: int32): ProgressPrinter =
  ## Принтер на весь рендер: дальше — только `update` и `clear`.
  ProgressPrinter(
    totalSeconds: totalSeconds,
    sampleRate: sampleRate,
    startedAt: epochTime(),
    lastDraw: -1.0,
    frame: 0,
    drawn: false
  )

proc progressLine*(p: ProgressPrinter; done, total: int64): string =
  ## Текст показания. Отдельная функция, а не печать: её можно проверить
  ## тестом и показать в `--json`, не рисуя ничего.
  let sr = (if p.sampleRate > 0: p.sampleRate else: 48000'i32).float64
  let totalF = (if total > 0: total else: 1).float64
  let doneF = min(max(done.float64, 0.0), totalF)
  let percent = int(doneF * 100.0 / totalF)
  let audioDone = doneF / sr
  let wall = max(0.0, epochTime() - p.startedAt)
  let speed = if wall > 0.05: audioDone / wall else: 0.0
  let left =
    if speed > 0.001: (p.totalSeconds - audioDone) / speed
    else: 0.0

  result = SpinnerFrames[p.frame mod SpinnerFrames.len] &
    " рендер " & $percent & "% · " &
    durationText(audioDone) & " / " & durationText(p.totalSeconds) &
    " · прошло " & durationText(wall) &
    " · осталось " & durationText(max(0.0, left)) &
    (if speed > 0.0: " · ×" & formatFloat(speed, ffDecimal, 1)
     else: " · замер")

proc writeLine(s: string) =
  ## Печать в stderr без риска уронить рендер: сломанный поток — не ошибка
  ## расчёта (то же правило, что в `cli/context.nim`).
  try:
    stderr.write(s)
    stderr.flushFile()
  except CatchableError:
    discard

proc update*(p: ProgressPrinter; done, total: int64) =
  ## Показывание прогресса. Троттлинг — по экранному времени, а не по
  ## кадрам: иначе быстрый рендер мигает быстрее, чем человек успевает
  ## прочитать.
  if p.isNil:
    return
  let finished = total > 0 and done >= total
  let now = epochTime()
  if not finished and now - p.lastDraw < MinDrawInterval:
    return
  p.lastDraw = now
  inc p.frame

  if finished:
    # Перевод строки завершает показание. Начинать его надо с `\r`: до
    # этого курсор стоит в конце предыдущей строки прогресса, и без `\r`
    # «100 %» дописался бы к «99 %» на том же самом экране.
    writeLine("\r" & progressLine(p, done, total) & "\n")
    p.drawn = false
  else:
    writeLine("\r" & progressLine(p, done, total) & EraseToEndOfLine)
    p.drawn = true

proc clear*(p: ProgressPrinter) =
  ## Стереть недописанную строку (рендер упал раньше 100 %).
  if p.isNil or not p.drawn:
    return
  writeLine("\r" & EraseToEndOfLine)
  p.drawn = false

proc callback*(p: ProgressPrinter): RenderProgressProc =
  ## Колбэк для `OfflineRenderOptions.onProgress`.
  result = proc(done, total: int64) {.gcsafe, raises: [].} =
    p.update(done, total)

proc autoProgress*(totalSeconds: float64; sampleRate: int32;
                   force = false): RenderProgressProc =
  ## Прогресс «как есть»: включается сам, если stderr — терминал.
  ## `force` — для сценариев, которым он нужен и в пайпе (`--progress`).
  if not force and not terminal.isatty(stderr):
    return nil
  callback(newProgress(totalSeconds, sampleRate))