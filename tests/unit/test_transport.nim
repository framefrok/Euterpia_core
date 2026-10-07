# tests/unit/test_transport.nim
#
# Control-plane таймлайн: BBT-конверсия и размер такта (issue #58).
#
# Баг, который этот тест фиксирует: доли считались ЧЕТВЕРТЯМИ, то есть
# знаменатель размера игнорировался. Для 6/8 `beat` не мог превысить 3,
# а `barBeatTickToSample(1, 4, 0)` уже выходил за границы такта.
#
# В 4/4 поведение не должно измениться — это проверяется явно, чтобы
# фикс не сломал самый частый случай.

import std/unittest
import std/atomics
import std/json
import transport

const
  Sr = 48000.0'f32
  Bpm = 120.0'f32
  # 120 BPM @ 48 кГц: четверть = 24000 сэмплов.
  SamplesPerQuarter = 24000.0

proc mk(num, den: int32): Transport =
  result = initTransport(Sr)
  result.setTempo(Bpm)
  result.timeSignature = TimeSignature(numerator: num, denominator: den)

proc ticksPerBeat(den: int32): int32 =
  ## 960 PPQ, пересчитанные в текущую долю.
  960'i32 * 4'i32 div den

suite "transport: размер такта и BBT":

  test "samplesPerBar учитывает знаменатель":
    var t = mk(4, 4)
    check t.samplesPerBar() == 96000.0
    t = mk(6, 8)
    check t.samplesPerBar() == 72000.0
    t = mk(3, 4)
    check t.samplesPerBar() == 72000.0
    t = mk(7, 8)
    check t.samplesPerBar() == 84000.0

  test "4/4: поведение не изменилось":
    var t = mk(4, 4)
    check t.samplesPerQuarter() == SamplesPerQuarter

    var e = t.sampleToBarBeatTick(0)
    check e.bar == 1 and e.beat == 1 and e.tick == 0

    e = t.sampleToBarBeatTick(24000)
    check e.bar == 1 and e.beat == 2 and e.tick == 0

    e = t.sampleToBarBeatTick(6000)
    check e.bar == 1 and e.beat == 1 and e.tick == 240

    e = t.sampleToBarBeatTick(96000)
    check e.bar == 2 and e.beat == 1 and e.tick == 0

    check t.barBeatTickToSample(1, 2, 0) == 24000
    check t.barBeatTickToSample(2, 1, 0) == 96000

  test "6/8: доля — восьмая, а не четверть":
    var t = mk(6, 8)
    # Восьмая = 24000 * 4 / 8 = 12000 сэмплов; такт = 72000.
    var e = t.sampleToBarBeatTick(0)
    check e.bar == 1 and e.beat == 1 and e.tick == 0

    e = t.sampleToBarBeatTick(12000)
    check e.bar == 1 and e.beat == 2 and e.tick == 0

    e = t.sampleToBarBeatTick(36000)
    check e.bar == 1 and e.beat == 4 and e.tick == 0

    e = t.sampleToBarBeatTick(60000)
    check e.bar == 1 and e.beat == 6 and e.tick == 0

    e = t.sampleToBarBeatTick(72000)
    check e.bar == 2 and e.beat == 1 and e.tick == 0

  test "6/8: обратная функция не выходит за такт":
    var t = mk(6, 8)
    check t.barBeatTickToSample(1, 1, 0) == 0
    check t.barBeatTickToSample(1, 4, 0) == 36000
    check t.barBeatTickToSample(1, 6, 0) == 60000
    check t.barBeatTickToSample(2, 1, 0) == 72000

  test "7/8: долей в такте семь":
    var t = mk(7, 8)
    var e = t.sampleToBarBeatTick(6 * 12000)
    check e.bar == 1 and e.beat == 7 and e.tick == 0
    e = t.sampleToBarBeatTick(7 * 12000)
    check e.bar == 2 and e.beat == 1 and e.tick == 0

  test "round-trip по всем размерам (в пределах разрешения тика)":
    for (num, den) in [(4'i32, 4'i32), (6'i32, 8'i32), (3'i32, 4'i32), (7'i32, 8'i32)]:
      var t = mk(num, den)
      let tpb = ticksPerBeat(den)
      for beat in 1 .. num:
        for tick in [0'i32, 1'i32, tpb div 2, tpb - 1'i32]:
          let sample = t.barBeatTickToSample(1, beat, tick)
          let back = t.sampleToBarBeatTick(sample)
          check back.bar == 1
          check back.beat == beat
          check back.tick == tick

  test "getSnapshot: доли и такты согласованы с размером":
    var t68 = mk(6, 8)
    # Середина 6/8-такта: 3 восьмых из 6.
    t68.setPosition(36000)
    let s68 = t68.getSnapshot()
    check abs(s68.barPosition - 0.5) < 1e-9
    check abs(s68.beatPosition - 3.0) < 1e-9
    check s68.tickPosition == 0

    var t44 = mk(4, 4)
    t44.setPosition(48000)   # середина 4/4-такта: 2 четверти из 4
    let s44 = t44.getSnapshot()
    check abs(s44.barPosition - 0.5) < 1e-9
    check abs(s44.beatPosition - 2.0) < 1e-9

  test "loop wrap не зависит от размера":
    var t = mk(6, 8)
    t.setLoop(true, 0, 72000)
    t.setPosition(71000)
    t.advancePosition(2000)          # 73000 -> 1000
    check t.samplePosition.load(moRelaxed) == 1000
    t.setPosition(500)
    t.advancePosition(-2000)         # назад за начало -> конец такта
    check t.samplePosition.load(moRelaxed) == 70500

suite "transport: offline-сессия (#257)":
  test "имена состояний обратимы":
    for s in [tsStopped, tsPlaying, tsRecording, tsPaused]:
      var back: TransportState
      check transportStateFromName(transportStateName(s), back)
      check back == s
    var unknown: TransportState
    check not transportStateFromName("nonsense", unknown)

  test "срез сессии переживает round-trip (состояние, позиция, цикл)":
    var t = mk(4, 4)
    t.setPosition(339000)
    t.setLoop(true, 192000, 384000)
    t.pause()

    let snap = t.sessionSnapshotJson()
    check snap["schema"].getStr == TransportSessionSchema
    check snap["state"].getStr == "paused"

    var restored = initTransport(Sr)
    check applySessionSnapshot(snap, restored)
    check restored.currentState() == tsPaused
    check restored.samplePosition.load(moRelaxed) == 339000
    check restored.loopEnabled.load(moRelaxed)
    check restored.loopStart.load(moRelaxed) == 192000
    check restored.loopEnd.load(moRelaxed) == 384000

  test "чужая или битая сессия отвергается, а не чинится молча":
    var t = initTransport(Sr)
    # Чужой schema.
    check not applySessionSnapshot(%*{"schema": "other.v9", "state": "playing"}, t)
    # Наш schema, но неизвестное состояние.
    check not applySessionSnapshot(
      %*{"schema": TransportSessionSchema, "state": "flying"}, t)
    # Не объект.
    check not applySessionSnapshot(newJArray(), t)
    # Состояние не изменилось: отвергнутое не «применилось наполовину».
    check t.currentState() == tsStopped
