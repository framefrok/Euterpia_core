# tests/unit/test_lilv_backend.nim
#
# LV2-адаптер за `plugin_api` (issue #39).
#
# liblilv в CI может отсутствовать (и на машине разработчика тоже), поэтому
# тест доказывает главное для надёжности: отсутствие библиотеки — это
# `peUnavailable` и пустые ответы, а не падение процесса. Реальный хостинг
# LV2 проверяется на машине с liblilv вручную (`plugin scan` по бандлу).

import std/[unittest, os]

import plugin_api
import lilv_plugin_backend

suite "lv2/lilv: контракт и graceful degrade (#39)":

  test "pluginInit без liblilv даёт peUnavailable":
    let api = createLilvPluginApi()
    doAssert api != nil
    defer: destroyLilvPluginApi(api)

    putEnv("EUTERPIA_LILV_LIB", "/nonexistent/liblilv-0.so")
    let err = pluginInit(api, nil)
    delEnv("EUTERPIA_LILV_LIB")
    # Машина без liblilv — peUnavailable; с библиотекой — peOk. Оба исхода
    # законны: падение процесса — нет.
    check err in {peOk, peUnavailable}

    # Все nil-safe обёртки обязаны отвечать «нет данных», а не падать.
    check pluginCount(api, cstring("/tmp/no-bundle")) <= 0
    var info: PluginInfo
    check not pluginInfo(api, cstring("/tmp/no-bundle"), 0, info)
    check pluginInstantiate(api, cstring("/tmp/no-bundle"), 0).isNil
    check pluginBackendNameOf(api) == "lv2"

  test "методы инстанса без библиотеки не падают":
    let api = createLilvPluginApi()
    doAssert api != nil
    defer: destroyLilvPluginApi(api)
    putEnv("EUTERPIA_LILV_LIB", "/nonexistent/liblilv-0.so")
    discard pluginInit(api, nil)
    delEnv("EUTERPIA_LILV_LIB")

    let h = pluginInstantiate(api, cstring("/tmp/no-bundle"), 0)
    check h.isNil
    # nil-хэндл: обёртка обязана ответить отказом до вызова адаптера.
    check pluginActivate(api, h, 48000.0, 512, 2, 2) == peUnavailable
    pluginDeactivate(api, h)
    pluginReset(api, h)
    var ctx: NodeProcessContext
    var audio: NodeAudioPorts
    var inQ, outQ: EventQueue
    check pluginProcess(api, h, addr ctx, addr audio, addr inQ, addr outQ) ==
      ppsError
    check pluginParamCount(api, h) == 0
    check pluginLatencyFrames(api, h) == 0
    pluginDestroy(api, h)
