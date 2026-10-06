# tests/unit/test_aligned_mem.nim
#
# aligned_mem — shared-память, выровненная сильнее MemAlign (issue #364).
#
# Что проверяется:
#   - адрес кратен запрошенному выравниванию при любом смещении аллокатора
#     (проверяем серией аллокаций: одна из них обязательно «неудобная»);
#   - память обнулена;
#   - вырожденные входы (size <= 0, не степень двойки) дают nil, а не крэш;
#   - освобождение парной функцией не портит соседние блоки;
#   - выравнивание типа EventQueue (ради него всё и сделано) равно 64.

import std/unittest
import signal_types
import aligned_mem

suite "aligned_mem":
  test "EventQueue действительно требует 64 байта":
    # Если это перестанет быть правдой, фикс #364 теряет смысл, а тесты
    # ниже — опору.
    check alignof(EventQueue) == 64
    check sizeof(EventQueue) mod 64 == 0

  test "адрес кратен выравниванию для серии аллокаций":
    var ptrs: seq[pointer]
    for i in 0 ..< 32:
      let p = alignedSharedAlloc0(sizeof(EventQueue), alignof(EventQueue))
      check p != nil
      check isAlignedShared(p, alignof(EventQueue))
      check (cast[uint](p) and 63'u) == 0'u
      ptrs.add p
    for p in ptrs:
      alignedSharedDealloc(p)

  test "память обнулена":
    let n = 8
    let p = alignedSharedAlloc0(sizeof(EventQueue) * n, alignof(EventQueue))
    check p != nil
    let bytes = cast[ptr UncheckedArray[byte]](p)
    var nonzero = 0
    for i in 0 ..< sizeof(EventQueue) * n:
      if bytes[i] != 0'u8: inc nonzero
    check nonzero == 0

    # И запись по выровненному адресу — то, на чём падал UBSan.
    let q = cast[ptr EventQueue](p)
    q.events[0].kind = evNoteOn
    check q.events[0].kind == evNoteOn
    alignedSharedDealloc(p)

  test "другие степени двойки тоже поддерживаются":
    for a in [8, 16, 32, 128, 256]:
      let p = alignedSharedAlloc0(4096 + a, a)
      check p != nil
      check isAlignedShared(p, a)
      alignedSharedDealloc(p)

  test "некорректные параметры дают nil":
    check alignedSharedAlloc0(0, 64) == nil
    check alignedSharedAlloc0(-1, 64) == nil
    check alignedSharedAlloc0(64, 0) == nil
    check alignedSharedAlloc0(64, -64) == nil
    check alignedSharedAlloc0(64, 48) == nil   # не степень двойки

  test "nil и вырожденные адреса освобождаются без крэша":
    alignedSharedDealloc(nil)
    check not isAlignedShared(nil, 64)

  test "освобождение не портит соседние блоки":
    let a = alignedSharedAlloc0(sizeof(EventQueue), alignof(EventQueue))
    let b = alignedSharedAlloc0(sizeof(EventQueue), alignof(EventQueue))
    check a != nil and b != nil and a != b
    let qb = cast[ptr EventQueue](b)
    qb.events[1].kind = evNoteOff
    alignedSharedDealloc(a)
    check qb.events[1].kind == evNoteOff
    alignedSharedDealloc(b)

  test "по умолчанию выравнивание — строка кэша пулов":
    check DefaultSharedAlignment == 64
    let p = alignedSharedAlloc0(1)
    check isAlignedShared(p)
    alignedSharedDealloc(p)
