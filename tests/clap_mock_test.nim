# tests/clap_mock_test.nim
#
# Сквозной тест хостинга CLAP через `adapters/clap` (issue #53):
# load → enumerate → instantiate → activate → process → params → state →
# host-callback. Плагин — mock из `tests/mock/mock_clap_plugin.nim`,
# собранный в разделяемую библиотеку задачей `nimble clapMock`.
#
# Ранее host- и plugin-side расширения проверялись напрямую (без плагина);
# этот тест закрывает путь целиком, где адаптер и плагин встречаются по
# настоящему ABI.
#
# В файле дерева нет: путь берётся из `build/` (каталог в .gitignore).

import std/[unittest, os]
import plugin_api
import signal_types
import node_interface
import clap_plugin_backend
import clap_host_extensions
import project

const
  Frames = 64

  MockLibPath =
    when defined(windows): "build/mockclap.dll"
    elif defined(macosx): "build/libmockclap.dylib"
    else: "build/libmockclap.so"

  # Должно совпадать с MockPluginId в tests/mock/mock_clap_plugin.nim.
  MockPluginId = "com.euterpia.mock.gain"

type
  Rig = object
    ## Аудио-обвязка: planar-буферы 2 канала + порты + контекст.
    inSamples: array[Frames * 2, float32]
    outSamples: array[Frames * 2, float32]
    inBuf: AudioBuffer
    outBuf: AudioBuffer
    ports: NodeAudioPorts
    ctx: NodeProcessContext

proc initRig(rig: var Rig) =
  rig.inBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr rig.inSamples[0]),
    channels: 2, frames: int32(Frames), stride: int32(Frames))
  rig.outBuf = AudioBuffer(
    data: cast[ptr UncheckedArray[float32]](addr rig.outSamples[0]),
    channels: 2, frames: int32(Frames), stride: int32(Frames))
  rig.ports = NodeAudioPorts()
  rig.ports.inputs[0] = addr rig.inBuf
  rig.ports.inputCount = 1
  rig.ports.outputs[0] = addr rig.outBuf
  rig.ports.outputCount = 1
  rig.ctx = NodeProcessContext(
    sampleRate: 48000.0'f32, blockSize: int32(Frames), samplePosition: 0'i64)

proc fillInput(rig: var Rig) =
  for i in 0 ..< Frames * 2:
    rig.inSamples[i] = float32(i) * 0.001'f32

proc clearOutput(rig: var Rig) =
  for i in 0 ..< Frames * 2:
    rig.outSamples[i] = -1.0'f32

proc outputScaledBy(rig: Rig; gain: float32): bool =
  for i in 0 ..< Frames * 2:
    if abs(rig.outSamples[i] - rig.inSamples[i] * gain) > 1e-5'f32:
      return false
  true

# ---------------------------------------------------------------------------
# Общая оснастка: библиотека mock-плагина лежит в build/.
# ---------------------------------------------------------------------------

proc mockLibPath(): cstring =
  cstring(MockLibPath)

suite "clap mock plugin: host end-to-end":
  test "load → enumerate → instantiate → activate":
    check fileExists(MockLibPath)
    let api = newClapPluginApi()
    check not api.isNil
    defer: freeClapPluginApi(api)

    var log = silentLogger()
    check pluginInit(api, addr log) == peOk
    check pluginBackendNameOf(api) == "clap"

    let path = mockLibPath()
    check pluginCount(api, path) == 1

    var info: PluginInfo
    check pluginInfo(api, path, 0, info)
    check info.id == MockPluginId
    check info.name == "EUTERPIA Mock Gain"
    check info.vendor == "EUTERPIA"
    check info.audioInCount == 1
    check info.audioOutCount == 1
    check info.paramCount == 2
    check info.hasState
    check info.reportedLatency == 8

    let h = pluginInstantiate(api, path, 0)
    check not h.isNil
    defer: pluginDestroy(api, h)

    check pluginActivate(api, h, 48000.0, int32(Frames), 1, 1) == peOk
    check pluginLatencyFrames(api, h) == 8

    # Параметры видны с корректными диапазонами/флагами.
    check pluginParamCount(api, h) == 2
    var p0: PluginParamInfo
    check pluginParamInfo(api, h, 0, p0)
    check p0.id == 0'u32
    check p0.name == "Gain"
    check p0.minValue == 0.0
    check p0.maxValue == 2.0
    check p0.defaultValue == 1.0
    check ppfAutomatable in p0.flags

    var p1: PluginParamInfo
    check pluginParamInfo(api, h, 1, p1)
    check p1.id == 1'u32
    check p1.name == "Bypass"
    check ppfInteger in p1.flags          # CLAP_IS_STEPPED -> ppfInteger
    check p1.step == 1.0
    check not pluginParamInfo(api, h, 9, p1)   # индекс вне диапазона

  test "process применяет gain; paramSet уезжает событиями на flush":
    let api = newClapPluginApi()
    check not api.isNil
    defer: freeClapPluginApi(api)
    var log = silentLogger()
    discard pluginInit(api, addr log)

    let h = pluginInstantiate(api, mockLibPath(), 0)
    check not h.isNil
    defer: pluginDestroy(api, h)
    check pluginActivate(api, h, 48000.0, int32(Frames), 1, 1) == peOk

    var rig: Rig
    rig.initRig()
    rig.fillInput()

    # gain по умолчанию = 1.0: выход повторяет вход.
    rig.clearOutput()
    check pluginProcess(api, h, addr rig.ctx, addr rig.ports, nil, nil) == ppsContinue
    check rig.outputScaledBy(1.0'f32)

    # В CLAP нет setValue: значение применяется на ближайшем flush/process.
    check pluginParamSet(api, h, 0'u32, 0.5)
    check pluginParamFlush(api, h, nil, nil)
    check abs(pluginParamGet(api, h, 0'u32) - 0.5) < 1e-9

    rig.clearOutput()
    check pluginProcess(api, h, addr rig.ctx, addr rig.ports, nil, nil) == ppsContinue
    check rig.outputScaledBy(0.5'f32)

    # Нормированный set: 0.75 диапазона [0,2] -> 1.5 (и это НЕ clamp к 1).
    check pluginParamSet(api, h, 0'u32, 0.75, normalized = true)
    check pluginParamFlush(api, h, nil, nil)
    check abs(pluginParamGet(api, h, 0'u32) - 1.5) < 1e-9

    rig.clearOutput()
    check pluginProcess(api, h, addr rig.ctx, addr rig.ports, nil, nil) == ppsContinue
    check rig.outputScaledBy(1.5'f32)


  test "request_callback доходит до main-thread, state — байт-в-байт":
    let api = newClapPluginApi()
    check not api.isNil
    defer: freeClapPluginApi(api)
    var log = silentLogger()
    discard pluginInit(api, addr log)

    let h = pluginInstantiate(api, mockLibPath(), 0)
    check not h.isNil
    defer: pluginDestroy(api, h)
    check pluginActivate(api, h, 48000.0, int32(Frames), 1, 1) == peOk

    var rig: Rig
    rig.initRig()
    rig.fillInput()

    let ctx = clapHostContextOf(api, h)
    check not ctx.isNil

    # Плагин зовёт host.request_callback из process — ровно один раз.
    check pluginProcess(api, h, addr rig.ctx, addr rig.ports, nil, nil) == ppsContinue
    check takeCallbackRequests(ctx) == 1
    pluginOnMainThread(api, h)          # mock.on_main_thread вызывается
    check takeCallbackRequests(ctx) == 0

    # Первый process — единственное место, где адаптер помечает audio-поток
    # (clap.thread-check): markAudioThread ставит текущий поток. В тесте он
    # же и main-поток (контекст создан в этом потоке), поэтому истинны оба
    # предиката; в реальном хосте их разносит драйвер.
    check isAudioThreadNow(ctx)
    check isMainThreadNow(ctx)

    # clap.state: сохраняем при gain = 1.5, меняем, восстанавливаем.
    check pluginParamSet(api, h, 0'u32, 1.5)
    check pluginParamFlush(api, h, nil, nil)

    let blob = saveInstanceState(api, h)
    check blob.len == 16                # два float64 из mock-плагина
    check blob != newSeq[byte](0)

    check pluginParamSet(api, h, 0'u32, 0.25)
    check pluginParamFlush(api, h, nil, nil)
    check abs(pluginParamGet(api, h, 0'u32) - 0.25) < 1e-9

    check loadInstanceState(api, h, blob)
    check abs(pluginParamGet(api, h, 0'u32) - 1.5) < 1e-9

    # Пустой блоб — «состояния нет», это не ошибка.
    check loadInstanceState(api, h, newSeq[byte](0))

# ---------------------------------------------------------------------------
# Проект: состояние плагина переживает save/load байт-в-байт.
# ---------------------------------------------------------------------------

suite "clap mock plugin: state в проекте":
  test "блоб плагина сохраняется и восстанавливается через core/project":
    let api = newClapPluginApi()
    check not api.isNil
    defer: freeClapPluginApi(api)
    var log = silentLogger()
    discard pluginInit(api, addr log)

    let path = mockLibPath()
    let h = pluginInstantiate(api, path, 0)
    check not h.isNil
    defer: pluginDestroy(api, h)
    check pluginActivate(api, h, 48000.0, int32(Frames), 1, 1) == peOk

    check pluginParamSet(api, h, 0'u32, 0.75)
    check pluginParamFlush(api, h, nil, nil)
    let blob = saveInstanceState(api, h)
    check blob.len == 16

    var proj = ProjectFormat(
      format: ProjectFormatName, version: ProjectFormatVersion)
    proj.pluginStates.add PluginStateFormat(
      nodeId: 1, pluginId: MockPluginId, state: blob)

    let file = getTempDir() / "euterpia_clap_state.json"
    let saved = saveProject(proj, file)
    check saved.success
    defer: removeFile(file)

    let loaded = loadProject(file)
    check loaded.success
    check loaded.value.pluginStates.len == 1
    check loaded.value.pluginStates[0].nodeId == 1
    check loaded.value.pluginStates[0].pluginId == MockPluginId
    let restoredBlob = loaded.value.pluginStates[0].state
    check restoredBlob.len == blob.len
    check restoredBlob == blob          # побайтовое совпадение

    # Блоб из проекта действительно восстанавливает параметр в свежий инстанс.
    let h2 = pluginInstantiate(api, path, 0)
    check not h2.isNil
    defer: pluginDestroy(api, h2)
    check pluginActivate(api, h2, 48000.0, int32(Frames), 1, 1) == peOk
    check abs(pluginParamGet(api, h2, 0'u32) - 1.0) < 1e-9   # дефолт
    check loadInstanceState(api, h2, restoredBlob)
    check abs(pluginParamGet(api, h2, 0'u32) - 0.75) < 1e-9

