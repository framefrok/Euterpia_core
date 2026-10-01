# tests/unit/test_svf.nim
#
# SVF (topology-preserving transform): АЧХ по типам, устойчивость.
#
# ВАЖНО: параметр resonance ноды — это k = 1/Q (как в C-ядре),
# поэтому Butterworth Q = 0.707 задаётся как resonance = 1.414.

import std/[unittest, math]
import sdk/node_api
import builtin/filters/svf
import unit/test_support

const
  ButterworthReso = 1.414f     # k = 1/Q, Q = 0.707 -> -3 dB на cutoff

proc renderSineSvf(kind, cutoff, reso: float32; freq: float32;
                   blocks: int): seq[float32] =
  var phase = 0.0'f64
  let inc = 2.0 * PI * float64(freq) / float64(TestSampleRate)
  renderNode(getSvfFactory(), getSvfDesc(), blocks,
    setup = proc(state: pointer) =
      getSvfFactory().setParam(state, SvfParamType, kind, false)
      getSvfFactory().setParam(state, SvfParamCutoff, cutoff, false)
      getSvfFactory().setParam(state, SvfParamResonance, reso, false),
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, sin(phase).float32)
        phase += inc
  )

suite "svf":
  test "lowpass: проходная полоса без потерь":
    let s = renderSineSvf(0.0f, 1000.0f, ButterworthReso, 100.0f, 8)
    check s.isFinite()
    check s[2048 .. ^1].peak() > 0.85f

  test "lowpass: -3 dB на частоте среза":
    # Butterworth 2-го порядка: |H(fc)| = 1/sqrt(2) = 0.707.
    let s = renderSineSvf(0.0f, 1000.0f, ButterworthReso, 1000.0f, 8)
    let amp = s[2048 .. ^1].peak()
    check amp > 0.6f and amp < 0.8f

  test "lowpass: сигнал далеко выше среза подавлен":
    let s = renderSineSvf(0.0f, 1000.0f, ButterworthReso, 12000.0f, 8)
    check s[2048 .. ^1].peak() < 0.1f

  test "highpass: низких частот нет, высокие проходят":
    # Регрессия: design() обнулял ic1/ic2 на каждом блоке, из-за чего
    # highpass терял установившийся режим и НЧ проходили почти целиком.
    let low = renderSineSvf(1.0f, 1000.0f, ButterworthReso, 50.0f, 8)
    let high = renderSineSvf(1.0f, 1000.0f, ButterworthReso, 8000.0f, 8)
    check low[2048 .. ^1].peak() < 0.1f
    check high[2048 .. ^1].peak() > 0.85f

  test "high resonance не разгоняет фильтр":
    # Резонансный режим: k = 0.1 -> Q = 10 -> пик ~+20 dB на cutoff.
    # Фильтр обязан остаться конечным (самовозбуждение недопустимо).
    var phase = 0.0'f64
    let inc = 2.0 * PI * 1000.0 / float64(TestSampleRate)
    let s = renderNode(getSvfFactory(), getSvfDesc(), 16,
      setup = proc(state: pointer) =
        getSvfFactory().setParam(state, SvfParamType, 0.0f, false)
        getSvfFactory().setParam(state, SvfParamCutoff, 1000.0f, false)
        getSvfFactory().setParam(state, SvfParamResonance, 0.1f, false),
      prepare = proc(tb: var TestBuffers) =
        for i in 0 ..< TestBlockSize:
          tb.setInputSample(i, sin(phase).float32)
          phase += inc
    )
    check s.isFinite()
    # Q=10 даёт пик ~10, дальше затухание: 16 — щедрый, но конечный потолок.
    check s.peak() < 16.0f