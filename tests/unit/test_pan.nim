# tests/unit/test_pan.nim
#
# Панорама: закон постоянной мощности, крайние позиции, отсутствие NaN.
#
# Нормировка C-ядра (eut_pan_gains): усиления умножены на sqrt(2),
# поэтому в центре gl = gr = 1.0 (полный сигнал в оба канала), на краю
# активный канал = 1.414. Инвариант: gl^2 + gr^2 = 2 в любой позиции —
# воспринимаемая мощность не меняется при панорамировании.

import std/[unittest, math]
import sdk/node_api
import builtin/mixing/pan
import unit/test_support

const
  Sqrt2 = 1.41421356'f32

proc renderSinePan(panVal: float32; blocks: int): tuple[l, r: seq[float32]] =
  var phase = 0.0'f64
  let inc = 2.0 * PI * 440.0 / float64(TestSampleRate)
  renderNodeStereo(getPanFactory(), getPanDesc(), blocks,
    setup = proc(state: pointer) =
      getPanFactory().setParam(state, PanParamPan, panVal, false),
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, (0.5 * sin(phase)).float32)
        phase += inc
  )

suite "pan":
  test "центр: каналы равны, сигнал проходит на полную":
    let s = renderSinePan(0.0f, 8)
    let l = s.l[2048 .. ^1]
    let r = s.r[2048 .. ^1]
    check l.isFinite() and r.isFinite()
    # gl = gr = cos(45°) * sqrt(2) = 1.0
    check abs(l.peak() - 0.5f) < 0.02f
    check abs(r.peak() - 0.5f) < 0.02f

  test "край вправо: правый канал усилен, левый в тишине":
    let s = renderSinePan(1.0f, 8)
    let l = s.l[2048 .. ^1]
    let r = s.r[2048 .. ^1]
    # gr = sin(90°) * sqrt(2) = 1.414 -> выход 0.707
    check abs(r.peak() - 0.5f * Sqrt2) < 0.05f
    check l.peak() < 0.01f          # cos(90°) = 0

  test "край влево: зеркальная ситуация":
    let s = renderSinePan(-1.0f, 8)
    let l = s.l[2048 .. ^1]
    let r = s.r[2048 .. ^1]
    check abs(l.peak() - 0.5f * Sqrt2) < 0.05f
    check r.peak() < 0.01f

  test "constant power: сумма квадратов угловых усилений постоянна":
    # gl^2 + gr^2 = 2 в любой позиции — иначе моно-сведение меняет
    # громкость при панорамировании.
    for panVal in [-1.0'f32, -0.5f, 0.0f, 0.5f, 1.0f]:
      let s = renderSinePan(panVal, 6)
      let l = s.l[2048 .. ^1].peak() / 0.5'f32
      let r = s.r[2048 .. ^1].peak() / 0.5'f32
      check abs(l * l + r * r - 2.0f) < 0.1f

  test "значение за пределами [-1, 1] зажимается":
    let s = renderSinePan(5.0f, 6)
    check s.l.isFinite() and s.r.isFinite()
    check s.l[2048 .. ^1].peak() < 0.01f   # как при +1