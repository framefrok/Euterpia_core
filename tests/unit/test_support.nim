# tests/unit/test_support.nim
#
# Общая оснастка юнит-тестов DSP: сборка портов, рендер ноды блоками,
# измерения сигнала.
#
# Тесты НЕ realtime: здесь можно выделять память и использовать seq.
# Проверка отсутствия аллокаций живёт отдельно, в tests/realtime.

import
  std/math,
  signal_types,
  node_interface
import sdk/node_api

const
  TestSampleRate* = 48000.0'f32
  TestBlockSize* = 512

type
  TestBuffers* = object
    ## Хранилище под аудио и контекст.
    ##
    ## Владеет памятью сэмплов, пока живёт сам объект: порты ноды
    ## хранят указатели на буферы, поэтому буферы должны пережить вызов.
    ctx: NodeProcessContext
    audio: NodeAudioPorts
    eventsIn: EventQueue

    ## Номер текущего блока (0-based): prepare может различать
    ## первый блок (импульс) и последующие (тишина).
    blockIndex*: int

    inL, inR: array[TestBlockSize, float32]
    outL, outR: array[TestBlockSize, float32]

    inBuf: AudioBuffer
    outBuf: AudioBuffer

proc initTestBuffers*(tb: var TestBuffers) =
  tb.ctx = NodeProcessContext(
    sampleRate: TestSampleRate,
    blockSize: int32(TestBlockSize),
    samplePosition: 0'i64
  )

  tb.inBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr tb.inL[0]),
    channels: 2, frames: TestBlockSize.int32, stride: TestBlockSize.int32
  )
  tb.outBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr tb.outL[0]),
    channels: 2, frames: TestBlockSize.int32, stride: TestBlockSize.int32
  )

  tb.audio = NodeAudioPorts()
  tb.audio.inputCount = 1
  tb.audio.outputCount = 1
  tb.audio.inputs[0] = addr tb.inBuf
  tb.audio.outputs[0] = addr tb.outBuf

  clearEvents(addr tb.eventsIn)

proc setInputSample*(tb: var TestBuffers; frame: int; value: float32) =
  tb.inL[frame] = value
  tb.inR[frame] = value

proc clearInput*(tb: var TestBuffers) =
  for i in 0 ..< TestBlockSize:
    tb.inL[i] = 0.0f
    tb.inR[i] = 0.0f

proc setOutputChannelCount*(tb: var TestBuffers; channels: int32) =
  tb.outBuf.channels = channels
  tb.audio.outputCount = 1
  tb.audio.outputs[0] = addr tb.outBuf

# ----------------------------------------------------------------------------
# Рендер ноды
# ----------------------------------------------------------------------------

proc renderNodeStereo*(factory: ptr NodeFactory; desc: ptr NodeDesc;
                       blocks: int; prepare: proc(tb: var TestBuffers) = nil;
                       setup: proc(state: pointer) = nil): tuple[l, r: seq[float32]] =
  ## Как renderNode, но оба канала — нужно для панорамы и стерео-эффектов.
  let state = factory.create(desc, nil)
  if state.isNil:
    raise newException(ValueError, "createState вернул nil")

  try:
    if not setup.isNil:
      setup(state)

    var tb: TestBuffers
    tb.initTestBuffers()

    result.l = newSeq[float32](blocks * TestBlockSize)
    result.r = newSeq[float32](blocks * TestBlockSize)

    for b in 0 ..< blocks:
      tb.clearInput()
      tb.blockIndex = b
      if not prepare.isNil:
        prepare(tb)

      factory.process(addr tb.ctx, addr tb.audio, nil, nil, state)

      copyMem(addr result.l[b * TestBlockSize],
              addr tb.outL[0], TestBlockSize * sizeof(float32))
      copyMem(addr result.r[b * TestBlockSize],
              addr tb.outR[0], TestBlockSize * sizeof(float32))

    factory.destroy(state)
  finally:
    discard

proc renderNode*(factory: ptr NodeFactory; desc: ptr NodeDesc;
                 blocks: int; prepare: proc(tb: var TestBuffers) = nil;
                 setup: proc(state: pointer) = nil): seq[float32] =
  ## Прогоняет ноду через blocks блоков по TestBlockSize.
  ##
  ## prepare вызывается перед каждым блоком (в нём обычно кладут вход),
  ## setup — один раз сразу после создания состояния (в них ставят параметры).
  ##
  ## Возвращает левый канал выхода целиком.
  renderNodeStereo(factory, desc, blocks, prepare, setup).l

# ----------------------------------------------------------------------------
# Измерения сигнала
# ----------------------------------------------------------------------------

proc peak*(samples: openArray[float32]): float32 =
  for s in samples:
    let a = if s < 0.0f: -s else: s
    if a > result:
      result = a

proc rms*(samples: openArray[float32]): float32 =
  if samples.len == 0:
    return 0.0f
  var acc = 0.0'f64
  for s in samples:
    acc += float64(s) * float64(s)
  sqrt(acc / float64(samples.len)).float32

proc dcOffset*(samples: openArray[float32]): float32 =
  if samples.len == 0:
    return 0.0f
  var acc = 0.0'f64
  for s in samples:
    acc += float64(s)
  (acc / float64(samples.len)).float32

proc isSilent*(samples: openArray[float32]; eps: float32 = 1e-7f): bool =
  peak(samples) <= eps

proc countZeroCrossings*(samples: openArray[float32]): int =
  ## Грубая оценка частоты: пересечения нуля с гистерезисом.
  var crossings = 0
  var i = 1
  while i < samples.len:
    if (samples[i - 1] < 0.0f) and (samples[i] >= 0.0f):
      inc crossings
    inc i
  result = crossings

proc estimateFreq*(samples: openArray[float32],
                   sampleRate: float32 = TestSampleRate): float32 =
  ## Частота по пересечениям нуля на участке без разрывов фазы.
  if samples.len < 4:
    return 0.0f
  result = float32(countZeroCrossings(samples)) * sampleRate /
           float32(samples.len)

proc sineAt*(index: int; freq: float32; sampleRate: float32 = TestSampleRate;
             phase: float32 = 0.0f): float32 =
  sin(2.0f * PI * (freq * float32(index) / sampleRate) + phase)

proc isFinite*(samples: openArray[float32]): bool =
  ## Проверка на NaN/Inf. Любая нода, выпускающая NaN, портит весь микс
  ## дальше по графу, поэтому это проверяется явно и часто.
  for s in samples:
    if s != s:               # NaN не равен сам себе
      return false
    if s > 3.4e38 or s < -3.4e38:
      return false
  true

proc thdDb*(samples: openArray[float32]; fundamental: float32;
            sampleRate: float32 = TestSampleRate): float32 =
  ## Грубая оценка THD по суммарной энергии вне основного тона.
  ##
  ## Достаточно, чтобы отличить «polyBLEP-пила» от наивной пилы:
  ## у наивной алиасинг даёт THD в десятки процентов.
  if samples.len < 16:
    return 0.0f

  # Окно Ханна убирает утечку спектра, из-за которой оценка завышена.
  var energyFund = 0.0'f64
  var energyRest = 0.0'f64
  let n = samples.len

  for k in 2 ..< 64:
    let w = 0.5'f64 * (1.0 - cos(2.0 * PI * float64(k) / float64(n)))
    let phase = 2.0 * PI * float64(k) * float64(fundamental) / float64(sampleRate)

    var re = 0.0'f64
    var im = 0.0'f64
    for i in 0 ..< n:
      let x = float64(samples[i]) * (0.5'f64 * (1.0 - cos(2.0 * PI * float64(i) / float64(n - 1))))
      re += x * cos(phase * float64(i))
      im += x * sin(phase * float64(i))
    re *= 2.0 / float64(n)
    im *= 2.0 / float64(n)
    discard w

    let mag = re * re + im * im
    if k == 2:
      energyFund += mag
    else:
      energyRest += mag

  if energyFund <= 0.0:
    return 0.0f
  10.0'f32 * log10(float32(energyRest / energyFund))
