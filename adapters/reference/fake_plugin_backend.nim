# adapters/reference/fake_plugin_backend.nim
#
# Эталонный (reference) адаптер хостинга плагинов за `core/plugin_api.nim`.
#
# Это НЕ хостинг реального формата. Это минимальная, детерминированная
# реализация таблицы методов `PluginApi`, которая:
#
#   * не тянет dynlib и не требует внешних бинарей;
#   * позволяет проверить сам контракт (единицы тестов идут «на чистой
#     машине», см. tests/unit/test_plugin_api.nim);
#   * служит образцом для CLAP/EUT/LV2-адаптеров: граф и scheduler
#     работают через `PluginApi` и не знают о формате.
#
# «Библиотека» плагинов живёт в памяти: путь `memory://euterpia-fx`
# содержит два плагина — gain (2 параметра) и delay (1 параметр, задержка
# 64 кадра). Этого достаточно, чтобы доказать: второй плагин/формат
# подключается без правок Core.
#
# Realtime-контракт (§9, §10): `fakeProcess` не аллоцирует, не лочит и не
# бросает исключений; все буферы — фиксированного размера внутри инстанса.
#
# MANIFEST §8, §40, §41, §42, §102.

import std/math
import plugin_api
import signal_types
import node_interface

{.push raises: [].}

const
  FakeLibraryPath* = "memory://euterpia-fx"
  FakePluginCount* = 2
  FakeDelayLatency* = 64
  FakeGainMinDb* = -60.0
  FakeGainMaxDb* = 12.0

type
  FakePluginKind* = enum
    fpkGain
    fpkDelay

  FakePluginInstance = object
    ## Состояние одного инстанса. Живёт в shared-куче, время жизни —
    ## от instantiate() до destroy().
    kind: FakePluginKind
    active: bool
    sampleRate: float64
    maxBlock: int32
    audioIn: int32
    audioOut: int32
    paramCount: int32
    paramIds: array[4, uint32]
    paramValues: array[4, float64]

  FakePluginBackend = object
    ## Состояние адаптера (поле `impl` таблицы методов).
    mainThreadCalls: int32

# ----------------------------------------------------------------------------
# Утилиты
# ----------------------------------------------------------------------------

proc implOf(api: ptr PluginApi): ptr FakePluginBackend {.inline.} =
  if api.isNil:
    return nil
  cast[ptr FakePluginBackend](api.impl)

proc instOf(handle: PluginHandle): ptr FakePluginInstance {.inline.} =
  cast[ptr FakePluginInstance](handle)

proc dbToLin(db: float64): float64 {.inline.} =
  pow(2.0, db * (1.0 / 6.0205999132796239))

proc clamp01(v: float64): float64 {.inline.} =
  if v < 0.0: 0.0 elif v > 1.0: 1.0 else: v

proc initFakeInstance(kind: FakePluginKind): ptr FakePluginInstance =
  let inst = cast[ptr FakePluginInstance](allocShared0(sizeof(FakePluginInstance)))
  if inst.isNil:
    return nil
  inst.kind = kind
  case kind
  of fpkGain:
    inst.paramCount = 2
    inst.paramIds[0] = 1
    inst.paramIds[1] = 2
    # param 1: Gain (dB), param 2: Bypass (choice)
  of fpkDelay:
    inst.paramCount = 1
    inst.paramIds[0] = 1
    # param 1: Mix
  result = inst

proc defaultsFor(inst: ptr FakePluginInstance) =
  ## Значения по умолчанию. Индекс в массиве — позиция, не id.
  case inst.kind
  of fpkGain:
    inst.paramValues[0] = 0.0     # 0 dB
    inst.paramValues[1] = 0.0     # не bypass
  of fpkDelay:
    inst.paramValues[0] = 0.5     # 50% wet

proc paramIndex(inst: ptr FakePluginInstance; paramId: uint32): int =
  for i in 0 ..< int(inst.paramCount):
    if inst.paramIds[i] == paramId:
      return i
  -1

# ----------------------------------------------------------------------------
# Таблица методов PluginApi
# ----------------------------------------------------------------------------

proc fakeInit(api: ptr PluginApi; log: ptr Logger): PluginError
    {.cdecl, raises: [], gcsafe.} =
  let impl = implOf(api)
  if impl.isNil:
    return peUnavailable
  impl.mainThreadCalls = 0
  peOk

proc fakeShutdown(api: ptr PluginApi) {.cdecl, raises: [], gcsafe.} =
  discard

proc fakePluginCount(api: ptr PluginApi; path: cstring): int32
    {.cdecl, raises: [], gcsafe.} =
  if path.isNil:
    return -1
  if $path == FakeLibraryPath:
    return int32(FakePluginCount)
  0

proc fillGainInfo(info: var PluginInfo) =
  info.id = "memory.gain"
  info.name = "Fake Gain"
  info.vendor = "EUTERPIA reference"
  info.version = "1.0.0"
  info.category = pcEffect
  info.audioInCount = 1
  info.audioOutCount = 1
  info.paramCount = 2
  info.hasState = true
  info.hasGui = false
  info.reportedLatency = 0

proc fillDelayInfo(info: var PluginInfo) =
  info.id = "memory.delay"
  info.name = "Fake Delay"
  info.vendor = "EUTERPIA reference"
  info.version = "1.0.0"
  info.category = pcEffect
  info.audioInCount = 1
  info.audioOutCount = 1
  info.paramCount = 1
  info.hasState = true
  info.hasGui = false
  info.reportedLatency = int32(FakeDelayLatency)

proc fakePluginInfo(
  api: ptr PluginApi;
  path: cstring;
  index: int32;
  info: var PluginInfo
): bool {.cdecl, raises: [], gcsafe.} =
  if implOf(api).isNil or path.isNil or $path != FakeLibraryPath:
    return false
  case index
  of 0:
    fillGainInfo(info)
    true
  of 1:
    fillDelayInfo(info)
    true
  else:
    false

proc fakeInstantiate(
  api: ptr PluginApi;
  path: cstring;
  index: int32
): PluginHandle {.cdecl, raises: [], gcsafe.} =
  if implOf(api).isNil or path.isNil or $path != FakeLibraryPath:
    return nil
  case index
  of 0:
    result = cast[PluginHandle](initFakeInstance(fpkGain))
  of 1:
    result = cast[PluginHandle](initFakeInstance(fpkDelay))
  else:
    result = nil
  if not result.isNil:
    defaultsFor(instOf(result))

proc fakeDestroy(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  if handle.isNil:
    return
  deallocShared(instOf(handle))

proc fakeActivate(
  api: ptr PluginApi;
  handle: PluginHandle;
  sampleRate: float64;
  maxBlock: int32;
  audioIn: int32;
  audioOut: int32
): PluginError {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil:
    return peNoSuchPlugin
  if audioIn <= 0 or audioOut <= 0 or maxBlock <= 0 or sampleRate <= 0.0:
    return peInstantiateFailed
  inst.sampleRate = sampleRate
  inst.maxBlock = maxBlock
  inst.audioIn = audioIn
  inst.audioOut = audioOut
  inst.active = true
  peOk

proc fakeDeactivate(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if not inst.isNil:
    inst.active = false

proc fakeReset(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if not inst.isNil:
    defaultsFor(inst)

proc fakeProcess(
  api: ptr PluginApi;
  handle: PluginHandle;
  ctx: ptr NodeProcessContext;
  audio: ptr NodeAudioPorts;
  inEvents: ptr EventQueue;
  outEvents: ptr EventQueue
): PluginProcessStatus {.cdecl, raises: [], gcsafe.} =
  ## Realtime: без аллокаций, локов и исключений.
  let inst = instOf(handle)
  if inst.isNil or audio.isNil or not inst.active:
    return ppsError

  # Коэффициент передачи: gain-плагин применяет Gain (param 1) и Bypass
  # (param 2); delay-плагин — Mix (param 1). Оба — детерминированная
  # линейная операция, этого достаточно для проверки контракта.
  var coeff = 1.0
  case inst.kind
  of fpkGain:
    if inst.paramValues[1] >= 0.5:
      coeff = 1.0
    else:
      coeff = dbToLin(inst.paramValues[0])
  of fpkDelay:
    coeff = clamp01(inst.paramValues[0])

  var frames = 0
  if not ctx.isNil:
    frames = int(ctx.blockSize)
  elif audio.outputCount > 0 and not audio.outputs[0].isNil:
    frames = int(audio.outputs[0].frames)

  for c in 0 ..< int(audio.outputCount):
    let dst = audio.outputs[c]
    if dst.isNil or dst.data.isNil:
      continue
    let useFrames = min(frames, int(dst.frames))
    if audio.inputCount > 0 and not audio.inputs[0].isNil and
       not audio.inputs[0].data.isNil:
      let src = audio.inputs[0].data
      for i in 0 ..< useFrames:
        dst.data[i] = float32(float64(src[i]) * coeff)
    else:
      for i in 0 ..< useFrames:
        dst.data[i] = 0.0f

  # Проброс событий: адаптер обязан уметь это без аллокаций.
  if not inEvents.isNil and not outEvents.isNil:
    clearEvents(outEvents)
    for i in 0 ..< inEvents.count:
      if outEvents.count >= MaxBlockEvents:
        break
      outEvents.events[outEvents.count] = inEvents.events[i]
      inc outEvents.count

  ppsContinue

proc fakeParamCount(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil:
    return 0
  inst.paramCount

proc fakeParamInfo(
  api: ptr PluginApi;
  handle: PluginHandle;
  index: int32;
  info: var PluginParamInfo
): bool {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil or index < 0 or index >= int(inst.paramCount):
    return false
  info.id = inst.paramIds[index]
  case inst.kind
  of fpkGain:
    if index == 0:
      info.name = "Gain"
      info.flags = {ppfAutomatable}
      info.minValue = FakeGainMinDb
      info.maxValue = FakeGainMaxDb
      info.defaultValue = 0.0
      info.step = 0.1
    else:
      info.name = "Bypass"
      info.flags = {ppfAutomatable, ppfChoice, ppfInteger}
      info.minValue = 0.0
      info.maxValue = 1.0
      info.defaultValue = 0.0
      info.step = 1.0
  of fpkDelay:
    info.name = "Mix"
    info.flags = {ppfAutomatable}
    info.minValue = 0.0
    info.maxValue = 1.0
    info.defaultValue = 0.5
    info.step = 0.01
  true

proc fakeParamGet(api: ptr PluginApi; handle: PluginHandle;
  paramId: uint32): float64 {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil:
    return 0.0
  let idx = paramIndex(inst, paramId)
  if idx < 0:
    return 0.0
  inst.paramValues[idx]

proc fakeParamSet(api: ptr PluginApi; handle: PluginHandle;
  paramId: uint32; value: float64; normalized: bool): bool
    {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil:
    return false
  let idx = paramIndex(inst, paramId)
  if idx < 0:
    return false
  var v = value
  if normalized:
    var lo = 0.0
    var hi = 1.0
    var info: PluginParamInfo
    if fakeParamInfo(api, handle, int32(idx), info):
      lo = info.minValue
      hi = info.maxValue
    v = lo + clamp01(value) * (hi - lo)
  inst.paramValues[idx] = v
  true

proc fakeParamFlush(
  api: ptr PluginApi;
  handle: PluginHandle;
  inEvents: ptr EventQueue;
  outEvents: ptr EventQueue
): bool {.cdecl, raises: [], gcsafe.} =
  ## Sample-accurate: читает evParamChange из inEvents, применяет к
  ## параметрам и подтверждает одним out-event.
  let inst = instOf(handle)
  if inst.isNil:
    return false
  if not outEvents.isNil:
    clearEvents(outEvents)
  if inEvents.isNil:
    return false
  for i in 0 ..< inEvents.count:
    let ev = inEvents.events[i]
    if ev.kind != evParamChange:
      continue
    let paramId = uint32(max(0.0f, ev.data[0]))
    let idx = paramIndex(inst, paramId)
    if idx < 0:
      continue
    inst.paramValues[idx] = float64(ev.data[1])
    if not outEvents.isNil and outEvents.count < MaxBlockEvents:
      outEvents.events[outEvents.count] = RealtimeEvent(
        frameOffset: ev.frameOffset,
        kind: evParamChange,
        port: ev.port,
        channel: ev.channel,
        data: [float32(paramId), ev.data[1], 0.0f, 0.0f]
      )
      inc outEvents.count
  true

proc fakeStateSave(api: ptr PluginApi; handle: PluginHandle;
  dst: pointer; maxLen: int): int {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil or dst.isNil:
    return -1
  let need = int(inst.paramCount) * sizeof(float64)
  if maxLen < need:
    return -1
  copyMem(dst, unsafeAddr inst.paramValues[0], need)
  need

proc fakeStateLoad(api: ptr PluginApi; handle: PluginHandle;
  src: pointer; len: int): bool {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil or src.isNil:
    return false
  let need = int(inst.paramCount) * sizeof(float64)
  if len < need:
    return false
  copyMem(addr inst.paramValues[0], src, need)
  true

proc fakeLatencyFrames(api: ptr PluginApi; handle: PluginHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  let inst = instOf(handle)
  if inst.isNil:
    return 0
  if inst.kind == fpkDelay:
    return int32(FakeDelayLatency)
  0

proc fakeOnMainThread(api: ptr PluginApi; handle: PluginHandle)
    {.cdecl, raises: [], gcsafe.} =
  let impl = implOf(api)
  if not impl.isNil:
    inc impl.mainThreadCalls

# ----------------------------------------------------------------------------
# Фабрика адаптера
# ----------------------------------------------------------------------------

proc newFakePluginApi*(): ptr PluginApi =
  ## Собирает таблицу методов reference-адаптера в shared-куче.
  ## Вызывающий владеет результатом и обязан позвать `freeFakePluginApi`.
  let impl = createShared(FakePluginBackend)
  if impl.isNil:
    return nil
  result = createShared(PluginApi)
  if result.isNil:
    deallocShared(impl)
    return nil
  result.backendName = "reference-fake"
  result.impl = cast[pointer](impl)
  result.init = fakeInit
  result.shutdown = fakeShutdown
  result.pluginCount = fakePluginCount
  result.pluginInfo = fakePluginInfo
  result.instantiate = fakeInstantiate
  result.destroy = fakeDestroy
  result.activate = fakeActivate
  result.deactivate = fakeDeactivate
  result.reset = fakeReset
  result.process = fakeProcess
  result.countParams = fakeParamCount
  result.paramInfo = fakeParamInfo
  result.paramGet = fakeParamGet
  result.paramSet = fakeParamSet
  result.paramFlush = fakeParamFlush
  result.stateSave = fakeStateSave
  result.stateLoad = fakeStateLoad
  result.latencyFrames = fakeLatencyFrames
  result.onMainThread = fakeOnMainThread

proc freeFakePluginApi*(api: ptr PluginApi) =
  if api.isNil:
    return
  if not api.impl.isNil:
    deallocShared(cast[ptr FakePluginBackend](api.impl))
  deallocShared(api)

proc fakeMainThreadCalls*(api: ptr PluginApi): int32 =
  ## Для тестов: сколько раз адаптер вызвал onMainThread.
  let impl = implOf(api)
  if impl.isNil:
    return 0
  impl.mainThreadCalls

{.pop.}

