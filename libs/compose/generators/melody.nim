# libs/compose/generators/melody.nim
#
# Генератор мелодии (issue #COMPOSE-018).
#
# Зачем: превратить Compose из DSL в генератор музыки. Мелодия строится
# детерминированно (`musicRandom`) поверх гармонии и лада: выбираются шаги
# (аккордовые тоны/ступени/паузы) внутри полутонового коридора вокруг центра,
# поэтому результат музыкально осмыслен, а не случаен — и воспроизводим по seed
# (#COMPOSE-015/018/032: seed 123 всегда даёт одну и ту же мелодию).
#
# Возвращается `Melody` (шаги, а не питчи): при компиляции Compose сам считает
# высоты по аккорду каждого такта, поэтому смена прогрессии не ломает мелодию.

import compose/melody
  # Melody/MelodyStep + chordTone/degree/rest.
import compose/harmony
  # Progression/chordAt/chordTone — «каркас» мелодии.
import compose/scale
  # Scale/degree — ступени лада.
import compose/random
  # musicRandom — детерминированный выбор.

{.push raises: [].}

proc generateMelody*(prog: Progression; scale: Scale; seed: int;
                     bars: int = 1; center: int = 69; range: int = 12;
                     density: float = 0.6): Melody =
  ## Мелодия на `bars` тактов 4/4 над гармонией `prog` и ладом `scale`.
  ##
  ## - `density` — доля звучащих шагов (0 — одни паузы, 1 — без пауз);
  ## - `center`/`range` — полутоновый коридор: шаги вне него не выбираются
  ##   (мелодия не «улетает» из регистра инструмента);
  ## - `seed` — полный детерминизм: один seed всегда даёт одну мелодию.
  ##
  ## Шаги — теоретические: ~70% аккордовые тоны (мелодия ложится на гармонию),
  ## остальное — ступени лада; длительности из набора четверть/восьмая/16-я.
  var rng = musicRandom(seed)
  var bar = 0
  var beatsInBar = 0.0
  var beatsLeft = float(max(1, bars)) * 4.0
  result.name = "gen" & $seed
  while beatsLeft > 1e-6:
    let dur = min(beatsLeft, rng.randomChoice([0.5, 0.5, 1.0, 0.25, 2.0]))
    let chord = prog.chordAt(bar)
    # Кандидаты внутри коридора: сначала аккордовые тоны, затем ступени лада.
    var chordSteps: seq[MelodyStep]
    var scaleSteps: seq[MelodyStep]
    for d in 1 .. 4:
      let p = chord.chordTone(d)
      if p >= center - range and p <= center + range:
        chordSteps.add chordTone(d, dur)
    for d in 1 .. 7:
      let p = scale.degree(d)
      if p >= center - range and p <= center + range:
        scaleSteps.add degree(d, dur)
    let total = chordSteps.len + scaleSteps.len
    if total == 0 or rng.nextFloat() > density:
      result.steps.add rest(dur)
    elif chordSteps.len > 0 and rng.nextFloat() < 0.7:
      result.steps.add rng.randomChoice(chordSteps)
    else:
      result.steps.add rng.randomChoice(scaleSteps & chordSteps)
    beatsLeft -= dur
    beatsInBar += dur
    while beatsInBar >= 4.0 - 1e-9:
      inc bar
      beatsInBar -= 4.0

proc respond*(call: Melody): Melody =
  ## «Ответ» на фразу (call & response, #COMPOSE-020): та же мелодия, но
  ## вторая половина — зеркальная (шаги второй половины задом наперёд).
  ## Детерминировано, без новой случайности — узнаваемый диалог на основе уже
  ## сочинённой фразы.
  result.name = call.name & "~resp"
  result.transpose = call.transpose
  let half = call.steps.len div 2
  for i, s in call.steps:
    if i < half:
      result.steps.add s
    else:
      result.steps.add call.steps[^(i - half + 1)]

{.pop.}
