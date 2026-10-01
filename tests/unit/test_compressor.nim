# tests/unit/test_compressor.nim
#
# Комрессор: пропускание тихого, ослабление громкого, конечность.

import std/[unittest, math]
import sdk/node_api
import builtin/dynamics/compressor
import unit/test_support

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