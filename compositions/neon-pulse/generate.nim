#!/usr/bin/env -S nim r
# compositions/neon-pulse/generate.nim
#
# «Neon Pulse» — современный тёмный трэп-бит (140 BPM, A minor), написанный
# библиотекой libs/compose. Вся пьеса — код: форма, гармония, паттерны,
# аккорд-осведомлённые бас/мелодия/арп, детерминированные филлы и
# гуманизация. Один запуск пишет всё разом:
#
#   *.notes, neon_pulse.eproj, neon_pulse.mid, neon_pulse.wav
#
# Запуск:  nim r compositions/neon-pulse/generate.nim
#
# Что демонстрирует (по issue roadmap):
#   COMPOSE-001 time      — 8.bars / 4.bars вместо подсчёта тактов
#   COMPOSE-002 form      — intro/verse/chorus/break/drop/outro подряд
#   COMPOSE-003 pattern   — repeat, humanize, overlay, concat (&)
#   COMPOSE-004/005       — прогрессия Am|F|C|G + лад A minor
#   COMPOSE-006 melody    — chordTone/degree/passing/stack поверх гармонии
#   COMPOSE-007 variation — вариант(1/4/5): кварта, инверсия, ретрофраза
#   COMPOSE-008/024       — piece → play/during → build/toArrangement → Core
#   COMPOSE-009 role      — roleDrums/roleBass/roleLead/…
#   COMPOSE-013           — hard cut: break без баса/ударных + ролл в дроп
#   COMPOSE-014/015       — humanize с seed, musicRandom — детерминизм
#   COMPOSE-016/019       — ритм-библиотека, trapKit/fill/rollTo
#   COMPOSE-033           — независимые вариации темы по секциям
#   COMPOSE-041           — один seed = один бит (см. тест детерминизма)

import std/[os, strutils]

import compose/compose
import compose/midi

const
  Seed = 12345
  BPM = 140.0

let here = parentDir(currentSourcePath())

# ============================================================================
# Форма: секции выстраиваются подряд, такты считает библиотека
# ============================================================================

var song = piece("Neon Pulse", BPM)
discard song.section("intro", 8.bars)
discard song.section("verse", 16.bars)
discard song.section("chorus", 8.bars)
discard song.section("break", 4.bars)     # хард-кат: ударных и баса нет
discard song.section("drop", 8.bars)
discard song.section("outro", 4.bars)

# ============================================================================
# Гармония и тональность — по ним рендерятся бас, пад, арп и колокол
# ============================================================================

let prog = progression(@["Am", "F", "C", "G"])   # короткий тёмный цикл
let key = minorScale("A")
discard song.harmony(prog, key)

# ============================================================================
# Партии: паттерны и мелодии (высоты считаются при компиляции)
# ============================================================================

# Тема колокола — двухтактовая фраза «вопрос–ответ» над прогрессией.
let theme = melody("neonTheme",
  # вопрос: тоника, квинта, терция текущего аккорда
  degree(1, 1.0), degree(5, 0.5), chordTone(2, 0.5), degree(5, 1.0), rest(1.0),
  # ответ: ступень лада → опора на корень аккорта
  degree(3, 0.5), degree(5, 0.5), chordTone(1, 1.0), rest(2.0))

# Бас «808»: корень аккорда каждым тактом, две октавы ниже — мелодия,
# отрендеренная поверх гармонии (никакого ручного пересчёта pitch).
let bass808 = melody("bass808",
  chordTone(1, 1.5), rest(0.5), chordTone(1, 1.0), rest(0.5),
  chordTone(1, 0.5)).transpose(-24)

# Пад: трезвучие текущего такта, само меняется вместе с прогрессией.
let pad = melody("neonPad", stack([1, 3, 5], 4.0))

# Арпеджио восьмыми по ступеням аккорда (октавой ниже колокола) — фигурой
# генератора баса: `bsArp` = вверх-вниз по аккордовым тонам (COMPOSE-017).
let arp = bassLine(bsArp).transpose(-12)

# Колокольные «метки» для break: корень аккорда на весь такт.
let bellHit = melody("bellHit", chordTone(1, 4.0))

# ============================================================================
# Ударные: киты, филлы, ролл — детерминированы по Seed
# ============================================================================

# Базовый такт: кик-фигура + бэкбит + шестнадцатые хэты, «оживлённые»
# детерминированной гуманизацией (один seed — один результат).
let kit = trapKit(Seed mod 997).humanize(0.01, 10, Seed)

# Intro: только восьмые хэты (лаконичный вход).
let introHats = hats(eighth()).humanize(0.012, 8, Seed + 1)

# Verse: 3 такта кита + филл на четвёртом, четыре раза.
let verseKit = (kit.repeat(3) & fill(Seed + 13)).repeat(4)

# Chorus: кит с клэпом на бэкбите; последний такт — снэр-филл.
let chorusKit = overlay([kit, clap(rhythm(". x . x", 1.0))])
let chorusFull = chorusKit.repeat(7) & fill(Seed + 7)

# Break: три такта тишины (хард-кат) + ролл-разгон в последнем такте —
# переход в дроп (COMPOSE-013: STOP → ROLL → DROP).
let breakRoll = rawPattern("breakRoll",
  @[r(12.0)] & rollTo(Snare, HiMidTom, 16).events, 16.0)

# Drop: краш в первом такте + семь тактов кита.
let crashBar = overlay([kit, rhythm("x . . .", 1.0).toPattern(Crash)])
let dropKit = crashBar & kit.repeat(7)

# ============================================================================
# Дорожки: что и когда звучит (roles помечают участие в миксе)
# ============================================================================

# Ударные: хэты в intro, киты в verse/chorus/drop, ролл в break.
discard song.play("drums", introHats, roleDrums, nodeType = "euterpia.drums").during("intro")
discard song.play("drums", verseKit, roleDrums).during("verse")
discard song.play("drums", chorusFull, roleDrums).during("chorus")
discard song.play("drums", breakRoll, roleDrums).during("break")
discard song.play("drums", dropKit, roleDrums).during("drop")
discard song.setParam("drums", "drive", 0.35'f32)
discard song.setParam("drums", "level", -6.0'f32)

# Бас: входит с verse, молчит в break (хард-кат) и outro.
discard song.play("bass", bass808, roleBass, nodeType = "euterpia.organ").during("verse", "chorus", "drop")
discard song.setParam("bass", "bars", 0.55'f32)    # плотный низ
discard song.setParam("bass", "click", 0.6'f32)    # щелчок атаки
discard song.setParam("bass", "tone", 0.4'f32)
discard song.setParam("bass", "level", -8.0'f32)

# Пад: атмосфера intro/break/outro + подложка хора и дропа.
discard song.play("pad", pad, rolePad, nodeType = "euterpia.strings").during("intro", "chorus", "break", "outro")
discard song.setParam("pad", "ensemble", 9.0'f32)
discard song.setParam("pad", "level", -13.0'f32)

# Колокол: тема в intro, её вариации в chorus/drop, метки в break,
# ретрофраза в outro (COMPOSE-033: вариации независимы по секциям).
discard song.play("bell", theme, roleLead, nodeType = "euterpia.bell").during("intro")
discard song.play("bell", theme, roleLead).during("chorus").variant(1)   # кварта вверх
discard song.play("bell", theme, roleLead).during("drop").variant(4)     # инверсия-зеркало
discard song.play("bell", bellHit, roleLead).during("break")
discard song.play("bell", theme, roleLead).during("outro").variant(5)    # фраза задом
discard song.setParam("bell", "decay", 8.0'f32)
discard song.setParam("bell", "level", -10.0'f32)

# Арпеджио: только в verse (контраст к колоколу) и в дропе (плотность).
discard song.play("arp", arp, roleArp, nodeType = "euterpia.piano").during("verse", "drop")
discard song.setParam("arp", "tone", 0.6'f32)
discard song.setParam("arp", "decay", 1.4'f32)
discard song.gain("arp", -13.0'f32)     # production-команда: level ноды (COMPOSE-012)
discard song.pan("arp", 0.25'f32)       # чуть вправо — не спорит с колоколом

# ============================================================================
# Автоматизация (COMPOSE-011): точки в тактах, значения — в единицах параметра
# ============================================================================

# Пад вплывает в intro (мягкая кривая), сумматор поднимается к дропу.
discard song.automate(ramp("pad", "level", 0.0, 8.bars, -32.0, -13.0,
                           curveSmooth))
discard song.automate(ramp(MixTrack, "level", 32.0, 4.bars, -8.0, -6.0,
                           curveLinear))

# ============================================================================
# Компиляция: проверка, партитуры, проект, MIDI, звук
# ============================================================================

# Абсолютные ноты и отчёт по МОДЕЛИ — до сборки проекта (COMPOSE-031).
let notes = song.build()
echo "Нот в пьесе: ", notes.len
echo analyze(song)

# Музыкальная проверка ЗАМЫСЛА до компиляции (COMPOSE-029): форма, размещения,
# гармония под мелодии. Потом — техническая проверка раскладки.
for p in validate(song):
  echo p

var arr = song.toArrangement()
arr.mixLevel = -6.0'f32   # запас от суммы пяти дорожек — без клиппинга

# Проверка раскладки (имена нод, параметры) до генерации проекта.
let problems = validate(arr)
for p in problems:
  echo p

arr.writeNotes(here)                          # *.notes — человекочитаемо
arr.writeProject(here / "neon_pulse.eproj")   # проект EUTERPIA
discard arr.writeMidi(here / "neon_pulse.mid") # Standard MIDI File
let rr = arr.render(here / "neon_pulse.wav")  # звук
if not rr.ok:
  echo "render error: ", rr.error
  quit(1)
echo "Готово: ", rr.path, " (", formatFloat(rr.seconds, ffDecimal, 1), " c)"

