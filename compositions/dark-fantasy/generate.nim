#!/usr/bin/env -S nim r
# compositions/dark-fantasy/generate.nim
#
# «Cathedral of Ash» — medieval dark fantasy на Nim (библиотека libs/compose).
# Версия 3: энергии 2-й версии + струнный фундамент и колокол-«метки» по
# краям разделов (инструменты euterpia.strings и euterpia.bell).
#
# Запуск:  nim r compositions/dark-fantasy/generate.nim
# Пишет:   *.notes, ensemble.eut и ensemble.wav — одной командой.

import std/[math, os]

import compose/score
import compose/song
import compose/engine

const BARS = 88

proc chord(name: string): seq[int] =
  case name
  of "Dm": @[50, 53, 57]
  of "Bb": @[46, 50, 53]
  of "F":  @[53, 57, 60]
  of "Gm": @[55, 58, 62]
  of "C":  @[48, 52, 55]
  of "A":  @[45, 49, 52]
  of "Am": @[45, 48, 52]
  of "Eb": @[51, 55, 58]
  else: @[50, 53, 57]

proc progression(section: string): seq[string] =
  case section
  of "dawn":   @["Dm", "Bb", "Gm", "Dm"]
  of "march":  @["Dm", "Bb", "F", "C", "Gm", "Dm", "Bb", "A"]
  of "charge": @["Dm", "Gm", "Bb", "C", "Dm", "Eb", "Gm", "A"]
  of "lament": @["Bb", "F", "Gm", "Dm", "Bb", "C", "Dm", "Am"]
  of "finale": @["Dm", "Bb", "Gm", "A", "Dm", "F", "Gm", "Dm"]
  else: @["Dm"]

const SECTIONS = [("dawn", 1, 12), ("march", 13, 32), ("charge", 33, 52),
                  ("lament", 53, 68), ("finale", 69, 88)]

proc sectionOf(b: int): string =
  for s in SECTIONS:
    if b >= s[1] and b <= s[2]:
      return s[0]
  "march"

proc sectionStart(name: string): int =
  for s in SECTIONS:
    if s[0] == name:
      return s[1]
  1

proc chordNameAt(b: int): string =
  let s = sectionOf(b)
  let p = progression(s)
  p[(b - sectionStart(s)) mod p.len]

proc chordAt(b: int): seq[int] = chord(chordNameAt(b))

# Динамика: зарядаемся к «Charge», стихаем в «Lament», поднимаем в «Finale».
proc dyn(section: string): float =
  case section
  of "dawn": 0.80
  of "march": 1.00
  of "charge": 1.18
  of "lament": 0.82
  of "finale": 1.10
  else: 1.0

proc velAt(b, base: int): int =
  max(1, min(127, int(round(float(base) * dyn(sectionOf(b))))))

# ---------------------------------------------------------------------------
# Мотивы (MIDI: d4=62, e4=64, f4=65, g4=67, a4=69, bb4=70, c5=72, d5=74,
# eb5=75, e5=76, f5=77, g5=79, a5=81)
# ---------------------------------------------------------------------------

# Зов флейты в рассвете — парящий, с длинным дыханием.
let FLUTE_CALL: Motif = @[
  bar(n(74, 2), n(76, 2)),
  bar(n(77, 1), n(76, 1), n(74, 2)),
  bar(n(72, 2), n(69, 2)),
  bar(n(70, 3), r(1)),
  bar(n(74, 2), n(77, 2)),
  bar(n(79, 1), n(77, 1), n(76, 2)),
  bar(n(74, 2), n(72, 2)),
  bar(n(74, 3), r(1))]

# Маршевая тема лютни — волевая, с подъёмом на си♭.
let MARCH: Motif = @[
  bar(n(62, 0.5), n(64, 0.5), n(65, 1), n(69, 1), n(67, 1)),
  bar(n(65, 0.5), n(64, 0.5), n(62, 1), n(60, 2)),
  bar(n(69, 0.5), n(70, 0.5), n(72, 1), n(70, 1), n(69, 1)),
  bar(n(65, 2), n(64, 1), n(62, 1))]

# Разгон волынки: ровные восьмые, «топающий» ход — характeр атаки.
let CHARGE_8: Motif = @[
  bar(n(62, 0.5), n(62, 0.5), n(65, 0.5), n(64, 0.5), n(62, 0.5), n(60, 0.5), n(62, 1)),
  bar(n(67, 0.5), n(65, 0.5), n(64, 0.5), n(62, 0.5), n(60, 0.5), n(62, 0.5), n(64, 1)),
  bar(n(69, 0.5), n(70, 0.5), n(69, 0.5), n(67, 0.5), n(65, 0.5), n(64, 0.5), n(65, 1)),
  bar(n(62, 0.5), n(64, 0.5), n(62, 0.5), n(60, 0.5), n(58, 0.5), n(60, 0.5), n(62, 1))]

# Шестнадцатые — «ускорение»: та же тема мельче, ощущение разгона.
let CHARGE_16: Motif = @[
  bar(n(62, 0.25), n(62, 0.25), n(65, 0.25), n(64, 0.25), n(62, 0.25), n(60, 0.25),
      n(62, 0.25), n(64, 0.25), n(65, 0.5), n(64, 0.5), n(62, 1)),
  bar(n(67, 0.25), n(65, 0.25), n(64, 0.25), n(62, 0.25), n(60, 0.25), n(62, 0.25),
      n(64, 0.25), n(65, 0.25), n(67, 0.5), n(65, 0.5), n(64, 1)),
  bar(n(69, 0.25), n(70, 0.25), n(69, 0.25), n(67, 0.25), n(65, 0.25), n(64, 0.25),
      n(65, 0.25), n(67, 0.25), n(69, 0.5), n(70, 0.5), n(69, 1)),
  bar(n(62, 0.25), n(64, 0.25), n(62, 0.25), n(60, 0.25), n(58, 0.25), n(60, 0.25),
      n(62, 0.25), n(64, 0.25), n(62, 0.5), n(60, 0.5), n(62, 1))]

# Плач — высокий, на разрыв.
let LAMENT: Motif = @[
  bar(n(74, 2), n(72, 2)),
  bar(n(70, 2), n(69, 2)),
  bar(n(67, 2), n(69, 2)),
  bar(n(65, 3), r(1)),
  bar(n(74, 2), n(77, 2)),
  bar(n(76, 2), n(74, 2)),
  bar(n(72, 2), n(70, 2)),
  bar(n(69, 3), r(1))]

# Финал: хорал-эпилог.
let FINALE: Motif = @[
  bar(n(62, 4)),
  bar(n(69, 2), n(67, 2)),
  bar(n(65, 2), n(64, 2)),
  bar(n(62, 4))]

let CADENCE: Motif = @[
  bar(n(81, 2), n(79, 2)),
  bar(n(77, 2), n(76, 2)),
  bar(n(74, 2), n(72, 2)),
  bar(n(74, 3), r(1))]

proc genOrgan(): Part =
  ## Соборный орган: бурдон (органум) в рассвете, полные аккорды и педаль
  ## в остальном.
  result = part("choir")
  for b in 1 .. BARS:
    let tones = chordAt(b)
    let sec = sectionOf(b)
    var notes: seq[int]
    if sec == "dawn":
      notes = @[tones[0], tones[2]]
    else:
      notes = tones
    if sec in ["march", "charge", "finale"]:
      notes.insert(tones[0] - 12, 0)
    result.add bar(velAt(b, 74), ch(notes, 4))


proc genPiano(): Part =
  result = part("harp")
  for b in 1 .. BARS:
    let tones = chordAt(b)
    let sec = sectionOf(b)
    let pool = tones & @[tones[0] + 12]
    var evs: seq[NoteEvent]
    if sec == "dawn":
      if b < 5:
        result.add bar(velAt(b, 70), r(4))
        continue
      for k in [0, 1, 2, 3]: evs.add ch(@[pool[k]], 1)
    elif sec == "lament":
      for k in [3, 2, 1, 0]: evs.add ch(@[pool[k]], 1)
    else:
      for k in [0, 1, 2, 3, 2, 1, 0, 2]: evs.add ch(@[pool[k]], 0.5)
    result.add bar(velAt(b, 80), evs)

proc genGuitar(): Part =
  result = part("lute")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    let tones = chordAt(b)
    if sec == "dawn":
      result.add bar(velAt(b, 92), r(4))
    elif sec == "march":
      result.add MARCH[(b - sectionStart("march")) mod MARCH.len].sameVel(velAt(b, 102))
    elif sec == "charge":
      var evs: seq[NoteEvent]
      for _ in 0 ..< 8: evs.add ch(@[tones[0], tones[2]], 0.5)
      result.add bar(velAt(b, 104), evs)
    elif sec == "lament":
      result.add bar(velAt(b, 90), r(4))
    else:
      result.add FINALE[(b - sectionStart("finale")) mod FINALE.len].sameVel(velAt(b, 100))

proc genFlute(): Part =
  result = part("flute")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    if sec == "dawn":
      result.add FLUTE_CALL[(b - 1) mod FLUTE_CALL.len].sameVel(velAt(b, 96))
    elif sec == "lament":
      result.add LAMENT[(b - sectionStart("lament")) mod LAMENT.len].sameVel(velAt(b, 98))
    elif sec == "finale":
      let k = b - sectionStart("finale")
      if k < FLUTE_CALL.len:
        result.add FLUTE_CALL[k].sameVel(velAt(b, 100))
      elif k == FLUTE_CALL.len:
        result.add CADENCE[0].sameVel(velAt(b, 100))
      else:
        result.add bar(velAt(b, 96), r(4))
    else:
      result.add bar(velAt(b, 90), r(4))

proc genBagpipe(): Part =
  result = part("pipes")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    if sec == "charge":
      let k = b - sectionStart("charge")
      if k < 8:
        result.add CHARGE_8[k mod CHARGE_8.len].sameVel(velAt(b, 104))
      elif k < 14:
        result.add CHARGE_8[k mod CHARGE_8.len].sameVel(velAt(b, 108))
      else:
        result.add CHARGE_16[k mod CHARGE_16.len].sameVel(velAt(b, 110))
    elif sec == "finale":
      result.add FINALE[(b - sectionStart("finale")) mod FINALE.len].sameVel(velAt(b, 102))
    else:
      result.add bar(velAt(b, 90), r(4))

proc genStrings(): Part =
  ## Струнный фундамент: длинные педали низких струн под гармонию.
  ## Тембр — регистром: в плаче низкие «виолончельные» ноты, в марше/финале
  ## добавляется октавный удвоитель.
  result = part("cello")
  for b in 1 .. BARS:
    let tones = chordAt(b)
    let sec = sectionOf(b)
    if sec == "dawn":
      result.add bar(velAt(b, 58), n(tones[0] - 12, 4))
    elif sec == "lament":
      result.add bar(velAt(b, 62), ch(@[tones[0] - 12, tones[2]], 4))
    else:
      result.add bar(velAt(b, 68), ch(@[tones[0] - 12, tones[0]], 4))

proc genBell(): Part =
  ## Колокол — редкие удары-«метки» по краям разделов, атмосфера собора.
  result = part("bell")
  for b in 1 .. BARS:
    var hit = false
    var tone = chordAt(b)[0] + 12
    if b == 1:
      hit = true
    elif b == sectionStart("lament"):
      hit = true
    elif b == sectionStart("finale"):
      hit = true
    elif b == BARS:
      hit = true
    if hit:
      result.add bar(100, n(tone, 4))
    else:
      result.add bar(80, r(4))

proc genDrums(): Part =
  result = part("war")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    if sec == "dawn":
      result.add bar(velAt(b, 80), r(4))
    elif sec == "march":
      var evs: seq[NoteEvent]
      let pat = @[@[36], @[41], @[36, 45], @[41], @[36], @[41], @[36, 45], @[41]]
      for k, nt in pat:
        if b mod 4 == 0 and k >= 6:
          evs.add n(38, 0.5)
        elif b == sectionStart("march") and k == 0:
          evs.add ch(@[36, 49], 0.5)
        else:
          evs.add ch(nt, 0.5)
      result.add bar(velAt(b, 100), evs)
    elif sec == "charge":
      let k = b - sectionStart("charge")
      var evs: seq[NoteEvent]
      if k < 8:                       # четверти-томы
        for nt in [@[36], @[41], @[36, 45], @[41]]: evs.add ch(nt, 1)
      elif k < 14:                    # восьмые «галоп»
        for nt in [@[36], @[41], @[36], @[41], @[36, 45], @[41], @[36], @[41]]:
          evs.add ch(nt, 0.5)
      else:                           # шестнадцатые — «ускорение»
        for i in 0 ..< 16:
          let nt = if i mod 4 == 0: @[36] elif i mod 4 == 2: @[38] else: @[41]
          evs.add ch(nt, 0.25)
      if b == sectionStart("charge"): evs[0] = ch(@[36, 49], evs[0].beats)
      result.add bar(velAt(b, 106), evs)
    elif sec == "lament":
      if b mod 2 == 0:
        var evs: seq[NoteEvent]
        for nt in [@[36], @[41], @[36], @[41]]: evs.add ch(nt, 1)
        result.add bar(velAt(b, 78), evs)
      else:
        result.add bar(velAt(b, 78), r(4))
    else:  # finale
      if b == sectionStart("finale"):
        result.add bar(velAt(b, 108), ch(@[36, 49], 0.5), ch(@[36], 0.5),
                       n(38, 1), ch(@[42], 1), ch(@[42], 1))
      elif b == BARS:
        result.add bar(velAt(b, 112), ch(@[36, 49], 4))
      else:
        var evs: seq[NoteEvent]
        for nt in [@[36, 42], @[42], @[38, 42], @[42], @[36, 42], @[42], @[38, 42], @[46]]:
          evs.add ch(nt, 0.5)
        result.add bar(velAt(b, 104), evs)

proc main() =
  let here = parentDir(currentSourcePath())
  var arr = arrangement("Cathedral of Ash", tempo = 100.0f32)
  # Восемь партий в сумме дают запас меньше нуля: держим -8 dB на мастере,
  # чтобы клиппинга не было даже в кульминации (проверяет инспектор #290).
  arr.mixLevel = -8.0f32

  var organ = instrument("euterpia.organ", "Organ", "choir")
  organ.setParam("level", -6.0f32)
  organ.setParam("bars", 0.62f32)
  arr.add(organ, genOrgan())

  var piano = instrument("euterpia.piano", "Piano", "harp")
  piano.setParam("level", -5.0f32)
  piano.setParam("tone", 0.50f32)
  piano.setParam("pan", 0.20f32)
  arr.add(piano, genPiano())

  var guitar = instrument("euterpia.guitar", "Guitar", "lute")
  guitar.setParam("level", -4.0f32)
  guitar.setParam("tone", 0.62f32)
  guitar.setParam("pan", -0.20f32)
  arr.add(guitar, genGuitar())

  var flute = instrument("euterpia.flute", "Flute", "flute")
  flute.setParam("level", -4.0f32)
  flute.setParam("breath", 0.35f32)
  flute.setParam("pan", 0.15f32)
  arr.add(flute, genFlute())

  var pipes = instrument("euterpia.bagpipe", "Bagpipe", "pipes")
  pipes.setParam("level", -7.0f32)
  pipes.setParam("drone", 0.32f32)
  pipes.setParam("droneFreq", 73.42f32)   # D2 — бурдон в тональности
  arr.add(pipes, genBagpipe())

  var drums = instrument("euterpia.drums", "Drums", "war")
  drums.setParam("level", -4.0f32)
  arr.add(drums, genDrums())

  var cello = instrument("euterpia.strings", "Cello", "cello")
  cello.setParam("level", -12.0f32)
  cello.setParam("tone", 0.42f32)        # тёмный «виолончельный» срез
  cello.setParam("vibrato", 8.0f32)
  cello.setParam("ensemble", 6.0f32)
  cello.setParam("pan", -0.10f32)
  arr.add(cello, genStrings())

  var bell = instrument("euterpia.bell", "Bell", "bell")
  bell.setParam("level", -10.0f32)
  bell.setParam("decay", 6.0f32)
  bell.setParam("pan", 0.25f32)
  arr.add(bell, genBell())

  arr.writeNotes(here)
  let proj = here / "ensemble.eut"
  arr.writeProject(proj)
  echo "wrote ", proj

  let rr = arr.render(here / "ensemble.wav")
  if rr.ok:
    echo "rendered ", rr.path, " (", rr.seconds, " s)"
  else:
    echo "render error: ", rr.error

when isMainModule:
  main()

