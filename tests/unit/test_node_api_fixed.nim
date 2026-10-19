# tests/unit/test_node_api_fixed.nim
#
# Фиксированные строки descriptor'а: обрезка всегда даёт валидный UTF-8
# (issue #398). Раньше `setFixed` откатывал continuation-байты, но оставлял
# «висячий» lead-байт: из `😀` при обрезке получался байт `F0`, и `readFixed`
# возвращал невалидную строку.

import std/[unittest, unicode]

import sdk/node_api

proc validUtf8(s: string): bool {.inline.} =
  validateUtf8(s) < 0

suite "node_api: setFixed и UTF-8 (#398)":
  test "4-байтовый символ, обрезанный посередине, отбрасывается целиком":
    var buf: array[6, char]
    setFixed(buf, "😀😀")           # 8 байт, в буфер влезает 5
    check readFixed(buf) == "😀"
    check validUtf8(readFixed(buf))

  test "ровно влезающий символ сохраняется":
    var buf: array[5, char]         # 4 байта + NUL
    setFixed(buf, "😀😀")
    check readFixed(buf) == "😀"
    check validUtf8(readFixed(buf))

  test "неполный символ в конце не оставляет lead-байт":
    var buf: array[4, char]         # влезает 3 байта из 4
    setFixed(buf, "😀")
    check readFixed(buf) == ""
    check validUtf8(readFixed(buf))

  test "ASCII + обрезанный lead-байт: остаётся только ASCII":
    var buf: array[3, char]
    setFixed(buf, "a😀")            # 1 + 4 байта, влезает a + F0
    check readFixed(buf) == "a"
    check validUtf8(readFixed(buf))

  test "2- и 3-байтовые символы на границе":
    var two: array[3, char]         # 2 байта + NUL
    setFixed(two, "é")
    check readFixed(two) == "é"

    var cut2: array[2, char]
    setFixed(cut2, "éx")            # влезает только C3
    check readFixed(cut2) == ""

    var three: array[4, char]       # 3 байта + NUL
    setFixed(three, "€")
    check readFixed(three) == "€"

    var cut3: array[3, char]
    setFixed(cut3, "€x")            # E2 82 — неполная последовательность
    check readFixed(cut3) == ""

  test "невалидный вход обрезается на первом плохом байте":
    var buf: array[8, char]
    setFixed(buf, "ok\xF0bad")      # F0 без continuation
    check readFixed(buf) == "ok"
    check validUtf8(readFixed(buf))

  test "overlong-форма и суррогат не проходят в буфер":
    var overlong: array[4, char]
    setFixed(overlong, "\xC0\xAF")  # overlong '/'
    check readFixed(overlong) == ""

    var surrogate: array[4, char]
    setFixed(surrogate, "\xED\xA0\x80")  # U+D800
    check readFixed(surrogate) == ""

  test "буфер из одного байта — всегда пустая строка":
    var buf: array[1, char]
    setFixed(buf, "abc")
    check readFixed(buf) == ""
