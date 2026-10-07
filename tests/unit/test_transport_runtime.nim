# tests/unit/test_transport_runtime.nim
#
# Runtime-контракт транспорта в Audio Engine (issue #257).
#
# Issue требует, чтобы Core предоставлял единый контракт транспорта, а не
# только его control-plane модель. До #257 audio_engine знал лишь
# `playing: bool`, поэтому пауза была неотличима от стопа, стоп не сбрасывал
# позицию, а цикл (`setLoop`) писался в runtime прямо с control-path в обход
# очереди команд.
#
# Тест фиксирует ровно это:
#   * play → tsPlaying;
#   * pause → tsPaused, позиция СОХРАНЕНА;
#   * stop  → tsStopped, позиция = 0;
#   * play после pause продолжает с сохранённой позиции;
#   * цикл приходит командой (postSetLoop) и применяется в audio-потоке;
#   * темп идемпотентен, некорректный темп отвергается;
#   * seek согласован в секундах и кадрах, отрицательное прижимается к 0.

import std/unittest
import audio_engine
import ipc_bus   ## `TransportState`/`ts*` — дом состояния в audio-потоке.

const
  Sr = 48000.0'f32
  Block = 256'i32

proc mkEngine(): ptr AudioEngine =
  result = createAudioEngine(Sr, Block)
  check result != nil

proc renderOnce(engine: ptr AudioEngine) =
  ## Один блок realtime-рендера без входа: очередь команд разбирается,
  ## позиция продвигается (если транспорт идёт).
  var outBuf: array[Block * 2, float32]
  engine.renderBlock(cast[ptr UncheckedArray[float32]](addr outBuf[0]))

suite "audio_engine: runtime-контракт транспорта (#257)":
  test "play переводит транспорт в tsPlaying и двигает позицию":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    check e.transportState() == tsStopped
    check e.postPlay()
    renderOnce(e)
    check e.transportState() == tsPlaying
    check e.currentFrame() == int64(Block)

  test "pause сохраняет позицию, stop сбрасывает":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    discard e.postSeekSeconds(1.0)   # 48000 кадров
    renderOnce(e)
    check e.currentFrame() == 48000

    discard e.postPlay()
    renderOnce(e)
    check e.transportState() == tsPlaying
    check e.currentFrame() == 48000 + int64(Block)

    # Пауза: состояние пауза, позиция НЕ сброшена, продвижения нет.
    discard e.postPause()
    let pausedFrame = e.currentFrame()
    renderOnce(e)
    check e.transportState() == tsPaused
    check e.currentFrame() == pausedFrame
    check e.currentFrame() != 0

    # Стоп: stopped и позиция = 0.
    discard e.postStop()
    renderOnce(e)
    check e.transportState() == tsStopped
    check e.currentFrame() == 0

  test "play после pause продолжает с сохранённой позиции":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    discard e.postSeekSeconds(0.5)
    renderOnce(e)
    discard e.postPlay()
    renderOnce(e)
    discard e.postPause()
    renderOnce(e)
    let paused = e.currentFrame()
    discard e.postPlay()
    renderOnce(e)
    check e.transportState() == tsPlaying
    check e.currentFrame() == paused + int64(Block)

  test "темп идемпотентен, некорректный отвергается":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    discard e.postSetTempo(140.0)
    renderOnce(e)
    check e.currentTempo() == 140.0
    discard e.postSetTempo(140.0)
    renderOnce(e)
    check e.currentTempo() == 140.0
    discard e.postSetTempo(80.0)
    renderOnce(e)
    check e.currentTempo() == 80.0
    # Некорректный темп игнорируется: прежний остаётся.
    discard e.postSetTempo(-10.0)
    renderOnce(e)
    check e.currentTempo() == 80.0

  test "цикл приходит командой и применяется в audio-потоке":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    check not e.isLoopEnabled()
    check e.postSetLoop(true, 1000'i64, 2000'i64)
    renderOnce(e)
    check e.isLoopEnabled()
    check e.loopStartFrame() == 1000'i64
    check e.loopEndFrame() == 2000'i64

    check e.postSetLoop(false, 1000'i64, 2000'i64)
    renderOnce(e)
    check not e.isLoopEnabled()

  test "seek согласован в секундах и кадрах, отрицательное прижимается к 0":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    discard e.postSeekSeconds(2.5)
    renderOnce(e)
    check e.currentFrame() == 120000
    discard e.postSeekSamples(48000)
    renderOnce(e)
    check e.currentFrame() == 48000
    discard e.postSeekSeconds(-5.0)
    renderOnce(e)
    check e.currentFrame() == 0

  test "цикл переносит позицию в начало при пересечении границы":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    # Цикл 0..512 при блоке 256: с позиции 256 блок доводит до 512 → 0.
    discard e.postSetLoop(true, 0'i64, 512'i64)
    discard e.postSeekSamples(256)
    discard e.postPlay()
    renderOnce(e)
    check e.currentFrame() == 0

  test "офлайн-рендер двигает транспорт без play (forceAdvance)":
    let e = mkEngine()
    defer: destroyAudioEngine(e)

    # outputBuffer вмещает ВСЕ кадры (totalFrames * 2 float), scratch — блок.
    let total = int64(Block) * 4
    var outBuf = newSeq[float32](int(total) * 2)
    var scratch = newSeq[float32](int(Block) * 2)
    e.renderOffline(
      total,
      cast[ptr UncheckedArray[float32]](addr outBuf[0]),
      cast[ptr UncheckedArray[float32]](addr scratch[0]))
    check e.currentFrame() == total
