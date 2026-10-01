# nodes/sdk/dsp_units.nim
#
# Единицы измерения DSP-параметров: dB <-> линейная, семитон, цент.
#
# Отдельный модуль потому, что это самая частая «математика» в нодах
# и она обязана быть одинаковой у всех: когда фильтр, компрессор и
# микшер считают dB по-разному, проект начинает «плавать» при смене
# одного нода на другой.
#
# Все функции — только холодная сторона и control rate внутри process().

import std/math

{.push raises: [].}

const
  DbSilence* = -80.0'f32
  DbUnity* = 0.0'f32

proc dbToLin*(db: float32): float32 {.inline.} =
  ## dB -> линейный коэффициент усиления. exp2 быстрее и стабильнее
  ## pow(10, db/20) на длинных блоках.
  pow(2.0'f32, db * (1.0'f32 / 6.0205999132796239'f32))

proc linToDb*(lin: float32): float32 {.inline.} =
  if lin <= 1e-9'f32:
    return DbSilence
  6.0205999132796239'f32 * (log2(lin))

proc semitonesToRatio*(semitones: float32): float32 {.inline.} =
  pow(2.0'f32, semitones * (1.0'f32 / 12.0'f32))

proc centsToRatio*(cents: float32): float32 {.inline.} =
  pow(2.0'f32, cents * (1.0'f32 / 1200.0'f32))

proc midiNoteToFreq*(note: float32): float32 {.inline.} =
  ## Нота 69 = 440 Гц (A4). Стандарт MIDI.
  440.0'f32 * pow(2.0'f32, (note - 69.0'f32) * (1.0'f32 / 12.0'f32))

proc freqToMidiNote*(freq: float32): float32 {.inline.} =
  if freq <= 0.0'f32:
    return 0.0'f32
  69.0'f32 + 12.0'f32 * (log2(freq / 440.0'f32))

{.pop.}
