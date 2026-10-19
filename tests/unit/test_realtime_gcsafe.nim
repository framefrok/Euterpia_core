# tests/unit/test_realtime_gcsafe.nim
#
# Realtime-путь доказуемо GC-safe (issue #16).
#
# Тест не проверяет DSP-значения — он ВЫЗЫВАЕТ аудио-путь из отдельного
# потока. Nim разрешает вызов процедуры из `{.thread.}`-процедуры только если
# она `gcsafe`, поэтому сам факт сборки этого файла и есть компиляторное
# доказательство: `renderBlock` и `noteStatus` не трогают глобальное
# GC-состояние.
#
# Если из прагмы `rt` или из callback-типов пропадёт `gcsafe`, тест перестанет
# компилироваться — это и есть регрессионный детектор.

import std/[unittest, typedthreads]
import node_interface
import audio_engine

const
  Frames = 128

type
  RtProbe = object
    engine: ptr AudioEngine
    ranBlocks: int32
    noteSeen: bool

proc rtWorker(p: pointer) {.thread, gcsafe.} =
  ## Выполняется в НЕ-main потоке: сюда можно звать только gcsafe-процедуры.
  let probe = cast[ptr RtProbe](p)
  if probe.isNil:
    return

  if not probe.engine.isNil:
    # Буфер заранее выделен в shared-куче: GC-аллокации внутри потока не нужны.
    let outBuf = cast[ptr UncheckedArray[float32]](
      allocShared0(sizeof(float32) * Frames * 2))
    if not outBuf.isNil:
      probe.engine.renderBlock(outBuf)
      # Единственный писатель — этот поток; main читает после joinThread,
      # поэтому атомик здесь не нужен.
      inc probe.ranBlocks
      probe.engine.noteStatus(0x00000004'u32)   # output underflow
      probe.noteSeen = probe.engine.xrunCount() >= 1'u32
      deallocShared(cast[pointer](outBuf))

suite "realtime-путь: gcsafe доказан компилятором (#16)":
  test "renderBlock и noteStatus вызываются из отдельного потока":
    let engine = createAudioEngine(
      sampleRate = 48000.0'f32, blockSize = int32(Frames))
    check engine != nil

    var probe = RtProbe(engine: engine, ranBlocks: 0, noteSeen: false)
    var th: Thread[pointer]
    createThread(th, rtWorker, addr probe)
    joinThread(th)

    check probe.ranBlocks == 1'i32
    # noteStatus из потока дошёл до счётчика: вызов реально прошёл.
    check engine.xrunCount() >= 1'u32
    check probe.noteSeen

    destroyAudioEngine(engine)
