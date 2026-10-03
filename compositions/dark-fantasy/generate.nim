#!/usr/bin/env -S nim r
# compositions/dark-fantasy/generate.nim
#
# Генератор «Cathedral of Ash» на Nim через библиотеку `libs/compose`
# (issue #285, #295). Заменяет прежний скрипт: проект — это данные Core, и
# строить их тем же типом, что читает ядро, надёжнее, чем текстовым скриптом.
#
# Запуск:  nim r compositions/dark-fantasy/generate.nim
# Пишет:   guitar/piano/organ/drums.notes  (человекочитаемая нотация)
#          ensemble.eut                    (готовый проект для `euterpia render`)
#
# Форма (76 тактов 4/4 при 76 BPM ≈ 4:00), ре минор с модальными красками:
# Пролог → Марш → Плач → Катаклизм → Эпилог.

import std/[math, os]

import compose/score
import compose/song

const BARS = 76

# ---------------------------------------------------------------------------
# Гармония и форма
# ---------------------------------------------------------------------------

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
  of "prologue":  @["Dm", "Dm", "Bb", "Dm", "Dm", "C", "Dm", "Dm", "Bb", "F", "C", "Dm"]
  of "march":     @["Dm", "Bb", "C", "Dm", "Gm", "Bb", "C", "A"]
  of "lament":    @["Bb", "F", "Gm", "Dm", "Bb", "C", "Dm", "Am"]
  of "cataclysm": @["Dm", "Gm", "Bb", "C", "Dm", "Eb", "Gm", "A"]
  of "epilogue":  @["Dm", "Bb", "Gm", "Dm", "Bb", "C", "Dm", "Dm"]
  else: @["Dm"]

const SECTIONS = [("prologue", 1, 12), ("march", 13, 32), ("lament", 33, 48),
                  ("cataclysm", 49, 64), ("epilogue", 65, 76)]

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

proc chordAt(b: int): seq[int] =
  chord(chordNameAt(b))

# Динамика: пролог тихо, катаклизм — кульминация, эпилог затухает.
proc dyn(section: string): float =
  case section
  of "prologue": 0.80
  of "march": 1.00
  of "lament": 0.85
  of "cataclysm": 1.15
  of "epilogue": 0.75
  else: 1.0

proc velAt(b, base: int): int =
  max(1, min(127, int(round(float(base) * dyn(sectionOf(b))))))

# ---------------------------------------------------------------------------
# Мотивы (MIDI: d4=62, e4=64, f4=65, g4=67, a4=69, bb4=70, c5=72, d5=74,
# eb5=75, e5=76, f5=77, g5=79, a5=81)
# ---------------------------------------------------------------------------

let CHANT: Motif = @[
  bar(n(62, 4)),
  bar(n(65, 2), n(64, 2)),
  bar(n(62, 4)),
  bar(n(60, 4)),
  bar(n(62, 2), n(65, 2)),
  bar(n(67, 4)),
  bar(n(65, 2), n(64, 2)),
  bar(n(62, 4)),
  bar(n(69, 4)),
  bar(n(67, 2), n(65, 2)),
  bar(n(64, 4)),
  bar(n(62, 4))]

let MARCH: Motif = @[
  bar(n(62, 0.75), n(64, 0.25), n(65, 1), n(69, 1), n(67, 1)),
  bar(n(65, 0.75), n(64, 0.25), n(62, 1), n(60, 2)),
  bar(n(69, 0.75), n(70, 0.25), n(72, 1), n(70, 1), n(69, 1)),
  bar(n(65, 2), n(64, 1), n(62, 1))]

let LAMENT: Motif = @[
  bar(n(74, 2), n(72, 2)),
  bar(n(70, 2), n(69, 2)),
  bar(n(67, 2), n(69, 2)),
  bar(n(65, 3), r(1)),
  bar(n(74, 2), n(77, 2)),
  bar(n(76, 2), n(74, 2)),
  bar(n(72, 2), n(70, 2)),
  bar(n(69, 3), r(1))]

let CADENCE: Motif = @[
  bar(n(81, 2), n(79, 2)),
  bar(n(77, 2), n(76, 2)),
  bar(n(74, 2), n(72, 2)),
  bar(n(74, 3), r(1))]

# ---------------------------------------------------------------------------
# Партии
# ---------------------------------------------------------------------------

proc genOrgan(): Part =
  ## Соборный орган: бурдон (органум-квинта) в прологе/эпилоге, полные
  ## аккорды и педаль в марше/катаклизме.
  result = part("choir")
  for b in 1 .. BARS:
    let tones = chordAt(b)
    let sec = sectionOf(b)
    var notes: seq[int]
    if sec == "prologue" or sec == "epilogue":
      notes = @[tones[0], tones[2]]
    else:
      notes = tones
    if sec == "march" or sec == "cataclysm":
      notes.insert(tones[0] - 12, 0)
    result.add bar(velAt(b, 74), ch(notes, 4))

proc genPiano(): Part =
  ## Пиано как арфа/колокольчики: разложенные аккорды по разделам.
  result = part("harp")
  for b in 1 .. BARS:
    let tones = chordAt(b)
    let sec = sectionOf(b)
    let pool = tones & @[tones[0] + 12]
    var evs: seq[NoteEvent]
    if sec == "prologue":
      if b < 5:
        result.add bar(velAt(b, 70), r(4))
        continue
      for k in [0, 1, 2, 3]:
        evs.add ch(@[pool[k]], 1)
    elif sec == "lament":
      for k in [3, 2, 1, 0]:
        evs.add ch(@[pool[k]], 1)
    elif sec == "cataclysm":
      for k in [0, 1, 2, 3, 2, 1, 0, 2]:
        evs.add ch(@[pool[k]], 0.5)
    elif sec == "epilogue":
      if b < 70:
        result.add bar(velAt(b, 70), r(4))
        continue
      evs.add ch(@[pool[0], pool[1], pool[2]], 4)
    else:  # march
      for k in [0, 1, 2, 3, 2, 1, 0, 2]:
        evs.add ch(@[pool[k]], 0.5)
    result.add bar(velAt(b, 80), evs)

proc genGuitar(): Part =
  ## Лютня: хорал → марш → плач → напев в верхней октаве (кульминация).
  result = part("lute")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    if sec == "prologue":
      result.add CHANT[b - 1].sameVel(velAt(b, 96))
    elif sec == "march":
      result.add MARCH[(b - sectionStart("march")) mod MARCH.len].sameVel(velAt(b, 102))
    elif sec == "lament":
      result.add LAMENT[(b - sectionStart("lament")) mod LAMENT.len].sameVel(velAt(b, 100))
    elif sec == "cataclysm":
      let k = b - sectionStart("cataclysm")
      if k < CHANT.len:
        # Развитие: хорал звучит октавой выше — регистровая вершина.
        result.add CHANT[k].transpose(12).sameVel(velAt(b, 110))
      else:
        result.add CADENCE[k - CHANT.len].sameVel(velAt(b, 108))
    else:  # epilogue
      let k = b - sectionStart("epilogue")
      if k < 4:
        result.add CHANT[k].sameVel(velAt(b, 90))
      else:
        result.add bar(velAt(b, 88), r(4))


proc genDrums(): Part =
  ## Боевые барабаны: тишина в прологе, томы в марше, «сердце» в плаче,
  ## татаны в катаклизме, удар-точка в эпилоге.
  let WAR = @[@[36], @[41], @[36, 45], @[41], @[36], @[41], @[36, 45], @[41]]
  let HEAVY = @[@[36, 49], @[36], @[36, 41], @[36, 45],
                @[36], @[36, 41], @[36], @[36, 45]]
  let HEART = @[@[36], @[41], @[36], @[41]]

  proc drumBar(notes: seq[seq[int]]; v: int; crashFirst: bool): Bar =
    var evs: seq[NoteEvent]
    for k, nt in notes:
      evs.add ch(if crashFirst and k == 0: @[36, 49] else: nt, 0.5)
    bar(v, evs)

  result = part("war")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    if sec == "prologue":
      if b == sectionStart("march") - 1:
        result.add bar(velAt(b, 92), ch(@[36, 41], 4))  # раскат в марш
      else:
        result.add bar(velAt(b, 80), r(4))
    elif sec == "march":
      var notes = WAR
      if b mod 4 == 0:  # филл в конце фразы
        notes = WAR[0 .. 5] & @[@[41], @[45]]
      result.add drumBar(notes, velAt(b, 100), b == sectionStart("march"))
    elif sec == "lament":
      if b mod 2 == 0:
        var evs: seq[NoteEvent]
        for nt in HEART:
          evs.add ch(nt, 1)
        result.add bar(velAt(b, 78), evs)
      else:
        result.add bar(velAt(b, 78), r(4))
    elif sec == "cataclysm":
      var notes = HEAVY
      if b mod 8 == 0:  # том-раскат раз в 8 тактов
        notes = HEAVY[0 .. 3] & @[@[45], @[41], @[45], @[41]]
      result.add drumBar(notes, velAt(b, 108), b == sectionStart("cataclysm"))
    else:  # epilogue
      if b == sectionStart("epilogue"):
        result.add bar(velAt(b, 95), ch(@[36, 49], 4))
      else:
        result.add bar(velAt(b, 80), r(4))

# ---------------------------------------------------------------------------
# Сборка проекта
# ---------------------------------------------------------------------------

proc main() =
  let here = parentDir(currentSourcePath())
  var arr = arrangement("Cathedral of Ash", tempo = 76.0f32)

  var guitar = instrument("euterpia.guitar", "Guitar", "lute")
  guitar.setParam("level", -4.0f32)
  guitar.setParam("tone", 0.60f32)
  guitar.setParam("pan", -0.20f32)
  arr.add(guitar, genGuitar())

  var piano = instrument("euterpia.piano", "Piano", "harp")
  piano.setParam("level", -5.0f32)
  piano.setParam("tone", 0.50f32)
  piano.setParam("pan", 0.22f32)
  arr.add(piano, genPiano())

  var organ = instrument("euterpia.organ", "Organ", "choir")
  organ.setParam("level", -5.0f32)
  organ.setParam("bars", 0.62f32)
  arr.add(organ, genOrgan())

  var drums = instrument("euterpia.drums", "Drums", "war")
  drums.setParam("level", -4.0f32)
  arr.add(drums, genDrums())

  arr.writeNotes(here)
  let proj = here / "ensemble.eut"
  arr.writeProject(proj)
  echo "wrote ", proj

when isMainModule:
  main()

