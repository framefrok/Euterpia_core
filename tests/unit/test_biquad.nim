# tests/unit/test_biquad.nim
#
# Biquad: амплитудно-частотная характеристика, устойчивость, типы фильтров.
#
# Проверяется не «числа совпали с эталоном», а физические свойства:
# проходная полоса без затухания, -3 dB на частоте среза, ноль в вы notch.

import std/[unittest, math]
import sdk/node_api
import builtin/filters/biquad
import builtin/native/eut_native
import unit/test_support

const
  LowShelfType  = 5.0'f32
  HighShelfType = 6.0'f32

proc renderSine(factory: ptr NodeFactory; desc: ptr NodeDesc;
               freq: float32; blocks: int;
               setup: proc(state: pointer)): seq[float32] =
  ## Рендер синуна заданной частоты во вход ноды.
  var phase = 0.0'f64
  let inc = 2.0 * PI * float64(freq) / float64(TestSampleRate)

  result = renderNode(factory, desc, blocks, setup = setup,
    prepare = proc(tb: var TestBuffers) =
      for i in 0 ..< TestBlockSize:
        tb.setInputSample(i, sin(phase).float32)
        phase += inc
  )

proc amplitudeAt(samples: openArray[float32]; freq: float32;
                 startFrom: int): float32 =
  ## Амплитуда по фазе на фиксированной частоте.
  var maxAbs = 0.0'f32
  var i = startFrom
  while i < samples.len:
    let v = samples[i]
    if abs(v) > maxAbs:
      maxAbs = abs(v)
    i += 1
  maxAbs

proc renderBiquadNative(kind: cint; freq, q, gainDb, inputFreq: float32;
                        blocks: int; redesignEachBlock: bool): seq[float32] =
  ## Рендер через C-ядро напрямую, блок за блоком, с повторным design()
  ## перед каждым блоком или без него — так же, как это делает нода.
  var b = newBiquad()
  # Коэффициенты считаются один раз всегда; режим redesignEachBlock лишь
  # повторяет design() перед каждым блоком — как это делает нода.
  biquadDesign(addr b, kind, TestSampleRate, freq, q, gainDb)

  var phase = 0.0'f64
  let inc = 2.0 * PI * float64(inputFreq) / float64(TestSampleRate)
  var bufIn, bufOut: array[TestBlockSize, float32]
  result = newSeq[float32](blocks * TestBlockSize)

  for blk in 0 ..< blocks:
    for i in 0 ..< TestBlockSize:
      bufIn[i] = sin(phase).float32
      phase += inc
    if redesignEachBlock:
      biquadDesign(addr b, kind, TestSampleRate, freq, q, gainDb)
    biquadProcess(addr b, addr bufIn[0], addr bufOut[0], TestBlockSize)
    for i in 0 ..< TestBlockSize:
      result[blk * TestBlockSize + i] = bufOut[i]

  freeBiquad(addr b)

proc renderShelf(kind, freq, gainDb: float32; blocks: int): seq[float32] =
  ## Полка (low/high shelf): рендер синуса заданной частоты через ноду.
  renderSine(getBiquadFactory(), getBiquadDesc(), freq, blocks,
    setup = proc(state: pointer) =
      let f = getBiquadFactory()
      f.setParam(state, BiquadParamType, kind, false)
      f.setParam(state, BiquadParamCutoff, 1000.0f, false)
      f.setParam(state, BiquadParamQ, 0.707f, false)
      f.setParam(state, BiquadParamGain, gainDb, false)
  )

suite "biquad":
  test "lowpass: проходная полоса без потерь":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 100.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 0.707f, false)
    )

    check signal.isFinite()
    check amplitudeAt(signal, 100.0f, 1024) > 0.85f

  test "lowpass: -3 dB на частоте среза":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 1000.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 0.707f, false)
    )

    let amp = amplitudeAt(signal, 1000.0f, 2048)
    # Фильтр Баттерворта 2-го порядка даёт -3.01 dB = 0.707 амплитуды.
    check amp > 0.6f and amp < 0.8f

  test "lowpass: сигнал далеко выше среза подавляется":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 12000.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 0.707f, false)
    )

    check amplitudeAt(signal, 12000.0f, 2048) < 0.1f

  test "notch: на частоте среза сигнал практически отсутствует":
    let signal = renderSine(getBiquadFactory(), getBiquadDesc(), 1000.0f, 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 3.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 1000.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 4.0f, false)
    )

    check signal.isFinite()
    check amplitudeAt(signal, 1000.0f, 4096) < 0.05f

  test "импульс: фильтр устойчив, хвост затухает в ноль":
    let signal = renderNode(getBiquadFactory(), getBiquadDesc(), 8,
      setup = proc(state: pointer) =
        getBiquadFactory().setParam(state, BiquadParamType, 0.0f, false)
        getBiquadFactory().setParam(state, BiquadParamCutoff, 400.0f, false)
        getBiquadFactory().setParam(state, BiquadParamQ, 8.0f, false),
      prepare = proc(tb: var TestBuffers) =
        discard
    )

    check signal.isFinite()
    # Высокий Q даёт долгий хвост, но он обязан затухнуть, а не
    # расти или уйти в бесконечность.
    check signal.peak() <= 1.5f

  # --- регрессии ядра (issues #19, #20) --------------------------------------

  test "design() не рвёт состояние: блочный и непрерывный рендер совпадают (#19)":
    # design() вызывается нодой на каждый блок. Если он обнуляет z1/z2,
    # выход «обрывается» на каждой границе блока (щелчок с периодом blockSize),
    # и блочный рендер перестаёт совпадать с непрерывным.
    let blockwise = renderBiquadNative(EutBiquadLowpass, 1000.0f, 0.707f, 0.0f,
                                       440.0f, 8, redesignEachBlock = true)
    let continuous = renderBiquadNative(EutBiquadLowpass, 1000.0f, 0.707f, 0.0f,
                                        440.0f, 8, redesignEachBlock = false)
    var maxDiff = 0.0'f32
    for i in 0 ..< blockwise.len:
      maxDiff = max(maxDiff, abs(blockwise[i] - continuous[i]))
    check maxDiff < 1.0e-4f

  test "lowShelf +6 dB: 100 Гц = +6 dB, 1 кГц = +3 dB, 12 кГц = 0 dB (#20)":
    check abs(renderShelf(LowShelfType, 100.0f, 6.0f, 8)[2048 .. ^1].peak() - 2.000f) < 0.15f
    check abs(renderShelf(LowShelfType, 1000.0f, 6.0f, 8)[2048 .. ^1].peak() - 1.414f) < 0.10f
    check abs(renderShelf(LowShelfType, 12000.0f, 6.0f, 8)[2048 .. ^1].peak() - 1.000f) < 0.10f

  test "highShelf +6 dB зеркален lowShelf (#20)":
    check abs(renderShelf(HighShelfType, 100.0f, 6.0f, 8)[2048 .. ^1].peak() - 1.000f) < 0.10f
    check abs(renderShelf(HighShelfType, 1000.0f, 6.0f, 8)[2048 .. ^1].peak() - 1.414f) < 0.10f
    check abs(renderShelf(HighShelfType, 12000.0f, 6.0f, 8)[2048 .. ^1].peak() - 2.000f) < 0.15f

  test "полки с gain = 0 dB полностью прозрачны (#20)":
    for kind in [LowShelfType, HighShelfType]:
      for f in [100.0f, 1000.0f, 12000.0f]:
        check abs(renderShelf(kind, f, 0.0f, 8)[2048 .. ^1].peak() - 1.0f) < 0.05f
