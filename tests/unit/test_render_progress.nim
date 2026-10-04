# tests/unit/test_render_progress.nim
#
# Индикатор прогресса офлайн-рендера (issue #310).
#
# Проверяется чистая часть — форматирование времени и текст показания.
# Сам ход рендера с колбэком проверяет CLI-тест (там процесс запускается
# по-настоящему), а здесь важно, чтобы строка была стабильной и читаемой.

import std/[unittest, strutils]

import compose/progress

suite "прогресс рендера: время (#310)":
  test "разряды фиксированы, иначе строка дёргалась бы":
    check durationText(0) == "0:00"
    check durationText(9) == "0:09"
    check durationText(65) == "1:05"
    check durationText(3599) == "59:59"

  test "через час формат меняется на ч:мм:сс":
    check durationText(3600) == "1:00:00"
    check durationText(3661) == "1:01:01"
    check durationText(36000) == "10:00:00"

  test "отрицательное время — ноль, а не мусор":
    check durationText(-5) == "0:00"

suite "прогресс рендера: строка показания (#310)":
  test "есть проценты, отрендерено/всего, прошло и осталось":
    let p = newProgress(60.0, 48000)
    let line = progressLine(p, 48000, 48000 * 60)
    check "1%" in line
    check "0:01 / 1:00" in line
    check "прошло" in line
    check "осталось" in line

  test "границы: 0 % и 100 %":
    let p = newProgress(10.0, 48000)
    check "0%" in progressLine(p, 0, 48000 * 10)
    check "100%" in progressLine(p, 48000 * 10, 48000 * 10)

  test "кадры сверх total не дают больше 100 %":
    let p = newProgress(10.0, 48000)
    check "100%" in progressLine(p, 48000 * 99, 48000 * 10)

  test "нулевой принтер не падает — колбэк могут не отдать":
    var p: ProgressPrinter = nil
    p.update(0, 0)
    p.clear()