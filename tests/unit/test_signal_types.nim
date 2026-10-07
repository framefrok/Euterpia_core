# tests/unit/test_signal_types.nim
#
# Контракты Core, на которые опирается весь DSP: сглаживание параметров
# и очередь событий.

import std/unittest
import signal_types

suite "signal_types":
  test "ParamSmoother: 99% пути за timeMs (контракт EUTERPIA)":
    # Именно этот контракт исправлялся: раньше timeMs трактовался как
    # постоянная времени one-pole, и параметр залипал на 87% навсегда.
    let sr = 48000.0'f32
    var sm = initSmoother(timeMs = 10.0f, sampleRate = sr, initialVal = 0.0f)
    sm.setTarget(1.0f)

    for i in 0 ..< 480:          # ровно 10 мс
      discard sm.process()

    check abs(sm.current - 0.99f) < 0.01f
    check sm.current > 0.98f and sm.current < 1.0f

    # Дальше хвост обязан дойти до цели, а не «зависнуть»:
    for i in 0 ..< 2000:
      discard sm.process()
    check abs(sm.current - 1.0f) < 1e-6f

  test "ParamSmoother: монотонность и отсутствие перелёта":
    var sm = initSmoother(timeMs = 5.0f, sampleRate = 48000.0f, initialVal = 0.0f)
    sm.setTarget(1.0f)
    var prev = -1.0'f32
    for i in 0 ..< 500:
      let v = sm.process()
      check v >= prev - 1e-9f
      check v <= 1.0f + 1e-6f
      prev = v

  test "ParamSmoother: нулевое время = мгновенный переход":
    var sm = initSmoother(timeMs = 0.0f, sampleRate = 48000.0f, initialVal = 0.0f)
    sm.setTarget(0.5f)
    discard sm.process()
    check abs(sm.current - 0.5f) < 1e-9f

  test "ParamSmoother: асимметрия вверх/вниз не ломает сходимость":
    var sm = initSmoother(timeMs = 1.0f, sampleRate = 48000.0f, initialVal = 1.0f)
    sm.setTarget(0.0f)
    for i in 0 ..< 480:
      discard sm.process()
    check sm.current < 0.02f

  test "ParamRamp воспроизводит process() по сэмплам (#386)":
    var a = initSmoother(timeMs = 15.0f, sampleRate = 48000.0f, initialVal = 0.0f)
    a.setTarget(1.0f)
    var b = initSmoother(timeMs = 15.0f, sampleRate = 48000.0f, initialVal = 0.0f)
    b.setTarget(1.0f)

    # Эталон — N вызовов process(), по одному на сэмпл.
    var expected: seq[float32]
    for i in 0 ..< 700:
      expected.add(b.process())

    var ramp = a.beginRamp(700)
    for i in 0 ..< 700:
      # Допуск ~ULP float32: ramp пересчитывает ту же экспоненту по одному
      # шагу, process — тоже, различие только в порядке округления.
      check abs(ramp.next() - expected[i]) < 1e-5f
    # Состояние тоже совпало.
    check abs(a.current - b.current) < 1e-5f

  test "ParamRamp: нарезка на блоки не меняет поток значений (#386)":
    ## Один и тот же переход, разбитый по-разному, обязан дать одинаковые
    ## значения по сэмплам — это и есть независимость от blockSize.
    proc renderChunked(blockSizes: seq[int]): seq[float32] =
      var sm = initSmoother(timeMs = 15.0f, sampleRate = 48000.0f, initialVal = 0.0f)
      sm.setTarget(1.0f)
      var total = 0
      for b in blockSizes:
        total += b
      result = newSeq[float32](total)
      var pos = 0
      for b in blockSizes:
        var ramp = sm.beginRamp(int32(b))
        for i in 0 ..< b:
          result[pos + i] = ramp.next()
        pos += b

    let total = 512
    let one = renderChunked(@[total])                     # один блок 512
    let small = renderChunked(@[64, 64, 64, 64, 64, 64, 64, 64])  # восемь по 64
    let mixed = renderChunked(@[100, 1, 300, 111])        # произвольная нарезка

    check one.len == small.len
    for i in 0 ..< one.len:
      check abs(one[i] - small[i]) < 1e-6f
      check abs(one[i] - mixed[i]) < 1e-6f

  test "EventQueue: сортировка по кадру и доле кадра":
    var q: EventQueue
    clearEvents(addr q)
    check q.count == 0

    var ev = RealtimeEvent(kind: evNoteOn)
    ev.frameOffset = 10
    ev.subFrame = 0.5f
    check pushEvent(addr q, ev)

    ev.frameOffset = 2
    ev.subFrame = 0.25f
    check pushEvent(addr q, ev)

    ev.frameOffset = 10
    ev.subFrame = 0.1f
    check pushEvent(addr q, ev)

    sortEvents(addr q)
    check q.events[0].frameOffset == 2
    check q.events[1].frameOffset == 10
    check q.events[1].subFrame < q.events[2].subFrame

  test "EventQueue: clipEvents отбрасывает события за пределами блока":
    var q: EventQueue
    clearEvents(addr q)
    for f in [0'u32, 5'u32, 100'u32, 200'u32]:
      var ev = RealtimeEvent(kind: evNoteOn)
      ev.frameOffset = f
      discard pushEvent(addr q, ev)

    clipEvents(addr q, 128'u32)
    check q.count == 3
    check q.events[2].frameOffset == 100

  test "EventQueue: переполнение не приводит к записи за пределы":
    var q: EventQueue
    clearEvents(addr q)
    var pushed = 0
    for i in 0 ..< (MaxBlockEvents + 10):
      var ev = RealtimeEvent(kind: evNoteOn)
      ev.frameOffset = uint32(i)
      if pushEvent(addr q, ev):
        inc pushed

    check pushed == MaxBlockEvents
    check q.count == MaxBlockEvents
