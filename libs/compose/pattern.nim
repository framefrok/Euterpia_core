# libs/compose/pattern.nim
#
# Система паттернов для «композиции как код» (issue #COMPOSE-003).
#
# Зачем: `Motif` (последовательность тактов) хорош для формы, но не для
# ритмической фигуры. Настоящая партия — это цепочка событий с длиной, над
# которой делают приёмы: `repeat`, `reverse`, `rotate`, `stretch`… Сейчас их
# приходится кодировать вручную, копируя ноты. Здесь паттерн — производная
# музыкальная единица, а приёмы — чистые функции над ним.
#
# `Pattern` = последовательность `NoteEvent` (тот же тип, что в `score`),
# поэтому паттерн свободно превращается в `Motif`/`Part` и уходит в те же
# `toNotes`/`toNotation` ядра. Compile-time трансформация: рантайм-движка
# повторов здесь нет — `repeat` разворачивается в ноты сразу (#COMPOSE-025).

import std/[math, algorithm, sequtils]

import compose/score
  # NoteEvent/Bar/Motif/Part + n/ch/r — общая модель событий, чтобы паттерн и
  # мотив не разъезжались.

{.push raises: [].}

type
  Pattern* = object
    ## Ритмическая фигура: именованная цепочка событий и её длина в долях.
    ## `lengthBeats` хранится, чтобы `repeat`/`extend` были честными (без
    ## пересчёта) и чтобы сдвиг при вставке в партию считался одним полем.
    name*: string
    events*: seq[NoteEvent]
    lengthBeats*: float
    velJitter*: int
      ## Магнитуда «живой» вариации velocity (0 — нет). Применяется при
      ## сведении в `Motif`: в модели `score` одна velocity на такт, поэтому
      ## `humanize(velocity=…)` сдвигает velocity тактов детерминированно.
    velSeed*: int
      ## Сид для velocity-вариации (гарантирует один результат на seed).

# ============================================================================
# Конструкторы
# ============================================================================

proc pattern*(name: string; events: varargs[NoteEvent]): Pattern =
  ## Паттерн из событий; длина = суммарная длительность событий.
  var len = 0.0
  for e in events:
    len += e.beats
  Pattern(name: name, events: @events, lengthBeats: len)

proc pattern*(name: string; events: seq[NoteEvent]): Pattern =
  ## Паттерн из уже собранной последовательности событий.
  var len = 0.0
  for e in events:
    len += e.beats
  Pattern(name: name, events: events, lengthBeats: len)

proc rawPattern*(name: string; events: seq[NoteEvent]; lengthBeats: float): Pattern =
  ## Паттерн с явно заданной длиной (для сдвиговых операций вроде `rotate`,
  ## где длина не равна сумме событий).
  Pattern(name: name, events: events, lengthBeats: lengthBeats)

# ============================================================================
# Приёмы развития (чистые функции: возвращают новый паттерн)
# ============================================================================

proc repeat*(p: Pattern; times: int): Pattern =
  ## Повторить паттерн `times` раз подряд (compile-time разворот, не цикл
  ## движка). `repeat(p, 4)` на 1-тактовом басе = 4 такта (#COMPOSE-025).
  result = p
  result.events = @[]
  result.lengthBeats = p.lengthBeats * float(max(0, times))
  for _ in 0 ..< max(0, times):
    result.events.add p.events

proc reverse*(p: Pattern): Pattern =
  ## Обратить порядок событий (ретроград). Длительности сохраняются, но
  ## порядок нот меняется — базовая техника развития мотива.
  var evs: seq[NoteEvent]
  for i in countdown(p.events.len - 1, 0):
    evs.add p.events[i]
  rawPattern(p.name, evs, p.lengthBeats)

proc rotate*(p: Pattern; by: float): Pattern =
  ## Циклический сдвиг паттерна на `by` долей: событие, начавшееся на
  ## позиции `by`, становится первым, а «обрезок» переезжает в конец. Полезно
  ## для смещения фигуры относительно доли. Длина сохраняется.
  if p.events.len == 0 or p.lengthBeats <= 0.0:
    return p
  let shift = by - floor(by / p.lengthBeats) * p.lengthBeats
  if shift <= 0.0:
    return p
  var head: seq[NoteEvent]
  var tail: seq[NoteEvent]
  var acc = 0.0
  for e in p.events:
    if acc < shift:
      # Событие пересекает границу сдвига — режем его на две части.
      let before = shift - acc
      if e.beats > before:
        var first = e
        first.beats = before
        tail.add first
        var rest = e
        rest.beats = e.beats - before
        head.add rest
      else:
        tail.add e
    else:
      head.add e
    acc += e.beats
  # head = то, что было после сдвига (стало началом); tail = обрезок в конец
  rawPattern(p.name, head & tail, p.lengthBeats)

proc stretch*(p: Pattern; factor: float): Pattern =
  ## Растянуть все длительности в `factor` раз (factor>1 — длиннее).
  ## Аугментация ритма. Длина масштабируется тем же множителем.
  result = p
  for e in result.events.mitems:
    e.beats = e.beats * factor
  result.lengthBeats = p.lengthBeats * factor

proc compress*(p: Pattern; factor: float): Pattern =
  ## Сжать длительности (factor>1 — короче). Диминуция ритма.
  if factor == 0.0:
    return p
  p.stretch(1.0 / factor)

proc transpose*(p: Pattern; semis: int): Pattern =
  ## Транспонировать все ноты на `semis` полутонов (паузы не трогает).
  result = p
  for e in result.events.mitems:
    for k in 0 ..< e.pitches.len:
      e.pitches[k] = uint8(int(e.pitches[k]) + semis)

proc starts(p: Pattern): seq[float] =
  ## Абсолютные старты событий (накопительная сумма длительностей). Внутрен-
  ## ний помощник: модель Pattern хранит длительности, а не позиции, но
  ## `quantize`/`rotate`/`humanize` работают со временем — им нужны старты.
  var pos = 0.0
  for e in p.events:
    result.add pos
    pos += e.beats

proc quantize*(p: Pattern; grid: float): Pattern =
  ## Притянуть начала событий к сетке `grid` долей (0.5 — восьмые, 0.25 —
  ## шестнадцатые). Сдвиг квантуется сдвигом предыдущего события (паузой или
  ## нотой), поэтому длительности событий сохраняются, а паттерн встаёт «по
  ## сетке». Точное выравнивание ритма без изменения самих нот.
  if grid <= 0.0 or p.events.len < 2:
    return p
  let st = p.starts()
  # Новые (округлённые) старты; первый всегда на 0.
  var newStart: seq[float] = @[0.0]
  for i in 1 ..< st.len:
    newStart.add round(st[i] / grid) * grid
  # Пересобираем длительности как разницу соседних стартов. Последнее
  # событие сохраняет свою длину (его конец не квантуем — иначе паттерн
  ## «поплывёт» по длине).
  var evs: seq[NoteEvent]
  for i, e in p.events:
    var dur: float
    if i + 1 < newStart.len:
      dur = max(0.0, newStart[i + 1] - newStart[i])
    else:
      dur = e.beats
    var ne = e
    ne.beats = dur
    evs.add ne
  rawPattern(p.name, evs, p.lengthBeats)

proc truncate*(p: Pattern; maxBeats: float): Pattern =
  ## Обрезать паттерн до `maxBeats` долей, последнее событие режется по
  ## границе. Нужно, когда фигура длиннее слота (например, 2 такта в 1).
  var acc = 0.0
  var evs: seq[NoteEvent]
  for e in p.events:
    if acc >= maxBeats:
      break
    let room = maxBeats - acc
    if e.beats <= room:
      evs.add e
    else:
      var cut = e
      cut.beats = room
      evs.add cut
    acc += e.beats
  rawPattern(p.name, evs, maxBeats)

proc extend*(p: Pattern; toBeats: float): Pattern =
  ## Дополнить паттерн паузой до длины `toBeats` долей (если он короче).
  if p.lengthBeats >= toBeats:
    return p.truncate(toBeats)
  var evs = p.events
  evs.add r(toBeats - p.lengthBeats)
  rawPattern(p.name, evs, toBeats)

proc patternMix(seed, i: int): float =
  ## Детерминированное число в [0, 1) из пары (seed, i) — чистый хеш без
  ## состояния и без системного RNG (у того рандомизированное зерно, которое
  ## ломает воспроизводимость #COMPOSE-015). Integer-микс с крупными простыми
  ## множителями даёт равномерное распределение и стабильность между запусками.
  var x = uint32(seed) xor (uint32(i) * 0x9E3779B9'u32)
  x = x xor (x shr 16)
  x = x * 0x7FEB352D'u32
  x = x xor (x shr 15)
  x = x * 0x846CA68B'u32
  x = x xor (x shr 16)
  float(x and 0x00FFFFFF'u32) / float(0x01000000'u32)

proc humanize*(p: Pattern; timing: float; velocity: int; rngSeed: int = 12345): Pattern =
  ## «Оживить» паттерн: детерминированный сдвиг времени (доли `timing` —
  ## амплитуда микросдвига) и вариация velocity. Настоящий seed-RNG живёт в
  ## `random.nim` (#COMPOSE-015); здесь — стабильный арифметический сдвиг,
  ## чтобы один и тот же `rngSeed` всегда давал один результат (это критично
  ## для воспроизводимого генератора). Velocity в модели Pattern не хранится
  ## (одна velocity на такт), поэтому вариация velocity запоминается в
  ## `velJitter`/`velSeed` и применяется при сведении в `Motif` (см. toMotif).
  result = p
  result.velJitter = max(0, velocity)
  result.velSeed = rngSeed
  if timing <= 0.0 or p.events.len < 2:
    return
  # Микросдвиг внутренних границ детерминированно: сдвиг i-й границы
  # считается чистой функцией mix(seed, i) в [-1, 1). Не системный RNG (его
  # зерно рандомизируется), а своя стабильная арифметика — один seed всегда
  # даёт один результат, что и требуется для воспроизводимого генератора.
  let st = p.starts()
  var newStart: seq[float] = @[0.0]
  for i in 1 ..< st.len:
    let unit = patternMix(rngSeed, i)          # [0, 1)
    let signed = unit * 2.0 - 1.0              # [-1, 1)
    let shifted = st[i] + signed * timing
    # Границы не должны пересекать соседей (сдвиг только «внутрь» слота).
    let prev = newStart[^1]
    let nextBound = if i + 1 < st.len: st[i + 1] else: st[i] + p.events[i].beats
    newStart.add min(max(shifted, prev), nextBound)
  var evs: seq[NoteEvent]
  for i, e in p.events:
    var dur: float
    if i + 1 < newStart.len:
      dur = max(0.0, newStart[i + 1] - newStart[i])
    else:
      dur = e.beats
    var ne = e
    ne.beats = dur
    evs.add ne
  result.events = evs

# ============================================================================
# Наложение и свинг (COMPOSE-014: groove/слои)
# ============================================================================

proc collectCuts(evs: openArray[NoteEvent]; cuts: var seq[float]) =
  ## Все границы событий (старты и концы) — точки разбиения при слиянии.
  var pos = 0.0
  for e in evs:
    cuts.add pos
    pos += e.beats
    cuts.add pos

proc pitchesCovering(evs: openArray[NoteEvent]; t0, t1: float): seq[uint8] =
  ## Питчи, звучащие непрерывно на отрезке [t0, t1) (событие целиком
  ## покрывает отрезок и не является паузой).
  var pos = 0.0
  for e in evs:
    let s = pos
    pos += e.beats
    if e.pitches.len > 0 and s <= t0 + 1e-9 and s + e.beats >= t1 - 1e-9:
      for p in e.pitches:
        if p notin result:
          result.add p

proc mergeEvents*(a, b: openArray[NoteEvent]; totalBeats: float): seq[NoteEvent] =
  ## Наложить две последовательности событий по времени. Одновременно
  ## звучащие ноты склеиваются в аккорд, там, где не звучит никто, — пауза;
  ## границы событий служат разрезами, поэтому ритм обоих слоёв сохраняется
  ## точно. `totalBeats` — общая длина (за ней обрезается всё сверх).
  ## Это основа `overlay` (киты ударных) и слияния секций в `arrangement`.
  if a.len == 0 and b.len == 0:
    return @[]
  var cuts: seq[float] = @[0.0]
  collectCuts(a, cuts)
  collectCuts(b, cuts)
  if totalBeats > 0.0:
    cuts.add totalBeats
  cuts.sort()
  # Дедупликация и отсечение за пределами [0, totalBeats].
  var uniq: seq[float]
  for c in cuts:
    if c < -1e-9:
      continue
    if totalBeats > 0.0 and c > totalBeats + 1e-9:
      continue
    if uniq.len == 0 or abs(c - uniq[^1]) > 1e-9:
      uniq.add c
  # Собираем события: на каждом отрезке — объединение питчей обоих слоёв.
  for i in 0 ..< max(0, uniq.len - 1):
    let t0 = uniq[i]
    let t1 = uniq[i + 1]
    if t1 - t0 < 1e-9:
      continue
    var pitches = pitchesCovering(a, t0, t1)
    for p in pitchesCovering(b, t0, t1):
      if p notin pitches:
        pitches.add p
    if pitches.len == 0:
      result.add r(t1 - t0)
    else:
      pitches.sort()
      result.add ch(pitches.mapIt(int(it)), t1 - t0)

proc overlay*(a, b: Pattern): Pattern =
  ## Наложение двух паттернов: kick + snare → один паттерн кита. Длина —
  ## большая из двух; одновременные удары становятся одним событием-аккордом.
  let total = max(a.lengthBeats, b.lengthBeats)
  let name = if a.name.len > 0: a.name else: b.name
  rawPattern(name, mergeEvents(a.events, b.events, total), total)

proc overlay*(patterns: openArray[Pattern]): Pattern =
  ## Наложение слоёв: `overlay([kick, snare, hats])` — готовый кит такта.
  if patterns.len == 0:
    return Pattern()
  if patterns.len == 1:
    return patterns[0]
  var total = 0.0
  var evs = patterns[0].events
  total = patterns[0].lengthBeats
  for i in 1 ..< patterns.len:
    total = max(total, patterns[i].lengthBeats)
    evs = mergeEvents(evs, patterns[i].events, total)
  rawPattern(patterns[0].name, evs, total)

proc swing*(p: Pattern; amount: float32; grid: float = 0.5): Pattern =
  ## Свинг: слабые доли (вторая половина каждой `grid`-доли) сдвигаются
  ## вправо на `amount * grid / 4`. `amount = 0` — ровно; `≈ 0.67` —
  ## триольный feel (слабая восьмая встаёт на 2/3 доли); `1.0` — maximum.
  ## Длительности пересобираются по новым стартам, границы не пересекаются —
  ## ритм остаётся последовательностью событий (детерминировано, без RNG).
  if amount <= 0.0f32 or p.events.len < 2:
    return p
  let st = p.starts()
  let shift = float(amount) * grid * 0.25
  var newStart: seq[float] = @[0.0]
  for i in 1 ..< st.len:
    let phase = st[i] - floor(st[i] / grid) * grid
    var ns = st[i]
    if abs(phase - grid * 0.5) < 1e-6:
      ns = st[i] + shift
    let prev = newStart[^1]
    let nextBound = if i + 1 < st.len: st[i + 1] else: st[i] + p.events[i].beats
    newStart.add max(prev, min(ns, nextBound))
  var evs: seq[NoteEvent]
  for i, e in p.events:
    var dur: float
    if i + 1 < newStart.len:
      dur = max(0.0, newStart[i + 1] - newStart[i])
    else:
      dur = e.beats
    var ne = e
    ne.beats = dur
    evs.add ne
  rawPattern(p.name, evs, p.lengthBeats)

proc groove*(p: Pattern; swingAmount: float32; timing: float = 0.012;
             velocity: int = 6; seed: int = 12345): Pattern =
  ## «Живой» ритм одной командой: свинг слабых долей + детерминированная
  ## микрогуманизация времени и velocity. Один seed — один результат
  ## (#COMPOSE-014/015): `bass.groove(0.54, seed = 42)`.
  p.swing(swingAmount).humanize(timing, velocity, seed)

# ============================================================================
# Извлечение длины/позиций
# ============================================================================

proc eventAt*(p: Pattern; beats: float): NoteEvent =
  ## Событие, активное на доле `beats` (0-базная). Для ритмических
  ## запросов «что играет на 2.5 доле». Пустое событие, если вне паттерна.
  var acc = 0.0
  for e in p.events:
    if beats >= acc and beats < acc + e.beats:
      return e
    acc += e.beats
  NoteEvent()

proc length*(p: Pattern): float =
  ## Длина паттерна в долях (как хранится).
  p.lengthBeats

# ============================================================================
# Мост в Motif/Part (общая модель событий со score)
# ============================================================================

proc motifBarVel(p: Pattern; barIdx: int; events: seq[NoteEvent]): Bar =
  ## Такт паттерна с детерминированной velocity-вариацией (если humanize
  ## задал `velJitter`). Базовая velocity 100 (как в `score.bar`), сдвиг в
  ## ±velJitter по чистому хешу (velSeed, barIdx) — один seed = один результат.
  var base = 100
  if p.velJitter > 0:
    let unit = patternMix(p.velSeed, barIdx + 1)   # [0, 1)
    let signed = (unit * 2.0 - 1.0) * float(p.velJitter)
    base += int(round(signed))
  bar(max(1, min(127, base)), events)

proc toMotif*(p: Pattern; beatsPerBar: float = 4.0): Motif =
  ## Уложить паттерн в такты по `beatsPerBar` долей. Граница такта режет
  ## событие надвое, поэтому ритм сохраняется точно и мотив читается
  ## штатными средствами (`score`). Если паттерн «гуманизирован»
  ## (`velJitter > 0`), velocity каждого такта детерминированно варьируется —
  ## в модели `score` одна velocity на такт, поэтому «живость» применяется
  ## на этом уровне и остаётся воспроизводимой по `velSeed`.
  var barEvents: seq[NoteEvent]
  var barBeats = 0.0
  var cursor = 0.0
  var barIdx = 0
  for e in p.events:
    var remaining = e.beats
    var first = e
    while remaining > 1e-9:
      let room = beatsPerBar - barBeats
      if room <= 1e-9:
        result.add motifBarVel(p, barIdx, barEvents)
        barEvents = @[]
        barBeats = 0.0
        inc barIdx
        continue
      let take = min(room, remaining)
      var chunk = first
      chunk.beats = take
      barEvents.add chunk
      barBeats += take
      remaining -= take
      if barBeats >= beatsPerBar - 1e-9:
        result.add motifBarVel(p, barIdx, barEvents)
        barEvents = @[]
        barBeats = 0.0
        inc barIdx
    cursor += e.beats
  if barEvents.len > 0:
    result.add motifBarVel(p, barIdx, barEvents)

proc toPart*(p: Pattern; name: string = ""; beatsPerBar: float = 4.0): Part =
  ## Паттерн как партия (`score.Part`) — готова к `add`/`toNotes`/`toNotation`.
  let m = p.toMotif(beatsPerBar)
  result = part(if name.len > 0: name else: p.name)
  result.add m

proc `$`*(p: Pattern): string =
  ## Читаемый паттерн: имя и число событий.
  p.name & " (" & $p.events.len & " events, " & $p.lengthBeats & " beats)"

{.pop.}
