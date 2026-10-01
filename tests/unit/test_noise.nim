# tests/unit/test_noise.nim
#
# Шумы: ненулевой выход, конечность, детерминизм, управление уровнем.

import std/[unittest, math]
import sdk/node_api
import builtin/generators/noise
import unit/test_support

proc renderNoise(color, level: float32; blocks: int): seq[float32] =
  renderNode(getNoiseFactory(), getNoiseDesc(), blocks,
    setup = proc(state: pointer) =
      getNoiseFactory().setParam(state, NoiseParamColor, color, false)
      getNoiseFactory().setParam(state, NoiseParamLevel, level, false)
  )

suite "noise":
  test "белый: ненулевой сигнал без NaN":
    let s = renderNoise(0.0f, 0.0f, 8)
    check s.isFinite()
    check not s.isSilent()
    # Равномерный шум [-1, 1]: RMS теоретически 0.577, пик близок к 1.
    check s.rms() > 0.2f
    check s.peak() <= 1.05f

  test "розовый: спектрально ровнее, но тоже ненулевой":
    let s = renderNoise(1.0f, 0.0f, 8)
    check s.isFinite()
    check not s.isSilent()
    check s.rms() > 0.05f

  test "коричневый: интегратор с утечкой не уезжает в inf":
    let s = renderNoise(2.0f, 0.0f, 32)
    check s.isFinite()
    check not s.isSilent()
    # Утечка + safety_clip(±8) обязана удерживать сигнал: без них
    # интегратор уходит за пределы float32 за 1.7 с (32 блока).
    check s.peak() <= 8.01f

  test "детерминизм: один seed — один и тот же сигнал":
    let a = renderNoise(0.0f, 0.0f, 4)
    let b = renderNoise(0.0f, 0.0f, 4)
    check a.len == b.len
    for i in 0 ..< a.len:
      if a[i] != b[i]:
        check false
        break

  test "-20 dB тише 0 dB":
    let loud = renderNoise(0.0f, 0.0f, 8)
    let quiet = renderNoise(0.0f, -20.0f, 8)
    check quiet.rms() < loud.rms() * 0.5f

  test "цвет шума не влияет на частоту сэмплера (нет NaN при смене типа)":
    for color in [0.0'f32, 1.0f, 2.0f, 99.0f]:
      let s = renderNoise(color, -6.0f, 4)
      check s.isFinite()