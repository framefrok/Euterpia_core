# libs/compose/generators/drums.nim
#
# Барабанные генераторы для «композиции как код» (issue #COMPOSE-019).
#
# Зачем: кик/снэр/хэт вручную пишутся одинаково каждый раз, а генератору
# нужны готовые связки и филлы, понимающие сетку. Здесь инструменты думают
# в GM-нотах `euterpia.drums` (36 бочка, 38 малый, 42 закрытый хэт, …),
# а ритмика берётся из `compose/rhythm` (фигуры) и `compose/random`
# (детерминированные филлы по seed).
#
# Это НЕ «жанровые песни»: функции дают связки нот/ритмов, которые дальше
# складываются, варьируются (`variant`, `humanize`) и размещаются по секциям
# (`during`) обычными средствами arranjement-слоя.

import std/math

import compose/score
  # NoteEvent + n/r — события.
import compose/pattern
  # Pattern/rawPattern/overlay/repeat — киты и слои.
import compose/rhythm
  # Rhythm/фигуры — ритмическая сетка.
import compose/random
  # musicRandom — детерминированные филлы.

{.push raises: [].}

const
  # GM-карта `euterpia.drums` (см. docs/libs/compose/instruments.md).
  Kick* = 36
  SideStick* = 37
  Snare* = 38
  Clap* = 39
  ElectricSnare* = 40
  LowTom* = 41
  ClosedHat* = 42
  HighTom* = 43
  PedalHat* = 44
  MidTom* = 45
  OpenHat* = 46
  LowMidTom* = 47
  HiMidTom* = 48
  Crash* = 49
  Ride* = 51
  Splash* = 55
  Cowbell* = 56
  Shake* = 70

# ============================================================================
# Одиночные слои: ритм → нота инструмента
# ============================================================================

proc kick*(rh: Rhythm; pitch: int = Kick): Pattern =
  ## Бочка по сетке: `kick(tresillo())` — кик-фигура одной командой.
  rh.toPattern(pitch, "kick")

proc snare*(rh: Rhythm; pitch: int = Snare): Pattern =
  ## Малый барабан по сетке.
  rh.toPattern(pitch, "snare")

proc clap*(rh: Rhythm): Pattern =
  ## Хлопок (clap) по сетке — «второй снэр» в современном бите.
  rh.toPattern(Clap, "clap")

proc hats*(rh: Rhythm; pitch: int = ClosedHat): Pattern =
  ## Хэты по сетке (по умолчанию закрытые).
  rh.toPattern(pitch, "hats")

# ============================================================================
# Готовые связки (один такт 4/4, если не сказано иначе)
# ============================================================================

proc backbeatSnare*(): Pattern =
  ## Бэкбит: малый на 2 и 4 — якорь любого бита.
  snare(rhythm(". x . x", 1.0, "backbeat"))

proc trapKick*(): Pattern =
  ## Трэп-бочка: «бум … бум-бум» на шестнадцатой сетке
  ## (доли 1, 3 и «и» перед следующей долей).
  kick(rhythm("x . . . . . . . x . . x . . . .", 0.25, "trapKick"))

proc trapHats*(seed: int = 7): Pattern =
  ## Хэты-шестнадцатые с детерминированным сокращением лишних ударов
  ## (плотность 0.85) — «живая» сетка, воспроизводимая по seed.
  var rng = musicRandom(seed)
  var evs: seq[NoteEvent]
  for i in 0 ..< 16:
    if i mod 4 == 0 or rng.nextFloat() < 0.85:
      evs.add n(ClosedHat, 0.25)
    else:
      evs.add r(0.25)
  rawPattern("trapHats", evs, 4.0)

proc houseFour*(): Pattern =
  ## «Фургон» house: бочка на каждую четверть.
  kick(rhythm("x x x x", 1.0, "houseFour"))

proc offbeatHat*(): Pattern =
  ## Слабые восьмые — классический offbeat-хэт techno/house.
  hats(rhythm(". x . x . x . x", 0.5, "offbeatHat"))

proc boomBapKit*(): Pattern =
  ## Boom-bap такт: бочка (tresillo-ход), бэкбит, восьмые хэты.
  overlay([kick(rhythm("x . . x . . x . x . . x . . x .", 0.25, "bbKick")),
           backbeatSnare(),
           hats(rhythm("x x x x x x x x", 0.5, "bbHats"))])

proc trapKit*(seed: int = 7): Pattern =
  ## Трэп-такт: бочка-фигура + бэкбит-снэр + шестнадцатые хэты по seed.
  overlay([trapKick(), backbeatSnare(), trapHats(seed)])

# ============================================================================
# Филлы и роллы (детерминированно по seed)
# ============================================================================

proc fill*(seed: int; steps: int = 16; stepBeats: float = 0.25;
           density: float = 0.7;
           pitches: openArray[int] = [Snare, MidTom, LowTom,
                                      LowMidTom, HighTom]): Pattern =
  ## Детерминированный филл: по сетке `steps` ударов с вероятностью
  ## `density`, высоты — из набора (снэры → томы). Один seed — один филл:
  ## запасная партия перед сменой секции всегда воспроизводима.
  var rng = musicRandom(seed)
  var evs: seq[NoteEvent]
  for i in 0 ..< max(1, steps):
    if i mod 4 == 0 or rng.nextFloat() < density:
      evs.add n(rng.randomChoice(pitches), stepBeats)
    else:
      evs.add r(stepBeats)
  rawPattern("fill", evs, float(steps) * stepBeats)

proc roll*(pitch: int; steps: int = 16; stepBeats: float = 0.25): Pattern =
  ## Ровный ролл (снэр-ролл, хэт-ролл) — наращивание перед дропом.
  var evs: seq[NoteEvent]
  for _ in 0 ..< max(1, steps):
    evs.add n(pitch, stepBeats)
  rawPattern("roll", evs, float(steps) * stepBeats)

proc rollTo*(startPitch, endPitch: int; steps: int = 16;
             stepBeats: float = 0.25): Pattern =
  ## Ролл с подъёмом высоты от `startPitch` до `endPitch` — «разгон»
  ## перед дропом/финалом.
  var evs: seq[NoteEvent]
  let n0 = max(1, steps)
  for i in 0 ..< n0:
    let t = float(i) / float(max(1, n0 - 1))
    let pitch = startPitch + int(round(t * float(endPitch - startPitch)))
    evs.add n(pitch, stepBeats)
  rawPattern("rollTo", evs, float(n0) * stepBeats)

{.pop.}
