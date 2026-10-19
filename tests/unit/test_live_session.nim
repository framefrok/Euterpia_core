# tests/unit/test_live_session.nim
#
# Публичный API живого сеанса (issue #92): без него CLI пришлось бы
# импортировать `audio_engine`/`ipc_bus`, что запрещает джоб architecture.
#
# Проверяется граница, а не устройство: сеанс создаётся из пустого
# пайплайна, callback выдаёт тишину, метрики читаются DTO, закрытие
# идемпотентно. Реальный драйвер — `nimble miniaudioSmoke` и ручной `play`.

import std/[unittest]

import compiled_pipeline
import live_session

suite "live session (#92)":
  test "пустой сеанс создаётся, рендерит тишину и закрывается":
    var owned = newOwnedPipeline()
    var session = initLiveSession(48000.0f, 128, move(owned))
    check session.isActive
    defer: session.closeLiveSession()

    check session.postPlay()
    check session.postSetTempo(120.0)
    check session.postSetMeter(4, 4)
    session.flushQueuedCommands()

    var outBuf: array[256, float32]
    for i in 0 ..< outBuf.len: outBuf[i] = 1.0f   # мусор прошлого блока
    liveRender(cast[pointer](addr session), nil,
               cast[ptr UncheckedArray[float32]](addr outBuf[0]), 128, 0, 2)
    for i in 0 ..< outBuf.len:
      check outBuf[i] == 0.0f

    # Метрики — DTO: состояние строкой, счётчики числами.
    var m: LiveMetrics
    var got = false
    while session.pollMetrics(m):
      got = true
    check got
    check m.transportState == "playing"
    check session.xrunCount() == 0'u32
    check session.droppedMetrics() == 0'u32
    check session.currentFrame() == 128

    discard session.postStop()
    session.flushQueuedCommands()
    check session.currentFrame() == 0

  test "некорректный размер блока — сеанс не создаётся":
    var owned = newOwnedPipeline()
    var session = initLiveSession(48000.0f, 0, move(owned))
    check not session.isActive
    session.closeLiveSession()

  test "closeLiveSession идемпотентен":
    var owned = newOwnedPipeline()
    var session = initLiveSession(48000.0f, 128, move(owned))
    check session.isActive
    session.closeLiveSession()
    check not session.isActive
    session.closeLiveSession()
    check not session.isActive
