# tests/unit/test_runtime_session.nim
#
# Headless runtime-сессия (#407): владелец AudioEngine живёт между запросами
# CLI, принимает команды транспорта и продвигает позицию по стенным часам.
#
# Тест проверяет ядро протокола (без сокетов): команды применяются сразу,
# состояние читается в схеме `euterpia.transport.v1`, stop сбрасывает
# позицию, seek/loop/tempo/meter доезжают до движка.

import std/[json, unittest]

import runtime_session
import transport

proc cmd(s: var RuntimeSession; command: string; extra: JsonNode = nil): JsonNode =
  var request = %*{"api": 1, "command": command}
  if extra != nil:
    for key, value in extra:
      request[key] = value
  var stopRequested = false
  result = s.applyRuntimeCommand(request, stopRequested)

suite "runtime session: транспорт между вызовами (#407)":
  test "init применяет темп и размер, состояние — stopped":
    var s = initRuntimeSession(48000.0f, 128, tempo = 140.0,
                              meterNum = 6, meterDen = 8)
    check s.isActive
    defer: s.closeRuntimeSession()

    let state = s.stateJson()
    check state["schema"].getStr() == TransportSessionSchema
    check state["state"].getStr() == "stopped"
    check state["tempo"].getFloat() == 140.0
    check state["meter"]["numerator"].getInt() == 6
    check state["meter"]["denominator"].getInt() == 8
    check state["position"]["frames"].getBiggestInt() == 0

  test "play живёт во времени: позиция растёт без нового вызова play":
    var s = initRuntimeSession(48000.0f, 128, tempo = 140.0)
    check s.isActive
    defer: s.closeRuntimeSession()

    let play = s.cmd("transport.play")
    check play["ok"].getBool()
    check play["state"]["state"].getStr() == "playing"

    s.tickRuntimeSession(1000)
    check s.stateJson()["position"]["frames"].getBiggestInt() == 0

    s.tickRuntimeSession(2000)   # 1 секунда аудио
    let frames = s.stateJson()["position"]["frames"].getBiggestInt()
    check frames >= 48000
    check s.stateJson()["position"]["seconds"].getFloat() >= 1.0

  test "stop останавливает и возвращает позицию в 0, pause сохраняет":
    var s = initRuntimeSession(48000.0f, 128)
    check s.isActive
    defer: s.closeRuntimeSession()

    discard s.cmd("transport.play")
    s.tickRuntimeSession(1000)
    s.tickRuntimeSession(2000)
    check s.stateJson()["position"]["frames"].getBiggestInt() > 0

    check s.cmd("transport.pause")["state"]["state"].getStr() == "paused"
    let pausedAt = s.stateJson()["position"]["frames"].getBiggestInt()
    s.tickRuntimeSession(3000)
    check s.stateJson()["position"]["frames"].getBiggestInt() == pausedAt

    let stopped = s.cmd("transport.stop")
    check stopped["state"]["state"].getStr() == "stopped"
    check stopped["state"]["position"]["frames"].getBiggestInt() == 0

  test "seek и loop доезжают до движка и видны в состоянии":
    var s = initRuntimeSession(48000.0f, 128)
    check s.isActive
    defer: s.closeRuntimeSession()

    let seek = s.cmd("transport.seek", %*{"frames": 24000})
    check seek["ok"].getBool()
    check seek["state"]["position"]["frames"].getBiggestInt() == 24000

    let loop = s.cmd("transport.loop", %*{"enabled": true,
                                           "startFrame": 1000,
                                           "endFrame": 2000})
    check loop["ok"].getBool()
    check loop["state"]["loop"]["enabled"].getBool()
    check loop["state"]["loop"]["startFrames"].getBiggestInt() == 1000
    check loop["state"]["loop"]["endFrames"].getBiggestInt() == 2000

    let off = s.cmd("transport.loop", %*{"enabled": false})
    check not off["state"]["loop"]["enabled"].getBool()

  test "tempo и meter меняются на живом движке":
    var s = initRuntimeSession(48000.0f, 128)
    check s.isActive
    defer: s.closeRuntimeSession()

    let tempo = s.cmd("engine.tempo", %*{"tempo": 90.0})
    check tempo["ok"].getBool()
    check tempo["state"]["tempo"].getFloat() == 90.0

    let meter = s.cmd("engine.meter", %*{"numerator": 3, "denominator": 4})
    check meter["ok"].getBool()
    check meter["state"]["meter"]["numerator"].getInt() == 3

  test "session.stop выставляет флаг, неизвестная команда — отказ":
    var s = initRuntimeSession(48000.0f, 128)
    check s.isActive
    defer: s.closeRuntimeSession()

    var stopRequested = false
    let stop = s.applyRuntimeCommand(%*{"api": 1, "command": "session.stop"},
                                     stopRequested)
    check stop["ok"].getBool()
    check stopRequested

    let bad = s.cmd("transport.teleport")
    check not bad["ok"].getBool()
    check bad["error"].getStr().len > 0

  test "остановка сессии освобождает движок (повторная — безопасна)":
    var s = initRuntimeSession(48000.0f, 128)
    check s.isActive
    s.closeRuntimeSession()
    check not s.isActive
    s.closeRuntimeSession()   # идемпотентно
    check not s.isActive
