# tests/unit/test_native_abi.nim
#
# Контракт Nim <-> C для состояний DSP.
#
# Раскладка C-структур из Nim недоступна (ограничение {.importc.} в Nim 2),
# поэтому здесь проверяются две стороны контракта:
#   1. сами C-размеры — через вызов C (abiCheck);
#   2. то, что Nim-обёртки действительно непрозрачные (один указатель) —
#      если бы в обёртке появилось поле, она перестала бы быть хэндлом,
#      и нода могла бы писать в память C мимо allocState.

import std/unittest
import builtin/native/eut_native

suite "native ABI":
  test "размеры C-состояний совпадают с задокументированными":
    # Явные числа, а не только сравнение: если C-структура вырастет,
    # числа перестанут сходиться сразу, а не «где-то в рантайме».
    check eut_native.abiCheck()

  test "обёртки — непрозрачные хэндлы, а не копии C-состояния":
    # Хэндл ровно в один указатель: размер C-структуры Nim не известен
    # и не должен быть известен (см. шапку eut_native.nim).
    check sizeof(Biquad) == sizeof(pointer)
    check sizeof(Svf) == sizeof(pointer)
    check sizeof(Osc) == sizeof(pointer)
    check sizeof(Noise) == sizeof(pointer)
    check sizeof(Compressor) == sizeof(pointer)
    check sizeof(Delay) == sizeof(pointer)
