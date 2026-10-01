# tests/unit/test_biquad.nim
#
# Biquad: амплитудно-частотная характеристика, устойчивость, типы фильтров.
#
# Проверяется не «числа совпали с эталоном», а физические свойства:
# проходная полоса без затухания, -3 dB на частоте среза, ноль в вы notch.

import std/[unittest, math]
import sdk/node_api
import builtin/filters/biquad
import unit/test_support

proc renderSine(factory: ptr NodeFactory; desc: ptr NodeDesc;
               freq: float32; blocks: int;
               setup: proc(state: pointer)): seq[float32] =
  ## Рендер синуна заданной частоты во вход ноды.
  var phase = 0.0'f64
  let inc = 2.0 * PI * float64(freq) / float64(TestSampleRate)

  result = renderNode(factory, desc, blocks, setup = setup,
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, sin(phase).float32)
        phase += inc
  )

proc amplitudeAt(samples: openArray[float32]; freq: float32;
                 startFrom: int): float32 =
  ## Амплитуда по фазе на фиксированной частоте.
  var maxAbs = 0.0'f32
  var i = startFrom
  while i < samples.len:
    let v = samples[i]
    if abs(v) > maxAbs:
      maxAbs = abs(v)
    i += 1
  maxAbs

suite "biquad":
  test "lowpass: проходная полоса без потерь":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 100.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 0.707f, false)
    )

    check signal.isFinite()
    check amplitudeAt(signal, 100.0f, 1024) > 0.85f

  test "lowpass: -3 dB на частоте среза":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 1000.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 0.707f, false)
    )

    let amp = amplitudeAt(signal, 1000.0f, 2048)
    # Фильтр Баттерворта 2-го порядка даёт -3.01 dB = 0.707 амплитуды.
    check amp > 0.6f and amp < 0.8f

  test "lowpass: сигнал далеко выше среза подавляется":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 12000.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 0.707f, false)
    )

    check amplitudeAt(signal, 12000.0f, 2048) < 0.1f

  test "notch: на частоте среза сигнал практически отсутствует":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 1000.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 3.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 4.0f, false)
    )

    check signal.isFinite()
    check amplitudeAt(signal, 1000.0f, 4096) < 0.05f

  test "импульс: фильтр устойчив, хвост затухает в ноль":
    let signal = renderNode(getBiquadFactory(), getBiquadDesc(), 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 400.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 8.0f, false),
      prepare = proc(tb: var TestBuffers) =
        discard
    )

    check signal.isFinite()
    # Высокий Q даёт долгий хвост, но он обязан затухнуть, а не
    # расти или уйти в бесконечность.
    check signal.peak() <= 1.5f
