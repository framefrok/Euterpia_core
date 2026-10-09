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

import std/[unittest, strutils]

import transport
import sequencer
  # AutomationCurve — сверка ординалов с кривыми Compose (COMPOSE-011).

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
import compose/rhythm
import compose/random
import compose/generators/drums
import compose/validate
import compose/generators/bass
import compose/generators/melody as genMelody
import compose/automation

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

suite "Compose melody register and stacks (COMPOSE-006/017)":
  let prog4 = progression(@["Am", "Em", "G", "G"])
  let aMinor = minorScale("A")

  test "transpose сдвигает регистр, не меняя шаги":
    let m = melody("low", chordTone(1), chordTone(2)).transpose(-24)
    let e = m.render(prog4, aMinor)
    check e[0].pitches == @[45'u8]   # A2 вместо A4
    check e[1].pitches == @[48'u8]   # C3 (терция Am)

  test "stack даёт аккорд текущего такта":
    let pad = melody("pad", stack([1, 3, 5], 4.0))
    let e = pad.render(prog4, aMinor)
    check e.len == 1
    check e[0].pitches == @[69'u8, 72'u8, 76'u8]   # Am
    let e2 = pad.render(prog4, aMinor, startBar = 1)
    check e2[0].pitches == @[64'u8, 67'u8, 71'u8]  # Em

suite "Compose rhythm library (COMPOSE-016)":
  test "DSL сетки: удары, паузы, разделители":
    let r = rhythm("x . x . | . x . x")
    check r.steps.len == 8
    check r.hitCount == 4
    check r.length == 2.0          # 8 шагов × 0.25

  test "фигуры одного такта 4/4":
    check quarter().length == 4.0
    check eighth().length == 4.0
    check sixteenth().length == 4.0
    check dotted().length == 4.0
    check tresillo().length == 4.0
    check offbeat().length == 4.0
    check abs(triplet().length - 4.0) < 0.001
    check clave().length == 8.0    # два такта
    check tresillo().hitCount == 6

  test "rhythm → pattern: удары становятся нотами":
    let p = tresillo().toPattern(36)
    check p.lengthBeats == 4.0
    var sounded = 0
    for e in p.events:
      if e.pitches.len > 0:
        inc sounded
        check e.pitches == @[36'u8]
    check sounded == 6

  test "циклический сдвиг сетки":
    let r = rhythm("x . . x", 1.0)
    check r.transposeSteps(1).hits == @[false, false, true, true]

suite "Compose deterministic random (COMPOSE-015)":
  test "один seed — одна последовательность":
    var a = musicRandom(12345)
    var b = musicRandom(12345)
    for _ in 0 ..< 32:
      check a.nextFloat() == b.nextFloat()
      check a.randInt(0, 100) == b.randInt(0, 100)

  test "другой seed — другая последовательность":
    var a = musicRandom(1)
    var b = musicRandom(2)
    var differs = false
    for _ in 0 ..< 8:
      if a.nextFloat() != b.nextFloat():
        differs = true
    check differs

  test "randomVelocity в легальном диапазоне":
    var rng = musicRandom(7)
    for _ in 0 ..< 200:
      let v = rng.randomVelocity(100, 30)
      check v >= 1 and v <= 127

  test "shuffle детерминирован":
    var a = musicRandom(9)
    var b = musicRandom(9)
    var xs = @[1, 2, 3, 4, 5, 6, 7, 8]
    var ys = xs
    a.shuffle(xs)
    b.shuffle(ys)
    check xs == ys
    check xs.len == 8

suite "Compose groove and layers (COMPOSE-014)":
  test "swing сдвигает слабые восьмые":
    let p = eighth().toPattern(60)
    let s = p.swing(1.0'f32)
    # Слабая восьмая встала на 2/3 доли: первая восьмая растянулась до
    # ≈0.6667, вторая сжалась до ≈0.3333 (триольный feel).
    check abs(s.events[0].beats - 0.6667) < 0.01
    check abs(s.events[1].beats - 0.3333) < 0.01
    # Детерминированность и сохранность длины
    let s2 = p.swing(1.0'f32)
    check s.events[0].beats == s2.events[0].beats
    check abs(s.lengthBeats - p.lengthBeats) < 1e-9

  test "overlay склеивает одновременные ноты в аккорд":
    let kickP = rhythm("x . . .", 1.0).toPattern(36)
    let snareP = rhythm(". x . .", 1.0).toPattern(38)
    let kit = overlay([kickP, snareP])
    check kit.lengthBeats == 4.0
    var hitsAt: seq[float]
    var pos = 0.0
    for e in kit.events:
      if e.pitches.len > 0:
        hitsAt.add pos
        check e.pitches == (if pos < 0.5: @[36'u8] else: @[38'u8])
      pos += e.beats
    check hitsAt == @[0.0, 1.0]

  test "groove детерминирован по seed":
    let p = sixteenth().toPattern(42)
    let g1 = p.groove(0.54, seed = 42)
    let g2 = p.groove(0.54, seed = 42)
    for i in 0 ..< g1.events.len:
      check g1.events[i].beats == g2.events[i].beats

  test "concat: фигуры подряд, длина — сумма":
    let a = rhythm("x . . .", 1.0).toPattern(36)
    let b = rhythm(". x . .", 1.0).toPattern(38)
    let ab = a & b
    check ab.lengthBeats == 8.0
    check ab.events.len == a.events.len + b.events.len
    # 7 тактов кита + 1 такт филла = 8 тактов одной партии
    check (trapKit(7).repeat(7) & fill(9)).lengthBeats == 32.0

suite "Compose drums generators (COMPOSE-019)":
  test "бэкбит: два удара на 2 и 4":
    let s = backbeatSnare()
    check s.lengthBeats == 4.0
    var pos = 0.0
    var hits: seq[float]
    for e in s.events:
      if e.pitches.len > 0:
        hits.add pos
        check e.pitches == @[38'u8]
      pos += e.beats
    check hits == @[1.0, 3.0]

  test "trapKit — кит из трёх слоёв, длина такта":
    let kit = trapKit(7)
    check kit.lengthBeats == 4.0
    var sounded = 0
    for e in kit.events:
      if e.pitches.len > 0:
        inc sounded
    check sounded > 0

  test "fill детерминирован по seed и меняется с seed":
    let f1 = fill(42)
    let f2 = fill(42)
    let f3 = fill(43)
    check f1.events.len == f2.events.len
    var same = true
    for i in 0 ..< f1.events.len:
      if f1.events[i].pitches != f2.events[i].pitches:
        same = false
    check same
    var diff = false
    for i in 0 ..< min(f1.events.len, f3.events.len):
      if f1.events[i].pitches != f3.events[i].pitches:
        diff = true
    check diff

  test "rollTo поднимает высоты":
    let rt = rollTo(36, 48, 8)
    check rt.events.len == 8
    check rt.events[0].pitches == @[36'u8]
    check rt.events[^1].pitches == @[48'u8]

suite "Compose determinism (COMPOSE-041)":
  test "build воспроизводим: две сборки — идентичные ноты":
    proc makeSong(): Piece =
      var s = piece("Determinism", 140.0)
      discard s.section("intro", 4.bars)
      discard s.section("verse", 8.bars)
      discard s.harmony(progression(@["Am", "F"]), minorScale("A"))
      let kit = trapKit(7).humanize(0.01, 8, 99)
      discard s.play("drums", kit, roleDrums, nodeType = "euterpia.drums").during("verse")
      let bass = melody("b", chordTone(1, 2.0), rest(2.0)).transpose(-24)
      discard s.play("bass", bass, roleBass).during("intro", "verse")
      s
    let a = makeSong().build()
    let b = makeSong().build()
    check a.len == b.len
    check a.len > 0
    for i in 0 ..< a.len:
      check a[i].startTick == b[i].startTick
      check a[i].pitch == b[i].pitch
      check a[i].velocity == b[i].velocity
      check a[i].duration == b[i].duration
      check a[i].channel == b[i].channel

suite "Compose musical validator (COMPOSE-029)":
  test "пустая форма — ошибка":
    let s = piece("X", 120.0)
    check hasErrors(validate(s))

  test "корректная пьеса — ни ошибок, ни предупреждений":
    var s = piece("X", 120.0)
    discard s.section("intro", 4.bars)
    discard s.harmony(progression(@["Am"]), minorScale("A"))
    let m = melody("m", chordTone(1, 4.0))
    discard s.play("bell", m, roleLead).during("intro")
    check validate(s).len == 0

  test "мелодия без гармонии — предупреждение, не ошибка":
    var s = piece("X", 120.0)
    discard s.section("intro", 4.bars)
    let m = melody("m", chordTone(1, 4.0))
    discard s.play("bell", m, roleLead).during("intro")
    let pr = validate(s)
    check not hasErrors(pr)
    var found = false
    for p in pr:
      if p.find("гармони") >= 0:
        found = true
    check found

  test "размещение в несуществующей секции — ошибка":
    var s = piece("X", 120.0)
    discard s.section("intro", 4.bars)
    let pat = pattern("p", n(60, 4.0))
    discard s.play("x", pat, roleLead).during("typo")
    check hasErrors(validate(s))

  test "дубли имён дорожек — ошибка":
    var s = piece("X", 120.0)
    discard s.section("intro", 4.bars)
    let pat = pattern("p", n(60, 4.0))
    var v1 = voice("a", "euterpia.osc", "n1")
    v1.play("p", pat).during("intro")
    var v2 = voice("a", "euterpia.osc", "n2")
    v2.play("p", pat).during("intro")
    s.add v1
    s.add v2
    check hasErrors(validate(s))

  test "пустое размещение — ошибка":
    var s = piece("X", 120.0)
    discard s.section("intro", 4.bars)
    var v = voice("a", "euterpia.osc", "n1")
    v.plays.add Play(partName: "empty")     # ни паттерна, ни мелодии
    v.plays[0].sections = @["intro"]
    s.add v
    check hasErrors(validate(s))

suite "Compose bass generators (COMPOSE-017)":
  let prog = progression(@["Am", "F"])
  let key = minorScale("A")

  test "root-бас: корень аккорда, транспонированный вниз":
    let e = bassLine(bsRoot).transpose(-24).render(prog, key)
    check e.len == 2
    check e[0].pitches == @[45'u8]      # A2 (Am)
    check e[1].pitches.len == 0         # дыхание в конце такта
    # второй такт — корень следующего аккорда прогрессии:
    let e2 = melody("r", chordTone(1, 4.0)).transpose(-24).render(
      prog, key, startBar = 1)
    check e2[0].pitches == @[41'u8]     # F2 (F)

  test "octave-бас: корень и октава":
    let e = bassLine(bsOctave).transpose(-24).render(prog, key)
    check e[0].pitches == @[45'u8]
    check e[1].pitches == @[57'u8]   # A2 + октава

  test "walking-бас идёт по аккордовым тонам":
    let e = bassLine(bsWalking).render(prog, key)
    check e.len == 4
    check e[0].pitches == @[69'u8]   # корень Am
    check e[1].pitches == @[72'u8]   # терция Am

  test "pedal-бас держит тонику лада, а не аккорд":
    let e = bassLine(bsPedal).render(prog, key)
    check e.len == 1
    check e[0].pitches == @[69'u8]   # A, хотя прогрессия начинается с Am
    check e[0].beats == 4.0

  test "doubledBass даёт пару нота + октава":
    let e = doubledBass(bassLine(bsRoot)).render(prog, key)
    check e[0].pitches == @[69'u8, 81'u8]

suite "Compose melody generator (COMPOSE-018)":
  let prog = progression(@["Am", "F", "C", "G"])
  let key = minorScale("A")

  test "один seed — одна мелодия":
    let a = generateMelody(prog, key, seed = 42, bars = 2)
    let b = generateMelody(prog, key, seed = 42, bars = 2)
    check a.steps.len == b.steps.len
    var same = true
    for i in 0 ..< a.steps.len:
      if a.steps[i].tone != b.steps[i].tone: same = false
      if a.steps[i].beats != b.steps[i].beats: same = false
      if a.steps[i].degree != b.steps[i].degree: same = false
      if a.steps[i].chordDegree != b.steps[i].chordDegree: same = false
    check same

  test "разные seed — разные мелодии":
    let a = generateMelody(prog, key, seed = 1, bars = 4)
    let b = generateMelody(prog, key, seed = 2, bars = 4)
    var diff = false
    for i in 0 ..< min(a.steps.len, b.steps.len):
      if a.steps[i].tone != b.steps[i].tone:
        diff = true
    check diff

  test "коридор удерживает регистр":
    let m = generateMelody(prog, key, seed = 7, bars = 2, center = 72, range = 5)
    let e = m.render(prog, key)
    check e.len == m.steps.len
    for ev in e:
      for p in ev.pitches:
        check p >= 72 - 5 and p <= 72 + 5

  test "density 0 — одни паузы":
    let m = generateMelody(prog, key, seed = 3, bars = 1, density = 0.0)
    for s in m.steps:
      check s.tone == mtRest

  test "respond зеркалит вторую половину шагов":
    let m = melody("m", chordTone(1), chordTone(2), chordTone(3), degree(1))
    let r = respond(m)
    check r.steps.len == 4
    check r.steps[0].chordDegree == 1
    check r.steps[1].chordDegree == 2
    check r.steps[2].tone == mtDegree   # последний шаг вызова — первым в ответе
    check r.steps[3].chordDegree == 3

suite "Compose automation and production (COMPOSE-011/012)":
  test "кривые Compose совпадают с AutomationCurve ядра":
    check ord(curveLinear) == ord(AutomationCurve.acLinear)
    check ord(curveStep) == ord(AutomationCurve.acStep)
    check ord(curveSmooth) == ord(AutomationCurve.acSmooth)
    check ord(curveBezier) == ord(AutomationCurve.acBezier)

  test "цепочка точек и длина дорожки":
    var lane = autom("bass", "level", 0.0, -40.0)
    lane.at(8.0, -8.0, curveSmooth)
    check lane.points.len == 2
    check lane.lengthBars == 8.0
    check lane.points[1].curve == curveSmooth

  test "ramp длиной в музыкальных длительностях":
    let lane = ramp("pad", "level", 4.0, 4.bars, -40.0, -6.0)
    check lane.points.len == 2
    check lane.points[0].bar == 4.0
    check lane.points[1].bar == 8.0    # 4 такта после начала

  test "дорожка компилируется в проект: nodeId, тики, кривые":
    var s = piece("A", 120.0)
    discard s.section("intro", 4.bars)
    discard s.harmony(progression(@["Am"]), minorScale("A"))
    let m = melody("m", chordTone(1, 4.0))
    discard s.play("bell", m, roleLead, nodeType = "euterpia.bell").during("intro")
    discard s.automate(ramp("bell", "level", 0.0, 4.0, -40.0, -6.0, curveSmooth))
    let arr = s.toArrangement()
    check validate(arr).len == 0
    let proj = buildProject(arr)
    check proj.sequencer.automationLanes.len == 1
    let lane = proj.sequencer.automationLanes[0]
    check lane.nodeId == 2                       # нода инструмента первого голоса
    check lane.points.len == 2
    check lane.points[0].tick == 0
    check lane.points[1].tick == 4 * 4 * 960     # четвёртый такт (4/4)
    check lane.points[0].value == -40.0
    check lane.points[1].curve == ord(curveSmooth)

  test "неизвестная дорожка/параметр — ошибка валидатора, не молчание":
    var s = piece("A", 120.0)
    discard s.section("intro", 4.bars)
    discard s.play("bell", pattern("p", n(60, 4.0)), roleLead,
                   nodeType = "euterpia.bell").during("intro")
    discard s.automate(autom("nosuch", "level", 0.0, -6.0))
    check hasErrors(validate(s))
    let arr = s.toArrangement()
    check hasErrors(validate(arr))

  test "@mix адресует сумматор":
    var s = piece("A", 120.0)
    discard s.section("intro", 4.bars)
    discard s.play("bell", pattern("p", n(60, 4.0)), roleLead,
                   nodeType = "euterpia.bell").during("intro")
    discard s.automate(ramp(MixTrack, "level", 0.0, 4.0, -6.0, -3.0))
    let arr = s.toArrangement()
    check validate(arr).len == 0
    let proj = buildProject(arr)
    check proj.sequencer.automationLanes.len == 1
    check proj.sequencer.automationLanes[0].nodeId == 3   # mixId = 1 + 2*1

  test "mute/unmute/solo управляют дорожками":
    var s = piece("A", 120.0)
    discard s.section("v", 4.bars)
    discard s.play("a", pattern("pa", n(60, 4.0)), roleLead,
                   nodeType = "euterpia.piano").during("v")
    discard s.play("b", pattern("pb", n(64, 4.0)), roleBass,
                   nodeType = "euterpia.piano").during("v")
    discard s.mute("b")
    let arr = s.toArrangement()
    check arr.entries.len == 2
    check not arr.entries[0].mute
    check arr.entries[1].mute
    check buildProject(arr).sequencer.tracks[1].mute
    discard s.unmute("b")
    check not s.toArrangement().entries[1].mute
    discard s.solo("a")
    let arr2 = s.toArrangement()
    check not arr2.entries[0].mute
    check arr2.entries[1].mute

  test "gain/pan задают параметры ноды (и проверяются)":
    var s = piece("A", 120.0)
    discard s.section("v", 4.bars)
    discard s.play("a", pattern("pa", n(60, 4.0)), roleLead,
                   nodeType = "euterpia.piano").during("v")
    discard s.gain("a", -9.0f32)
    discard s.pan("a", 0.5f32)
    let arr = s.toArrangement()
    check arr.entries[0].inst.params.len == 2
    check validate(arr).len == 0
