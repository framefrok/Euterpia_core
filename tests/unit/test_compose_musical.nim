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
import compose/form
import compose/melody
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

suite "Compose song form (COMPOSE-002)":
  test "секции выстраиваются подряд без ручного счёта тактов":
    var song = composition("Dark Trap", 96.0)
    discard song.section("intro", 8.bars)
    discard song.section("verse", 16.bars)
    discard song.section("chorus", 8.bars)
    discard song.section("drop", 4.bars)
    check song.sections[0].startBar == 0
    check song.sections[1].startBar == 8
    check song.sections[2].startBar == 24
    check song.sections[3].startBar == 32
    check song.endBar == 36

  test "роли определяются по имени":
    var song = composition("X")
    discard song.section("intro", 4.bars)
    discard song.section("verse", 4.bars)
    discard song.section("chorus", 4.bars)
    discard song.section("drop", 4.bars)
    check song.sections[0].kind == skIntro
    check song.sections[1].kind == skVerse
    check song.sections[2].kind == skChorus
    check song.sections[3].kind == skDrop

  test "поиск и адресация секций":
    var song = composition("X")
    discard song.section("intro", 8.bars)
    discard song.section("verse", 16.bars)
    check song.hasSection("verse")
    check not song.hasSection("typo")
    check song.find("verse").startBar == 8
    check song.find("typo").lengthBars == 0
    check song.sectionAt(0).kind == skIntro
    check song.sectionAt(10).kind == skVerse
    check song.sectionAt(40).lengthBars == 0

  test "длительность в секундах":
    var song = composition("X", 96.0)  # 36 тактов 4/4 при 96 = 90 сек
    discard song.section("a", 36.bars)
    check abs(song.lengthSeconds - 90.0) < 0.01

suite "Compose chord-aware melody (COMPOSE-006)":
  test "ноты согласованы с гармонией":
    let prog = progression(@["Am", "Em", "G", "G"])
    let am = minorScale("A")
    let m = melody("theme", chordTone(1), degree(3), passingTone(), chordTone(3))
    check m.steps.len == 4
    let evs = m.render(prog, am)
    check evs.len == 4
    check evs[0].pitches == @[69'u8]   # chordTone(1) на Am = A
    check evs[1].pitches == @[72'u8]   # degree(3) в A minor = C
    check evs[3].pitches == @[76'u8]   # chordTone(3) на Am = E (квинта)

  test "мелодия меняется вместе с аккордом":
    let prog = progression(@["Am", "Em", "G", "G"])
    let am = minorScale("A")
    let m = melody("m3", chordTone(1, 4.0), chordTone(1, 4.0))  # 2 такта
    let e = m.render(prog, am)
    check e[0].pitches == @[69'u8]   # Am (bar 0)
    check e[1].pitches == @[64'u8]   # Em (bar 1)

  test "пауза не даёт высоты":
    let prog = progression(@["Am", "Em", "G", "G"])
    let am = minorScale("A")
    let m = melody("m4", rest(1.0), chordTone(1))
    let e = m.render(prog, am)
    check e[0].pitches.len == 0

  test "мелодия как паттерн":
    let prog = progression(@["Am", "Em", "G", "G"])
    let am = minorScale("A")
    let m = melody("theme", chordTone(1), degree(3), chordTone(5))
    let p = m.toPattern(prog, am)
    check p.events.len == 3

import compose/arrangement
import compose/song

suite "Compose arrangement (COMPOSE-008, COMPOSE-024)":
  test "bell.play(theme).during(intro) компилируется в Part со стартом":
    var c = piece("Dark Trap", 96.0)
    discard c.section("intro", 8.bars)
    discard c.section("verse", 16.bars)
    discard c.section("chorus", 8.bars)

    let bellTheme = pattern("theme", n(76, 1.0), n(79, 1.0), n(81, 2.0))  # 4 доли/такт
    let bassPat = pattern("bass", n(45, 0.5), r(0.5), n(45, 0.5), n(48, 0.5))  # 2 доли/такт

    var bell = voice("bell", "euterpia.osc", "bell_notes")
    bell.play("theme", bellTheme).during("intro")
    var bass = voice("bass", "euterpia.osc", "bass_notes")
    bass.play("bassline", bassPat).during("verse", "chorus")
    c.add bell
    c.add bass

    check not c.isEmpty
    check bell.plays[0].sections == @["intro"]
    check bass.plays[0].sections == @["verse", "chorus"]

    let arr = c.toArrangement()
    check arr.name == "Dark Trap"
    check arr.tempo == 96.0
    check arr.entries.len == 2
    # Клип каждой дорожки покрывает всю форму (32 такта): молчащие секции —
    # паузы внутри клипа, поэтому ноты позже лежат внутри границ клипа и
    # `startTick` у них абсолютный (совпадает с build).
    check arr.entries[0].part.lengthTicks == 32 * 4 * 960
    check arr.entries[1].part.lengthTicks == 32 * 4 * 960

  test "пустая пьеса определяется как пустая":
    var c = piece("Empty")
    check c.isEmpty
    discard c.section("intro", 4.bars)
    check c.isEmpty  # есть секция, но нет голосов
    var v = voice("x", "t", "n")
    c.add v
    check not c.isEmpty

  test "неизвестная секция пропускается при резолве":
    var c = piece("X")
    discard c.section("intro", 4.bars)
    let pat = pattern("p", n(60, 4.0))
    var v = voice("x", "euterpia.osc", "n")
    v.play("p", pat).during("nonexistent")
    c.add v
    let arr = c.toArrangement()
    check arr.entries.len == 0  # нет валидных секций — нет дорожек

suite "Compose arrangement (COMPOSE-002/024)":
  test "партии раскладываются по секциям автоматически":
    var song = piece("Dark Trap", 96.0)
    discard song.section("intro", 8.bars)
    discard song.section("verse", 16.bars)
    discard song.section("chorus", 8.bars)
    let bell = pattern("bell", n(72, 1.0), n(76, 1.0))
    let bass = pattern("bass", n(45, 0.5), n(45, 0.5))
    discard song.play("bell", bell, roleLead).during("intro", "chorus")
    discard song.play("bass", bass, roleBass).during("verse")
    let notes = song.build()
    # bell: intro (bar 0) + chorus (bar 24)
    check song.find("intro").startBar == 0
    check song.find("chorus").startBar == 24
    # 1.5 такта на повтор * 4 повтора = 6 тактов в intro
    doAssert notes.len > 0, "arrangement не должен быть пустым"

  test "позиции нот в тиках корректны":
    var song = piece("X", 120.0)
    discard song.section("intro", 4.bars)
    discard song.section("verse", 4.bars)
    let p = pattern("p", n(60, 1.0))
    discard song.play("voice", p, roleLead).during("verse")  # старт на bar 4
    let notes = song.build()
    doAssert notes.len > 0
    # intro 4 такта пауз → первая нота verse на такте 4: 4 × 4 доли × 960
    check notes[0].startTick == 4 * 4 * 960
    check notes[0].pitch == 60'u8

  test "партия с гармонией через мелодию":
    var song = piece("X", 120.0)
    discard song.section("verse", 4.bars)
    let prog = progression(@["Am", "Em"])
    let am = minorScale("A")
    let m = melody("theme", chordTone(1), chordTone(3))
    discard song.play("melody", m, roleMelody).during("verse")
    discard song.harmony(prog, am)
    let notes = song.build()
    # Фраза из 2 нот повторяется в каждом из 4 тактов verse; каждая реплика
    # рендерится заново по аккорду своего такта (Am → Em → Am → Em).
    doAssert notes.len == 8
    check notes[0].pitch == 69'u8   # A (Am root, такт 0)
    check notes[1].pitch == 76'u8   # E (Am 5th, такт 0)
    check notes[2].pitch == 64'u8   # E (Em root, такт 1)
