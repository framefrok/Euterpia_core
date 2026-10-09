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
    ## аккорду: `mtChordTone` бьёт точно в ноты аккорда, `mtPassing`/
    ## `mtApproach` — плавные связки.
    mtDegree
    mtChordTone
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

  Melody* = object
    ## Мелодия как последовательность шагов (ещё без конкретных высот — они
    ## вычисляются при наложении на гармонию через `render`). Это позволяет
    ## написать «мелодию» один раз и переиспользовать поверх любой прогрессии.
    name*: string
    steps*: seq[MelodyStep]

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

proc melody*(name: string; steps: varargs[MelodyStep]): Melody =
  ## Собрать мелодию из шагов. Высоты не фиксируются — они появятся при
  ## `render(melody, progression, scale)`.
  Melody(name: name, steps: @steps)

# ============================================================================
# Наложение мелодии на гармонию + лад → конкретные ноты
# ============================================================================

proc tonePitch(step: MelodyStep; chord: Chord; scale: Scale;
               lastPitch: int): int =
  ## Высота одного шага. `chordTone` — точная нота аккорда; `passing` —
  ## соседняя ступень лада (связка); `approach` — полутон к следующей
  ## аккордовой ноте; `degree` — ступень лада. `lastPitch` даёт связность
  ## (параллели), чтобы проходящие/заходящие тоны выбирались рядом с
  ## предыдущей нотой, а не в произвольной октаве.
  case step.tone
  of mtRest:
    -1
  of mtDegree:
    scale.degree(step.degree)
  of mtChordTone:
    chord.chordTone(step.chordDegree)
  of mtPassing:
    # Проходящий: аккордовая нота ± 1 ступень лада, выбираем ближнюю к
    # предыдущей высоте (минимальный скачок).
    var best = chord.chordTone(step.chordDegree + 1)
    if lastPitch > 0:
      let down = chord.chordTone(step.chordDegree) - 1
      if abs(down - lastPitch) < abs(best - lastPitch):
        best = down
    best
  of mtApproach:
    # Заход: полутон к цели (аккордовая нота), снизу или сверху по близости.
    let target = chord.chordTone(max(1, step.chordDegree))
    var cand = target - 1
    if lastPitch > 0 and abs(target + 1 - lastPitch) < abs(cand - lastPitch):
      cand = target + 1
    cand

proc render*(m: Melody; progression: Progression; scale: Scale;
             startBar: int = 0; barsPerChord: int = -1): seq[NoteEvent] =
  ## Превратить мелодию в конкретные ноты поверх прогрессии. Каждый шаг
  ## попадает на аккорд своего такта (`progression.chordAt`), поэтому высота
  ## всегда согласована с гармонией. `startBar` — смещение (если мелодия
  ## начинается не с первого такта). `barsPerChord` переопределяет
  ## распределение аккордов (по умолчанию — из прогрессии). Возвращает
  ## готовые `NoteEvent` для `toMotif`/`toPart`.
  var events: seq[NoteEvent]
  var bar = startBar
  var lastPitch = -1
  for step in m.steps:
    let bpc = if barsPerChord > 0: barsPerChord else: progression.barsPerChord
    let chord = progression.chordAt(bar div bpc * bpc)
    let pitch = tonePitch(step, chord, scale, lastPitch)
    if step.tone == mtRest or pitch < 0:
      events.add r(step.beats)
      lastPitch = -1
    else:
      events.add n(pitch, step.beats)
      lastPitch = pitch
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
