# tests/unit/test_compose_diagnostics.nim
#
# Диагностика ошибок в «композиции как код» (issue #311).
#
# Проверяется то, что раньше молчало или падало:
#   * опечатка в имени параметра — ошибка со списком допустимых имён
#     (раньше параметр просто не применялся, рендер был «успешным»);
#   * неизвестный тип ноды — ошибка со списком доступных типов (раньше
#     `AssertionDefect` и стектрейм из `builder.nim`);
#   * пустая партия и пустая раскладка — предупреждение, а не ошибка:
#     пустой проект законен, но сказать о нём надо.

import std/[unittest, os, strutils]

import compose/score
import compose/song
import compose/engine

proc oneBar(partName: string): Part =
  ## Партия из одного такта с одной нотой.
  result = part(partName)
  result.add bar(100, n(60, 1.0))

proc onePart(nodeType, nodeName, notesName: string;
             partName = "p"; paramName = ""): Arrangement =
  ## Раскладка из одной партии с одним тактом — минимальный случай,
  ## в котором проверка обязана что-то сказать.
  var inst = instrument(nodeType, nodeName, notesName)
  if paramName.len > 0:
    inst.setParam(paramName, 1.0f32)
  var arr = arrangement("T", 120)
  arr.add(inst, oneBar(partName))
  arr

suite "compose: неизвестный тип ноды (#311)":
  test "ошибка называет проблему и перечисляет доступные типы":
    let problems = validate(onePart("euterpia.kazoo", "K", "k"))
    check problems.len > 0
    check hasErrors(problems)
    check (problems[0].find("euterpia.kazoo") >= 0)
    # Подсказка без списка типов оставляет человека в ощупь.
    check (problems[0].find("доступные типы") >= 0)
    check (problems[0].find("euterpia.piano") >= 0)

  test "рендер возвращает ошибку, а не падает":
    let rr = onePart("euterpia.kazoo", "K", "k").render(
      getTempDir() / "euterpia_compose_bad_type.wav")
    check not rr.ok
    check (rr.error.find("euterpia.kazoo") >= 0)

suite "compose: опечатка в параметре (#311)":
  test "имя параметра проверяется, допустимые имена перечислены":
    let problems = validate(onePart("euterpia.piano", "P", "p",
                                   paramName = "blabla"))
    check hasErrors(problems)
    check (problems[0].find("blabla") >= 0)
    check (problems[0].find("допустимые параметры") >= 0)
    check (problems[0].find("decay") >= 0)

  test "рендер возвращает ошибку вместо тихого успеха":
    let rr = onePart("euterpia.piano", "P", "p", paramName = "blabla").render(
      getTempDir() / "euterpia_compose_bad_param.wav")
    check not rr.ok
    check (rr.error.find("blabla") >= 0)

suite "compose: пустое и повторяющееся (#311)":
  test "пустая раскладка — предупреждение, а не ошибка":
    let problems = validate(arrangement("T", 120))
    check problems.len > 0
    check not hasErrors(problems)
    check (problems[0].find("внимание") >= 0)

  test "партия без тактов — предупреждение":
    var arr = arrangement("T", 120)
    arr.add(instrument("euterpia.piano", "P", "p"), part("empty"))
    let problems = validate(arr)
    check not hasErrors(problems)
    check (problems.len > 0)

  test "повтор имени ноды — ошибка":
    var arr = arrangement("T", 120)
    arr.add(instrument("euterpia.piano", "P", "p"),
            oneBar("a"))
    arr.add(instrument("euterpia.piano", "P", "q"),
            oneBar("b"))
    check hasErrors(validate(arr))

suite "compose: корректная раскладка (#311)":
  test "норма не даёт ни ошибок, ни предупреждений":
    let problems = validate(onePart("euterpia.piano", "P", "p"))
    check problems.len == 0

  test "правильные параметры проходят проверку":
    var inst = instrument("euterpia.strings", "S", "s")
    inst.setParam("tone", 0.4f32)
    inst.setParam("ensemble", 6.0f32)
    var arr = arrangement("T", 120)
    arr.add(inst, oneBar("s"))
    check validate(arr).len == 0

  test "рендер собираемой раскладки успешен и предупреждений нет":
    let rr = onePart("euterpia.piano", "P", "p").render(
      getTempDir() / "euterpia_compose_ok.wav")
    check rr.ok
    check rr.warnings.len == 0