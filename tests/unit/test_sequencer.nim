# tests/unit/test_sequencer.nim
#
# Sequencer — компиляция клипов/нот в события и RT-выборка событий блока
# (issue #57).
#
# Что проверяется:
#   - editor-side мутаторы: addTrack/addClip/addNote/addAutomationPoint
#     (границы, сортировка точек, отвержение некорректных аргументов);
#   - compile: не-loop и loop раскрытие нот, обрезка noteOff по границе
#     клипа, нормировка velocity, maxTick по событиям и автоматизации;
#   - processBlock: бинарный поиск событий блока, frameOffset, mute трека,
#     подсчёт droppedEvents при переполнении EventQueue;
#   - getAutomationValue / fillAutomationBlock: интерполяция по кривым.

import std/[unittest, math]
import signal_types
import transport
import sequencer

# =============================================================================
# Editor-side мутаторы
# =============================================================================

suite "sequencer: editor mutators":
  test "addClip отвергает неверный трек и неположительную длину":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)

    check s.addClip(1, ctMidi, 0, 100) == -1     # трека ещё нет
    discard s.addTrack(ttMidi, "T1")
    check s.addClip(1, ctMidi, 0, 0) == -1       # длина 0
    check s.addClip(1, ctMidi, 0, -5) == -1      # длина отрицательная
    check s.addClip(1, ctMidi, 0, 100) == 1

  test "addNote игнорирует несуществующий трек/клип":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    discard s.addTrack(ttMidi, "T1")
    discard s.addClip(1, ctMidi, 0, 960)

    s.addNote(9, 1, 0, 100, 60, 100)   # нет трека 9
    s.addNote(1, 9, 0, 100, 60, 100)   # нет клипа 9
    s.addNote(1, 1, 0, 100, 60, 100)   # валидная нота
    check s.tracks[0].clips[0].notes.len == 1

  test "addAutomationPoint группирует и сортирует точки по тику":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)

    s.addAutomationPoint(1, 1, tick = 300, value = 3.0f)
    s.addAutomationPoint(1, 1, tick = 100, value = 1.0f)
    s.addAutomationPoint(2, 5, tick = 50, value = 9.0f)   # другая дорожка

    check s.automationLanes.len == 2
    check s.automationLanes[0].nodeId == 1
    check s.automationLanes[0].points.len == 2
    check s.automationLanes[0].points[0].tick == 100
    check s.automationLanes[0].points[1].tick == 300
    check s.automationLanes[1].paramId == 5'u32

# =============================================================================
# Compile
# =============================================================================

suite "sequencer: compile":
  test "не-loop: noteOn/noteOff, обрезка по границе клипа, velocity 0..1":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    discard s.addTrack(ttMidi, "T1")
    discard s.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    # Короткая нота целиком внутри клипа.
    s.addNote(1, 1, startTick = 0, duration = 480, pitch = 60, velocity = 127)
    # Нота длиннее клипа: её noteOff обязан обрезаться концом клипа.
    s.addNote(1, 1, startTick = 480, duration = 960, pitch = 62, velocity = 64)

    let c = s.compile()
    check c.tracks.len == 1
    check c.tracks[0].clips.len == 1
    let ev = c.tracks[0].clips[0].events
    check ev.len == 4

    check ev[0].tick == 0
    check ev[0].kind == evNoteOn
    check ev[0].note == 60
    check ev[0].channel == 0
    check abs(ev[0].velocity - 1.0f) < 1e-6

    check ev[1].tick == 480
    check ev[1].kind == evNoteOff
    check ev[1].note == 60

    check ev[2].tick == 480
    check ev[2].kind == evNoteOn
    check ev[2].note == 62

    check ev[3].tick == 960          # min(start+dur, clipEnd): клип обрезал
    check ev[3].kind == evNoteOff
    check ev[3].note == 62

    check c.maxTick == 960

  test "loop: клип повторяется до maxSongTicks":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    discard s.addTrack(ttMidi, "T1")
    discard s.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    s.tracks[0].clips[0].loopEnabled = true
    s.addNote(1, 1, startTick = 0, duration = 240, pitch = 60, velocity = 100)

    let c = s.compile(maxSongTicks = 3000)
    let ev = c.tracks[0].clips[0].events
    # Итерации 0, 960, 1920, 2880 (a0 < 3000), затем 3840 >= 3000 — стоп.
    check ev.len == 8
    check ev[0].tick == 0    and ev[0].kind == evNoteOn
    check ev[1].tick == 240  and ev[1].kind == evNoteOff
    check ev[2].tick == 960  and ev[2].kind == evNoteOn
    check ev[3].tick == 1200 and ev[3].kind == evNoteOff
    check ev[4].tick == 1920 and ev[4].kind == evNoteOn
    check ev[6].tick == 2880 and ev[6].kind == evNoteOn
    check ev[7].tick == 3120 and ev[7].kind == evNoteOff
    check c.maxTick == 3120

  test "клип с неположительной длиной не даёт событий":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    discard s.addTrack(ttMidi, "T1")
    discard s.addClip(1, ctMidi, 0, 960)
    s.addNote(1, 1, 0, 100, 60, 100)
    s.tracks[0].clips[0].lengthTicks = 0
    let c = s.compile()
    check c.tracks[0].clips.len == 0
    check c.maxTick == 0

  test "maxTick учитывает автоматизацию даже без нот":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    s.addAutomationPoint(nodeId = 1, paramId = 2, tick = 5000, value = 1.0f)

    let c = s.compile()
    check c.automation.len == 1
    check c.automation[0].points.len == 1
    check c.maxTick == 5000

# =============================================================================
# Runtime
# =============================================================================

suite "sequencer: runtime":
  test "processBlock выбирает события блока и считает frameOffset":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    discard s.addTrack(ttMidi, "T1")
    discard s.addClip(1, ctMidi, 0, 9600)
    s.addNote(1, 1, 0, 100, 60, 127)
    s.addNote(1, 1, 1000, 100, 61, 127)
    s.addNote(1, 1, 2000, 100, 62, 127)

    var compiled = s.compile()
    var rt = initRuntime(addr compiled)
    var q: EventQueue

    rt.processBlock(0, 200, 1.0f, q)
    check q.count == 2
    check q.events[0].kind == evNoteOn and q.events[0].frameOffset == 0'u32
    check q.events[1].kind == evNoteOff and q.events[1].frameOffset == 100'u32

    rt.processBlock(200, 1200, 1.0f, q)
    check q.count == 2
    check q.events[0].kind == evNoteOn and q.events[0].frameOffset == 800'u32
    check q.events[1].kind == evNoteOff and q.events[1].frameOffset == 900'u32

    # Пустой блок очищает очередь (processBlock начинается с clearEvents).
    rt.processBlock(5000, 6000, 1.0f, q)
    check q.count == 0

  test "mute трека исключает его события":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    discard s.addTrack(ttMidi, "T1")
    discard s.addClip(1, ctMidi, 0, 9600)
    s.addNote(1, 1, 0, 100, 60, 127)
    s.tracks[0].mute = true

    var compiled = s.compile()
    check compiled.tracks[0].mute
    var rt = initRuntime(addr compiled)
    var q: EventQueue
    rt.processBlock(0, 9600, 1.0f, q)
    check q.count == 0

  test "переполнение EventQueue считается в droppedEvents":
    var t = initTransport(48000.0'f32)
    var s = initSequencer(addr t)
    discard s.addTrack(ttMidi, "T1")
    discard s.addClip(1, ctMidi, 0, 100000)
    for i in 0 ..< 200:
      s.addNote(1, 1, int32(i * 10), 5, 60, 100)   # 200 нот => 400 событий

    var compiled = s.compile()
    var rt = initRuntime(addr compiled)
    var q: EventQueue
    rt.processBlock(0, 100000, 1.0f, q)

    check q.count == MaxBlockEvents
    check rt.droppedEvents == uint32(400 - MaxBlockEvents)

  test "initRuntime с nil не падает":
    var rt = initRuntime(nil)
    var q: EventQueue
    rt.processBlock(0, 1000, 1.0f, q)
    check q.count == 0
    check rt.droppedEvents == 0'u32


# =============================================================================
# Автоматизация
# =============================================================================

suite "sequencer: automation":
  test "getAutomationValue: линейная интерполяция и края":
    var c: CompiledSequencer
    c.automation.add CompiledAutomation(
      nodeId: 1, paramId: 1,
      points: @[
        AutomationPoint(tick: 0, value: 0.0f, curve: acLinear),
        AutomationPoint(tick: 1000, value: 1.0f, curve: acLinear)
      ])

    check c.getAutomationValue(1, 1, -10) == 0.0f
    check c.getAutomationValue(1, 1, 0) == 0.0f
    check abs(c.getAutomationValue(1, 1, 500) - 0.5f) < 1e-5
    check c.getAutomationValue(1, 1, 1000) == 1.0f
    check c.getAutomationValue(1, 1, 5000) == 1.0f
    # Нет дорожки — 0.
    check c.getAutomationValue(99, 99, 500) == 0.0f

  test "step держит левое значение до следующей точки":
    var c: CompiledSequencer
    c.automation.add CompiledAutomation(
      nodeId: 1, paramId: 2,
      points: @[
        AutomationPoint(tick: 0, value: 0.25f, curve: acStep),
        AutomationPoint(tick: 1000, value: 0.75f, curve: acStep)
      ])
    check c.getAutomationValue(1, 2, 0) == 0.25f
    check c.getAutomationValue(1, 2, 999) == 0.25f
    check c.getAutomationValue(1, 2, 1000) == 0.75f

  test "fillAutomationBlock пишет значения на каждый сэмпл":
    var c: CompiledSequencer
    c.automation.add CompiledAutomation(
      nodeId: 2, paramId: 5,
      points: @[
        AutomationPoint(tick: 0, value: 0.0f, curve: acLinear),
        AutomationPoint(tick: 64, value: 1.0f, curve: acLinear)
      ])

    var buf = newSeq[float32](8)
    c.fillAutomationBlock(
      nodeId = 2, paramId = 5, blockStartTick = 0, ticksPerSample = 1.0f,
      output = cast[ptr UncheckedArray[float32]](addr buf[0]), numSamples = 8)
    for i in 0 ..< 8:
      check abs(buf[i] - float32(i) / 64.0f) < 1e-5

    # Отсутствующая дорожка заливает нулями, а не мусором.
    var buf2 = newSeq[float32](4)
    for i in 0 ..< buf2.len: buf2[i] = 1.0f
    c.fillAutomationBlock(
      nodeId = 99, paramId = 99, blockStartTick = 0, ticksPerSample = 1.0f,
      output = cast[ptr UncheckedArray[float32]](addr buf2[0]), numSamples = 4)
    for v in buf2:
      check v == 0.0f

