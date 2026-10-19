# tests/unit/test_src.nim
#
# Контракт ресемплинга (issue #8).
#
# Что доказывается:
#   1. синус через 44.1k→48k и 48k→44.1k не даёт NaN/Inf и клиппинга,
#      а амплитуда и RMS сохраняются;
#   2. длительность потока совпадает с ожидаемой с точностью до сэмпла
#      (с учётом заявленной задержки окна);
#   3. `process` пишет не больше `maxOutFrames`;
#   4. ошибки конфигурации — nil/0, а не падение;
#   5. каналы независимы (стерео не перемешивается).

import std/[unittest, math]

import src_api
import stream_resampler

const
  TestBlock = 512
  TestChannels = 2
  TestSeconds = 0.5

proc rmsOf(samples: openArray[float32]): float64 =
  if samples.len == 0:
    return 0.0
  var sum = 0.0
  for v in samples:
    sum += float64(v) * float64(v)
  sqrt(sum / float64(samples.len))

proc peakOf(samples: openArray[float32]): float64 =
  result = 0.0
  for v in samples:
    let a = abs(float64(v))
    if a > result:
      result = a

type
  Rig = object
    api: ptr SrcApi
    handle: SrcHandle
    inBuf: array[TestChannels, array[TestBlock, float32]]
    outBuf: array[TestChannels, array[TestBlock * 4, float32]]

proc openRig(inRate, outRate: float64; channels = TestChannels): Rig =
  result.api = newSrcApi()
  doAssert result.api != nil
  doAssert srcInit(result.api, nil) == seOk
  result.handle = srcCreateConverter(result.api, inRate, outRate,
                                     int32(channels), int32(TestBlock))
  doAssert result.handle != nil

proc closeRig(rig: var Rig) =
  if rig.api != nil:
    srcDestroyConverter(rig.api, rig.handle)
    srcShutdown(rig.api)
    freeSrcApi(rig.api)
    rig.api = nil
    rig.handle = nil

proc maxOutFor(inFrames, inRate, outRate: int): int =
  ## Верхняя граница выходных кадров для блока: ceil + запас на дробную фазу.
  int(ceil(float64(inFrames) * float64(outRate) / float64(inRate))) + 8

proc runSine(rig: var Rig; inRate, outRate, freq: float64;
             channels = TestChannels;
             outLeft, outRight: var seq[float32]) =
  ## Прогоняет TestSeconds секунд синуса блоками и складывает выход
  ## по каналам.
  let totalIn = int(float64(inRate) * TestSeconds)
  var done = 0
  var phase = 0.0
  let step = 2.0 * PI * freq / inRate
  outLeft = @[]
  outRight = @[]
  while done < totalIn:
    let frames = min(TestBlock, totalIn - done)
    for i in 0 ..< frames:
      let v = float32(sin(phase))
      for ch in 0 ..< channels:
        rig.inBuf[ch][i] = v
      phase += step
      if phase >= 2.0 * PI:
        phase -= 2.0 * PI
    let maxOut = maxOutFor(frames, int(inRate), int(outRate))
    let produced = srcProcess(
      rig.api, rig.handle,
      cast[ptr UncheckedArray[float32]](addr rig.inBuf[0][0]),
      int32(TestBlock),
      int32(frames),
      cast[ptr UncheckedArray[float32]](addr rig.outBuf[0][0]),
      int32(TestBlock * 4),
      int32(maxOut))
    check produced >= 0
    check produced <= maxOut
    for i in 0 ..< produced:
      if channels > 0: outLeft.add rig.outBuf[0][i]
      if channels > 1: outRight.add rig.outBuf[1][i]
    done += frames

suite "src: контракт ресемплинга (#8)":

  test "upsampling 44.1k→48k: без NaN/Inf, амплитуда и RMS сохранены":
    var rig = openRig(44100.0, 48000.0)
    defer: rig.closeRig()
    var left, right: seq[float32]
    runSine(rig, 44100.0, 48000.0, 1000.0, TestChannels, left, right)

    check left.len > 0
    for v in left:
      check classify(float64(v)) notin {fcNan, fcInf, fcNegInf}
    # Первые кадры — прайминг окна (история нулевая), их не учитываем.
    let skip = left.len div 10
    let body = left[skip .. ^1]
    let peak = peakOf(body)
    check peak > 0.9
    check peak <= 1.05        # конечное окно даёт десятые доли процента выброса
    check abs(rmsOf(body) - 0.7071) < 0.03

  test "длительность совпадает с отношением частот (в пределах сэмпла)":
    var rig = openRig(44100.0, 48000.0)
    defer: rig.closeRig()
    var left, right: seq[float32]
    let totalIn = 44100 * 2
    var done = 0
    var phase = 0.0
    let step = 2.0 * PI * 440.0 / 44100.0
    while done < totalIn:
      let frames = min(TestBlock, totalIn - done)
      for i in 0 ..< frames:
        let v = float32(sin(phase))
        rig.inBuf[0][i] = v
        rig.inBuf[1][i] = v
        phase += step
      let produced = srcProcess(
        rig.api, rig.handle,
        cast[ptr UncheckedArray[float32]](addr rig.inBuf[0][0]),
        int32(TestBlock), int32(frames),
        cast[ptr UncheckedArray[float32]](addr rig.outBuf[0][0]),
        int32(TestBlock * 4),
        int32(maxOutFor(frames, 44100, 48000)))
      for i in 0 ..< produced:
        left.add rig.outBuf[0][i]
      done += frames
    # Задержка окна — половина taps входных кадров; остальное обязано
    # совпасть с 48000/44100.
    let expected = int(floor(float64(totalIn - 12) * 48000.0 / 44100.0))
    check abs(left.len - expected) <= 2

  test "upsampling 16k→48k (кратное отношение) не клиппирует":
    var rig = openRig(16000.0, 48000.0)
    defer: rig.closeRig()
    var left, right: seq[float32]
    runSine(rig, 16000.0, 48000.0, 1000.0, TestChannels, left, right)
    let body = left[left.len div 10 .. ^1]
    check peakOf(body) > 0.9
    check peakOf(body) <= 1.05

  test "каналы независимы: DC 0.5 слева и 0 справа":
    var rig = openRig(48000.0, 48000.0)
    defer: rig.closeRig()
    for i in 0 ..< TestBlock:
      rig.inBuf[0][i] = 0.5'f32
      rig.inBuf[1][i] = 0.0'f32
    let produced = srcProcess(
      rig.api, rig.handle,
      cast[ptr UncheckedArray[float32]](addr rig.inBuf[0][0]),
      int32(TestBlock), int32(TestBlock),
      cast[ptr UncheckedArray[float32]](addr rig.outBuf[0][0]),
      int32(TestBlock * 4), int32(TestBlock))
    check produced > 0
    # Первые кадры — прайминг окна: там история ещё нулевая.
    for i in 16 ..< produced:
      check abs(float64(rig.outBuf[0][i]) - 0.5) < 1.0e-4
      check abs(float64(rig.outBuf[1][i])) < 1.0e-4

  test "ошибки конфигурации: nil/0 вместо падения":
    let api = newSrcApi()
    doAssert api != nil
    defer: freeSrcApi(api)
    check srcCreateConverter(api, 0.0, 48000.0, 2, 512).isNil
    check srcCreateConverter(api, 48000.0, -1.0, 2, 512).isNil
    check srcCreateConverter(api, 1.0, 48000.0, 2, 512).isNil
    check srcCreateConverter(api, 48000.0, 48000.0, 0, 512).isNil
    check srcCreateConverter(api, 48000.0, 48000.0, 3, 512).isNil
    check srcCreateConverter(api, 48000.0, 48000.0, 2, 4).isNil
    check srcProcess(api, nil, nil, 0, 0, nil, 0, 0) == 0

  test "latency > 0 и reset возвращает поток в исходное состояние":
    var rig = openRig(44100.0, 48000.0)
    defer: rig.closeRig()
    check srcLatencyFrames(rig.api, rig.handle) > 0

    for i in 0 ..< TestBlock:
      rig.inBuf[0][i] = 0.25'f32
      rig.inBuf[1][i] = 0.25'f32
    discard srcProcess(rig.api, rig.handle,
      cast[ptr UncheckedArray[float32]](addr rig.inBuf[0][0]),
      int32(TestBlock), int32(TestBlock),
      cast[ptr UncheckedArray[float32]](addr rig.outBuf[0][0]),
      int32(TestBlock * 4), int32(TestBlock))
    srcReset(rig.api, rig.handle)
    let after = srcProcess(rig.api, rig.handle,
      cast[ptr UncheckedArray[float32]](addr rig.inBuf[0][0]),
      int32(TestBlock), int32(TestBlock),
      cast[ptr UncheckedArray[float32]](addr rig.outBuf[0][0]),
      int32(TestBlock * 4), int32(TestBlock))
    check after > 0
    # После reset окно снова праймится нулями: первый отсчёт меньше DC.
    check abs(float64(rig.outBuf[0][0])) < 0.25
    check srcBackendNameOf(rig.api) == "polyphase-sinc"

  test "downsampling 48k→44.1k: без NaN/Inf и клиппинга":
    var rig = openRig(48000.0, 44100.0)
    defer: rig.closeRig()
    var left, right: seq[float32]
    runSine(rig, 48000.0, 44100.0, 1000.0, TestChannels, left, right)

    check left.len > 0
    for v in left:
      check classify(float64(v)) notin {fcNan, fcInf, fcNegInf}
    let skip = left.len div 10
    let body = left[skip .. ^1]
    check peakOf(body) > 0.9
    check peakOf(body) <= 1.05
    check abs(rmsOf(body) - 0.7071) < 0.03
