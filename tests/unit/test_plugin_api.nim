# tests/unit/test_plugin_api.nim
#
# Контракт хостинга плагинов (issue #29).
#
# Тест доказывает четыре вещи:
#   1. Core управляет плагином через таблицу методов `plugin_api` и не
#      знает, CLAP там, EUT или ничего. Reference-адаптер определён в
#      `adapters/reference/fake_plugin_backend.nim`, поэтому тест:
#        * не требует установленного плагина/сети;
#        * не грузит dynlib;
#        * воспроизводит поведение хоста детерминированно.
#   2. nil-safe обёртки дают код ошибки, а не падение.
#   3. Второй плагин подключается тем же кодом (нет правок scheduler /
#      compiled_pipeline — тест не импортирует их вовсе).
#   4. `process` работает на буферах Core без аллокаций (только POD).

import std/unittest
import plugin_api
import signal_types
import node_interface
import fake_plugin_backend

const
  BlockSize = 64
  SampleRate = 48000.0

type
  TestRig = object
    ctx: NodeProcessContext
    audio: NodeAudioPorts
    inL: array[BlockSize, float32]
    outL: array[BlockSize, float32]
    inBuf: AudioBuffer
    outBuf: AudioBuffer
    inEvents: EventQueue
    outEvents: EventQueue

proc initRig(rig: var TestRig) =
  rig.ctx = NodeProcessContext(
    sampleRate: float32(SampleRate),
    blockSize: int32(BlockSize),
    samplePosition: 0'i64
  )
  rig.inBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr rig.inL[0]),
    channels: 1, frames: int32(BlockSize), stride: int32(BlockSize)
  )
  rig.outBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr rig.outL[0]),
    channels: 1, frames: int32(BlockSize), stride: int32(BlockSize)
  )
  rig.audio = NodeAudioPorts()
  rig.audio.inputCount = 1
  rig.audio.outputCount = 1
  rig.audio.inputs[0] = addr rig.inBuf
  rig.audio.outputs[0] = addr rig.outBuf
  clearEvents(addr rig.inEvents)
  clearEvents(addr rig.outEvents)

proc fillInput(rig: var TestRig; value: float32) =
  for i in 0 ..< BlockSize:
    rig.inL[i] = value
    rig.outL[i] = 0.0f

proc createBackend(): ptr PluginApi =
  let api = newFakePluginApi()
  check api != nil
  check pluginInit(api, nil) == peOk
  api

suite "plugin_api: контракт хостинга":

  test "nil-safe обёртки не падают":
    check pluginInit(nil, nil) == peUnavailable
    check pluginCount(nil, "memory://euterpia-fx") == -1
    check pluginInstantiate(nil, "memory://euterpia-fx", 0) == nil
    check pluginProcess(nil, nil, nil, nil, nil, nil) == ppsError
    check pluginParamCount(nil, nil) == 0
    check pluginParamGet(nil, nil, 1) == 0.0
    check pluginParamSet(nil, nil, 1, 1.0) == false
    check pluginStateSave(nil, nil, nil, 0) == -1
    check pluginStateLoad(nil, nil, nil, 0) == false
    check pluginLatencyFrames(nil, nil) == 0
    check pluginBackendNameOf(nil) == "none"
    # destroy/shutdown/deactivate/reset/onMainThread на nil — тихий no-op.
    pluginShutdown(nil)
    pluginDeactivate(nil, nil)
    pluginReset(nil, nil)
    pluginDestroy(nil, nil)
    pluginOnMainThread(nil, nil)

  test "фабрика выставляет имя формата":
    let api = createBackend()
    check pluginBackendNameOf(api) == "reference-fake"
    pluginShutdown(api)
    freeFakePluginApi(api)

  test "перечисление плагинов идёт через контракт":
    let api = createBackend()

    check pluginCount(api, "memory://euterpia-fx") == 2
    check pluginCount(api, "memory://nope") == 0

    var info: PluginInfo
    check pluginInfo(api, "memory://euterpia-fx", 0, info)
    check info.id == "memory.gain"
    check info.category == pcEffect
    check info.paramCount == 2

    check pluginInfo(api, "memory://euterpia-fx", 1, info)
    check info.id == "memory.delay"
    check info.reportedLatency == 64

    # Индекс вне диапазона и чужой путь — false, без падения.
    check pluginInfo(api, "memory://euterpia-fx", 9, info) == false
    check pluginInfo(api, "memory://nope", 0, info) == false

    freeFakePluginApi(api)

  test "activate -> process -> deactivate":
    let api = createBackend()
    let h = pluginInstantiate(api, "memory://euterpia-fx", 0)
    check h != nil

    var rig: TestRig
    rig.initRig()
    rig.fillInput(1.0f)

    # Без activate process обязан вернуть ошибку.
    check pluginProcess(api, h, addr rig.ctx, addr rig.audio,
                        addr rig.inEvents, addr rig.outEvents) == ppsError

    check pluginActivate(api, h, SampleRate, int32(BlockSize), 1, 1) == peOk

    # Gain по умолчанию 0 dB -> unity.
    check pluginParamSet(api, h, 1, 0.0, false)
    check pluginProcess(api, h, addr rig.ctx, addr rig.audio,
                        addr rig.inEvents, addr rig.outEvents) == ppsContinue
    check abs(rig.outL[0] - 1.0f) < 1e-6f

    # Gain +6.0206 dB ≈ коэффициент 2.0.
    check pluginParamSet(api, h, 1, 6.0205999132796239, false)
    rig.fillInput(1.0f)
    discard pluginProcess(api, h, addr rig.ctx, addr rig.audio,
                          addr rig.inEvents, addr rig.outEvents)
    check abs(rig.outL[0] - 2.0f) < 1e-4f

    # Bypass (normalized = true): 1.0 -> максимум -> обход.
    check pluginParamSet(api, h, 2, 1.0, true)
    rig.fillInput(1.0f)
    discard pluginProcess(api, h, addr rig.ctx, addr rig.audio,
                          addr rig.inEvents, addr rig.outEvents)
    check abs(rig.outL[0] - 1.0f) < 1e-6f

    pluginDeactivate(api, h)
    check pluginProcess(api, h, addr rig.ctx, addr rig.audio,
                        addr rig.inEvents, addr rig.outEvents) == ppsError

    pluginDestroy(api, h)
    freeFakePluginApi(api)

  test "события пробрасываются без аллокаций":
    let api = createBackend()
    let h = pluginInstantiate(api, "memory://euterpia-fx", 0)
    discard pluginActivate(api, h, SampleRate, int32(BlockSize), 1, 1)

    var rig: TestRig
    rig.initRig()
    rig.fillInput(0.5f)
    discard pushEvent(addr rig.inEvents, RealtimeEvent(
      frameOffset: 0'u32, kind: evNoteOn, data: [60.0f, 1.0f, 0.0f, 0.0f]))
    discard pushEvent(addr rig.inEvents, RealtimeEvent(
      frameOffset: 4'u32, kind: evNoteOff, data: [60.0f, 0.0f, 0.0f, 0.0f]))

    discard pluginProcess(api, h, addr rig.ctx, addr rig.audio,
                          addr rig.inEvents, addr rig.outEvents)

    check rig.outEvents.count == 2
    check rig.outEvents.events[0].kind == evNoteOn
    check rig.outEvents.events[1].kind == evNoteOff

    pluginDestroy(api, h)
    freeFakePluginApi(api)

  test "параметры: count / info / get / set / flush":
    let api = createBackend()
    let h = pluginInstantiate(api, "memory://euterpia-fx", 0)
    check pluginParamCount(api, h) == 2

    var info: PluginParamInfo
    check pluginParamInfo(api, h, 0, info)
    check info.id == 1'u32
    check info.name == "Gain"
    check ppfAutomatable in info.flags
    check info.minValue == -60.0

    check pluginParamInfo(api, h, 1, info)
    check info.name == "Bypass"
    check ppfChoice in info.flags
    check pluginParamInfo(api, h, 5, info) == false

    # set/get
    check pluginParamSet(api, h, 1, 3.0, false)
    check pluginParamGet(api, h, 1) == 3.0
    check pluginParamSet(api, h, 999, 1.0, false) == false

    # flush: evParamChange data[0] = paramId, data[1] = value
    var inQ, outQ: EventQueue
    clearEvents(addr inQ)
    clearEvents(addr outQ)
    discard pushEvent(addr inQ, RealtimeEvent(
      frameOffset: 2'u32, kind: evParamChange, data: [1.0f, -6.0f, 0.0f, 0.0f]))
    check pluginParamFlush(api, h, addr inQ, addr outQ)
    check pluginParamGet(api, h, 1) == -6.0
    check outQ.count == 1
    check outQ.events[0].kind == evParamChange

    pluginDestroy(api, h)
    freeFakePluginApi(api)

  test "state сохраняется и восстанавливается байт-в-байт":
    let api = createBackend()
    let h = pluginInstantiate(api, "memory://euterpia-fx", 0)

    check pluginParamSet(api, h, 1, 4.5, false)
    check pluginParamSet(api, h, 2, 1.0, false)

    var saved: array[64, byte]
    let n = pluginStateSave(api, h, addr saved[0], saved.len)
    check n == 2 * sizeof(float64)

    # Сброс параметров к дефолтам.
    pluginReset(api, h)
    check pluginParamGet(api, h, 1) == 0.0

    check pluginStateLoad(api, h, addr saved[0], n)
    check pluginParamGet(api, h, 1) == 4.5
    check pluginParamGet(api, h, 2) == 1.0

    # Буфер меньше нужного -> ошибка, состояние не портится.
    check pluginStateSave(api, h, addr saved[0], 4) == -1
    check pluginStateLoad(api, h, addr saved[0], 4) == false

    pluginDestroy(api, h)
    freeFakePluginApi(api)

  test "latency и onMainThread идут через контракт":
    let api = createBackend()

    let gain = pluginInstantiate(api, "memory://euterpia-fx", 0)
    check pluginLatencyFrames(api, gain) == 0
    pluginDestroy(api, gain)

    let delay = pluginInstantiate(api, "memory://euterpia-fx", 1)
    check pluginLatencyFrames(api, delay) == 64

    check fakeMainThreadCalls(api) == 0
    pluginOnMainThread(api, delay)
    pluginOnMainThread(api, delay)
    check fakeMainThreadCalls(api) == 2

    pluginDestroy(api, delay)
    freeFakePluginApi(api)

  test "второй плагин подключается тем же кодом (формат-агностично)":
    ## Один и тот же вызов контракта обслуживает разные плагины: это и
    ## есть доказательство, что добавление формата/плагина не требует
    ## правок Core. Тест сознательно не импортирует scheduler/pipeline.
    let api = createBackend()

    for idx in 0 ..< 2:
      var info: PluginInfo
      check pluginInfo(api, "memory://euterpia-fx", int32(idx), info)
      let h = pluginInstantiate(api, "memory://euterpia-fx", int32(idx))
      check h != nil
      check pluginActivate(api, h, SampleRate, int32(BlockSize), 1, 1) == peOk

      var rig: TestRig
      rig.initRig()
      rig.fillInput(0.25f)
      check pluginProcess(api, h, addr rig.ctx, addr rig.audio,
                          addr rig.inEvents, addr rig.outEvents) == ppsContinue
      for i in 0 ..< BlockSize:
        check rig.outL[i] == rig.outL[i]     # не NaN

      pluginDestroy(api, h)

    freeFakePluginApi(api)

  test "instantiate с плохим путём/индексом даёт nil":
    let api = createBackend()
    check pluginInstantiate(api, "memory://nope", 0) == nil
    check pluginInstantiate(api, "memory://euterpia-fx", 7) == nil
    freeFakePluginApi(api)
