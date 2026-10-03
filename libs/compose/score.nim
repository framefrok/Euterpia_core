# libs/compose/score.nim
#
# Музыкальная модель для «композиции как код» (issue #285, библиотека libs).
#
# Зачем: писать музыку в JSON немыслимо, а держать форму и мотивы в скрипте
# на чужом языке — значит иметь два источника правды о проекте. Здесь композиция
# описывается типами Nim, а на выход идут либо текстовая нотация ядра
# (`core/notation`, удобна человеку и CLI), либо ноты проекта (`NoteFormat`
# из `core/project`, которые читает ядро напрямую).
#
# Модель намеренно простая и «музыкальная», а не сигнальная:
#   * `NoteEvent` — звук или пауза на N долей (доля = четверть);
#   * `Bar` — такт: события и общая velocity;
#   * `Motif` — последовательность тактов; над ней есть приёмы развития
#     (транспозиция, увеличение) — то, чем делается форма;
#   * `Part` — партия: имя и такты.
#
# Времена считаются в тиках по разрешению ядра (`PpqTicksPerQuarter`), чтобы
# `toNotes` отдавал готовые для проекта ноты без пересчёта у вызывающего.

import std/[math, sequtils, strutils]

import transport
import project

{.push raises: [].}

type
  NoteEvent* = object
    ## Один шаг партитуры. Пустой `pitches` — пауза (двигает время).
    pitches*: seq[uint8]
    beats*: float

  Bar* = object
    ## Такт: события и velocity по умолчанию (1..127).
    events*: seq[NoteEvent]
    vel*: int

  Motif* = seq[Bar]
    ## Последовательность тактов — то, что повторяют и развивают.

  Part* = object
    ## Партия: имя и такты.
    name*: string
    bars*: seq[Bar]

# ============================================================================
# События
# ============================================================================

proc n*(pitch: int; beats: float): NoteEvent =
  ## Нота `pitch` (MIDI) длительностью `beats` долей.
  NoteEvent(pitches: @[uint8(pitch)], beats: beats)

proc ch*(pitches: openArray[int]; beats: float): NoteEvent =
  ## Аккорд: несколько нот звучат одновременно.
  NoteEvent(pitches: pitches.mapIt(uint8(it)), beats: beats)

proc r*(beats: float): NoteEvent =
  ## Пауза на `beats` долей.
  NoteEvent(pitches: @[], beats: beats)

proc bar*(vel: int; events: varargs[NoteEvent]): Bar =
  ## Такт из событий с заданной velocity.
  Bar(events: @events, vel: max(1, min(127, vel)))

proc bar*(vel: int; events: seq[NoteEvent]): Bar =
  ## Такт из уже собранной последовательности событий (арпеджио и т.п.).
  Bar(events: events, vel: max(1, min(127, vel)))

proc bar*(events: varargs[NoteEvent]): Bar =
  ## Такт с velocity по умолчанию (100) — для описания мотивов.
  bar(100, events)

proc motif*(bars: openArray[Bar]): Motif =
  ## Мотив как последовательность тактов.
  @bars

# ============================================================================
# Приёмы развития
# ============================================================================

proc transpose*(m: Motif; semis: int): Motif =
  ## Транспозиция всех нот мотива на `semis` полутонов (паузы не трогает).
  for b in m:
    var nb = b
    for k in 0 ..< nb.events.len:
      nb.events[k].pitches = nb.events[k].pitches.mapIt(uint8(int(it) + semis))
    result.add nb

proc transpose*(b: Bar; semis: int): Bar =
  ## Транспозиция одного такта (для развития внутри партии).
  result = b
  for k in 0 ..< result.events.len:
    result.events[k].pitches = result.events[k].pitches.mapIt(uint8(int(it) + semis))

proc augment*(m: Motif; factor: float): Motif =
  ## Увеличение: все длительности умножаются на `factor`.
  for b in m:
    var nb = b
    for k in 0 ..< nb.events.len:
      nb.events[k].beats = nb.events[k].beats * factor
    result.add nb

proc cycle*(m: Motif; barCount: int): Motif =
  ## Повтор мотива до нужного числа тактов (оборот прогрессии).
  if m.len == 0:
    return
  for i in 0 ..< barCount:
    result.add m[i mod m.len]

# ============================================================================
# Такты и партии
# ============================================================================

proc beats*(b: Bar): float =
  ## Длительность такта в долях — для проверки «такт набран ровно».
  for e in b.events:
    result += e.beats

proc add*(p: var Part; m: Motif) =
  ## Дописать мотив в партию.
  for b in m:
    p.bars.add b

proc add*(p: var Part; b: Bar) =
  p.bars.add b

proc part*(name: string): Part =
  Part(name: name)

proc sameVel*(b: Bar; v: int): Bar =
  ## Копия такта с новой velocity (для динамики по разделам).
  result = b
  result.vel = max(1, min(127, v))

proc withDynamics*(m: Motif; v: int): Motif =
  ## Мотив с единой velocity — динамика раздела применяется целиком.
  for b in m:
    result.add b.sameVel(v)

# ============================================================================
# Вывод: нотация ядра и ноты проекта
# ============================================================================

const
  NoteNames: array[12, string] =
    ["c", "c#", "d", "d#", "e", "f", "f#", "g", "g#", "a", "a#", "b"]

proc pname*(pitch: int): string =
  ## Имя ноты в формате ядра: 60 → `c4`, 70 → `a#4`.
  NoteNames[pitch mod 12] & $(pitch div 12 - 1)

proc durSuffix(beats: float): string =
  ## Длительность в синтаксисе нотации ядра (`/4` — четверть, точка — ×1.5).
  let b = round(beats * 1000.0) / 1000.0
  if b == 4.0: "/1"
  elif b == 3.0: "/2."
  elif b == 2.0: "/2"
  elif b == 1.5: "/4."
  elif b == 1.0: "/4"
  elif b == 0.75: "/8."
  elif b == 0.5: "/8"
  elif b == 0.375: "/16."
  elif b == 0.25: "/16"
  elif b == 0.125: "/32"
  else: "/4"

proc eventToken(e: NoteEvent): string =
  if e.pitches.len == 0:
    "r" & durSuffix(e.beats)
  elif e.pitches.len == 1:
    pname(int(e.pitches[0])) & durSuffix(e.beats)
  else:
    "(" & e.pitches.mapIt(pname(int(it))).join(" ") & ")" & durSuffix(e.beats)

proc toNotation*(p: Part; defaultVel: int = 100): string =
  ## Партия как текст нотации ядра (`core/notation`). Velocity вешается на
  ## первый неот-элемент такта — так значение действует на весь такт, а
  ## строка остаётся корректной (пауза с `:V` не нужна).
  discard defaultVel
  for b in p.bars:
    var toks: seq[string]
    for e in b.events:
      toks.add eventToken(e)
    if toks.len == 0:
      continue
    var target = 0
    for k, e in b.events:
      if e.pitches.len > 0:
        target = k
        break
    toks[target] = toks[target] & ":" & $b.vel
    result.add toks.join(" ") & " |\n"

proc lengthTicks*(p: Part): int32 =
  ## Длина партии в тиках ядра.
  for b in p.bars:
    for e in b.events:
      result += int32(round(e.beats * float(PpqTicksPerQuarter)))

proc toNotes*(p: Part; channel: int = 0): seq[NoteFormat] =
  ## Ноты в форме проекта (`core/project`): позиция в тиках, длительность в
  ## тиках, pitch/velocity/channel. Паузы двигают курсор, нот не создавая.
  var cursor = 0'i32
  for b in p.bars:
    for e in b.events:
      let dur = max(1'i32, int32(round(e.beats * float(PpqTicksPerQuarter))))
      for pitch in e.pitches:
        result.add NoteFormat(
          startTick: cursor, duration: dur, pitch: pitch,
          velocity: uint8(max(1, min(127, b.vel))), channel: uint8(channel))
      cursor += dur

{.pop.}

