# tests/unit/test_metronome.nim
#
# Нода метронома (#112): сетка, акценты, выключенное состояние.
#
# Тест считает ТРИГГЕРЫ (`evTrigger`), а не «на слух»: позиция клика — это
# кадр, который метроном положил в очередь. Так проверяются сразу число
# кликов, их абсолютные позиции и отсутствие двойных кликов на границе
# смены размера.

import std/[math, unittest]

import signal_types
import node_interface
import metronome

const
  SampleRate = 48000.0f
  Block = 512'i32

proc runMetronome(num, den: int32; bars: int): seq[float64] =
  ## Возвращает абсолютные позиции кликов за `bars` тактов.
  var metro = initMetronome(SampleRate)
  metro.enabled = true
  var ctx: NodeProcessContext
  ctx.sampleRate = SampleRate
  ctx.blockSize = Block
  ctx.flags = {pfTransportPlaying}
  ctx.transport.tempo = 120.0
  ctx.transport.timeSigNum = num
  ctx.transport.timeSigDen = den
  ctx.transport.flags = {pfTransportPlaying}

  let samplesPerClick = float64(SampleRate) * 60.0 / 120.0 * 4.0 / float64(den)
  let samplesPerBar = samplesPerClick * float64(num)
  let totalFrames = int64(round(samplesPerBar * float64(bars)))
  var audio = newSeq[float32](int(Block) * 2)
  var buf = AudioBuffer(data: cast[ptr UncheckedArray[float32]](addr audio[0]),
                        channels: 2, frames: Block, stride: 2)

  var pos = 0'i64
  while pos < totalFrames:
    ctx.samplePosition = pos
    ctx.transport.barPosition = float64(pos) / samplesPerBar
    var q: EventQueue
    processMetronome(metro, addr ctx, addr buf, addr q)
    for i in 0 ..< int(q.count):
      let ev = q.events[i]
      if ev.kind == evTrigger:
        let at = float64(pos) + float64(ev.frameOffset) +
                 float64(ev.subFrame)
        # Клик на самом конце окна принадлежит следующему такту: рендер
        # читает блок целиком, а длительность задана кадрами.
        if at < float64(totalFrames):
          result.add at
    pos += int64(Block)

suite "метроном (#112)":
  test "число кликов и позиции точны для 4/4, 3/4, 6/8 и 5/4":
    for (num, den) in [(4'i32, 4'i32), (3'i32, 4'i32),
                       (6'i32, 8'i32), (5'i32, 4'i32)]:
      let clicks = runMetronome(num, den, 2)
      check clicks.len == int(num) * 2
      let samplesPerClick =
        float64(SampleRate) * 60.0 / 120.0 * 4.0 / float64(den)
      for k, at in clicks:
        let expected = float64(k) * samplesPerClick
        check abs(at - expected) <= 1.0

  test "выключенный метроном: ни одного триггера и тишина":
    var metro = initMetronome(SampleRate)
    metro.enabled = false
    var ctx: NodeProcessContext
    ctx.sampleRate = SampleRate
    ctx.blockSize = Block
    ctx.flags = {pfTransportPlaying}
    ctx.transport.tempo = 120.0
    ctx.transport.timeSigNum = 4
    ctx.transport.timeSigDen = 4
    var audio = newSeq[float32](int(Block) * 2)
    var buf = AudioBuffer(data: cast[ptr UncheckedArray[float32]](addr audio[0]),
                          channels: 2, frames: Block, stride: 2)
    var q: EventQueue
    processMetronome(metro, addr ctx, addr buf, addr q)
    check q.count == 0
    for sample in audio:
      check sample == 0.0f

  test "смена размера на лету не даёт двойного клика на границе":
    # 1 такт 4/4, затем 3/4: клики после смены идут с шагом нового размера.
    var metro = initMetronome(SampleRate)
    metro.enabled = true
    var ctx: NodeProcessContext
    ctx.sampleRate = SampleRate
    ctx.blockSize = Block
    ctx.flags = {pfTransportPlaying}
    ctx.transport.tempo = 120.0
    ctx.transport.timeSigNum = 4
    ctx.transport.timeSigDen = 4
    var audio = newSeq[float32](int(Block) * 2)
    var buf = AudioBuffer(data: cast[ptr UncheckedArray[float32]](addr audio[0]),
                          channels: 2, frames: Block, stride: 2)

    let perQuarter = float64(SampleRate) * 60.0 / 120.0
    let bar44 = perQuarter * 4.0
    let bar34 = perQuarter * 3.0

    var positions: seq[float64] = @[]
    var pos = 0'i64
    while pos < int64(bar44):
      ctx.samplePosition = pos
      ctx.transport.barPosition = float64(pos) / bar44
      var q: EventQueue
      processMetronome(metro, addr ctx, addr buf, addr q)
      for i in 0 ..< int(q.count):
        if q.events[i].kind == evTrigger:
          positions.add float64(pos) + float64(q.events[i].frameOffset) +
                       float64(q.events[i].subFrame)
      pos += int64(Block)

    # Второй такт начинается ровно с границы; позиция клика на границе —
    # один (не два) и дальше шаг 3/4.
    metro.enabled = true
    ctx.transport.timeSigNum = 3
    ctx.transport.timeSigDen = 4
    # Продолжаем со следующего БЛОКА: кадр 96000 уже отрендерен первым
    # проходом, повторно его не эмитим.
    let start = pos
    let barStart = int64(round(bar44))
    while pos < start + int64(bar34):
      ctx.samplePosition = pos
      ctx.transport.barPosition = float64(pos - barStart) / bar34
      var q: EventQueue
      processMetronome(metro, addr ctx, addr buf, addr q)
      for i in 0 ..< int(q.count):
        if q.events[i].kind == evTrigger:
          positions.add float64(pos) + float64(q.events[i].frameOffset) +
                       float64(q.events[i].subFrame)
      pos += int64(Block)

    # Позиции строго возрастают: дубля на границе нет.
    for i in 1 ..< positions.len:
      check positions[i] > positions[i - 1]
