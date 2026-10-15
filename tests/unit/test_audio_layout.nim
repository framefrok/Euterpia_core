# tests/unit/test_audio_layout.nim
#
# Явная раскладка AudioBuffer (issue #392, EUT-NEW-024/040).
#
# Проблема: planar/interleaved вычислялась эвристикой `stride >= frames`.
# Для interleaved stereo с frames=1, stride=1 это даёт `1 >= 1` → ложно
# planar, и сэмпл читается неверно. Теперь раскладка — поле `layout`,
# а эвристика остаётся только фолбэком для `alAuto`.
#
# Что проверяется:
#   - interleaved stereo с frames=1 распознаётся как interleaved (isPlanar=false);
#   - planar и interleaved с одними и теми же данными дают идентичные
#     sampleAt по всем каналам и кадрам;
#   - channelPtr на interleaved == nil (нужен scalar-путь), на planar != nil;
#   - alAuto сохраняет прежнее поведение эвристики (обратная совместимость).

import std/[unittest, math]
import signal_types
import sdk/audio_buffers

const
  Channels = 2
  Frames = 1

proc planarData(): array[Channels * Frames, float32] =
  # planar: сначала весь канал 0, затем весь канал 1.
  result[0] = 0.11f   # ch0 frame0
  result[1] = 0.22f   # ch1 frame0

proc interleavedData(): array[Channels * Frames, float32] =
  # interleaved: L,R,L,R,... по кадрам.
  result[0] = 0.11f   # frame0 ch0
  result[1] = 0.22f   # frame0 ch1

suite "audio_layout: явная раскладка буфера (#392)":
  test "interleaved stereo с frames=1 не определяется как planar":
    var data = interleavedData()
    var buf = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr data[0]),
      channels: Channels, frames: Frames, stride: 1, layout: alInterleaved)
    # Ровно тот случай, что ломался: stride(1) >= frames(1) дало бы planar.
    check not isPlanar(addr buf)

  test "planar stereo с frames=1 — planar":
    var data = planarData()
    var buf = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr data[0]),
      channels: Channels, frames: Frames, stride: Frames, layout: alPlanar)
    check isPlanar(addr buf)

  test "planar и interleaved дают одинаковые сэмплы через sampleAt":
    var pd = planarData()
    var id = interleavedData()
    var planar = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr pd[0]),
      channels: Channels, frames: Frames, stride: Frames, layout: alPlanar)
    var inter = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr id[0]),
      channels: Channels, frames: Frames, stride: 1, layout: alInterleaved)
    for ch in 0 ..< Channels:
      for fr in 0 ..< Frames:
        check abs(sampleAt(addr planar, ch.int32, fr.int32) -
                  sampleAt(addr inter, ch.int32, fr.int32)) < 1.0e-6f

  test "setSampleAt пишет в правильную ячейку для обеих раскладок":
    var pd: array[Channels * Frames, float32]
    var id: array[Channels * Frames, float32]
    var planar = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr pd[0]),
      channels: Channels, frames: Frames, stride: Frames, layout: alPlanar)
    var inter = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr id[0]),
      channels: Channels, frames: Frames, stride: 1, layout: alInterleaved)
    setSampleAt(addr planar, 1, 0, 0.77f)
    setSampleAt(addr inter, 1, 0, 0.77f)
    # planar: ch1 лежит по индексу stride*ch + fr = 1*1 + 0 = 1
    check abs(pd[1] - 0.77f) < 1.0e-6f
    # interleaved: ch1 кадра 0 лежит по индексу fr*channels + ch = 0*2 + 1 = 1
    check abs(id[1] - 0.77f) < 1.0e-6f
    check abs(pd[1] - id[1]) < 1.0e-6f

  test "channelPtr: planar даёт непрерывный указатель, interleaved — nil":
    var pd = planarData()
    var id = interleavedData()
    var planar = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr pd[0]),
      channels: Channels, frames: Frames, stride: Frames, layout: alPlanar)
    var inter = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr id[0]),
      channels: Channels, frames: Frames, stride: 1, layout: alInterleaved)
    check not channelPtr(addr planar, 0, Frames).isNil
    check not channelPtr(addr planar, 1, Frames).isNil
    check channelPtr(addr inter, 0, Frames).isNil
    check channelPtr(addr inter, 1, Frames).isNil

  test "alAuto — фолбэк на прежнюю эвристику (обратная совместимость)":
    var id = interleavedData()
    # Без явного layout: stride(1) >= frames(1) → по-прежнему ложно planar,
    # ровно как до issue. alAuto обязан сохранить старое поведение.
    var auto = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr id[0]),
      channels: Channels, frames: Frames, stride: 1)
    check auto.layout == alAuto
    check isPlanar(addr auto)   # эвристика stride>=frames

