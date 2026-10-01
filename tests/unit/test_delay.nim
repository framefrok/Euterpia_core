# tests/unit/test_delay.nim
#
# Задержка: сэмпл-точная позиция эха, режимы mix/feedback, конечность.

import std/[unittest, math]
import sdk/node_api
import builtin/effects/delay
import unit/test_support

const
  DelaySec = 0.25                         # стартовое время, не меняется
  ExpectedEcho = int(DelaySec * float64(TestSampleRate))   # 12000

proc argPeak(s: openArray[float32]; fromIdx, toIdx: int): (int, float32) =
  ## Позиция и значение максимума на отрезке.
  var bestIdx = fromIdx
  var bestVal = 0.0'f32
  for i in fromIdx ..< min(toIdx, s.len):
    let a = abs(s[i])
    if a > bestVal:
      bestVal = a
      bestIdx = i
  (bestIdx, bestVal)

proc renderImpulseDelay(feedback, mix: float32; blocks: int): seq[float32] =
  ## Импульс (один сэмпл 1.0) в блоке 0, дальше тишина.
  renderNode(getDelayFactory(), getDelayDesc(), blocks,
    setup = proc(state: pointer) =
      let f = getDelayFactory()
      f.setParam(state, DelayParamTimeL, DelaySec, false)
      f.setParam(state, DelayParamTimeR, DelaySec, false)
      f.setParam(state, DelayParamFeedback, feedback, false)
      f.setParam(state, DelayParamMix, mix, false),
    prepare = proc(tb: var TestBuffers) =
      if tb.blockIndex == 0:
        tb.setInputSample(0, 1.0f)
  )

proc renderConstDelay(feedback, mix, value: float32; blocks: int): seq[float32] =
  ## Постоянный вход `value` во все кадры: удобно, чтобы изолировать
  ## сухой и влажный пути задержки.
  renderNode(getDelayFactory(), getDelayDesc(), blocks,
    setup = proc(state: pointer) =
      let f = getDelayFactory()
      f.setParam(state, DelayParamTimeL, DelaySec, false)
      f.setParam(state, DelayParamTimeR, DelaySec, false)
      f.setParam(state, DelayParamFeedback, feedback, false)
      f.setParam(state, DelayParamMix, mix, false),
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, value)
  )

suite "delay":
  test "эхо приходит ровно через delay-время":
    # mix=1 (полностью wet), feedback=0 (одно эхо). wetGain = mix*0.5,
    # поэтому амплитуда эха ~0.5.
    let s = renderImpulseDelay(0.0f, 1.0f, 32)
    check s.isFinite()

    let (idx, amp) = argPeak(s, ExpectedEcho - 500, ExpectedEcho + 500)
    check amp > 0.3f
    check abs(idx - ExpectedEcho) <= 300

  test "feedback=0: второго эха нет":
    let s = renderImpulseDelay(0.0f, 1.0f, 64)
    let (_, secondEcho) = argPeak(s, 2 * ExpectedEcho - 500,
                                     2 * ExpectedEcho + 500)
    check secondEcho < 0.05f

  test "feedback>0: повторы затухают, а не растут":
    let s = renderImpulseDelay(0.5f, 1.0f, 96)
    let (_, first) = argPeak(s, ExpectedEcho - 500, ExpectedEcho + 500)
    let (_, third) = argPeak(s, 3 * ExpectedEcho - 500, 3 * ExpectedEcho + 500)
    check s.isFinite()
    # Каждый повтор слабее предыдущего (fb < 1 + lowpass в петле).
    check third < first
    check first > 0.2f

  test "сигнал без эха не появляется раньше времени":
    let s = renderImpulseDelay(0.0f, 1.0f, 32)
    # До задержки во влажной части пусто: всё, что есть, — сухой импульс.
    let (_, early) = argPeak(s, 10, ExpectedEcho - 2000)
    check early < 0.1f

  test "мокрая дорожка не даёт NaN при экстремальных параметрах":
    let s = renderImpulseDelay(0.95f, 1.0f, 64)
    check s.isFinite()
    check s.peak() < 8.0f   # safety clip не даёт уйти за пределы

  # --- регрессии ядра (issues #22, #23) --------------------------------------

  test "эхо приходит точно на delay-кадр, без сдвига на отсчёт (#22)":
    # Базис Catmull-Rom был смещён: при t = 0 отдавался buf[i0+1], из-за чего
    # всё чтение уезжало ровно на один отсчёт вперёд (эхо раньше на 1 кадр).
    let s = renderImpulseDelay(0.0f, 1.0f, 32)
    let (idx, amp) = argPeak(s, ExpectedEcho - 100, ExpectedEcho + 100)
    check amp > 0.3f
    check idx == ExpectedEcho

  test "mix = 1 — строго 100% wet, сухой сигнал не проходит (#23)":
    let s = renderConstDelay(0.0f, 1.0f, 1.0f, 64)
    check s.isFinite()
    # До первого эха выход должен быть тишиной (сухого прохода нет).
    let (_, early) = argPeak(s, 6000, ExpectedEcho - 500)
    check early < 0.02f
    # На эхе влажный сигнал выходит на полную амплитуду.
    let (_, atEcho) = argPeak(s, ExpectedEcho - 100, ExpectedEcho + 100)
    check atEcho > 0.9f

  test "mix = 0 — сухой проход без изменений (#23)":
    let s = renderConstDelay(0.0f, 0.0f, 1.0f, 32)
    check s.isFinite()
    var minv = 1.0'f32
    var maxv = 0.0'f32
    for i in 6000 ..< s.len:
      minv = min(minv, s[i])
      maxv = max(maxv, s[i])
    check minv > 0.99f
    check maxv < 1.01f

  test "mix = 0.5 — сухой и влажный в равных долях (#23)":
    let s = renderConstDelay(0.0f, 0.5f, 1.0f, 64)
    check s.isFinite()
    let (_, pre)  = argPeak(s, 6000, ExpectedEcho - 500)
    let (_, post) = argPeak(s, ExpectedEcho + 500, 2 * ExpectedEcho - 500)
    check abs(pre - 0.5f) < 0.02f
    check abs(post - 1.0f) < 0.02f