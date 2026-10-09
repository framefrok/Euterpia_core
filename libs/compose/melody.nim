# libs/compose/melody.nim
#
# Аккорд-осведомлённая мелодия для «композиции как код» (issue #COMPOSE-006).
#
# Зачем: генератору нужна мелодия поверх конкретной гармонии («Am → Em → G»),
# а не только поверх лада. Обычная мелодия по ступеням лада рискует ударить
# «не туда» на смене аккорда. Здесь каждая нота понимает текущий аккорд:
# `chordTone()` бьёт точно в созвучие, `passingTone()`/`approachTone()` ведут
# к нему — как настоящая мелодия, а не случайные высоты.
#
# Мелодия = последовательность `NoteEvent` (тот же тип, что в score/pattern),
# поэтому готова к `toMotif`/`toPart` и уходит в тот же `ProjectFormat`.
# Всё детерминировано: один seed — одна мелодия (важно для #COMPOSE-015/032).
# Чистая музыкальная семантика: Core про chord-tone не знает — это Compose.

import std/math

import compose/score
  # NoteEvent/Part — общая модель событий.
import compose/scale
  # Scale/degree — мелодия опирается на лад.
import compose/harmony
  # Progression/chordAt/chordTone — гармония задаёт «куда бить».
import compose/pattern
  # Pattern/rawPattern — мелодию можно сразу превращать в паттерн.

{.push raises: [].}

type
  MelodyTone* = enum
    ## Роль ноты в мелодии относительно текущего аккорда. `mtDegree` —
    ## ступень лада (может быть неаккордовой), остальные — по отношению к
    ## аккорду: `mtChordTone` бьёт точно в ноты аккорда, `mtChord` — стак
    ## нескольких ступеней (аккомпанемент/пад), `mtPassing`/`mtApproach` —
    ## плавные связки.
    mtDegree
    mtChordTone
    mtChord
    mtPassing
    mtApproach
    mtRest

  MelodyStep* = object
    ## Один шаг мелодии: тон и его длительность в долях. Компилируется в
    ## `NoteEvent` при `render` с конкретной гармонией и ладом.
    tone*: MelodyTone
    beats*: float
    degree*: int        # для mtDegree: ступень лада
    chordDegree*: int   # для mtChordTone/Passing/Approach: ступень аккорда
    degrees*: seq[int]  # для mtChord: ступени аккорда, звучащие вместе

  Melody* = object
    ## Мелодия как последовательность шагов (ещё без конкретных высот — они
    ## вычисляются при наложении на гармонию через `render`). Это позволяет
    ## написать «мелодию» один раз и переиспользовать поверх любой прогрессии.
    ## `transpose` — сдвиг регистра в полутонах: бас = мелодия по аккорду на
    ## две октавы ниже (`melody(...).transpose(-24)`), не переписывая шаги.
    name*: string
    steps*: seq[MelodyStep]
    transpose*: int

# ============================================================================
# DSL построения мелодии
# ============================================================================

proc degree*(deg: int; beats: float = 1.0): MelodyStep =
  ## Шаг «ступень лада»: `degree(3)` — 3-я ступень текущего лада.
  MelodyStep(tone: mtDegree, beats: beats, degree: deg)

proc chordTone*(deg: int = 1; beats: float = 1.0): MelodyStep =
  ## Шаг «нота аккорда»: `chordTone()` — корень/бас, `chordTone(3)` — терция.
  MelodyStep(tone: mtChordTone, beats: beats, chordDegree: deg)

proc passingTone*(beats: float = 0.5): MelodyStep =
  ## Проходящий тон между аккордовыми нотами (ступень аккорда +1).
  MelodyStep(tone: mtPassing, beats: beats, chordDegree: 0)

proc approachTone*(beats: float = 0.5): MelodyStep =
  ## Заход в следующую ноту снизу/сверху (на полутон к цели).
  MelodyStep(tone: mtApproach, beats: beats, chordDegree: 0)

proc rest*(beats: float = 1.0): MelodyStep =
  ## Пауза в мелодии.
  MelodyStep(tone: mtRest, beats: beats)

proc stack*(degrees: openArray[int] = [1, 3, 5]; beats: float = 4.0): MelodyStep =
  ## Стак ступеней аккорда одновременно — пад/аккомпанемент поверх гармонии:
  ## `stack([1, 3, 5], 4.0)` звучит как трезвучие текущего такта, само меняясь
  ## вместе с прогрессией (COMPOSE-010/011: слои без ручного пересчёта).
  ## Ступени — теоретические (1/3/5/7): они переводятся в n-ю ноту аккорда
  ## (`chordTone`), потому что аккорд — это терции, и 3-я ступень = 2-я нота.
  MelodyStep(tone: mtChord, beats: beats, degrees: @degrees)

proc melody*(name: string; steps: varargs[MelodyStep]): Melody =
  ## Собрать мелодию из шагов. Высоты не фиксируются — они появятся при
  ## `render(melody, progression, scale)`.
  Melody(name: name, steps: @steps)

proc transpose*(m: Melody; semis: int): Melody =
  ## Сдвиг регистра всей мелодии на `semis` полутонов. Шаги (ступени,
  ## аккордовые тоны) остаются теми же — меняется только регистр при
  ## `render`: `.transpose(-24)` = «та же мелодия двумя октавами ниже»,
  ## что и нужно басу поверх гармонии (COMPOSE-017).
  Melody(name: m.name, steps: m.steps, transpose: m.transpose + semis)

# ============================================================================
# Наложение мелодии на гармонию + лад → конкретные ноты
# ============================================================================

proc tonePitches(step: MelodyStep; chord: Chord; scale: Scale;
                 lastPitch: int): seq[int] =
  ## Высоты одного шага (у стака — несколько). `chordTone` — точная нота
  ## аккорда; `mtChord` — все указанные ступени вместе (аккорд); `passing` —
  ## соседняя ступень лада (связка); `approach` — полутон к следующей
  ## аккордовой ноте; `degree` — ступень лада. `lastPitch` даёт связность
  ## (параллели), чтобы проходящие/заходящие тоны выбирались рядом с
  ## предыдущей нотой, а не в произвольной октаве.
  case step.tone
  of mtRest:
    return @[]
  of mtDegree:
    return @[scale.degree(step.degree)]
  of mtChordTone:
    return @[chord.chordTone(step.chordDegree)]
  of mtChord:
    # Теоретические ступени (1/3/5/7) → n-я нота аккорда: аккорд — это
    # терции, поэтому 3-я ступень = 2-я нота, 5-я = 3-я, 7-я = 4-я.
    for d in step.degrees:
      result.add chord.chordTone(max(1, (d + 1) div 2))
  of mtPassing:
    # Проходящий: аккордовая нота ± 1 ступень лада, выбираем ближнюю к
    # предыдущей высоте (минимальный скачок).
    var best = chord.chordTone(step.chordDegree + 1)
    if lastPitch > 0:
      let down = chord.chordTone(step.chordDegree) - 1
      if abs(down - lastPitch) < abs(best - lastPitch):
        best = down
    return @[best]
  of mtApproach:
    # Заход: полутон к цели (аккордовая нота), снизу или сверху по близости.
    let target = chord.chordTone(max(1, step.chordDegree))
    var cand = target - 1
    if lastPitch > 0 and abs(target + 1 - lastPitch) < abs(cand - lastPitch):
      cand = target + 1
    return @[cand]

proc render*(m: Melody; progression: Progression; scale: Scale;
             startBar: int = 0; barsPerChord: int = -1): seq[NoteEvent] =
  ## Превратить мелодию в конкретные ноты поверх прогрессии. Каждый шаг
  ## попадает на аккорд своего такта (`progression.chordAt`), поэтому высота
  ## всегда согласована с гармонией. `startBar` — смещение (если мелодия
  ## начинается не с первого такта — например, реплика фразы внутри секции).
  ## `barsPerChord` переопределяет распределение аккордов (по умолчанию —
  ## из прогрессии). Сдвиг регистра (`m.transpose`) применяется здесь —
  ## готовые `NoteEvent` для `toMotif`/`toPart`.
  var events: seq[NoteEvent]
  var bar = startBar
  var lastPitch = -1
  for step in m.steps:
    let bpc = if barsPerChord > 0: barsPerChord else: progression.barsPerChord
    let chord = progression.chordAt(bar div bpc * bpc)
    let pitches = tonePitches(step, chord, scale, lastPitch)
    if step.tone == mtRest or pitches.len == 0:
      events.add r(step.beats)
      lastPitch = -1
    else:
      # Регистр: сдвиг + защита диапазона MIDI (0..127).
      var shifted: seq[uint8]
      for p in pitches:
        shifted.add uint8(max(0, min(127, p + m.transpose)))
      events.add NoteEvent(pitches: shifted, beats: step.beats)
      lastPitch = int(shifted[0])
    # Продвигаем такт по длительности шага (4 доли = 1 такт).
    bar += int(step.beats / 4.0)
  events

proc toPattern*(m: Melody; progression: Progression; scale: Scale;
                startBar: int = 0; barsPerChord: int = -1): Pattern =
  ## Мелодия как ритмический паттерн (для приёмов repeat/transpose/…).
  let evs = m.render(progression, scale, startBar, barsPerChord)
  var len = 0.0
  for e in evs:
    len += e.beats
  rawPattern(m.name, evs, len)

proc totalBeats*(m: Melody): float =
  ## Суммарная длительность мелодии в долях.
  for s in m.steps:
    result += s.beats

proc `$`*(m: Melody): string =
  ## Читаемая мелодия: имя и число шагов.
  m.name & " (" & $m.steps.len & " steps, " & $m.totalBeats & " beats)"

{.pop.}
