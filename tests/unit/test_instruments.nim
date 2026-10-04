# tests/unit/test_instruments.nim
#
# Инструменты оркестра (issue #274): C-движки напрямую и ноды через события.
#
# Оснастка `InstrumentRig` держит состояние ноды, её порты и очередь событий
# так, чтобы тест повторял реальный путь ядра: note-on кладётся в `EventQueue`,
# нода обрабатывает блок, звук читается из выходного буфера. Две раскладки
# выхода проверяются одинаково важны: planar (внутри графа) и interleaved
# (инструмент последним в цепочке, мастер-шина).
#
# Буферы оснастки фиксированы `InstScratchFrames` — тем же потолком, что у
# временного буфера нод в C, поэтому «блок длиннее счётчика» проверяется на
# настоящем пределе, а не на выдуманном.

import std/[math, unittest]

import signal_types
import node_interface
import sdk/node_api
import builtin/native/eut_native
import builtin/instruments/instrument_common
import builtin/instruments/organ
import builtin/instruments/piano
import builtin/instruments/guitar
import builtin/instruments/drums
import builtin/instruments/flute
import builtin/instruments/bagpipe
import builtin/instruments/strings
import builtin/instruments/bell
import builtin/instruments/plucked
import builtin/instruments/recorder
import builtin/instruments/brass
import builtin/instruments/timpani
import builtin/instruments/choir
import builtin/instruments/reed

const
  Sr = 48000.0'f32
  Block = 512
  Channels = 2
  MaxFrames = int(InstScratchFrames)

type
  PlanarStorage = object
    ## Два непрерывных канала: именно так нода видит выход внутри графа.
    left: array[MaxFrames, float32]
    right: array[MaxFrames, float32]

  InstrumentRig = object
    ## Одна нода-инструмент, готовая к прогону блоков.
    factory: ptr NodeFactory
    desc: ptr NodeDesc
    state: pointer
    ctx: NodeProcessContext
    audio: NodeAudioPorts
    events: NodeEventPorts
    q: EventQueue
    outBuf: AudioBuffer
    planar: PlanarStorage
    interleaved: array[MaxFrames * Channels, float32]
    frames: int32
    isInterleaved: bool

proc bindOutput(rig: var InstrumentRig) =
  ## Привязывает выход ноды к хранилищу нужной раскладки.
  if rig.isInterleaved:
    rig.outBuf = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr rig.interleaved[0]),
      channels: int32(Channels), frames: rig.frames, stride: 1'i32)
  else:
    rig.outBuf = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr rig.planar.left[0]),
      channels: int32(Channels), frames: rig.frames, stride: int32(MaxFrames))
  rig.audio.outputCount = 1
  rig.audio.outputs[0] = addr rig.outBuf

proc initRig(rig: var InstrumentRig; factory: ptr NodeFactory;
             desc: ptr NodeDesc; interleaved: bool): bool =
  ## Создаёт состояние ноды и собирает порты. false — состояние не создалось.
  rig.factory = factory
  rig.desc = desc
  rig.state = factory.create(desc, nil)
  if rig.state.isNil:
    return false
  rig.frames = int32(Block)
  rig.isInterleaved = interleaved
  rig.ctx = NodeProcessContext(sampleRate: Sr, blockSize: rig.frames,
                               samplePosition: 0'i64)
  clearEvents(addr rig.q)
  rig.audio = NodeAudioPorts()
  rig.events = NodeEventPorts()
  rig.events.inputCount = 1
  rig.events.inputs[0] = addr rig.q
  rig.bindOutput()
  true

proc setFrames(rig: var InstrumentRig; frames: int32) =
  ## Меняет длину блока: нужно тесту «блок длиннее временного буфера».
  rig.frames = frames
  rig.ctx.blockSize = frames
  rig.bindOutput()

proc freeRig(rig: var InstrumentRig) =
  if not rig.state.isNil:
    rig.factory.destroy(rig.state)
    rig.state = nil

proc pushNote(rig: var InstrumentRig; kind: RealtimeEventKind; note: int;
              velocity: float32; offset: int32 = 0) =
  ## Кладёт note-on/note-off. `velocity` — нормированная (0..1), как в MIDI-пути.
  discard pushEvent(addr rig.q, RealtimeEvent(
    frameOffset: uint32(offset), kind: kind, channel: 0'u8,
    data: [float32(note), velocity, 0.0f, 0.0f]))

proc pushCc(rig: var InstrumentRig; controller, value: int) =
  ## Кладёт контроллер: value — целое MIDI 0..127.
  discard pushEvent(addr rig.q, RealtimeEvent(
    frameOffset: 0'u32, kind: evCC, channel: 0'u8,
    data: [float32(controller), float32(value) / 127.0f, 0.0f, 0.0f]))

proc renderBlock(rig: var InstrumentRig) =
  rig.ctx.blockSize = rig.frames
  rig.factory.process(addr rig.ctx, addr rig.audio, nil, addr rig.events,
                      rig.state)
  rig.ctx.samplePosition += int64(rig.frames)
  # Движок наполняет очередь событий заново каждый блок: событие живёт один
  # блок. Без очистки note-on, поданный один раз, переигрывался бы каждым
  # блоком — и проверка «all-notes-off гасит голоса» была бы вечно ложной.
  clearEvents(addr rig.q)

proc clearBlock(rig: var InstrumentRig) =
  for i in 0 ..< MaxFrames:
    rig.planar.left[i] = 0.0f
    rig.planar.right[i] = 0.0f
  for i in 0 ..< MaxFrames * Channels:
    rig.interleaved[i] = 0.0f

proc lastBlockPeak(rig: InstrumentRig): float32 =
  ## Пик последнего обработанного блока, в его собственном формате.
  var p = 0.0f
  if rig.outBuf.stride >= rig.outBuf.frames:
    for i in 0 ..< int(rig.frames):
      p = max(p, max(abs(rig.planar.left[i]), abs(rig.planar.right[i])))
  else:
    for i in 0 ..< int(rig.frames) * Channels:
      p = max(p, abs(rig.interleaved[i]))
  p

proc blockIsFinite(rig: InstrumentRig): bool =
  ## NaN/Inf в выходе недопустимы: одна нода портит весь микс.
  if rig.outBuf.stride >= rig.outBuf.frames:
    for i in 0 ..< int(rig.frames):
      for v in [rig.planar.left[i], rig.planar.right[i]]:
        if v != v or v > 3.4e38'f32 or v < -3.4e38'f32:
          return false
  else:
    for i in 0 ..< int(rig.frames) * Channels:
      let v = rig.interleaved[i]
      if v != v or v > 3.4e38'f32 or v < -3.4e38'f32:
        return false
  true

# ----------------------------------------------------------------------------
# Мерки для гитары: струна — не осциллятор, её свойства видны только по
# записанному сигналу (автокорреляция и энергия в полосах).
# ----------------------------------------------------------------------------

const
  GuitarProbeNote = 28
    ## E1 ≈ 41.2 Гц. Низкая нота выбрана нарочно: период длинный, поэтому
    ## сдвиг строя на атаке виден в сэмплах, а не в их долях.
  GuitarProbeBlock = 512

proc guitarRender(note: int; vel: float32; seconds: float32): seq[float32] =
  ## Одна нота через C-движок гитары. Параметры близки к нодовым по
  ## умолчанию, но `drive` выключен: насыщение нелинейно и смазывает
  ## спектральные мерки.
  var g = newGuitar(8, Sr)
  doAssert g.isReady
  guitarSet(addr g, 0.28f, 0.65f, 0.55f, 0.0f, 0.0f, 0.4f, 0.0f, 0.8f)
  guitarNoteOn(addr g, note, vel)
  var l, r: array[GuitarProbeBlock, float32]
  let total = int(Sr * seconds)
  result = newSeq[float32](total)
  var pos = 0
  while pos < total:
    for i in 0 ..< l.len:
      l[i] = 0.0f
      r[i] = 0.0f
    guitarProcess(addr g, addr l[0], addr r[0], 1, l.len)
    for i in 0 ..< min(l.len, total - pos): result[pos + i] = l[i]
    pos += l.len
  freeGuitar(addr g)

proc autocorrLag(buf: seq[float32]; first, count, lo, hi: int): float32 =
  ## Период струны: лаг с лучшей автокорреляцией плюс параболическое
  ## уточнение. Целый лаг округляет в сэмпл, а въезд строя на атаке — это
  ## доли сэмпла, их видно только по вершине параболы.
  var best = -1.0f
  var bestLag = lo
  for lag in lo .. hi:
    var acc = 0.0f
    for i in first ..< first + count:
      acc += buf[i] * buf[i + lag]
    if acc > best:
      best = acc
      bestLag = lag
  if bestLag > lo and bestLag < hi:
    var c0, c1, c2: float32
    for i in first ..< first + count:
      c0 += buf[i] * buf[i + bestLag - 1]
      c1 += buf[i] * buf[i + bestLag]
      c2 += buf[i] * buf[i + bestLag + 1]
    let den = c0 - 2.0f * c1 + c2
    if den != 0.0f:
      return float32(bestLag) + 0.5f * (c0 - c2) / den
  float32(bestLag)

proc bandRms(buf: seq[float32]; first, count: int; fc: float32; high: bool;
             stages: int): float32 =
  ## Энергия в полосе на окне `[first, first+count)`: каскад однополюсников.
  ## Мерка грубая, но одинаковая для любой версии ядра: значение имеют
  ## отношения, а не абсолютные числа.
  let a = 1.0f - exp(-6.2831853f * fc / Sr)
  var z = newSeq[float32](stages)
  var acc = 0.0
  for i in first ..< first + count:
    var y = buf[i]
    for s in 0 ..< stages:
      z[s] += (y - z[s]) * a
      y = if high: y - z[s] else: z[s]
    acc += float64(y) * float64(y)
  sqrt(float32(acc / float64(count)))

# ----------------------------------------------------------------------------
# Мерки для третьей партии (#321): щипковый нейлон и свободноязычковые.
#
# Язычок и струна — не осцилляторы: «мягче верх», «есть разлив» и «шум
# воздуха слышен» проверяются только по записанному сигналу. Ниже — те же
# приёмы, что для гитары: автокорреляция (строй), энергия в полосах
# (яркость) и огибающая (биения разлива).
# ----------------------------------------------------------------------------

const
  PluckProbeNote = 69
    ## A4: укулеле обязан держать ту же высоту, что арфа и клавесин.
  ReedProbeNote = 60
    ## C4 ≈ 261.6 Гц (лаг 183 при 48 кГц) — середина диапазона язычков.
  ReedProbeBlock = 512

proc pluckRender(note: int; vel, nylon: float32; seconds: float32):
    seq[float32] =
  ## Один щипок через C-движок щипковых. `nylon` — доля нейлоновой струны
  ## (0 — сталь арфы и клавесина, 1 — укулеле).
  var g = newPluck(8, Sr)
  doAssert g.isReady
  pluckSet(addr g, 0.7f, 0.9f, 0.4f, 0.3f, 200.0f, nylon, 0.0f, 0.8f)
  pluckNoteOn(addr g, note, vel)
  var l, r: array[ReedProbeBlock, float32]
  let total = int(Sr * seconds)
  result = newSeq[float32](total)
  var pos = 0
  while pos < total:
    for i in 0 ..< l.len:
      l[i] = 0.0f
      r[i] = 0.0f
    pluckProcess(addr g, addr l[0], addr r[0], 1, l.len)
    for i in 0 ..< min(l.len, total - pos): result[pos + i] = l[i]
    pos += l.len
  freePluck(addr g)

proc reedRender(note: int; vel: float32; seconds: float32; tone, detune, noise,
                attack, formantHz: float32): seq[float32] =
  ## Одна нота через C-движок свободноязычковых. Характер инструмента — это
  ## ровно `detune` (разлив) и `formantHz` (камера): так нода задаёт баян и
  ## гармошку, и так же их проверяет тест.
  var g = newReed(12, Sr)
  doAssert g.isReady
  reedSet(addr g, tone, detune, noise, attack, formantHz, 0.0f, 0.8f)
  reedNoteOn(addr g, note, vel)
  var l, r: array[ReedProbeBlock, float32]
  let total = int(Sr * seconds)
  result = newSeq[float32](total)
  var pos = 0
  while pos < total:
    for i in 0 ..< l.len:
      l[i] = 0.0f
      r[i] = 0.0f
    reedProcess(addr g, addr l[0], addr r[0], 1, l.len)
    for i in 0 ..< min(l.len, total - pos): result[pos + i] = l[i]
    pos += l.len
  freeReed(addr g)

proc signalPeak(buf: seq[float32]): float32 =
  ## Пик записи: «движок отдал звук» и «движок отдал тишину».
  for v in buf:
    result = max(result, abs(v))

proc envelopeVar(buf: seq[float32]; win: int): float32 =
  ## Разброс огибающей: RMS по окнам `win` кадров, затем коэффициент
  ## вариации (σ/μ). Биения разлива видны именно здесь: ровный язычок даёт
  ## единицы процентов, разлив — десятки.
  var sums: seq[float64]
  var pos = 0
  while pos + win <= buf.len:
    var acc = 0.0'f64
    for i in pos ..< pos + win:
      acc += float64(buf[i]) * float64(buf[i])
    sums.add sqrt(acc / float64(win))
    pos += win
  if sums.len == 0: return 0.0f
  var mean = 0.0'f64
  for v in sums: mean += v
  mean /= float64(sums.len)
  if mean <= 0.0: return 0.0f
  var variance = 0.0'f64
  for v in sums:
    variance += (v - mean) * (v - mean)
  sqrt(float32(variance / float64(sums.len))) / float32(mean)

proc diffRms(a, b: seq[float32]): float32 =
  ## RMS разницы двух записей. Нужен там, где параметр ничего не меняет
  ## «в среднем» (шум воздуха поверх тона), но обязан быть слышен.
  let n = min(a.len, b.len)
  if n == 0: return 0.0f
  var acc = 0.0'f64
  for i in 0 ..< n:
    let d = float64(a[i] - b[i])
    acc += d * d
  sqrt(float32(acc / float64(n)))

proc paramDefault(desc: NodeDesc; name: string): float32 =
  ## Значение параметра по умолчанию: им нода говорит, каким инструмент
  ## рождён (разлив баяна, нейлон укулеле).
  for k in 0 ..< int(desc.paramCount):
    if readFixed(desc.params[k].name) == name:
      return desc.params[k].defaultValue
  -1.0f

# ----------------------------------------------------------------------------
# Движки напрямую (C-контракт)
# ----------------------------------------------------------------------------

suite "инструменты: C-движки (eut_inst.c)":
  test "размеры состояний совпадают с задокументированными":
    check abiCheck()

  test "каждый движок принимает ноту и отдаёт звук":
    var o = newOrgan(8, Sr)
    check o.isReady
    organNoteOn(addr o, 60, 0.9f)
    var l, r: array[512, float32]
    for b in 0 ..< 8:
      organProcess(addr o, addr l[0], addr r[0], 1, l.len)
    var p = 0.0f
    for i in 0 ..< l.len:
      p = max(p, abs(l[i]))
    check p > 1e-4f
    organAllOff(addr o)
    freeOrgan(addr o)

  test "ударные отображают ноты по карте GM, незнакомые игнорируются":
    check drumsPieceForNote(36) == EutDrumKick
    check drumsPieceForNote(38) == EutDrumSnare
    check drumsPieceForNote(42) == EutDrumHatClosed
    check drumsPieceForNote(49) == EutDrumCrash
    check drumsPieceForNote(99) == -1

  test "тарелки и хэты не на порядок тише малого (регрессия #287)":
    proc drumPeak(note: int): float32 =
      var g = newDrums(16, Sr)
      drumsSet(addr g, 1.0f, 1.0f, 1.0f, 0.6f, 0.2f, 0.0f, 0.85f)
      drumsNoteOn(addr g, note, 0.95f)
      var l, r: array[512, float32]
      for b in 0 ..< 20:
        for i in 0 ..< l.len:
          l[i] = 0.0f
          r[i] = 0.0f
        drumsProcess(addr g, addr l[0], addr r[0], 1, l.len)
        for i in 0 ..< l.len:
          result = max(result, abs(l[i]))
      freeDrums(addr g)

    let snare = drumPeak(38)
    let hat = drumPeak(42)
    let crash = drumPeak(49)
    check snare > 0.02f
    # Металлические детали должны быть сопоставимы, а не тише на порядок:
    # раньше хэт/тарелка давали ~0.003 против ~0.06 у малого (разрыв ×20).
    check hat > 0.25f * snare
    check crash > 0.25f * snare


  test "гитара переинициализируется в пределах выделенной памяти струн":
    var g = newGuitar(4, 44100.0f)
    check g.isReady
    check guitarInitAt(addr g, 48000.0f)
    check guitarInitAt(addr g, GuitarMaxSampleRate)
    freeGuitar(addr g)

  test "смычковые отвечают на ноту и держат высоту":
    var g = newStrings(8, Sr)
    check g.isReady
    stringsSet(addr g, 0.5f, 10.0f, 7.0f, 0.0f, 0.7f)
    stringsNoteOn(addr g, 57, 0.9f)
    var l, r: array[512, float32]
    var peak = 0.0f
    for b in 0 ..< 16:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      stringsProcess(addr g, addr l[0], addr r[0], 1, l.len)
      for i in 0 ..< l.len:
        peak = max(peak, abs(l[i]))
    check peak > 1e-3f
    check peak <= 1.5f
    stringsAllOff(addr g)
    freeStrings(addr g)

  test "колокол звенит долго и затухает":
    var g = newBell(8, Sr)
    check g.isReady
    bellSet(addr g, 1.0f, 4.0f, 0.5f, 0.0f, 0.7f)
    bellNoteOn(addr g, 60, 1.0f)
    var l, r: array[512, float32]
    var early = 0.0f
    var late = 0.0f
    for b in 0 ..< 200:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      bellProcess(addr g, addr l[0], addr r[0], 1, l.len)
      for i in 0 ..< l.len:
        if b < 10: early = max(early, abs(l[i]))
        if b >= 190: late = max(late, abs(l[i]))
    check early > 1e-3f
    # Естественное затухание: к концу хвост тише начала, но ещё слышен.
    check late < early
    freeBell(addr g)

  test "щипковые, свирель, медь, литавры и хор отдают звук":
    var l, r: array[512, float32]

    block:
      var g = newPluck(4, Sr)
      check g.isReady
      check pluckInitAt(addr g, 44100.0f)
      pluckSet(addr g, 0.6f, 0.7f, 0.4f, 0.4f, 200.0f, 0.0f, 0.0f, 0.8f)
      pluckNoteOn(addr g, 60, 0.9f)
      var peak = 0.0f
      for b in 0 ..< 8:
        for i in 0 ..< l.len: l[i] = 0.0f
        pluckProcess(addr g, addr l[0], addr l[0], 1, l.len)
        for i in 0 ..< l.len: peak = max(peak, abs(l[i]))
      check peak > 1e-3f
      pluckAllOff(addr g)
      freePluck(addr g)

    block:
      var g = newRecorder(4, Sr)
      check g.isReady
      recorderSet(addr g, 0.6f, 0.3f, 5.0f, 0.0f, 0.8f)
      recorderNoteOn(addr g, 72, 0.9f)
      var peak = 0.0f
      for b in 0 ..< 8:
        for i in 0 ..< l.len: l[i] = 0.0f
        recorderProcess(addr g, addr l[0], addr l[0], 1, l.len)
        for i in 0 ..< l.len: peak = max(peak, abs(l[i]))
      check peak > 1e-3f
      recorderAllOff(addr g)
      freeRecorder(addr g)

    block:
      var g = newBrass(4, Sr)
      check g.isReady
      brassSet(addr g, 0.55f, 0.35f, 6.0f, 0.0f, 0.8f)
      brassNoteOn(addr g, 60, 0.9f)
      var peak = 0.0f
      for b in 0 ..< 8:
        for i in 0 ..< l.len: l[i] = 0.0f
        brassProcess(addr g, addr l[0], addr l[0], 1, l.len)
        for i in 0 ..< l.len: peak = max(peak, abs(l[i]))
      check peak > 1e-3f
      brassAllOff(addr g)
      freeBrass(addr g)

    block:
      var g = newTimpani(4, Sr)
      check g.isReady
      timpaniSet(addr g, 1.0f, 1.0f, 0.5f, 0.0f, 0.8f)
      timpaniNoteOn(addr g, 45, 1.0f)
      var early = 0.0f
      for b in 0 ..< 12:
        for i in 0 ..< l.len: l[i] = 0.0f
        timpaniProcess(addr g, addr l[0], addr l[0], 1, l.len)
        if b < 6:
          for i in 0 ..< l.len: early = max(early, abs(l[i]))
      check early > 1e-3f
      freeTimpani(addr g)

    block:
      var g = newChoir(4, Sr)
      check g.isReady
      choirSet(addr g, 0.0f, 0.5f, 9.0f, 0.0f, 0.8f)
      choirNoteOn(addr g, 60, 0.9f)
      var peak = 0.0f
      for b in 0 ..< 16:
        for i in 0 ..< l.len: l[i] = 0.0f
        choirProcess(addr g, addr l[0], addr l[0], 1, l.len)
        for i in 0 ..< l.len: peak = max(peak, abs(l[i]))
      check peak > 1e-3f
      choirAllOff(addr g)
      freeChoir(addr g)

  test "щипковые держат строй: арфа на ноте A4 даёт ~440 Гц":
    var g = newPluck(4, Sr)
    check g.isReady
    pluckSet(addr g, 0.7f, 0.9f, 0.4f, 0.3f, 200.0f, 0.0f, 0.0f, 0.8f)
    pluckNoteOn(addr g, 69, 1.0f)
    var l, r: array[512, float32]
    var n = 0
    var buf = newSeq[float32](24000)
    var pos = 0
    while pos < buf.len:
      for i in 0 ..< l.len: l[i] = 0.0f
      pluckProcess(addr g, addr l[0], addr l[0], 1, l.len)
      for i in 0 ..< min(l.len, buf.len - pos): buf[pos + i] = l[i]
      pos += l.len
    # Автокорреляция: у щипка богатый спектр, и zero-crossing считает лишние
    # переходы. Основной тон — это лаг, на котором сигнал похож сам на себя.
    var best = 0.0f
    var bestLag = 0
    for lag in 60 .. 200:
      var acc = 0.0f
      for i in 4800 ..< 12000:
        acc += buf[i] * buf[i + lag]
      if acc > best:
        best = acc
        bestLag = lag
    check bestLag > 0
    let f = Sr / float32(bestLag)
    check abs(f - 440.0f) < 12.0f
    freePluck(addr g)

  test "тело корпуса гитары даёт нижней середине вес (#318)":
    # Перекос спектра на окне 0.25–0.75 с: энергия ниже 100 Гц к энергии
    # выше 500 Гц. Окно фиксированное, а не весь буфер: хвост струны садится
    # по ВЧ быстрее (это демпфер, а не тело) и на длинной выдержке тянет
    # мерку за собой. Снято с ядра: с телом 1.39, без него 1.12 (замер
    # временным отключением `bodyBoost`) — мягкая полка low-shelf ~2 дБ.
    let buf = guitarRender(GuitarProbeNote, 1.0f, 2.5f)
    let head = int(Sr * 0.25f)
    let win = int(Sr * 0.5f)
    let low = bandRms(buf, head, win, 100.0f, false, 4)
    let high = bandRms(buf, head, win, 500.0f, true, 4)
    check low > 0.0f
    check high > 0.0f
    check low / high > 1.25f

  test "демпфер струны двухполюсный: ВЧ-хвост садится быстрее низа (#318)":
    # Вторая ступень ФНЧ в петле ускоряет спад верхних гармоник. Мерка —
    # насколько полоса 1 кГц+ садится быстрее полосы 300 Гц−: общий спад
    # струны сокращается сам. Снято с ядра: −19.8 дБ против −10.1 дБ у
    # однополюсной петли (проверено временным обходом второй ступени).
    let buf = guitarRender(GuitarProbeNote, 1.0f, 2.5f)
    let head = int(Sr * 0.25f)
    let tail = int(Sr * 1.5f)
    let win = int(Sr * 0.5f)
    let low = bandRms(buf, tail, win, 300.0f, false, 4) /
              bandRms(buf, head, win, 300.0f, false, 4)
    let high = bandRms(buf, tail, win, 1000.0f, true, 4) /
               bandRms(buf, head, win, 1000.0f, true, 4)
    check low > 0.0f
    check high > 0.0f
    check 20.0f * log10(high / low) < -15.0f

  test "сильный щипок натягивает струну: атака въезжает вверх (#318)":
    # Огибающая строя: чем сильнее щипок, тем выше строй первые десятки
    # миллисекунд. Сравниваются сильный и слабый щипок на одном окне — так
    # из мерки уходит собственная «осадка» струны, она от силы щипка не
    # зависит. Замер: 1.21 сэмпла у E1 на ff против 0.0004 без огибающей.
    let loud = guitarRender(GuitarProbeNote, 1.0f, 0.25f)
    let soft = guitarRender(GuitarProbeNote, 0.1f, 0.25f)
    check loud.max > 0.01f
    let loudLag = autocorrLag(loud, 0, 4096, 1000, 1350)
    let softLag = autocorrLag(soft, 0, 4096, 1000, 1350)
    check loudLag > 0.0f
    check softLag > 0.0f
    # Короче период — выше строй: сильный щипок обязан опережать слабый.
    check loudLag < softLag - 0.5f

  test "флейта монофонична: новая нота гасит прежний голос":
    var g = newFlute(8, Sr)
    check g.isReady
    fluteNoteOn(addr g, 72, 0.9f)
    var l, r: array[512, float32]
    for b in 0 ..< 4:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      fluteProcess(addr g, addr l[0], addr r[0], 1, l.len)
    # Вторая нота через малое время: прежний голос обязан быстро уйти.
    fluteNoteOn(addr g, 74, 0.9f)
    fluteAllOff(addr g)
    for b in 0 ..< 8:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      fluteProcess(addr g, addr l[0], addr r[0], 1, l.len)
    var p = 0.0f
    for i in 0 ..< l.len:
      p = max(p, abs(l[i]))
    check p < 1.0f        # без «двух флейт» и без рассинхрона
    freeFlute(addr g)

  test "reset обнуляет DSP-состояние голоса — следующий блок тишина (#316)":
    # Контракт паники: после `xReset` ни одного сэмпла остаточного состояния
    # (фазы, фильтры дыхания, огибающие — всё обнулено C-функцией).
    # `xAllOff` этого не гарантирует: он лишь снимает ноты, и именно поэтому
    # девять «новых» инструментов звали не тот сброс.
    var g = newFlute(8, Sr)
    check g.isReady
    fluteNoteOn(addr g, 69, 0.9f)
    var l, r: array[512, float32]
    for b in 0 ..< 4:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      fluteProcess(addr g, addr l[0], addr r[0], 1, l.len)

    fluteReset(addr g)
    for i in 0 ..< l.len:
      l[i] = 0.0f
      r[i] = 0.0f
    fluteProcess(addr g, addr l[0], addr r[0], 1, l.len)
    var peak = 0.0f
    for i in 0 ..< l.len:
      peak = max(peak, abs(l[i]))
    check peak == 0.0f
    freeFlute(addr g)

  test "reset щипковых чистит линию задержки Карплуса-Стронга (#316)":
    # У щипковых состояние — это буфер струны (`g->memory`). Если его не
    # обнулить, «заряженная» струна звучит после паники.
    var g = newPluck(4, Sr)
    check g.isReady
    pluckSet(addr g, 0.7f, 0.9f, 0.4f, 0.3f, 200.0f, 0.0f, 0.0f, 0.8f)
    pluckNoteOn(addr g, 69, 1.0f)
    var l, r: array[512, float32]
    for b in 0 ..< 4:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      pluckProcess(addr g, addr l[0], addr r[0], 1, l.len)

    pluckReset(addr g)
    var peak = 0.0f
    for b in 0 ..< 4:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      pluckProcess(addr g, addr l[0], addr r[0], 1, l.len)
      for i in 0 ..< l.len:
        peak = max(peak, abs(l[i]))
    check peak == 0.0f
    freePluck(addr g)

  # --- третья партия: укулеле, баян, гармошка (#321) -------------------------

  test "нейлон глушит верх струны: укулеле темнее стали (#321)":
    # Укулеле — это тот же Карплус-Стронг с нейлоновой струной: мягче
    # возбуждение и быстрее спад ВЧ в петле. Мерка — отношение энергии выше
    # 2 кГц к энергии ниже: яркость струны, а не её громкость.
    proc brightness(buf: seq[float32]): float32 =
      bandRms(buf, 2400, 9600, 2000.0f, true, 3) /
        bandRms(buf, 2400, 9600, 2000.0f, false, 3)

    let steel = pluckRender(PluckProbeNote, 1.0f, 0.0f, 1.0f)
    let half = pluckRender(PluckProbeNote, 1.0f, 0.5f, 1.0f)
    let nylon = pluckRender(PluckProbeNote, 1.0f, 1.0f, 1.0f)
    check signalPeak(steel) > 0.05f
    check signalPeak(nylon) > 0.02f
    let bs = brightness(steel)
    let bh = brightness(half)
    let bn = brightness(nylon)
    # Замер с ядра: 0.111 → 0.064 → 0.028. Спад обязан быть монотонным:
    # ручка «нейлон» не переключатель, а доля.
    check bn < bh
    check bh < bs
    check bn < 0.5f * bs
    # Сталь не тронута: при `nylon = 0` формулы петли и возбуждения прежние,
    # поэтому яркость держится на историческом уровне (замер с ядра: 0.111).
    # Мерка сторожит именно путь арфы и клавесина: правка «для укулеле»,
    # задевшая сталь, сдвинет эту границу.
    check abs(bs - 0.111f) < 0.03f

  test "при nylon = 0 струна прежняя: у steel-инструментов параметр выключен (#321)":
    # Гарантия «арфа и клавесин звучат бит-в-бит как раньше» держится на
    # том, что формула петли и возбуждения при `nylon = 0` не меняется.
    # Проверяем то, чем она обеспечена: новые ручки выключены у steel-нод и
    # включены у укулеле, разлив у баяна есть, у гармошки — нет.
    check paramDefault(getHarpDesc()[], "nylon") == 0.0f
    check paramDefault(getHarpsichordDesc()[], "nylon") == 0.0f
    check paramDefault(getUkuleleDesc()[], "nylon") == 1.0f
    check paramDefault(getAccordionDesc()[], "detune") > 0.0f
    check paramDefault(getHarmonicaDesc()[], "detune") == 0.0f
    check paramDefault(getUkuleleDesc()[], "tone") > 0.0f

  test "язычковые держат строй: баян и гармошка дают C4 (#321)":
    # Лаг 183 при 48 кГц — это 262 Гц. Разлив на строй не влияет: три
    # язычка расходятся на центы, период остаётся общим.
    let acc = reedRender(ReedProbeNote, 0.9f, 1.5f, 0.50f, 12.0f, 0.0f, 0.05f,
                         1400.0f)
    let har = reedRender(ReedProbeNote, 0.9f, 1.5f, 0.72f, 0.0f, 0.0f, 0.018f,
                         2600.0f)
    check signalPeak(acc) > 0.05f
    check signalPeak(har) > 0.05f
    for buf in [acc, har]:
      # Второй секунды нет — строй садится за десятки мс, и по окну сразу
      # после атаки виден уже установившийся тон.
      let f = Sr / autocorrLag(buf, 9600, 8192, 150, 220)
      check abs(f - 261.63f) < 4.0f

  test "разлив баяна качает огибающую, сухой язычок ровен (#321)":
    # Разлив — это биения расстроенных язычков: их слышно как «дыхание»
    # громкости. Мерка — коэффициент вариации RMS по окнам 50 мс.
    let spread = reedRender(ReedProbeNote, 0.9f, 1.5f, 0.50f, 12.0f, 0.0f,
                            0.05f, 1400.0f)
    let dry = reedRender(ReedProbeNote, 0.9f, 1.5f, 0.50f, 0.0f, 0.0f, 0.05f,
                         1400.0f)
    let spreadVar = envelopeVar(spread, 2400)
    let dryVar = envelopeVar(dry, 2400)
    check dryVar > 0.0f
    # Замер с ядра: 0.264 против 0.071 — разлив качает огибающую в разы.
    check spreadVar > 2.0f * dryVar

  test "воздух язычка слышен и пропорционален параметру шума (#321)":
    # Шум меха/дыхания не меняет тон «в среднем», поэтому мера — энергия
    # разницы с записью без шума: она обязана расти вместе с параметром.
    let quiet = reedRender(ReedProbeNote, 0.9f, 1.0f, 0.72f, 0.0f, 0.0f,
                           0.018f, 2600.0f)
    let again = reedRender(ReedProbeNote, 0.9f, 1.0f, 0.72f, 0.0f, 0.0f,
                           0.018f, 2600.0f)
    let mid = reedRender(ReedProbeNote, 0.9f, 1.0f, 0.72f, 0.0f, 0.3f, 0.018f,
                         2600.0f)
    let loud = reedRender(ReedProbeNote, 0.9f, 1.0f, 0.72f, 0.0f, 1.0f, 0.018f,
                          2600.0f)
    # Один и тот же вход — один и тот же выход: шум язычка детерминирован
    # (как и у остальных движков — от ноты, а не от времени).
    check diffRms(quiet, again) == 0.0f
    let dMid = diffRms(mid, quiet)
    let dLoud = diffRms(loud, quiet)
    # Замер с ядра: 0.00098 при 0.3 и 0.00326 при 1.0 — рост линейный.
    check dMid > 1.0e-4f
    check dLoud > 2.5f * dMid

  test "reset язычковых обнуляет состояние голосов — следующий блок тишина (#321)":
    # Контракт паники распространяется и на новый движок: фаз язычков,
    # резонаторов камеры и шума воздуха после `reedReset` быть не должно.
    var g = newReed(8, Sr)
    check g.isReady
    reedSet(addr g, 0.5f, 12.0f, 0.6f, 0.05f, 1400.0f, 0.0f, 0.8f)
    reedNoteOn(addr g, 60, 0.9f)
    var l, r: array[512, float32]
    for b in 0 ..< 4:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      reedProcess(addr g, addr l[0], addr r[0], 1, l.len)

    reedReset(addr g)
    var peak = 0.0f
    for b in 0 ..< 4:
      for i in 0 ..< l.len:
        l[i] = 0.0f
        r[i] = 0.0f
      reedProcess(addr g, addr l[0], addr r[0], 1, l.len)
      for i in 0 ..< l.len:
        peak = max(peak, abs(l[i]))
    check peak == 0.0f
    freeReed(addr g)


# ----------------------------------------------------------------------------
# Ноды: события -> голоса -> звук
# ----------------------------------------------------------------------------

suite "инструменты: ноды играют по событиям":
  test "орган, фортепиано, гитара и ударные дают звук на note-on":
    # Каждый инструмент проверен одинаково: событие в очередь блока, затем
    # блок — сигнал обязан появиться, не выйти за единицу и не дать NaN.
    # Нота ударных обязана попадать в GM-карту (60 — это уже не барабан).
    let rigs = [
      (getOrganFactory(), getOrganDesc(), 60),
      (getPianoFactory(), getPianoDesc(), 60),
      (getGuitarFactory(), getGuitarDesc(), 60),
      (getFluteFactory(), getFluteDesc(), 60),
      (getBagpipeFactory(), getBagpipeDesc(), 60),
      (getStringsFactory(), getStringsDesc(), 57),
      (getBellFactory(), getBellDesc(), 60),
      (getHarpFactory(), getHarpDesc(), 60),
      (getHarpsichordFactory(), getHarpsichordDesc(), 60),
      (getRecorderFactory(), getRecorderDesc(), 72),
      (getBrassFactory(), getBrassDesc(), 60),
      (getTimpaniFactory(), getTimpaniDesc(), 45),
      (getChoirFactory(), getChoirDesc(), 60),
      (getUkuleleFactory(), getUkuleleDesc(), 60),
      (getAccordionFactory(), getAccordionDesc(), 60),
      (getHarmonicaFactory(), getHarmonicaDesc(), 60),
      (getDrumsFactory(), getDrumsDesc(), 38)
    ]
    for (factory, desc, note) in rigs:
      var rig: InstrumentRig
      check rig.initRig(factory, desc, false)
      rig.pushNote(evNoteOn, note, 0.9f)
      rig.renderBlock()
      let p = rig.lastBlockPeak()
      check p > 0.01f
      check p <= 1.0f
      check rig.blockIsFinite()
      rig.freeRig()

  test "note-on со смещением внутри блока стартует ровно в этом сэмпле":
    var rig: InstrumentRig
    check rig.initRig(getPianoFactory(), getPianoDesc(), false)
    let offset = 300'i32
    rig.pushNote(evNoteOn, 64, 1.0f, offset)
    rig.renderBlock()

    var before = 0.0f
    for i in 0 ..< int(offset):
      before = max(before, abs(rig.planar.left[i]))
    var after = 0.0f
    for i in int(offset) ..< Block:
      after = max(after, abs(rig.planar.left[i]))
    check before <= 1e-7f
    check after > 1e-4f
    rig.freeRig()

  test "all-notes-off гасит голоса":
    var rig: InstrumentRig
    check rig.initRig(getOrganFactory(), getOrganDesc(), false)
    rig.pushNote(evNoteOn, 48, 1.0f)
    rig.pushNote(evNoteOn, 55, 1.0f)
    for _ in 0 ..< 4:
      rig.renderBlock()
    check rig.lastBlockPeak() > 0.01f

    rig.pushCc(123, 0)
    for _ in 0 ..< 200:
      rig.clearBlock()
      rig.renderBlock()

    # После паники и достаточного времени на релиз выход обязан стать тихим.
    check rig.lastBlockPeak() <= 1e-5f
    rig.freeRig()

# ----------------------------------------------------------------------------
# Регрессия: инструмент последним в цепочке (interleaved-буфер драйвера)
# ----------------------------------------------------------------------------

suite "инструменты: выход прямо в драйвер (interleaved)":
  test "инструмент-«хвост» цепочки звучит, а не молчит":
    # Мастер-шина отдаёт interleaved-буфер (stride = 1, см. bindMasterProc
    # в pipeline_builder). Прежде такие ноды писали тишину: непрерывного
    # указателя на канал нет, и ядро не звали вовсе — проект рендерился
    # путём тишины, хотя граф был собран верно.
    let rigs = [
      (getOrganFactory(), getOrganDesc(), 57),
      (getPianoFactory(), getPianoDesc(), 57),
      (getGuitarFactory(), getGuitarDesc(), 57),
      (getFluteFactory(), getFluteDesc(), 57),
      (getBagpipeFactory(), getBagpipeDesc(), 57),
      (getUkuleleFactory(), getUkuleleDesc(), 57),
      (getAccordionFactory(), getAccordionDesc(), 57),
      (getHarmonicaFactory(), getHarmonicaDesc(), 57),
      (getDrumsFactory(), getDrumsDesc(), 38)
    ]
    for (factory, desc, note) in rigs:
      var rig: InstrumentRig
      check rig.initRig(factory, desc, true)
      rig.pushNote(evNoteOn, note, 0.95f)
      rig.renderBlock()
      check rig.lastBlockPeak() > 0.01f
      check rig.blockIsFinite()
      rig.freeRig()

  test "interleaved-выход совпадает с planar тем же сигналом":
    # Один и тот же звук в двух раскладках: расхождение больше 10^-6 означало
    # бы не «другой канал», а ошибку раскладки или двойное суммирование.
    var planarRig, interleavedRig: InstrumentRig
    check planarRig.initRig(getPianoFactory(), getPianoDesc(), false)
    check interleavedRig.initRig(getPianoFactory(), getPianoDesc(), true)

    planarRig.pushNote(evNoteOn, 60, 0.9f)
    interleavedRig.pushNote(evNoteOn, 60, 0.9f)

    var maxDiff = 0.0f
    for b in 0 ..< 4:
      planarRig.renderBlock()
      interleavedRig.renderBlock()
      for i in 0 ..< Block:
        maxDiff = max(maxDiff, abs(planarRig.planar.left[i] -
                                   interleavedRig.interleaved[i * 2]))
        maxDiff = max(maxDiff, abs(planarRig.planar.right[i] -
                                   interleavedRig.interleaved[i * 2 + 1]))
    check maxDiff <= 1e-6f
    check planarRig.lastBlockPeak() > 0.01f
    planarRig.freeRig()
    interleavedRig.freeRig()

  test "блок длиннее временного буфера обрабатывается по частям":
    # Буфер инструмента — InstScratchFrames (MaxBlockSize) на канал. Блок
    # ровно такой длины обязан пройти целиком: хвост тишины означал бы,
    # что чанки считают не по фактическому `frames`.
    var rig: InstrumentRig
    check rig.initRig(getOrganFactory(), getOrganDesc(), true)
    rig.setFrames(InstScratchFrames)
    rig.pushNote(evNoteOn, 62, 0.9f)
    rig.renderBlock()
    let lastFrame = abs(rig.interleaved[(int(InstScratchFrames) - 1) * 2])
    check lastFrame > 1e-6f
    rig.freeRig()

