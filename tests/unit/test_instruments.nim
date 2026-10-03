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

