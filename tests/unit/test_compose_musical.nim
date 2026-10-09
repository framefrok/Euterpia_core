# tests/unit/test_compose_musical.nim
#
# Музыкальный фундамент Compose (Milestone 1): время, лады, аккорды, паттерны.
#
# Проверяется то, на чём держится вся выразительность «композиции как код»:
#   * время: DSL `4.bars`/`2.beats`, `barAt`/`beatAt`/`secondsAt`, перевод в
#     тики ядра тем же разрешением (`PpqTicksPerQuarter`) — чтобы клипы и
#     ноты совпадали с `score`/`song` (#COMPOSE-001);
#   * лады: ступени `degree(1..7)`, смена тональности без переписывания
#     мелодии, `contains` (#COMPOSE-005);
#   * аккорды: разбор `Am`/`G7`/`Cmaj7`, `notes()`, обращения, прогрессии
#     `chordAt`/`notesAt` (#COMPOSE-004);
#   * паттерны: `repeat`/`reverse`/`transpose`/`truncate`/`toMotif` и
#     детерминированный `humanize` (один seed — один результат) (#COMPOSE-003).

import std/unittest

import transport

import compose/time
import compose/scale
import compose/harmony
import compose/pattern
import compose/score

suite "Compose musical time (COMPOSE-001)":
  test "DSL длительностей":
    check 4.bars.totalBeats == 16.0
    check 8.bars.totalBeats(4.0) == 32.0
    check (2.beats).beats == 2.0
    check (4.bars + 2.beats).bars == 4
    check (4.bars + 2.beats).beats == 2.0
    check (16.bars - 4.bars).bars == 12

  test "тики считаются разрешением ядра":
    # 8 тактов 4/4 = 32 доли * PpqTicksPerQuarter — тот же масштаб, что в score
    check 8.bars.totalTicks == 32 * PpqTicksPerQuarter
    check (1.beat).totalTicks == PpqTicksPerQuarter

  test "позиции barAt/beatAt/beatsAt":
    check barAt(8).bars == 8
    check barAt(8).beats == 0.0
    check beatAt(10).bars == 2
    check beatAt(10).beats == 2.0
    check beatsAt(32).bars == 8

  test "secondsAt через арифметику ядра":
    # 9 секунд при 60 BPM = 9 четвертей = 2 такта + 1 доля
    let p = secondsAt(9.0, 60.0)
    check p.bars == 2
    check abs(p.beats - 1.0) < 0.01

  test "смещение позиции длительностью":
    let p = barAt(8) + 4.bars
    check p.bars == 12
    check p.beats == 0.0

  test "secondsOf обратное преобразование":
    # 4 такта 4/4 при 120 BPM = 16 долей = 8 секунд
    check abs(secondsOf(barAt(4), 120.0) - 8.0) < 0.01

suite "Compose scales (COMPOSE-005)":
  test "ступени натурального минора от A":
    let am = minorScale("A")
    check am.degree(1) == 69
    check am.degree(3) == 72
    check am.degree(5) == 76
    check am.degree(7) == 79
    check am.degree(8) == 81

  test "смена тональности не меняет структуру мелодии":
    let am = minorScale("A")
    let cm = minorScale("C")
    check am.degrees(@[1, 3, 5]) == @[69, 72, 76]
    check cm.degrees(@[1, 3, 5]) == @[60, 63, 67]

  test "разбор имён нот":
    check notePitch("C") == 60
    check notePitch("A") == 69
    check notePitch("C#") == 61
    check notePitch("Db") == 61
    check notePitch("Bb4") == 70
    check noteName(69) == "a4"

  test "принадлежность ладу":
    let am = minorScale("A")
    check am.contains(72)
    check not am.contains(73)

  test "размер ладов":
    check scaleSteps(skMajor).len == 7
    check scaleSteps(skPentatonic).len == 5
    check scaleSteps(skChromatic).len == 12

  test "транспозиция тональности":
    check minorScale("A").transpose(-2).degree(1) == 67

suite "Compose harmony (COMPOSE-004)":
  test "разбор обозначений аккордов":
    check chord("Am").quality == cqMinor
    check chord("Am").root == 69
    check chord("G7").quality == cqDominant7
    check chord("C").quality == cqMajor
    check chord("C").notes() == @[60, 64, 67]

  test "ноты аккордов":
    check chord("Am").notes() == @[69, 72, 76]
    check chord("G7").notes() == @[67, 71, 74, 77]
    check chord("Cmaj7").notes() == @[60, 64, 67, 71]

  test "обращения":
    let inv = chord(69, cqMinor, 1)
    check inv.notes()[0] == 72   # терция в басу

  test "аккордовые ступени":
    let am = chord("Am")
    check am.chordTone(1) == 69
    check am.chordTone(2) == 72
    check am.chordTone(3) == 76
    check am.contains(72)
    check not am.contains(73)

  test "прогрессии по тактам с зацикливанием":
    let p = progression(@["Am", "Em", "G", "G"])
    check p.chordAt(0).root == 69
    check p.chordAt(1).root == 64
    check p.chordAt(2).root == 67
    check p.chordAt(4).root == 69   # зацикливание
    check p.notesAt(0) == @[69, 72, 76]
    check p.rootAt(1) == 64
    check p.transpose(3).chordAt(0).root == 72

suite "Compose patterns (COMPOSE-003)":
  test "конструктор считает длину":
    let bass = pattern("bass", n(45, 0.5), r(0.5), n(45, 0.5), n(48, 0.5))
    check bass.events.len == 4
    check bass.lengthBeats == 2.0

  test "repeat разворачивает ноты (compile-time)":
    let bass = pattern("bass", n(45, 0.5), n(45, 0.5))
    let r4 = bass.repeat(4)
    check r4.events.len == 8
    check r4.lengthBeats == 4.0

  test "reverse/transpose/stretch/compress":
    let bass = pattern("bass", n(45, 0.5), r(0.5), n(45, 0.5), n(48, 0.5))
    check bass.reverse().events[0].pitches == @[48'u8]
    check bass.transpose(5).events[0].pitches == @[50'u8]
    check bass.stretch(2.0).lengthBeats == 4.0
    check bass.compress(2.0).lengthBeats == 1.0

  test "truncate/extend":
    let bass = pattern("bass", n(45, 0.5), r(0.5), n(45, 0.5), n(48, 0.5))
    check bass.truncate(1.0).lengthBeats == 1.0
    check bass.truncate(1.0).events.len == 2
    check bass.extend(4.0).lengthBeats == 4.0

  test "toMotif укладывает в такты":
    let bass = pattern("bass", n(45, 0.5), r(0.5), n(45, 0.5), n(48, 0.5))
    let m = bass.toMotif()
    check m.len == 1
    check m[0].events.len == 4

  test "humanize детерминирован по seed":
    let bass = pattern("bass", n(45, 0.25), n(45, 0.25), n(48, 0.25), n(48, 0.25))
    let h1 = bass.humanize(0.05, 8, 12345)
    let h2 = bass.humanize(0.05, 8, 12345)
    for i in 0 ..< h1.events.len:
      check abs(h1.events[i].beats - h2.events[i].beats) < 1e-9
