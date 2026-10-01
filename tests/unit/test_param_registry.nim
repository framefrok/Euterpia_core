# tests/unit/test_param_registry.nim
#
# ParamRegistry — control-plane реестр параметров узлов с generation-handle.
#
# Что проверяется (критерии #57):
#   - bind/release/re-bind;
#   - исчерпание слотов даёт InvalidParamSlot, а не порчу таблицы;
#   - double-release — no-op, а не возврат «фантомного» слота;
#   - generation защищает старый handle от повторного использования слота;
#   - lookupParam по nil-регистру безопасен.

import std/unittest
import param_registry
import audio_params

suite "param_registry":
  test "bind выдаёт слот и монотонную генерацию":
    var reg = initParamRegistry(4)
    defer: reg.deinitParamRegistry()

    let b = reg.bindParam(1, 10)
    check b.isValid()
    check b.slot == 0'u32
    check b.generation == 1'u32

  test "повторный bind того же ключа идемпотентен":
    var reg = initParamRegistry(4)
    defer: reg.deinitParamRegistry()

    let b1 = reg.bindParam(7, 3)
    let b2 = reg.bindParam(7, 3)
    check b1.slot == b2.slot
    check b1.generation == b2.generation

  test "исчерпание слотов даёт InvalidParamSlot":
    var reg = initParamRegistry(2)
    defer: reg.deinitParamRegistry()

    let b0 = reg.bindParam(1, 1)
    let b1 = reg.bindParam(2, 1)
    check b0.slot == 0'u32
    check b1.slot == 1'u32

    let b2 = reg.bindParam(3, 1)
    check not b2.isValid()
    check b2.slot == InvalidParamSlot

  test "release возвращает слот, re-bind даёт новую генерацию":
    var reg = initParamRegistry(2)
    defer: reg.deinitParamRegistry()

    let b0 = reg.bindParam(1, 1)
    reg.releaseParam(1, 1)

    let b1 = reg.bindParam(2, 2)
    # Слот переиспользован, но генерация выросла — старый handle не совпадёт.
    check b1.slot == b0.slot
    check b1.generation == b0.generation + 1'u32

  test "double release не портит пул слотов":
    var reg = initParamRegistry(2)
    defer: reg.deinitParamRegistry()

    discard reg.bindParam(1, 1)
    reg.releaseParam(1, 1)
    reg.releaseParam(1, 1)          # второго владения нет — no-op
    reg.releaseParam(99, 99)        # несуществующий ключ — no-op

    # Оба слота должны быть доступны: 1 переиспользован выше, 1 — новый.
    let a = reg.bindParam(2, 2)
    let b = reg.bindParam(3, 3)
    check a.isValid()
    check b.isValid()
    check a.slot != b.slot

  test "lookupParam находит существующий и отвергает чужой ключ":
    var reg = initParamRegistry(4)
    defer: reg.deinitParamRegistry()

    let bound = reg.bindParam(5, 6)
    var found: ParamBinding
    check lookupParam(addr reg, 5, 6, found)
    check found.slot == bound.slot
    check found.generation == bound.generation
    check not lookupParam(addr reg, 5, 7, found)
    check not lookupParam(addr reg, 6, 6, found)

  test "lookupParam по nil-регистру возвращает false":
    var found: ParamBinding
    check not lookupParam(nil, 1, 1, found)

  test "capacity == 0 подменяется на MaxParamSlots":
    var reg = initParamRegistry(0)
    defer: reg.deinitParamRegistry()
    let b = reg.bindParam(1, 1)
    check b.isValid()
