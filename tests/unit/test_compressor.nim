# tests/unit/test_compressor.nim
#
# Комрессор: пропускание тихого, ослабление громкого, конечность.

import std/[unittest, math]
import sdk/node_api
import signal_types
import node_interface
import builtin/dynamics/compressor
import builtin/native/eut_native
import unit/test_support

proc compGainDbFor(detector: cint; threshold, ratio, makeupDb,
                   inputLevel: float32; n = 8192): float32 =
  ## Gain reduction ядра на постоянном входе — после сходимости детектора.
  var c = newCompressor(1, detector, TestSampleRate)
  compSetParams(addr c, threshold, ratio, 0.0f, 0.001f, 0.05f, makeupDb)

  var buf = newSeq[float32](n)
  for i in 0 ..< n:
    buf[i] = inputLevel

  compDetect(addr c, addr buf[0], n)
  result = compGainDb(addr c)
  freeCompressor(addr c)

proc renderSineComp(amplitude, threshold, ratio: float32;
                    blocks: int): seq[float32] =
  var phase = 0.0'f64
  let inc = 2.0 * PI * 220.0 / float64(TestSampleRate)
  renderNode(getCompFactory(), getCompDesc(), blocks,
    setup = proc(state: pointer) =
      let f = getCompFactory()
      f.setParam(state, CompParamThreshold, threshold, false)
      f.setParam(state, CompParamRatio, ratio, false)
      f.setParam(state, CompParamKnee, 0.0f, false)     # жёсткое колено
      f.setParam(state, CompParamAttack, 0.001f, false)
      f.setParam(state, CompParamRelease, 0.05f, false)
      f.setParam(state, CompParamMakeup, 0.0f, false),
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, (amplitude * sin(phase)).float32)
        phase += inc
  )

proc renderBlockPlanar(blockSize, blocks: int; res: var seq[float32]) =
  ## Локальный харнесс с произвольным размером блока (issue #64).
  ##
  ## `test_support` фиксирован на TestBlockSize = 512 кадров, поэтому дефект
  ## «блок больше 1024» им не ловился. Арена планарная, как в реальном графе:
  ## канал 0 в [0, bs), канал 1 в [bs, 2*bs).
  var ctx = NodeProcessContext(sampleRate: TestSampleRate,
                               blockSize: blockSize.int32)
  var inData = newSeq[float32](blockSize * 2)
  var outData = newSeq[float32](blockSize * 2)
  var inBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr inData[0]),
    channels: 2, frames: blockSize.int32, stride: blockSize.int32)
  var outBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr outData[0]),
    channels: 2, frames: blockSize.int32, stride: blockSize.int32)
  var audio = NodeAudioPorts()
  audio.inputCount = 1
  audio.outputCount = 1
  audio.inputs[0] = addr inBuf
  audio.outputs[0] = addr outBuf

  let f = getCompFactory()
  let state = f.create(getCompDesc(), nil)
  f.setParam(state, CompParamThreshold, -20.0f, false)
  f.setParam(state, CompParamRatio, 8.0f, false)
  f.setParam(state, CompParamKnee, 0.0f, false)
  f.setParam(state, CompParamAttack, 0.001f, false)
  f.setParam(state, CompParamRelease, 0.05f, false)
  f.setParam(state, CompParamMakeup, 0.0f, false)

  var phase = 0.0
  for b in 0 ..< blocks:
    for i in 0 ..< blockSize:
      let s = float32(0.9 * sin(phase))     # 0.9 = -1 дБ: выше порога
      inData[i] = s
      inData[blockSize + i] = s
      phase += 2.0 * PI * 220.0 / float64(TestSampleRate)
    f.process(addr ctx, addr audio, nil, nil, state)
    for i in 0 ..< blockSize:
      res[b * blockSize + i] = outData[i]

  f.destroy(state)

suite "compressor":
  test "ниже порога: сигнал проходит без потерь":
    # 0.01 = -40 dB при пороге -20 dB: огибающая глубоко под коленом,
    # gain должен остаться 1.0.
    let s = renderSineComp(0.01f, -20.0f, 8.0f, 8)
    let tail = s[2048 .. ^1]
    check tail.isFinite()
    let ratio = tail.rms() / 0.01'f32 * 1.41421f   # RMS синуса = A/sqrt(2)
    check ratio > 0.85f and ratio < 1.15f

  test "выше порога: громкий сигнал ослабляется":
    # 0.5 = -6 dB, порог -20, ratio 8 -> GR = (17 dB over) * (1 - 1/8)
    # с учётом stereo-link scale (+3 dB на моно) ~ 15 dB.
    let s = renderSineComp(0.5f, -20.0f, 8.0f, 16)
    let tail = s[2048 .. ^1]
    check tail.isFinite()
    check tail.rms() < 0.5'f32 * 0.5f   # как минимум -6 dB ослабления

  test "GR растёт с ratio при том же входе":
    let soft = renderSineComp(0.5f, -20.0f, 2.0f, 16)
    let hard = renderSineComp(0.5f, -20.0f, 20.0f, 16)
    check hard[2048 .. ^1].rms() < soft[2048 .. ^1].rms()

  test "порог растёт -> ослабление слабее":
    let lowThr = renderSineComp(0.5f, -30.0f, 8.0f, 16)
    let highThr = renderSineComp(0.5f, -6.0f, 8.0f, 16)
    # При пороге -6 dB вход -6 dB едва над коленом: ослабление меньше.
    check highThr[2048 .. ^1].rms() > lowThr[2048 .. ^1].rms()

  test "нулевой вход -> тишина, без NaN от логарифма":
    let s = renderSineComp(0.0f, -20.0f, 8.0f, 8)
    check s.isFinite()
    check s.isSilent()

  test "makeup поднимает выход":
    let plain = renderSineComp(0.5f, -20.0f, 8.0f, 16)
    var phase = 0.0'f64
    let inc = 2.0 * PI * 220.0 / float64(TestSampleRate)
    let boosted = renderNode(getCompFactory(), getCompDesc(), 16,
      setup = proc(state: pointer) =
        let f = getCompFactory()
        f.setParam(state, CompParamThreshold, -20.0f, false)
        f.setParam(state, CompParamRatio, 8.0f, false)
        f.setParam(state, CompParamKnee, 0.0f, false)
        f.setParam(state, CompParamAttack, 0.001f, false)
        f.setParam(state, CompParamRelease, 0.05f, false)
        f.setParam(state, CompParamMakeup, 12.0f, false),
      prepare = proc(tb: var TestBuffers) =
        for i in 0 ..< TestBlockSize:
          tb.setInputSample(i, (0.5 * sin(phase)).float32)
          phase += inc
    )
    check boosted[2048 .. ^1].rms() > plain[2048 .. ^1].rms() * 1.5f

  # --- регрессии ядра (issues #25, #26) --------------------------------------

  test "RMS-детектор измеряет мощность, а не смесь V и V² (#25)":
    # Постоянный сигнал 0.354 (-9 дБ). Порог -30 дБ, ratio 4, knee 0:
    # over = 21 дБ, GR = -(1 - 1/4) * 21 = -15.75 дБ.
    # Со старым детектором (env смешивал V² и V) выходило около -9.2 дБ.
    let gr = compGainDbFor(EutCompRms, -30.0f, 4.0f, 0.0f, 0.354f)
    check abs(gr - (-15.75f)) < 0.6f

  test "gainDb = 0 при сигнале ниже порога (#26)":
    # -40 дБ вход, порог -12 дБ: подавления нет — метрика обязана быть 0,
    # а не «уровень относительно порога» (-28 дБ).
    let gr = compGainDbFor(EutCompPeak, -12.0f, 4.0f, 0.0f, 0.01f)
    check abs(gr) < 0.01f

  test "gainDb соответствует применённому gain и не зависит от makeup (#26)":
    # Порог -30 дБ, ratio 4, вход 0.5 (-6 дБ): over = 24 дБ -> GR = -18 дБ.
    let gr = compGainDbFor(EutCompPeak, -30.0f, 4.0f, 0.0f, 0.5f)
    check abs(gr - (-18.0f)) < 0.6f

    # makeup меняет звук, но не gain reduction: метрика должна совпадать.
    let grMakeup = compGainDbFor(EutCompPeak, -30.0f, 4.0f, 6.0f, 0.5f)
    check abs(grMakeup - gr) < 0.6f

  test "блок больше 1024: хвост обрабатывается, а не глушится (#64)":
    var one = newSeq[float32](2048)
    var two = newSeq[float32](2048)
    renderBlockPlanar(2048, 1, one)   # один большой блок
    renderBlockPlanar(1024, 2, two)   # эталон: два блока по 1024

    check one.isFinite()

    # На исходной версии сэмплы после 1024-го читали память ЗА границей
    # gainCurve (ASan: heap-buffer-overflow, «0 bytes after 4152-byte
    # region»), и хвост блока превращался в тишину.
    check abs(one[1024]) > 0.01f
    check abs(one[^1]) > 0.01f

    # К концу блока сглаживание параметров сходится, поэтому хвост обязан
    # совпасть с эталонным разбиением: на баговой версии тут 0.0 против
    # 0.068 (глушение хвоста), с фиксом разница нулевая.
    check abs(one[^1] - two[^1]) < 1e-4f

  test "максимальный блок 4096 кадров: конечный результат и сжатие (#64)":
    var s = newSeq[float32](4096)
    renderBlockPlanar(4096, 1, s)

    check s.isFinite()
    check abs(s[0]) < 1e-6f        # вход 0 -> выход 0
    check abs(s[^1]) > 0.01f       # хвост блока сжат, а не обнулён
    # 0.9 = -1 дБ при пороге -20 дБ и ratio 8: ожидаем ослабление
    check abs(s[^1]) < 0.9f * 0.5f