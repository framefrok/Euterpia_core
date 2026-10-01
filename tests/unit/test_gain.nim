# tests/unit/test_gain.nim
#
# Gain: линейность, точность dB-преобразования, крайние значения.

import std/[unittest, math]
import sdk/node_api
import builtin/mixing/gain
import unit/test_support

proc renderSineGain(db: float32; blocks: int): seq[float32] =
  ## Синус 440 Гц амплитуды 0.5 во вход, gain задан в dB.
  var phase = 0.0'f64
  let inc = 2.0 * PI * 440.0 / float64(TestSampleRate)
  renderNode(getGainFactory(), getGainDesc(), blocks,
    setup = proc(state: pointer) =
      getGainFactory().setParam(state, GainParamGain, db, false),
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, (0.5 * sin(phase)).float32)
        phase += inc
  )

suite "gain":
  test "0 dB: сигнал проходит без изменения":
    # Первые блоки отбрасываются: сглаживание 15 мс должно дойти до цели.
    let sig = renderSineGain(0.0f, 8)
    let tail = sig[2048 .. ^1]
    check tail.isFinite()
    check abs(tail.peak() - 0.5f) < 0.01f

  test "-6 dB: амплитуда ровно в 0.501187 раза":
    let sig = renderSineGain(-6.0f, 8)
    let tail = sig[2048 .. ^1]
    # dbToLin(-6) = 2^(-6/6.0206) = 0.501187
    let ratio = tail.peak() / 0.5'f32
    check abs(ratio - 0.501187f) < 0.01f

  test "+6 dB: амплитуда почти вдвое":
    let sig = renderSineGain(6.0f, 8)
    let tail = sig[2048 .. ^1]
    # dbToLin(6) = 1.99526
    check abs(tail.peak() - 0.5f * 1.99526f) < 0.03f

  test "-80 dB: практическая тишина без NaN":
    let sig = renderSineGain(-80.0f, 6)
    check sig.isFinite()
    check sig[2048 .. ^1].peak() < 2.0e-4f

  test "getParam возвращает заданное, а не сглаженное":
    # UI и автоматизация читают целевое значение: сглаженное в момент
    # чтения ещё не доехало, и ползунок «прыгал бы назад».
    let state = getGainFactory().create(getGainDesc(), nil)
    check state != nil
    getGainFactory().setParam(state, GainParamGain, -12.5f, false)
    var v = 0.0'f32
    check getGainFactory().getParam(state, GainParamGain, addr v)
    check abs(v - (-12.5f)) < 1e-4f
    getGainFactory().destroy(state)