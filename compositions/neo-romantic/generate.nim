#!/usr/bin/env -S nim r
# compositions/neo-romantic/generate.nim
#
# Генератор «Neo-Romantic Ensemble» на Nim через библиотеку `libs/compose`
# (#285). Заменяет прежний текстовый скрипт: форма и мотивы — типы Nim,
# проект собирается тем же кодом, что читает ядро.
#
# Запуск:  nim r compositions/neo-romantic/generate.nim
# Пишет:   guitar/piano/organ/drums.notes и ensemble.eut
#
# 64 такта 4/4 при 92 BPM (~2:48), ля минор с модальными отклонениями:
# интро → A → B → A′ → кода.

import std/[math, os]

import compose/score
import compose/song
import compose/engine

const BARS = 64

# ---------------------------------------------------------------------------
# Гармония и форма
# ---------------------------------------------------------------------------

proc chord(name: string): seq[int] =
  case name
  of "Am": @[57, 60, 64]
  of "F":  @[53, 57, 60]
  of "C":  @[60, 64, 67]
  of "G":  @[55, 59, 62]
  of "Dm": @[62, 65, 69]
  of "Bb": @[58, 62, 65]
  of "E":  @[52, 56, 59]
  else: @[57, 60, 64]

proc progression(section: string): seq[string] =
  case section
  of "intro", "A": @["Am", "F", "C", "G"]
  of "B":          @["Dm", "Bb", "F", "C"]
  of "A2":         @["Am", "F", "Dm", "E"]
  of "coda":       @["F", "G", "Am", "Am"]
  else: @["Am", "F", "C", "G"]

const SECTIONS = [("intro", 1, 8), ("A", 9, 24), ("B", 25, 40),
                  ("A2", 41, 56), ("coda", 57, 64)]

proc sectionOf(b: int): string =
  for s in SECTIONS:
    if b >= s[1] and b <= s[2]:
      return s[0]
  "A"

proc sectionStart(name: string): int =
  for s in SECTIONS:
    if s[0] == name:
      return s[1]
  1

proc chordAt(b: int): seq[int] =
  let s = sectionOf(b)
  let p = progression(s)
  chord(p[(b - sectionStart(s)) mod p.len])

proc dyn(section: string): float =
  case section
  of "intro": 0.78
  of "A": 1.00
  of "B": 0.94
  of "A2": 1.10
  of "coda": 0.82
  else: 1.0

proc velAt(b, base: int): int =
  max(1, min(127, int(round(float(base) * dyn(sectionOf(b))))))

# ---------------------------------------------------------------------------
# Мотивы (ля минор)
# ---------------------------------------------------------------------------

let MELODY: Motif = @[
  bar(n(64, 0.5), n(69, 0.5), n(72, 1), n(71, 0.5), n(69, 0.5), n(67, 1)),
  bar(n(65, 1), n(69, 0.5), n(67, 0.5), n(65, 0.5), n(64, 0.5), n(62, 1)),
  bar(n(64, 0.5), n(67, 0.5), n(64, 1), n(60, 1), n(64, 1)),
  bar(n(62, 2), n(67, 1), r(1)),
  bar(n(69, 1), n(72, 0.5), n(71, 0.5), n(69, 0.5), n(67, 0.5), n(69, 1)),
  bar(n(65, 0.5), n(69, 0.5), n(72, 2), n(71, 1)),
  bar(n(67, 0.5), n(64, 0.5), n(60, 0.5), n(64, 0.5), n(67, 1), n(64, 1)),
  bar(r(2), n(62, 1), n(64, 1)),
  bar(n(64, 0.5), n(69, 0.5), n(72, 1), n(74, 0.5), n(72, 0.5), n(71, 1)),
  bar(n(69, 1), n(67, 0.5), n(65, 0.5), n(64, 0.5), n(62, 0.5), n(64, 1)),
  bar(n(67, 0.5), n(72, 0.5), n(67, 1), n(64, 1), n(60, 1)),
  bar(n(62, 2), r(2)),
  bar(n(64, 1), n(69, 1), n(72, 0.5), n(71, 0.5), n(69, 0.5), n(67, 0.5)),
  bar(n(65, 0.5), n(69, 0.5), n(72, 1), n(69, 1), n(65, 1)),
  bar(n(67, 1), n(71, 1), n(74, 1), n(76, 1)),
  bar(n(69, 3), r(1))]

let B_MOTIF: Motif = @[
  bar(n(62, 2), n(65, 2)),
  bar(n(58, 4)),
  bar(n(65, 2), n(69, 2)),
  bar(n(67, 3), r(1))]

let CODA_LINE: Motif = @[
  bar(n(76, 2), n(74, 2)),
  bar(n(72, 1), n(69, 1), n(64, 2))]

# ---------------------------------------------------------------------------
# Партии
# ---------------------------------------------------------------------------

proc genOrgan(): Part =
  result = part("organ")
  for b in 1 .. BARS:
    result.add bar(velAt(b, 72), ch(chordAt(b), 4))

proc genPiano(): Part =
  result = part("piano")
  for b in 1 .. BARS:
    let tones = chordAt(b)
    let sec = sectionOf(b)
    if sec == "intro" and b <= 4:
      result.add bar(velAt(b, 80), r(4))
      continue
    let pool = tones & @[tones[0] + 12]
    var order: seq[int]
    if sec == "B":
      order = @[0, 1, 2, 3, 0, 1, 2, 3]     # восходящий разлив
    else:
      order = @[0, 1, 2, 3, 2, 1, 0, 2]     # «качели»
    var evs: seq[NoteEvent]
    for k in order:
      evs.add ch(@[pool[k]], 0.5)
    result.add bar(velAt(b, 80), evs)

proc genGuitar(): Part =
  result = part("guitar")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    if sec == "intro":
      result.add bar(velAt(b, 96), r(4))
    elif sec == "A":
      result.add MELODY[(b - sectionStart("A")) mod MELODY.len].sameVel(velAt(b, 100))
    elif sec == "A2":
      # Кульминация: тема на октаву выше.
      result.add MELODY[(b - sectionStart("A2")) mod MELODY.len].
        transpose(12).sameVel(velAt(b, 102))
    elif sec == "B":
      result.add B_MOTIF[(b - sectionStart("B")) mod B_MOTIF.len].sameVel(velAt(b, 92))
    else:  # coda
      let k = b - sectionStart("coda")
      if k < CODA_LINE.len:
        result.add CODA_LINE[k].sameVel(velAt(b, 92))
      else:
        result.add bar(velAt(b, 90), r(4))

proc genDrums(): Part =
  let HAT = @[@[36, 42], @[42], @[38, 42], @[42], @[36, 42], @[42], @[38, 42], @[42]]
  let RIDE = @[@[36, 51], @[42], @[38, 51], @[42], @[36, 51], @[42], @[38, 51], @[46]]
  let SPARSE: seq[seq[int]] = @[@[36], @[], @[42], @[], @[36], @[], @[42, 38], @[]]

  proc patternBar(notes: seq[seq[int]]; v: int; fill, crash: bool): Bar =
    var evs: seq[NoteEvent]
    for k, nt in notes:
      if k == 0 and crash:
        evs.add ch(@[36, 49], 0.5)
      elif fill and k >= 6:
        evs.add n(38, 0.5)     # филл малым в конце фразы
      elif nt.len == 0:
        evs.add r(0.5)
      else:
        evs.add ch(nt, 0.5)
    bar(v, evs)

  result = part("drums")
  for b in 1 .. BARS:
    let sec = sectionOf(b)
    if sec == "intro":
      result.add bar(velAt(b, 100), r(4))
    elif sec == "A":
      result.add patternBar(HAT, velAt(b, 100), b mod 4 == 0, false)
    elif sec == "B":
      result.add patternBar(RIDE, velAt(b, 100), b mod 4 == 0, b == sectionStart("B"))
    elif sec == "A2":
      result.add patternBar(RIDE, velAt(b, 100), b mod 4 == 0, b == sectionStart("A2"))
    else:  # coda
      if b == sectionStart("coda"):
        result.add bar(velAt(b, 100), ch(@[36, 49], 0.5), n(49, 0.5),
                       ch(@[42], 1), n(38, 1), ch(@[42], 1))
      elif b == BARS:
        result.add bar(velAt(b, 100), ch(@[36, 49], 4))
      else:
        result.add patternBar(SPARSE, velAt(b, 100), false, false)

# ---------------------------------------------------------------------------
# Сборка проекта
# ---------------------------------------------------------------------------

proc main() =
  let here = parentDir(currentSourcePath())
  var arr = arrangement("Neo-Romantic Ensemble", tempo = 92.0f32)

  var guitar = instrument("euterpia.guitar", "Guitar", "guitar")
  guitar.setParam("level", -2.0f32)
  guitar.setParam("tone", 0.62f32)
  guitar.setParam("pan", -0.15f32)
  arr.add(guitar, genGuitar())

  var piano = instrument("euterpia.piano", "Piano", "piano")
  piano.setParam("level", -3.0f32)
  piano.setParam("tone", 0.55f32)
  piano.setParam("pan", 0.15f32)
  arr.add(piano, genPiano())

  var organ = instrument("euterpia.organ", "Organ", "organ")
  organ.setParam("level", -4.0f32)
  organ.setParam("bars", 0.55f32)
  arr.add(organ, genOrgan())

  var drums = instrument("euterpia.drums", "Drums", "drums")
  drums.setParam("level", -3.0f32)
  arr.add(drums, genDrums())

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

