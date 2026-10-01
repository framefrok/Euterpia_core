# tests/unit/test_saturate.nim
#
# Насыщение (soft clip) из eut_mix.c: прозрачность при drive = 0,
# монотонность по drive и достижимый потолок ceiling.
#
# Регрессия к багу «norm = 1/(1+drive)» (issue #27): эта нормировка ровно
# компенсировала входное усиление, из-за чего рост drive ОСЛАБЛЯЛ сигнал,
# а при drive = 0 выход обнулялся полностью.

import std/unittest
import builtin/native/eut_native

proc saturateOne(x, drive, ceiling: float32): float32 =
  var buf: array[1, float32]
  buf[0] = x
  mixSaturate(addr buf[0], 1, drive, ceiling)
  buf[0]

suite "saturate":
  test "drive = 0 прозрачен для малого сигнала (единичный наклон)":
    # y = x / (1 + |x|): в нуле наклон равен единице, поэтому очень
    # малый сигнал проходит почти без изменения.
    check abs(saturateOne(1.0e-4f, 0.0f, 1.0f) - 1.0e-4f) < 1.0e-5f

  test "drive = 0 не глушит сигнал (регрессия: раньше выход был ровно 0)":
    let y = saturateOne(1.0f, 0.0f, 1.0f)
    check y > 0.4f and y < 0.6f      # 1/(1+1) = 0.5

  test "выход строго монотонен по drive":
    var prev = -1.0f
    for d in [0.0f, 0.25f, 1.0f, 4.0f, 16.0f]:
      let y = saturateOne(1.0f, d, 1.0f)
      check y > prev
      prev = y

  test "|x| -> inf стремится к ceiling":
    check abs(saturateOne(1.0e6f, 1.0f, 1.0f) - 1.0f) < 1.0e-3f

  test "ceiling ограничивает выход сверху при любом drive":
    for d in [0.0f, 1.0f, 16.0f]:
      check saturateOne(1.0e6f, d, 0.8f) <= 0.8f + 1.0e-4f

  test "нечётная симметрия относительно нуля":
    for x in [0.1f, 0.5f, 1.0f, 8.0f]:
      check abs(saturateOne(-x, 2.0f, 1.0f) + saturateOne(x, 2.0f, 1.0f)) < 1.0e-5f
