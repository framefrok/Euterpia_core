# libs/compose/variation.nim
#
# Движок развития мотива (issue #COMPOSE-007, P1).
#
# Зачем: `score.nim` даёт основу (`transpose`/`augment`/`cycle`/`sameVel`), но
# для настоящей формы этого мало — нужны инверсия, ретроград, фрагментация,
# сжатие/расширение, смена регистра, ритмические и скоростные преобразования.
# Здесь они собраны как чистые функции над `Motif` (и парой поверх `Bar`), а
# также `applyVariant` — «пресет варианта» для `arrangement` (#COMPOSE-033):
# один номер варианта → связка приёмов (transpose+rhythm+fragment+…).
#
# Всё compile-time: никакого рантайма, только новые `Motif` из входных
# тактов — те же ноты, что уходят в Core через `toNotes`.

import std/[math, sequtils]

import compose/score

{.push raises: [].}

# ============================================================================
# Высотные преобразования
# ============================================================================

proc invert*(m: Motif): Motif =
  ## Инверсия мелодии вокруг первой ноты: интервалы разворачиваются в
  ## зеркало (восходящий малый секундовый ход → нисходящий). Паузы на месте,
  ## звуковое «направление» отражается. Опора — первая нота мотива.
  var pivot = 0
  var found = false
  for b in m:
    if found: break
    for e in b.events:
      if e.pitches.len > 0:
        pivot = int(e.pitches[0])
        found = true
        break
  for b in m:
    var nb = b
    for k in 0 ..< nb.events.len:
      if nb.events[k].pitches.len > 0:
        nb.events[k].pitches = nb.events[k].pitches.mapIt(
          uint8(pivot - (int(it) - pivot)))
    result.add nb

proc octave*(m: Motif; shift: int): Motif =
  ## Сдвиг всех нот на `shift` октав (±12 полутонов на октаву).
  transpose(m, shift * 12)

proc register*(m: Motif; center: int): Motif =
  ## Привести мотив к целевому регистру: транспонировать так, чтобы первая
  ## нота оказалась у `center` (ближайшая октава). Резкая, но управляемая
  ## смена «тесситуры» фразы.
  var first = 0
  var found = false
  block outer:
    for b in m:
      for e in b.events:
        if e.pitches.len > 0:
          first = int(e.pitches[0])
          found = true
          break outer
  if not found:
    return m
  let shift = center - first
  transpose(m, shift)

# ============================================================================
# Ритмические преобразования
# ============================================================================

proc retrograde*(m: Motif): Motif =
  ## Ретроград: порядок тактов обращается (фраза играется задом наперёд).
  for i in countdown(m.len - 1, 0):
    result.add m[i]

proc diminish*(m: Motif; factor: float): Motif =
  ## Диминуция: длительности делятся на `factor` (ритм ускоряется).
  if factor == 0.0:
    return m
  m.augment(1.0 / factor)

proc rhythm*(m: Motif; factor: float): Motif =
  ## Ритмическое преобразование: множитель длительностей. `factor<1` — быстрее
  ## (дробление), `>1` — медленнее (растяжка). Общий знаменатель для
  ## arrangement, где `rhythm(0.5)` = «темп вдвое плотнее».
  m.augment(factor)

# ============================================================================
# Формальные преобразования
# ============================================================================

proc fragment*(m: Motif; start: int; count: int): Motif =
  ## Фрагмент мотива: такты с `start` длиной `count` (с обрезкой по краям).
  ## Основа «разбитой темы» в bridge/outro.
  if m.len == 0:
    return
  let first = max(0, min(m.len - 1, start))
  let last = min(m.len - 1, first + max(0, count) - 1)
  for i in first .. last:
    result.add m[i]

proc fragment*(m: Motif; count: int): Motif =
  ## Фрагмент с начала: первые `count` тактов.
  m.fragment(0, count)

proc repeatBar*(m: Motif; barIdx: int; times: int): Motif =
  ## Повторить такт `barIdx` `times` раз подряд на его месте (орнамент,
  ## «застрявший» такт). Реализация на уровне формы, а не событий.
  if barIdx < 0 or barIdx >= m.len:
    return m
  for i, b in m:
    result.add b
    if i == barIdx:
      for _ in 0 ..< max(0, times):
        result.add b

proc expand*(m: Motif; afterBar: int): Motif =
  ## Расширение: после такта `afterBar` вставляется его копия — фраза
  ## «задерживает дыхание» перед кульминацией.
  if afterBar < 0 or afterBar >= m.len:
    return m
  for i, b in m:
    result.add b
    if i == afterBar:
      result.add b

proc contract*(m: Motif; barIdx: int): Motif =
  ## Сжатие: удалить такт `barIdx` — фраза «проглатывает» такт.
  for i, b in m:
    if i != barIdx:
      result.add b

# ============================================================================
# Скоростные преобразования (velocity = динамика)
# ============================================================================

proc velocityScale*(m: Motif; factor: float): Motif =
  ## Масштаб velocity всех тактов (0..2: тише/громче).
  for b in m:
    var nb = b
    nb.vel = max(1, min(127, int(round(float(b.vel) * factor))))
    result.add nb

proc accent*(m: Motif; every: int; boost: int): Motif =
  ## Акцент на каждом `every`-м такте (+boost к velocity), остальное
  ## возвращается к базовому уровню — пульсация акцентов как приём.
  for i, b in m:
    var nb = b
    if every > 0 and i mod every == 0:
      nb.vel = max(1, min(127, b.vel + boost))
    result.add nb

# ============================================================================
# Удаление/вставка нот
# ============================================================================

proc deleteNotes*(m: Motif; barIdx: int; keepFirst: bool = true): Motif =
  ## В такте `barIdx` оставить только первую ноту (или убрать все). Приём
  ## «выветривания» — мелодия растворяется в аккомпанементе.
  for i, b in m:
    var nb = b
    if i == barIdx:
      var kept: seq[NoteEvent]
      var firstFound = false
      for e in b.events:
        if e.pitches.len > 0 and not firstFound and keepFirst:
          kept.add e
          firstFound = true
        else:
          kept.add r(e.beats)
      nb.events = kept
    result.add nb

proc insertNote*(m: Motif; barIdx: int; note: NoteEvent): Motif =
  ## Вставить ноту в начало такта `barIdx`, сдвинув события. Если такт
  ## переполнен по 4/4, последнее событие обрезается по границе такта.
  for i, b in m:
    var nb = b
    if i == barIdx:
      var room = 4.0 - note.beats
      var evs: seq[NoteEvent] = @[note]
      for e in b.events:
        if room <= 1e-9:
          break
        let take = min(room, e.beats)
        var chunk = e
        chunk.beats = take
        evs.add chunk
        room -= take
      nb.events = evs
    result.add nb

# ============================================================================
# Пресеты вариантов (COMPOSE-033)
# ============================================================================
#
# Один номер варианта — связка приёмов. `arrangement` вызывает это для
# section-level вариаций: verse = базовый, chorus = вариант 1, final = 2 и
# т.д. Каждый вариант независим (своя высота, ритм, регистр).

proc applyVariantMotif*(m: Motif; variant: int): Motif =
  ## Применить номер варианта (0 = база). Меняет высоту/ритм/регистр, чтобы
  ## одна и та же тема звучала иначе в разных секциях.
  case variant
  of 0: m
  of 1: m.transpose(5)             # кварта вверх — «открытый» хор
  of 2: m.rhythm(0.5).transpose(7)  # плотнее и квинтой выше — «энергия»
  of 3: m.fragment(0, 1)           # обрывок темы — «память» в бридже
  of 4: m.invert()                 # зеркало — «вопрос/ответ»
  of 5: m.retrograde()             # задом наперёд — «эхо»
  else: m

{.pop.}
