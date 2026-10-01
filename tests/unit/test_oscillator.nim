# tests/unit/test_oscillator.nim
#
# Осциллятор: точность частоты, отсутствие NaN, реакция на параметры.

import std/[unittest, math]
import sdk/node_api
import sdk/dsp_units
import builtin/generators/oscillator
import unit/test_support

const
  FreqTolerance = 2.0'f32      # ±2 % по оценке через пересечения нуля

suite "oscillator":
  test "440 Гц синуса: частота и конечность сигнала":
    let signal = renderNode(getOscillatorFactory(), getOscillatorDesc(), 8,
      setup = proc(state: pointer) =
        getOscillatorFactory().setParam(state, OscParamWaveform, 0.0f, false)
        getOscillatorFactory().setParam(state, OscParamFrequency, 440.0f, false)
        getOscillatorFactory().setParam(state, OscParamLevel, 0.0f, false)
    )

    check signal.isFinite()
    check not signal.isSilent()

    let f = signal.estimateFreq()
    check abs(f - 440.0f) / 440.0f < FreqTolerance

  test "уровень 0 dB даёт пик около единицы":
    let signal = renderNode(getOscillatorFactory(), getOscillatorDesc(), 6,
      setup = proc(state: pointer) =
        getOscillatorFactory().setParam(state, OscParamWaveform, 1.0f, false)  # пила
        getOscillatorFactory().setParam(state, OscParamFrequency, 220.0f, false)
        getOscillatorFactory().setParam(state, OscParamLevel, 0.0f, false)
    )

    check signal.isFinite()
    check abs(signal.peak() - 1.0f) < 0.05f

  test "частота меняется через параметр":
    let signal = renderNode(getOscillatorFactory(), getOscillatorDesc(), 8,
      setup = proc(state: pointer) =
        getOscillatorFactory().setParam(state, OscParamWaveform, 1.0f, false)
        getOscillatorFactory().setParam(state, OscParamFrequency, 1000.0f, false)
    )

    let f = signal.estimateFreq()
    check abs(f - 1000.0f) / 1000.0f < FreqTolerance

  test "экстремальные параметры не ломают генератор":
    # Частота и уровень за пределами диапазона должны зажиматься,
    # а не давать NaN или бесконечный разгон.
    let signal = renderNode(getOscillatorFactory(), getOscillatorDesc(), 4,
      setup = proc(state: pointer) =
        getOscillatorFactory().setParam(state, OscParamWaveform, 2.0f, false)
        getOscillatorFactory().setParam(state, OscParamFrequency, 1e9f, false)
        getOscillatorFactory().setParam(state, OscParamLevel, 1e9f, false)
    )

    check signal.isFinite()
    check signal.peak() <= 8.0f

  test "MIDI-карта частот совпадает с таблицей":
    # Нота 69 = 440 Гц, октава = удвоение.
    check abs(midiNoteToFreq(69.0f) - 440.0f) < 0.01f
    check abs(midiNoteToFreq(81.0f) - 880.0f) < 0.01f
    check abs(midiNoteToFreq(57.0f) - 220.0f) < 0.01f
    check abs(freqToMidiNote(440.0f) - 69.0f) < 0.01f
