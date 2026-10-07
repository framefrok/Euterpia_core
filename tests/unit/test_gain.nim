# tests/unit/test_gain.nim
#
# Gain: линейность, точность dB-преобразования, крайние значения.

import std/[unittest, math]
import signal_types
import node_interface
import sdk/node_api
import builtin/mixing/gain
import unit/test_support

proc renderSineGain(db: float32; blocks: int): seq[float32] =
  ## Синус 440 Гц амплитуды 0.5 во вход, gain задан в dB.
  var phase = 0.0'f64
  let inc = 2.0 * PI * 440.0 / float64(TestSampleRate)
  renderNode(getGainFactory(), getGainDesc(), blocks,
    setup = proc(state: pointer) =
      getGainFactory().setParam(state, GainParamGain, db, false),
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, (0.5 * sin(phase)).float32)
        phase += inc
  )

proc renderConstGain(db: float32; blockSize: int; total: int): seq[float32] =
  ## Вход — константа 1.0, поэтому выход равен мгновенному линейному усилению.
  ## Один и тот же переход при разных blockSize обязан совпасть по сэмплам.
  let factory = getGainFactory()
  let desc = getGainDesc()
  let state = factory.create(desc, nil)
  check state != nil
  factory.setParam(state, GainParamGain, db, false)

  var inBuf = newSeq[float32](blockSize)
  var outBuf = newSeq[float32](blockSize)
  for i in 0 ..< blockSize:
    inBuf[i] = 1.0f

  var ctx: NodeProcessContext
  ctx.sampleRate = 48000.0f
  ctx.blockSize = int32(blockSize)

  var ab: AudioBuffer
  ab.data = cast[ptr UncheckedArray[float32]](addr inBuf[0])
  ab.channels = 1
  ab.frames = int32(blockSize)
  ab.stride = int32(blockSize)

  var ob: AudioBuffer
  ob.data = cast[ptr UncheckedArray[float32]](addr outBuf[0])
  ob.channels = 1
  ob.frames = int32(blockSize)
  ob.stride = int32(blockSize)

  var audio: NodeAudioPorts
  audio.inputCount = 1
  audio.outputCount = 1
  audio.inputs[0] = addr ab
  audio.outputs[0] = addr ob

  result = newSeq[float32](total)
  var done = 0
  while done < total:
    ctx.samplePosition = int64(done)
    factory.process(addr ctx, addr audio, nil, nil, state)
    for i in 0 ..< blockSize:
      result[done + i] = outBuf[i]
    done += blockSize

  factory.destroy(state)

suite "gain":
  test "переход усиления идентичен при blockSize 64/512/4096 (#386)":
    ## Регрессия: раньше нода применяла значение КОНЦА блока ко всему блоку,
    ## и форма перехода зависела от blockSize. Теперь — тот же поток сэмплов.
    let a64 = renderConstGain(-12.0f, 64, 4096)
    let a512 = renderConstGain(-12.0f, 512, 4096)
    let a4096 = renderConstGain(-12.0f, 4096, 4096)

    check a64.len == 4096
    for i in 0 ..< 4096:
      check abs(a64[i] - a512[i]) < 2e-4f
      check abs(a64[i] - a4096[i]) < 2e-4f

  test "0 dB: сигнал проходит без изменения":
    # Первые блоки отбрасываются: сглаживание 15 мс должно дойти до цели.
    let sig = renderSineGain(0.0f, 8)
    let tail = sig[2048 .. ^1]
    check tail.isFinite()
    check abs(tail.peak() - 0.5f) < 0.01f

  test "-6 dB: амплитуда ровно в 0.501187 раза":
    let sig = renderSineGain(-6.0f, 8)
    let tail = sig[2048 .. ^1]
    # dbToLin(-6) = 2^(-6/6.0206) = 0.501187
    let ratio = tail.peak() / 0.5'f32
    check abs(ratio - 0.501187f) < 0.01f

  test "+6 dB: амплитуда почти вдвое":
    let sig = renderSineGain(6.0f, 8)
    let tail = sig[2048 .. ^1]
    # dbToLin(6) = 1.99526
    check abs(tail.peak() - 0.5f * 1.99526f) < 0.03f

  test "-80 dB: практическая тишина без NaN":
    let sig = renderSineGain(-80.0f, 6)
    check sig.isFinite()
    check sig[2048 .. ^1].peak() < 2.0e-4f

  test "getParam возвращает заданное, а не сглаженное":
    # UI и автоматизация читают целевое значение: сглаженное в момент
    # чтения ещё не доехало, и ползунок «прыгал бы назад».
    let state = getGainFactory().create(getGainDesc(), nil)
    check state != nil
    getGainFactory().setParam(state, GainParamGain, -12.5f, false)
    var v = 0.0'f32
    check getGainFactory().getParam(state, GainParamGain, addr v)
    check abs(v - (-12.5f)) < 1e-4f
    getGainFactory().destroy(state)