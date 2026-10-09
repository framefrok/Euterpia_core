# libs/compose/generators/bass.nim
#
# Генераторы баса (issue #COMPOSE-017).
#
# Зачем: бас — каркас современной музыки, и писать его каждый раз вручную
# (корень-октава-ход) значит повторять одно и то же. Здесь — алгоритмические
# фигуры баса, а не «жанровые песни»: каждая возвращает МЕЛОДИЮ (не фиксированные
# питчи), поэтому она автоматически следует за гармонией пьесы (`harmony`) и
# ладом: `song.play("bass", bassLine(bsRoot), roleBass)` (#COMPOSE-006/017).
#
# Регистром управляет вызывающий: `.transpose(-24)` — «808» двумя октавами
# ниже; сами фигуры написаны в среднем регистре, чтобы их можно было положить
# и в бас, и в контрапункт.

import compose/melody
  # Melody/MelodyStep + chordTone/degree/rest — фигуры баса.

{.push raises: [].}

type
  BassStyle* = enum
    ## Алгоритмическая фигура баса.
    bsRoot        ## корень аккорда долгой нотой («808», два такта дыхания)
    bsOctave      ## корень + октавный удар на слабой доле
    bsWalking     ## ход по аккордовым тонам четвертями
    bsArp         ## арпеджио вверх-вниз восьмыми
    bsSyncopated  ## синкопы: смещённые удары с паузами
    bsPedal       ## педаль на тонике лада (не следует за аккордом)

proc bassLine*(style: BassStyle): Melody =
  ## Бас-фигура на один такт 4/4 как мелодия (рендерится поверх гармонии).
  ## Регистр — вызывающий: `bassLine(bsRoot).transpose(-24)`.
  case style
  of bsRoot:
    result = melody("bassRoot",
      chordTone(1, 3.5), rest(0.5))
  of bsOctave:
    result = melody("bassOctave",
      chordTone(1, 2.5), chordTone(4, 1.0), rest(0.5))
  of bsWalking:
    result = melody("bassWalking",
      chordTone(1, 1.0), chordTone(2, 1.0),
      chordTone(3, 1.0), chordTone(4, 1.0))
  of bsArp:
    result = melody("bassArp",
      chordTone(1, 0.5), chordTone(2, 0.5), chordTone(3, 0.5), chordTone(4, 0.5),
      chordTone(3, 0.5), chordTone(2, 0.5), chordTone(1, 0.5), chordTone(2, 0.5))
  of bsSyncopated:
    result = melody("bassSyncopated",
      chordTone(1, 1.5), rest(0.5), chordTone(1, 1.0),
      chordTone(4, 0.75), rest(0.25))
  of bsPedal:
    result = melody("bassPedal",
      degree(1, 4.0))

proc doubledBass*(bass: Melody): Melody =
  ## Бас с октавным дублем: аккордовые шаги звучат парой «нота + октава»
  ## (шаг становится аккордом) — «толстый» 808 без второго инструмента.
  ## Аккорд — это терции, поэтому октава в теоретических ступенях `stack` —
  ## это +6 ступеней (1 → 7, 3 → 9, 5 → 11).
  var steps: seq[MelodyStep] = bass.steps
  for s in steps.mitems:
    if s.tone == mtChordTone:
      s.tone = mtChord
      let low = 2 * s.chordDegree - 1     # порядковый номер → теоретическая ступень
      s.degrees = @[max(1, low), max(1, low + 6)]
  Melody(name: bass.name & "+oct", steps: steps, transpose: bass.transpose)

{.pop.}
