# libs/compose/validate.nim
#
# Музыкальный валидатор пьесы (issue #COMPOSE-029).
#
# Зачем: `song.validate(Arrangement)` ловит технические проблемы раскладки
# (неизвестный тип ноды, опечатка в параметре, дубли имён, #311), но ничего не
# знает о замысле: пустая форма, размещение в несуществующей секции, мелодия
# без гармонии, пустой паттерн. Композиция должна быть проверяема ДО
# компиляции — здесь именно это.
#
# Формат проблем тот же, что у `song.validate`: строки со словами «ошибка:»
# (сборка противоречива) и «внимание:» (допустимо, но подозрительно), поэтому
# работают общие `isError`/`hasErrors`/`problemBlock`. Собственного рантайма
# тут нет — только анализ модели `Piece`.

import compose/form
import compose/arrangement
  # Piece/Voice/Play/Section — музыкальная модель пьесы.

{.push raises: [].}

proc validate*(c: Piece): seq[string] =
  ## Музыкальные проблемы пьесы до компиляции в `Arrangement`. Пустой список —
  ## замысел непротиворечив. Проверяются: форма, голоса, размещения, диапазон
  ## вариаций, наличие гармонии под мелодии (#COMPOSE-029/033).
  if c.song.sections.len == 0:
    result.add "ошибка: форма пуста — ни одной секции " &
               "(song.section(\"verse\", 16.bars))"
  else:
    for s in c.song.sections:
      if s.lengthBars <= 0:
        result.add "внимание: секция «" & s.name & "» нулевой длины"
  if c.song.tempo <= 0.0:
    result.add "ошибка: темп пьесы не положителен (" & $c.song.tempo & ")"
  if c.voices.len == 0:
    result.add "внимание: в пьесе нет ни одного голоса — будет тишина"

  for i, v in c.voices:
    let who = "голос " & $i & " («" & v.trackName & "»)"
    if v.trackName.len == 0:
      result.add who & ": ошибка: пустое имя дорожки"
    for k in 0 ..< i:
      if c.voices[k].trackName == v.trackName:
        result.add who & ": ошибка: имя дорожки дублируется"
        break
    if v.nodeType.len == 0:
      result.add who & ": ошибка: не задан тип ноды (nodeType)"
    if v.plays.len == 0:
      result.add who & ": внимание: нет ни одного размещения (play) — голос молчит"
    for j, p in v.plays:
      let where = who & ", размещение " & $j & " («" & p.partName & "»)"
      if not p.hasPattern and not p.hasMelody:
        result.add where & ": ошибка: пустое размещение — ни паттерна, ни мелодии"
      if p.hasPattern and p.pattern.events.len == 0:
        result.add where & ": внимание: паттерн без событий — тишина"
      if p.hasMelody:
        if p.tune.steps.len == 0:
          result.add where & ": внимание: мелодия без шагов — тишина"
        if c.prog.chords.len == 0:
          result.add where & ": внимание: мелодия без гармонии " &
                     "(song.harmony) — ступени считаются от C major"
      if p.variant < 0 or p.variant > 5:
        result.add where & ": внимание: вариант " & $p.variant &
                   " не поддерживается (0..5) — тема звучит как базовая"
      if p.sections.len == 0:
        result.add where & ": внимание: секции не указаны (during) — " &
                   "размещение не попадает ни в одну секцию"
      else:
        for name in p.sections:
          if not c.song.hasSection(name):
            result.add where & ": ошибка: секции «" & name &
                       "» нет в форме (опечатка?)"

{.pop.}
