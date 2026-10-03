# tests/unit/test_param_flags.nim
#
# Флаги параметра — битовая маска (issue #292). Проверяем именно то, что
# ломалось: пара флагов не должна «просачиваться» в чужие биты.

import std/unittest
import sdk/node_api

suite "флаги параметров: битовая маска":
  test "automatable|modulatable не выставляет choice":
    let flags = uint32(npfAutomatable) or uint32(npfModulatable)
    check (flags and uint32(npfAutomatable)) != 0
    check (flags and uint32(npfModulatable)) != 0
    # Регрессия: при порядковых значениях бит 0 совпадал с npfChoice,
    # и `param set` отвергал дробные значения как «целочисленные».
    check (flags and uint32(npfChoice)) == 0
    check (flags and uint32(npfInteger)) == 0
    check (flags and uint32(npfHidden)) == 0

  test "все флаги — независимые степени двойки":
    var seen: set[uint32]
    for flag in NodeParamFlagOrder:
      let bit = uint32(flag)
      check bit > 0
      check (bit and (bit - 1)) == 0    # степень двойки
      check bit notin seen
      seen.incl bit

  test "integer и choice различаются":
    check uint32(npfInteger) != uint32(npfChoice)
