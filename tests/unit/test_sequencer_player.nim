# tests/unit/test_sequencer_player.nim
#
# Нода `euterpia.sequencer` (#87): клипы проекта → события графа.
#
# Проверяется то, ради чего нода существует:
#   * `SequencerRuntime.processBlock` действительно вызывается из process
#     (до #87 он не вызывался ни из одной ноды);
#   * события стоят в тех же кадрах, что и в `test_sequencer` — с точностью
#     до кадра, а не до блока;
#   * loop-клип повторяется, mute-дорожка молчит;
#   * переполнение очереди считается, а не теряется молча;
#   * без транспорта (не играет) нода молчит.

import std/[unittest, math]

import signal_types
import node_interface
import sequencer
import builtin/io/sequencer_player

const
  Ssr = 48000.0f
  Tempo = 120.0
  SamplesPerTick = 25.0
    ## 48000 Гц * 60 / (120 BPM * 960 PPQ).

proc makeContext(samplePosition: int64; frames: int32 = 512;
                 playing = true): NodeProcessContext =
  result.sampleRate = Ssr
  result.blockSize = frames
  result.samplePosition = samplePosition
  result.transport.tempo = Tempo
  result.flags = if playing: {pfTransportPlaying} else: {}

proc makeCompiled(sq: Sequencer; maxTicks: int32): ref CompiledSequencer =
  ## Владелец — тест: `ref` живёт до конца теста.
  result = new(CompiledSequencer)
  result[] = sq.compile(maxTicks)

proc runBlock(st: pointer; ctx: NodeProcessContext): tuple[q: EventQueue;
                                                        dropped: uint32] =
  var q: EventQueue
  var ports = NodeEventPorts()
  ports.outputCount = 1
  ports.outputs[0] = addr q
  var c = ctx
  processSequencerNode(addr c, nil, nil, addr ports, st)
  (q, droppedEvents(st))

suite "sequencer player (#87)":
  test "события стоят в тех же кадрах, что и в sequencer":
    var sq = Sequencer()
    discard sq.addTrack(ttMidi, "T")
    discard sq.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    sq.addNote(1, 1, startTick = 0, duration = 100, pitch = 60, velocity = 100)
    sq.addNote(1, 1, startTick = 480, duration = 100, pitch = 64, velocity = 80)

    let compiled = makeCompiled(sq, 960)

    let f = getSequencerPlayerFactory()
    let st = f.create(getSequencerPlayerDesc(), nil)
    check st != nil
    defer: f.destroy(st)
    setCompiledSequencer(st, addr compiled[])

    # Блок 0..511: тик 0 → кадр 0; тик 480 ещё не наступил.
    let a = runBlock(st, makeContext(0))
    check a.q.count == 1
    check a.q.events[0].kind == evNoteOn
    check a.q.events[0].frameOffset == 0'u32
    check a.q.events[0].data[0] == 60.0f
    check abs(a.q.events[0].data[1] - 100.0f / 127.0f) < 1e-6

    # Тик 480 = кадр 12000. Блок, начавшийся ровно на нём, — offset 0.
    let b = runBlock(st, makeContext(12000))
    check b.q.count >= 1
    check b.q.events[0].kind == evNoteOn
    check b.q.events[0].frameOffset == 0'u32
    check b.q.events[0].data[0] == 64.0f

    # Блок, начавшийся за 10 кадров до атаки: offset ровно 10.
    let c = runBlock(st, makeContext(11990))
    check c.q.count >= 1
    check c.q.events[0].frameOffset == 10'u32

  test "note-off приходит в своём кадре, а не в начале блока":
    var sq = Sequencer()
    discard sq.addTrack(ttMidi, "T")
    discard sq.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    sq.addNote(1, 1, startTick = 0, duration = 40, pitch = 60, velocity = 100)

    let compiled = makeCompiled(sq, 960)
    let f = getSequencerPlayerFactory()
    let st = f.create(getSequencerPlayerDesc(), nil)
    defer: f.destroy(st)
    setCompiledSequencer(st, addr compiled[])

    # Тик 40 = кадр 1000: блок 500..1011 должен увидеть off на кадре 500.
    let a = runBlock(st, makeContext(500))
    check a.q.count == 1
    check a.q.events[0].kind == evNoteOff
    check a.q.events[0].frameOffset == 500'u32

  test "loop-клип повторяется на каждом витке":
    var sq = Sequencer()
    discard sq.addTrack(ttMidi, "T")
    let clip = sq.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    sq.tracks[0].clips[0].loopEnabled = true
    sq.addNote(1, clip, startTick = 0, duration = 100, pitch = 62, velocity = 90)

    # Две копии: 0 и 960 тиков.
    let compiled = makeCompiled(sq, 1920)
    let f = getSequencerPlayerFactory()
    let st = f.create(getSequencerPlayerDesc(), nil)
    defer: f.destroy(st)
    setCompiledSequencer(st, addr compiled[])

    let first = runBlock(st, makeContext(0))
    let second = runBlock(st, makeContext(int64(960.0 * SamplesPerTick)))
    check first.q.count >= 1
    check second.q.count >= 1
    check second.q.events[0].kind == evNoteOn
    check second.q.events[0].frameOffset == 0'u32
    check second.q.events[0].data[0] == 62.0f

  test "mute дорожки глушит её события":
    var sq = Sequencer()
    discard sq.addTrack(ttMidi, "T")
    discard sq.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    sq.addNote(1, 1, startTick = 0, duration = 100, pitch = 60, velocity = 100)
    sq.tracks[0].mute = true

    let compiled = makeCompiled(sq, 960)
    let f = getSequencerPlayerFactory()
    let st = f.create(getSequencerPlayerDesc(), nil)
    defer: f.destroy(st)
    setCompiledSequencer(st, addr compiled[])

    let a = runBlock(st, makeContext(0))
    check a.q.count == 0

  test "переполнение очереди считается (droppedEvents)":
    var sq = Sequencer()
    discard sq.addTrack(ttMidi, "T")
    discard sq.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    # 200 нот на одном тике = 400 событий: больше MaxBlockEvents.
    for i in 0 ..< 200:
      sq.addNote(1, 1, startTick = 0, duration = 10,
                 pitch = uint8(30 + i mod 60), velocity = 100)

    let compiled = makeCompiled(sq, 960)
    let f = getSequencerPlayerFactory()
    let st = f.create(getSequencerPlayerDesc(), nil)
    defer: f.destroy(st)
    setCompiledSequencer(st, addr compiled[])

    let a = runBlock(st, makeContext(0))
    check int(a.q.count) == MaxBlockEvents
    check a.dropped > 0'u32

  test "без транспорта нода молчит и очищает выход":
    var sq = Sequencer()
    discard sq.addTrack(ttMidi, "T")
    discard sq.addClip(1, ctMidi, startTick = 0, lengthTicks = 960)
    sq.addNote(1, 1, startTick = 0, duration = 100, pitch = 60, velocity = 100)

    let compiled = makeCompiled(sq, 960)
    let f = getSequencerPlayerFactory()
    let st = f.create(getSequencerPlayerDesc(), nil)
    defer: f.destroy(st)
    setCompiledSequencer(st, addr compiled[])

    let a = runBlock(st, makeContext(0, playing = false))
    check a.q.count == 0

  test "отвязанный секвенсор (nil) — тишина":
    let f = getSequencerPlayerFactory()
    let st = f.create(getSequencerPlayerDesc(), nil)
    defer: f.destroy(st)
    check compiledSequencer(st).isNil

    let a = runBlock(st, makeContext(0))
    check a.q.count == 0
