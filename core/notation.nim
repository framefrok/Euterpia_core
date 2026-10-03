# core/notation.nim
#
# Текстовая нотация — то, чем человек записывает музыку, а ядро превращает
# её в тики.
#
# Зачем отдельный формат: проект (`project.eut`) хранит ноты как данные
# клипа, а писать музыку в JSON немыслимо. Поэтому есть строчный формат,
# который читается как ноты:
#
#   c4/4 d4/8 e4/8 (g4 b4 d5)/2 r/4 | e5/4 ...
#
# Правила (только ASCII — файл переживает любой редактор):
#
#   * нота:        `<буква><альтерация?><октава?>` — `c`, `c#4`, `bb3`;
#                  буквы латинские a..g, `#` — диез, `b` — бемоль;
#   * пауза:       `r` — двигает курсор, ноты не создаёт;
#   * аккорд:      `(c4 e4 g4)` — звучат одновременно, длительность общая;
#   * длительность: `/N`, N ∈ {1,2,4,8,16,32} (1 — целая, 4 — четверть);
#   * точка:       `.` (одна — ×1.5, две — ×1.75);
#   * velocity:    `:V`, V = 1..127 в единицах MIDI;
#   * черта:       `|` — граница такта; такт обязан быть набран ровно,
#                  иначе в отчёт попадёт предупреждение;
#   * комментарий: `#` до конца строки;
#   * пробелы и переводы строк между элементами свободны.
#
# Длительность и velocity запоминаются и действуют на последующие ноты без
# своих модификаторов — так пишутся длинные пассажи одной длины:
#
#   c4/16 d e f g a b c5
#
# Позиции считаются в тиках от `startTick` при разрешении 960 PPQ
# (`PpqTicksPerQuarter`), то есть в той же шкале, в которой думает
# транспорт и нотный секвенсор.
#
# Парсер не решает, что делать с нотами: он отдаёт их данными
# (`NotationNote`), а запись в паттерн ноды — дело вызывающего.
#
# Ошибка разбора НЕ бросается исключением: `ok` и позиция (`line`,
# `column`) возвращаются значением. Нотацию правит человек, поэтому «где
# ошибка» — часть ответа, а не стек вызовов.

import std/strutils
import transport

{.push raises: [].}

type
  NotationNote* = object
    startTick*: int32
    durationTicks*: int32
    pitch*: int32        # MIDI 0..127
    velocity*: int32     # MIDI 1..127

  NotationIssue* = object
    ## Место и причина: в отчёте CLI это печатается как `строка:колонка`.
    line*: int
    column*: int
    message*: string

  NotationResult* = object
    ok*: bool
      ## false — разбор остановлен на `error`; ноты до ошибки сохранены.
    error*: NotationIssue
      ## Заполнено только при `ok == false`.
    warnings*: seq[NotationIssue]
      ## Замечания, не мешающие играть (например, такт набран не ровно).
    notes*: seq[NotationNote]
    endTick*: int32
      ## Позиция курсора после последнего элемента — длина разобранного
      ## фрагмента в тиках (относительно `startTick`).
    barTicks*: int32
      ## Длительность такта в тиках, посчитанная по размеру.

# ==============================================================================
# Названия и имена нот
# ==============================================================================

const
  NoteNames: array[12, string] =
    ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

proc notationBarTicks*(timeSigNum, timeSigDen: int32): int32 =
  ## Длительность такта в тиках: 4/4 — 3840, 3/4 — 2880, 6/8 — 2880.
  ## Некорректный размер трактуется как 4/4: делить на ноль в разборе
  ## нотации нельзя, а «размер по умолчанию» — понятный компромисс.
  let num = if timeSigNum > 0: timeSigNum else: 4'i32
  let den = if timeSigDen > 0: timeSigDen else: 4'i32
  result = PpqTicksPerQuarter * 4'i32 * num div den
  if result <= 0:
    result = PpqTicksPerQuarter * 4'i32

proc notationNoteName*(pitch: int): string =
  ## Имя ноты в научной нотации («C4» = 60) — для отчётов CLI.
  if pitch < 0 or pitch > 127:
    return "?"
  NoteNames[pitch mod 12] & $(pitch div 12 - 1)

# ==============================================================================
# Разбор
#
# Внутри — маленький сканер по символам: строка читается один раз, позиция
# курсора и место в файле известны в каждой точке. Полноценный комбинатор
# парсеров здесь был бы дороже, чем задача: элементы разделены пробелами,
# а модификаторов три.
# ==============================================================================

type
  NotationParser = object
    text: string
    pos: int
    line: int
    column: int
    res: NotationResult

    cursor: int32     # текущий тик (абсолютный)
    barStart: int32   # тик начала текущего такта
    octave: int       # октава по умолчанию для нот без цифры
    defDur: int32     # длительность по умолчанию
    defVel: int32     # velocity по умолчанию

proc fail(p: var NotationParser; message: string) {.inline.} =
  ## Первая ошибка остаётся главной: дальнейшие — следствие.
  if p.res.ok:
    p.res.ok = false
    p.res.error = NotationIssue(line: p.line, column: p.column,
                                message: message)

proc warn(p: var NotationParser; message: string) {.inline.} =
  p.res.warnings.add NotationIssue(line: p.line, column: p.column,
                                   message: message)

proc atEnd(p: NotationParser): bool {.inline.} =
  p.pos >= p.text.len

proc advance(p: var NotationParser) {.inline.} =
  if p.text[p.pos] == '\n':
    inc p.line
    p.column = 1
  else:
    inc p.column
  inc p.pos

proc readToken(p: var NotationParser): string =
  ## Пропускает пробелы и комментарии и читает один элемент.
  ##
  ## Элемент не переносится на другую строку, а скобки аккорда защищают
  ## пробелы внутри: `(c4 e4 g4)/2` — один элемент.
  while not p.atEnd:
    let c = p.text[p.pos]
    if c == ' ' or c == '\t' or c == '\r' or c == '\n':
      p.advance()
    elif c == '#':
      # Диез внутри ноты пишется без пробела (`c#4`), поэтому `#` в начале
      # элемента — всегда комментарий.
      while not p.atEnd and p.text[p.pos] != '\n':
        p.advance()
    else:
      break

  if p.atEnd:
    return ""

  let start = p.pos
  var depth = 0
  while not p.atEnd:
    let c = p.text[p.pos]
    if c == '\n':
      break
    if depth == 0 and (c == ' ' or c == '\t' or c == '\r'):
      break
    if c == '(':
      inc depth
    elif c == ')' and depth > 0:
      dec depth
    p.advance()

  p.text[start ..< p.pos]

proc parsePitch(tok: string; i: var int; octave: var int): int =
  ## Разбирает `<буква><#|b><октава?>` и двигает `i`.
  ##
  ## Возврат: MIDI-номер 0..127; -1 — элемент начинается не с ноты;
  ## -2 — нота распознана, но вышла за диапазон MIDI.
  ## Октава (и запомненная) меняется только при успехе.
  if i >= tok.len:
    return -1

  let base = case tok[i]
    of 'c': 0
    of 'd': 2
    of 'e': 4
    of 'f': 5
    of 'g': 7
    of 'a': 9
    of 'b': 11
    else: return -1
  inc i

  var acc = 0
  if i < tok.len and tok[i] == '#':
    acc = 1
    inc i
  elif i < tok.len and tok[i] == 'b':
    acc = -1
    inc i

  var oct = octave
  if i + 1 < tok.len and tok[i] == '-' and tok[i + 1] in {'0' .. '9'}:
    inc i
    oct = -(ord(tok[i]) - ord('0'))
    inc i
  elif i < tok.len and tok[i] in {'0' .. '9'}:
    oct = ord(tok[i]) - ord('0')
    inc i

  let pitch = base + acc + 12 * (oct + 1)
  if pitch < 0 or pitch > 127:
    return -2

  octave = oct
  pitch


proc parseTail(p: var NotationParser; tok: string; start: int;
               nominal, total, vel: var int32): bool =
  ## Разбирает модификаторы элемента: `/dur`, точки, `:velocity`.
  ##
  ## `nominal` — длительность без точек (она запоминается как значение по
  ## умолчанию), `total` — фактическая длина с точками, `vel` — velocity.
  var i = start
  var base = nominal
  var v = vel
  var dots = 0

  while i < tok.len:
    case tok[i]
    of '/':
      inc i
      var n = 0
      var digits = 0
      while i < tok.len and tok[i] in {'0' .. '9'}:
        n = n * 10 + (ord(tok[i]) - ord('0'))
        inc i
        inc digits
      if digits == 0:
        p.fail("после `/` нужна длительность: " & tok)
        return false
      if n notin [1, 2, 4, 8, 16, 32]:
        p.fail("длительность вне ряда 1/2/4/8/16/32: " & tok)
        return false
      base = PpqTicksPerQuarter * 4'i32 div int32(n)

    of '.':
      inc dots
      inc i
      if dots > 2:
        p.fail("у ноты не больше двух точек: " & tok)
        return false

    of ':':
      inc i
      var n = 0
      var digits = 0
      while i < tok.len and tok[i] in {'0' .. '9'}:
        n = n * 10 + (ord(tok[i]) - ord('0'))
        inc i
        inc digits
      if digits == 0 or n < 1 or n > 127:
        p.fail("velocity — целое 1..127: " & tok)
        return false
      v = int32(n)

    else:
      p.fail("непонятный символ '" & $tok[i] & "' в элементе " & tok)
      return false

  total = base
  if dots >= 1:
    total += base div 2
  if dots >= 2:
    total += base div 4

  nominal = base
  vel = v
  true

proc parseChord(p: var NotationParser; tok: string): bool =
  ## `(c4 e4 g4)/2` — аккорд: ноты начинаются одновременно и звучат
  ## одинаково долго. Своих длительностей у нот внутри скобок нет:
  ## разная длина — это разные голоса, а не аккорд.
  let close = tok.find(')')
  if close < 0:
    p.fail("аккорд не закрыт: " & tok)
    return false

  let inside = tok[1 ..< close]
  var pitches: seq[int32]
  var oct = p.octave
  var j = 0
  while j < inside.len:
    while j < inside.len and (inside[j] == ' ' or inside[j] == '\t'):
      inc j
    if j >= inside.len:
      break
    let partStart = j
    while j < inside.len and inside[j] != ' ' and inside[j] != '\t':
      inc j
    let part = inside[partStart ..< j]

    var pi = 0
    let pitch = parsePitch(part, pi, oct)
    if pitch == -2:
      p.fail("нота вне диапазона MIDI: " & part)
      return false
    if pitch < 0 or pi < part.len:
      p.fail("в аккорде допустимы только ноты: " & part)
      return false
    pitches.add int32(pitch)

  if pitches.len == 0:
    p.fail("пустой аккорд: " & tok)
    return false

  var nominal = p.defDur
  var total = p.defDur
  var vel = p.defVel
  if not parseTail(p, tok, close + 1, nominal, total, vel):
    return false

  for pitch in pitches:
    p.res.notes.add NotationNote(startTick: p.cursor, durationTicks: total,
                                 pitch: pitch, velocity: vel)

  p.octave = oct
  p.defDur = nominal
  p.defVel = vel
  p.cursor += total
  true

proc parseToken(p: var NotationParser; tok: string) =
  if tok == "|":
    # Границу такта проверяем, но не навязываем: строка, набранная не
    # ровно, — это, скорее всего, опечатка в длительности, и молчать о ней
    # нельзя. Ошибкой это не считается: играть можно и так.
    let elapsed = p.cursor - p.barStart
    if elapsed != p.res.barTicks:
      p.warn("такт набран не ровно: " & $elapsed & " тиков вместо " &
             $p.res.barTicks)
    p.barStart = p.cursor
    return

  if tok[0] == '(':
    discard parseChord(p, tok)
    return

  if tok[0] == 'r':
    var nominal = p.defDur
    var total = p.defDur
    var vel = p.defVel
    if not parseTail(p, tok, 1, nominal, total, vel):
      return
    p.defDur = nominal
    p.defVel = vel
    p.cursor += total
    return

  var oct = p.octave
  var i = 0
  let pitch = parsePitch(tok, i, oct)
  if pitch == -2:
    p.fail("нота вне диапазона MIDI: " & tok)
    return
  if pitch < 0:
    p.fail("не элемент нотации: " & tok)
    return

  var nominal = p.defDur
  var total = p.defDur
  var vel = p.defVel
  if not parseTail(p, tok, i, nominal, total, vel):
    return

  p.res.notes.add NotationNote(startTick: p.cursor, durationTicks: total,
                               pitch: int32(pitch), velocity: vel)
  p.octave = oct
  p.defDur = nominal
  p.defVel = vel
  p.cursor += total


# ==============================================================================
# Точка входа
# ==============================================================================

proc parseNotation*(text: string; startTick: int32 = 0;
                    timeSigNum: int32 = 4; timeSigDen: int32 = 4;
                    velocity: int32 = 100): NotationResult =
  ## Разбирает нотацию в список нот.
  ##
  ## `startTick` — тик, на котором начинается первый элемент: вставка
  ## фрагмента в середину клипа не требует пересчёта позиций в тексте.
  ## `velocity` — velocity по умолчанию (ноты с `:V` её переопределяют).
  ##
  ## При ошибке разбор останавливается на первом проблемном элементе: всё,
  ## что успело разобраться, остаётся в `notes` (это позволяет показывать
  ## частичный результат), `ok` = false, а `error` указывает на место.
  var p: NotationParser
  p.text = text
  p.line = 1
  p.column = 1
  p.cursor = startTick
  p.barStart = startTick
  p.octave = 4
  p.defDur = PpqTicksPerQuarter
  p.defVel = if velocity < 1: 1'i32 elif velocity > 127: 127'i32 else: velocity
  p.res.ok = true
  p.res.barTicks = notationBarTicks(timeSigNum, timeSigDen)

  while p.res.ok:
    let tok = p.readToken()
    if tok.len == 0:
      break
    p.parseToken(tok)

  p.res.endTick = p.cursor
  result = p.res

proc notationLengthTicks*(notes: openArray[NotationNote]): int32 =
  ## Длина последовательности в тиках — максимум из концов нот. Нужна при
  ## укладке нескольких нотационных фрагментов друг за другом.
  for n in notes:
    let e = n.startTick + n.durationTicks
    if e > result:
      result = e

proc notationToPatternEvents*(notes: openArray[NotationNote];
                              channel: int32): seq[(int32, int32, int32, int32, int32)] =
  ## Раскладывает ноты нотации в пары «включение/выключение ноты».
  ##
  ## Возвращает кортежи `(tick, status, data1, data2, order)`: `status` —
  ## MIDI-статус без канала (`0x90` нота на, `0x80` нота выкл.). Пары идут
  ## в порядке позиций, а `order` разрешает ничьи: выключение раньше
  ## включения — иначе нота, начинающаяся ровно там, где заканчивается
  ## предыдущая, будет тут же погашена.
  ##
  ## Смысл в том, чтобы вызывающий (загрузчик сцены, CLI) не повторял одну
  ## и ту же арифметику: нотация живёт в тиках, а паттерн нод — в событиях.
  var events: seq[(int32, int32, int32, int32, int32)]
  events.setLen(notes.len * 2)
  var k = 0
  for n in notes:
    let pitch = if n.pitch < 0: 0'i32 elif n.pitch > 127: 127'i32 else: n.pitch
    let vel = if n.velocity < 1: 1'i32 elif n.velocity > 127: 127'i32 else: n.velocity
    let dur = if n.durationTicks < 1: 1'i32 else: n.durationTicks
    events[k] = (n.startTick, 0x90'i32 or (channel and 0x0F), pitch, vel, 1'i32)
    inc k
    events[k] = (n.startTick + dur, 0x80'i32 or (channel and 0x0F), pitch, 0'i32, 0'i32)
    inc k
  result = events

