proc lastBlockPeak(rig: InstrumentRig): float32 =
  ## Пик ПОСЛЕДНЕГО обработанного блока, в его собственном формате.
  if rig.outBuf.stride >= rig.outBuf.frames:
    var p = 0.0f

    for i in 0 ..< Block:
      p = max(p, max(abs(rig.planar.left[i]), abs(rig.planar.right[i])))
    p
  else:
    var p = 0.0f
    for i in 0 ..< Block * Channels:
      p = max(p, abs(rig.interleaved[i]))
    p

proc clearBlock(rig: var InstrumentRig) =
  if rig.outBuf.stride >= rig.outBuf.frames:
    for i in 0 ..< Block:
      rig.planar.left[i] = 0.0f
      rig.planar.right[i] = 0.0f
  else:
    for i in 0 ..< Block * Channels:
      rig.interleaved[i] = 0.0f

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
    check drumsPieceForNote(42) == EutDrumSnare
    check drumsPieceForNote(99) == -1

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
    # блок — сигнал обязан появиться и не выйти за единицу.
    let rigs = [
      (getOrganFactory(), getOrganDesc()),
      (getPianoFactory(), getPianoDesc()),
      (getGuitarFactory(), getGuitarDesc()),
      (getDrumsFactory(), getDrumsDesc())
    ]
    for (factory, desc) in rigs:
      var rig: InstrumentRig
      check rig.initRig(factory, desc, false)
      rig.pushNote(evNoteOn, 60, 0.9f)
      rig.renderBlock()
      let p = rig.lastBlockPeak()
      check p > 0.01f
      check p <= 1.0f
      rig.freeRig()

  test "note-on со смещением внутри блока стартует ровно в этом сэмпле":
    var rig: InstrumentRig
    check rig.initRig(getPianoFactory(), getPianoDesc(), false)
    let offset = 300'i32
    rig.pushNote(evNoteOn, 64, 1.0f, offset)
    rig.renderBlock()

    var before = 0.0f
    for i in 0 ..< offset:
      before = max(before, abs(rig.planar.left[i]))
    var after = 0.0f
    for i in offset ..< Block:
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
    for _ in 0 ..< 40:
      rig.clearBlock()
      rig.renderBlock()

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
      (getOrganFactory(), getOrganDesc()),
      (getPianoFactory(), getPianoDesc()),
      (getGuitarFactory(), getGuitarDesc()),
      (getDrumsFactory(), getDrumsDesc())
    ]
    for (factory, desc) in rigs:
      var rig: InstrumentRig
      check rig.initRig(factory, desc, true)
      rig.pushNote(evNoteOn, 57, 0.95f)
      rig.renderBlock()
      check rig.lastBlockPeak() > 0.01f
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
    rig.ctx.blockSize = InstScratchFrames
    rig.pushNote(evNoteOn, 62, 0.9f)
    rig.renderBlock()
    let lastFrame = abs(rig.interleaved[(Block - 1) * 2])
    check lastFrame > 1e-6f
    rig.freeRig()

    check rig.lastBlockPeak() <= 1e-6f
    rig.freeRig()
