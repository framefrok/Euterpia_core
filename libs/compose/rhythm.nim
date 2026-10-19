# libs/compose/rhythm.nim
#
# Библиотека ритмов для «композиции как код» (issue #COMPOSE-016).
#
# Зачем: ритм пользователь сейчас собирает из длительностей вручную, а
# генератору удобнее мыслить «фигурами»: tresillo, offbeat, шестнадцатая
# сетка. `Rhythm` — чистая ритмическая сетка (удар/пауза по шагам), без
# высот: один и тот же ритм годится и для хэтов, и для баса. Готовые
# фигуры + DSL-строка (`rhythm: "x . x . | . x . x"`) — музыкальный
# ввод вместо арифметики.
#
# Слой: чистая семантика (ни один модуль Core не знает про «tresillo»).
# Из ритма строится `Pattern` (`toPattern`), дальше — те же мотивы/клипы.
# Жанровые drum-связки (trap, boom-bap, house) живут в
# `compose/generators/drums` — здесь только время, без инструментов.

import compose/score
  # NoteEvent + n/r — ритм превращается в события той же модели.
import compose/pattern
  # Pattern/rawPattern — готовая ритмическая фигура с именем.

{.push raises: [].}

type
  RhythmStep* = object
    ## Один шаг сетки: удар или пауза, длина — в долях (обычно одинаковая
    ## у всех шагов, но тип не запрещает разную — для dotted-фигур).
    hit*: bool
    beats*: float32

  Rhythm* = object
    ## Ритмическая сетка: последовательность шагов + имя. Длина = сумма
    ## шагов (в долях); такт 4/4 = 4.0.
    name*: string
    steps*: seq[RhythmStep]

# ============================================================================
# DSL: rhythm("x . x . | . x . x")
# ============================================================================

proc rhythm*(pattern: string; stepBeats: float32 = 0.25;
             name: string = ""): Rhythm =
  ## Сетка из символов: `x`/`X`/`=` — удар, `.`/`-`/`_` — пауза; пробелы,
  ## табуляция и `|` — визуальные разделители (времени не занимают). Шаг =
  ## `stepBeats` долей (по умолчанию 0.25 = шестнадцатая). Неизвестные
  ## символы игнорируются — опечатка не роняет композицию.
  for c in pattern:
    case c
    of 'x', 'X', '=':
      result.steps.add RhythmStep(hit: true, beats: stepBeats)
    of '.', '-', '_':
      result.steps.add RhythmStep(hit: false, beats: stepBeats)
    of ' ', '|', '\t', '\n', '\r':
      discard
    else:
      discard
  result.name = name

proc rhythmFromHits*(hits: openArray[bool]; stepBeats: float32;
                     name: string = ""): Rhythm =
  ## Сетка из списка «удар/нет» — удобно строить из `randomRhythm`.
  result.name = name
  for h in hits:
    result.steps.add RhythmStep(hit: h, beats: stepBeats)

# ============================================================================
# Запросы
# ============================================================================

proc length*(r: Rhythm): float32 =
  ## Длина ритма в долях (сумма шагов).
  for s in r.steps:
    result += s.beats

proc hits*(r: Rhythm): seq[bool] =
  ## Только удары: где звучит (для генераторов и анализа).
  for s in r.steps:
    result.add s.hit

proc hitCount*(r: Rhythm): int =
  ## Число ударов.
  for s in r.steps:
    if s.hit:
      inc result

proc transposeSteps*(r: Rhythm; by: int): Rhythm =
  ## Циклический сдвиг сетки на `by` шагов (фигура «плывёт» по такту).
  if r.steps.len == 0 or by == 0:
    return r
  let n = r.steps.len
  let k = ((by mod n) + n) mod n
  result = r
  result.steps = r.steps[k ..^ 1] & r.steps[0 ..< k]

# ============================================================================
# Превращение в паттерн
# ============================================================================

proc toPattern*(rh: Rhythm; pitch: int; name: string = ""): Pattern =
  ## Ритм как паттерн одной высоты: удар → нота `pitch` длиной в шаг,
  ## пауза → пауза. Для перкуссии длина шага = «сколько звучит» (у
  ## ударных инструментов это гейт огибающей, а не сустейн).
  var evs: seq[NoteEvent]
  for s in rh.steps:
    if s.hit:
      evs.add n(pitch, float(s.beats))
    else:
      evs.add r(float(s.beats))
  rawPattern(if name.len > 0: name else: rh.name, evs, float(rh.length))

# ============================================================================
# Готовые фигуры (один такт 4/4, если не сказано иначе)
# ============================================================================

proc quarter*(): Rhythm =
  ## Четверти: `x x x x` (шаг 1.0).
  rhythm("x x x x", 1.0, "quarter")

proc eighth*(): Rhythm =
  ## Восьмые: `x x x x x x x x` (шаг 0.5).
  rhythm("x x x x x x x x", 0.5, "eighth")

proc sixteenth*(): Rhythm =
  ## Шестнадцатые: полная сетка такта (шаг 0.25) — база хэтов.
  rhythm("x x x x x x x x x x x x x x x x", 0.25, "sixteenth")

proc triplet*(): Rhythm =
  ## Триольные восьмые: 12 шагов по 1/3 доли.
  rhythm("x . x . x . x . x . x .", 1.0 / 3.0, "triplet")

proc dotted*(): Rhythm =
  ## Пятнистая фигура (длинная–короткая) по каждой доле: шестнадцатые
  ## `x . . x` × 4.
  rhythm("x . . x x . . x x . . x x . . x", 0.25, "dotted")

proc offbeat*(): Rhythm =
  ## Слабые доли: `. x . x . x . x` (восьмые со сдвигом) — «подъём».
  rhythm(". x . x . x . x", 0.5, "offbeat")

proc tresillo*(): Rhythm =
  ## Tresillo (3+3+2 шестнадцатых, дважды на такт) — каркас латинского
  ## и трэп-чувства.
  rhythm("x . . x . . x . x . . x . . x .", 0.25, "tresillo")

proc clave*(): Rhythm =
  ## Клаве 3-2 (сон/рокето), два такта на шестнадцатой сетке: сторона 3 —
  ## удары 0/6/12 первого такта, сторона 2 — доли 2 и 3 второго.
  var hits: seq[bool]
  for i in 0 ..< 16:
    hits.add i in [0, 6, 12]
  for i in 0 ..< 16:
    hits.add i == 4 or i == 8
  rhythmFromHits(hits, 0.25, "clave")

proc trap16*(): Rhythm =
  ## Полная шестнадцатая сетка — хэт-основа трэпа (акценты и вариации
  ## добавляются humanize/velocity, а не сеткой).
  sixteenth()

{.pop.}
