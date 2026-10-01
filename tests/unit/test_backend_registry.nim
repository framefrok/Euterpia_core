# tests/unit/test_backend_registry.nim
#
# Реестр бэкендов и hot-swap (issue #32).
#
# Главное утверждение: Core выбирает бэкенд по СТРОКОВОМУ имени и умеет
# переключаться между двумя адаптерами, не зная ни одной библиотеки. Тест
# полностью герметичен: адаптеры — фейковые, устройство не открывается.
#
# Что проверяется:
#   - регистрация/дубли/неизвестные имена;
#   - createBackend/destroyBackend зовут фабрику и деструктор;
#   - недоступная фабрика (nil) даёт reUnavailable и НЕ ломает выбор других;
#   - политика pickBackend: приоритет → первый доступный;
#   - менеджер: open → close → open, счётчики create == destroy (нет утечки
#     при hot-swap), сбой open откатывается;
#   - hot-swap на живом AudioEngine: рендер продолжается после переключения.

import std/unittest
import audio_backend_api
import audio_engine
import backend_registry
import backend_manager

const
  FakeBlockSize = 64
  FakeOutChannels = 2

type
  ProbeState = object
    ## Счётчики жизненного цикла. Лежат в shared-памяти: фабрики захватывают
    ## на них сырой указатель, а тест читает те же значения.
    created: int32
    destroyed: int32
    inited: int32
    opened: int32
    started: int32
    stopped: int32
    closed: int32
    ## > 0 == fakeOpen вернёт abeOpenFailed (проверка отката).
    refuseOpen: int32

  FakeImpl = object
    probe: ptr ProbeState
    render: AudioRenderProc
    engineCtx: pointer
    outChannels: int32
    opened: bool
    running: bool

proc newProbe(refuseOpen: bool = false): ptr ProbeState =
  result = cast[ptr ProbeState](allocShared0(sizeof(ProbeState)))
  if not result.isNil and refuseOpen:
    result.refuseOpen = 1

proc fakeImpl(api: ptr AudioBackendApi): ptr FakeImpl {.inline.} =
  if api.isNil: nil else: cast[ptr FakeImpl](api.impl)

# ---------------------------------------------------------------------------
# Таблица методов фейкового адаптера
# ---------------------------------------------------------------------------

proc fakeInit(api: ptr AudioBackendApi; log: ptr Logger): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let fi = fakeImpl(api)
  if fi.isNil or fi.probe.isNil: return abeUnavailable
  inc fi.probe.inited
  abeOk

proc fakeShutdown(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let fi = fakeImpl(api)
  if not fi.isNil and not fi.probe.isNil:
    fi.opened = false
    fi.running = false

proc fakeOpen(api: ptr AudioBackendApi; cfg: AudioStreamConfig;
              render: AudioRenderProc; engineCtx: pointer): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let fi = fakeImpl(api)
  if fi.isNil or render.isNil: return abeUnavailable
  if fi.probe.refuseOpen > 0:
    return abeOpenFailed
  fi.render = render
  fi.engineCtx = engineCtx
  fi.outChannels = cfg.outputChannels
  fi.opened = true
  inc fi.probe.opened
  abeOk

proc fakeStart(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let fi = fakeImpl(api)
  if fi.isNil or not fi.opened: return abeNotOpen
  fi.running = true
  inc fi.probe.started
  abeOk

proc fakeStop(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let fi = fakeImpl(api)
  if fi.isNil or not fi.opened: return abeNotOpen
  fi.running = false
  inc fi.probe.stopped
  abeOk

proc fakeClose(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let fi = fakeImpl(api)
  if fi.isNil: return
  fi.opened = false
  fi.running = false
  inc fi.probe.closed

proc fakeIsRunning(api: ptr AudioBackendApi): bool
    {.cdecl, raises: [], gcsafe.} =
  let fi = fakeImpl(api)
  if fi.isNil: false else: fi.running

proc fakeDeviceCount(api: ptr AudioBackendApi; wantInput: bool): int32
    {.cdecl, raises: [], gcsafe.} =
  1'i32

proc fakeDeviceInfo(api: ptr AudioBackendApi; index: int32; wantInput: bool;
                    info: var AudioDeviceInfo): bool
    {.cdecl, raises: [], gcsafe.} =
  info.id = index
  true

proc fakeXrunCount(api: ptr AudioBackendApi): uint64
    {.cdecl, raises: [], gcsafe.} =
  0'u64

proc fakeLatencyFrames(api: ptr AudioBackendApi): int32
    {.cdecl, raises: [], gcsafe.} =
  int32(FakeBlockSize)

# ---------------------------------------------------------------------------
# Фабрики, которые хост «регистрирует» в реестре
# ---------------------------------------------------------------------------

proc buildFakeApi(probe: ptr ProbeState): ptr AudioBackendApi =
  let api = cast[ptr AudioBackendApi](allocShared0(sizeof(AudioBackendApi)))
  let fi = cast[ptr FakeImpl](allocShared0(sizeof(FakeImpl)))
  if api.isNil or fi.isNil:
    if not api.isNil: deallocShared(cast[pointer](api))
    if not fi.isNil: deallocShared(cast[pointer](fi))
    return nil
  fi.probe = probe
  api.backendName = cstring"fake"
  api.impl = cast[pointer](fi)
  api.init = fakeInit
  api.shutdown = fakeShutdown
  api.open = fakeOpen
  api.start = fakeStart
  api.stop = fakeStop
  api.close = fakeClose
  api.isRunning = fakeIsRunning
  api.deviceCount = fakeDeviceCount
  api.deviceInfo = fakeDeviceInfo
  api.xrunCount = fakeXrunCount
  api.latencyFrames = fakeLatencyFrames
  api

proc makePair(probe: ptr ProbeState;
              unavailable: bool = false):
    tuple[create: BackendFactory, destroy: BackendDestroyer] =
  ## Пара «создать/уничтожить» для одного фейкового бэкенда. `unavailable`
  ## эмулирует «библиотеки нет»: фабрика честно возвращает nil.
  let drop: BackendDestroyer =
    proc(api: ptr AudioBackendApi) {.closure, raises: [].} =
      if api.isNil: return
      if not probe.isNil:
        inc probe.destroyed
      let fi = fakeImpl(api)
      if not fi.isNil:
        api.impl = nil
        deallocShared(cast[pointer](fi))
      deallocShared(cast[pointer](api))

  let spawn: BackendFactory =
    proc(log: Logger): ptr AudioBackendApi {.closure, raises: [].} =
      if unavailable:
        return nil
      if not probe.isNil:
        inc probe.created
      buildFakeApi(probe)

  (spawn, drop)

proc fakeConfig(outChannels: int32 = int32(FakeOutChannels)): AudioStreamConfig =
  AudioStreamConfig(
    sampleRate: 48000.0, blockSize: int32(FakeBlockSize),
    inputChannels: 0, outputChannels: outChannels,
    inputDevice: DefaultDeviceIndex, outputDevice: DefaultDeviceIndex)

proc pump(api: ptr AudioBackendApi; buf: ptr UncheckedArray[float32];
          frames: int32) =
  ## Вызов render так, как это сделал бы драйвер.
  let fi = fakeImpl(api)
  if fi.isNil or not fi.running or fi.render.isNil or buf.isNil:
    return
  fi.render(fi.engineCtx, nil, buf, frames, 0, fi.outChannels)

proc engineRender(engineCtx: pointer; driverIn: ptr UncheckedArray[float32];
                  driverOut: ptr UncheckedArray[float32]; frames: int32;
                  inputChannels, outputChannels: int32)
    {.cdecl, raises: [].} =
  let engine = cast[ptr AudioEngine](engineCtx)
  if engine.isNil or driverOut.isNil:
    return
  engine.renderBlock(driverOut)


# ---------------------------------------------------------------------------
# Реестр
# ---------------------------------------------------------------------------

suite "backend_registry":
  test "регистрация, порядок, дубли и неизвестные имена":
    var reg = initBackendRegistry()
    check reg.backendCount() == 0
    check reg.backendNameAt(0) == ""
    check not reg.hasBackend("a")

    let (createA, destroyA) = makePair(nil)
    let (createB, destroyB) = makePair(nil)

    check reg.registerBackend("a", createA, destroyA) == reOk
    check reg.registerBackend("b", createB, destroyB) == reOk
    check reg.backendCount() == 2
    check reg.backendNameAt(0) == "a"
    check reg.backendNameAt(1) == "b"
    check reg.backendNames() == @["a", "b"]
    check reg.indexOf("b") == 1
    check reg.indexOf("nope") == -1

    # Повторная регистрация отвергается: иначе выбор бэкенда стал бы
    # недетерминированным.
    check reg.registerBackend("a", createA, destroyA) == reAlreadyRegistered
    check reg.backendCount() == 2

    # Пустое имя и nil-фабрика — тоже отказ.
    check reg.registerBackend("", createA, destroyA) == reUnknownBackend
    check reg.registerBackend("c", nil, destroyA) == reUnknownBackend

  test "createBackend/destroyBackend зовут фабрику и деструктор":
    var reg = initBackendRegistry()
    let probe = newProbe()
    let (createA, destroyA) = makePair(probe)
    check reg.registerBackend("a", createA, destroyA) == reOk

    let (api, err) = reg.createBackend("a")
    check err == reOk
    check not api.isNil
    check probe.created == 1

    check reg.destroyBackend("a", api)
    check probe.destroyed == 1

    # nil-адаптер и неизвестное имя — false, без падения.
    check not reg.destroyBackend("a", nil)
    check not reg.destroyBackend("nope", api)

  test "неизвестное имя и недоступная фабрика различаются":
    var reg = initBackendRegistry()
    let probe = newProbe()
    let (okCreate, okDestroy) = makePair(probe)
    let (badCreate, badDestroy) = makePair(probe, unavailable = true)
    check reg.registerBackend("ok", okCreate, okDestroy) == reOk
    check reg.registerBackend("gone", badCreate, badDestroy) == reOk

    var (api, err) = reg.createBackend("nope")
    check err == reUnknownBackend
    check api.isNil

    (api, err) = reg.createBackend("gone")
    check err == reUnavailable
    check api.isNil

    # Сломанный адаптер не мешает выбрать рабочий.
    (api, err) = reg.createBackend("ok")
    check err == reOk
    check not api.isNil
    check reg.destroyBackend("ok", api)

  test "pickBackend: приоритет → первый доступный":
    var reg = initBackendRegistry()
    let probe = newProbe()
    let (c1, d1) = makePair(probe)
    let (c2, d2) = makePair(probe)
    let (c3, d3) = makePair(probe, unavailable = true)
    check reg.registerBackend("slow", c1, d1) == reOk
    check reg.registerBackend("fast", c2, d2) == reOk
    check reg.registerBackend("gone", c3, d3) == reOk

    # Приоритет уважается: "fast" выбран, хотя "slow" зарегистрирован раньше.
    block:
      let (name, api, err) = reg.pickBackend(["fast", "slow"])
      check err == reOk
      check name == "fast"
      check not api.isNil
      check reg.destroyBackend(name, api)

    # Недоступное имя в приоритете пропускается.
    block:
      let (name, api, err) = reg.pickBackend(["gone", "slow"])
      check err == reOk
      check name == "slow"
      check reg.destroyBackend(name, api)

    # Приоритета нет — берём первый, который вообще создался.
    block:
      let (name, api, err) = reg.pickBackend([])
      check err == reOk
      check name == "slow"
      check reg.destroyBackend(name, api)

    # Ни одного доступного адаптера.
    block:
      var onlyBad = initBackendRegistry()
      let (bc, bd) = makePair(probe, unavailable = true)
      check onlyBad.registerBackend("gone", bc, bd) == reOk
      let (name, api, err) = onlyBad.pickBackend(["gone"])
      check err == reUnavailable
      check name == ""
      check api.isNil

    block:
      var empty = initBackendRegistry()
      let (name, api, err) = empty.pickBackend([])
      check err == reUnknownBackend
      check name == ""
      check api.isNil


# ---------------------------------------------------------------------------
# Менеджер: владелец текущего адаптера и hot-swap
# ---------------------------------------------------------------------------

proc newManagerWithTwoFakes(probe: ptr ProbeState;
                            refuseSecond: bool = false):
    tuple[m: BackendManager, ok: bool] =
  var mgr = initBackendManager()
  let (c1, d1) = makePair(probe)
  let (c2, d2) = makePair(probe)
  var ok = mgr.registerBackend("a", c1, d1) == reOk
  ok = ok and mgr.registerBackend("b", c2, d2) == reOk
  if refuseSecond:
    # Второй адаптер «не открывается» — проверка отката и пропуска.
    discard
  (mgr, ok)

suite "backend_manager":
  test "open -> close -> open: ресурсы сходятся":
    let probe = newProbe()
    var (mgr, ok) = newManagerWithTwoFakes(probe)
    check ok
    check mgr.backendNames() == @["a", "b"]
    check not mgr.isOpen()
    check mgr.currentName() == ""
    check mgr.currentApi() == nil

    let cfg = fakeConfig()
    check mgr.openBackend("a", cfg, engineRender, nil) == bmOk
    check mgr.isOpen()
    check mgr.isRunning()
    check mgr.currentName() == "a"
    check probe.created == 1
    check probe.inited == 1
    check probe.opened == 1
    check probe.started == 1

    # Повторное открытие без закрытия отвергается.
    check mgr.openBackend("b", cfg, engineRender, nil) == bmAlreadyOpen

    mgr.closeBackend()
    check not mgr.isOpen()
    check not mgr.isRunning()
    check mgr.currentName() == ""
    check probe.stopped == 1
    check probe.closed == 1
    check probe.destroyed == 1

    # Идемпотентно.
    mgr.closeBackend()
    check probe.destroyed == 1

    # И открывается снова.
    check mgr.openBackend("b", cfg, engineRender, nil) == bmOk
    check mgr.currentName() == "b"
    check probe.created == 2
    mgr.closeBackend()
    check probe.created == probe.destroyed

  test "hot-swap a -> b -> a: ничего не течёт":
    let probe = newProbe()
    var (mgr, ok) = newManagerWithTwoFakes(probe)
    check ok

    let cfg = fakeConfig()
    check mgr.openBackend("a", cfg, engineRender, nil) == bmOk
    check probe.created == 1

    # Переключение на уже открытый бэкенд — no-op, поток не перезапускаем.
    check mgr.switchBackend("a", cfg, engineRender, nil) == bmOk
    check probe.created == 1
    check probe.started == 1

    check mgr.switchBackend("b", cfg, engineRender, nil) == bmOk
    check mgr.currentName() == "b"
    check probe.created == 2
    check probe.destroyed == 1
    check probe.stopped == 1

    check mgr.switchBackend("a", cfg, engineRender, nil) == bmOk
    check mgr.currentName() == "a"
    check probe.created == 3
    check probe.destroyed == 2
    check probe.stopped == 2

    mgr.closeBackend()
    # Каждый созданный адаптер освобождён ровно один раз.
    check probe.created == 3
    check probe.destroyed == 3
    check probe.opened == probe.closed

  test "неизвестное имя и отказ open не оставляют открытым":
    let probe = newProbe()
    var (mgr, ok) = newManagerWithTwoFakes(probe)
    check ok

    let cfg = fakeConfig()
    check mgr.openBackend("nope", cfg, engineRender, nil) == bmUnknownBackend
    check not mgr.isOpen()
    check probe.created == 0

    # Адаптер, который не открывается: откат без «висящего» адаптера.
    let probe2 = newProbe(refuseOpen = true)
    var mgr2 = initBackendManager()
    let (c, d) = makePair(probe2)
    check mgr2.registerBackend("refusing", c, d) == reOk
    check mgr2.openBackend("refusing", cfg, engineRender, nil) == bmOpenFailed
    check not mgr2.isOpen()
    check mgr2.currentName() == ""
    # Фабрика создала, менеджер обязан уничтожить.
    check probe2.created == 1
    check probe2.destroyed == 1

  test "openPreferred пропускает сломанный адаптер":
    let probe = newProbe()
    let probeBad = newProbe(refuseOpen = true)
    var mgr = initBackendManager()
    let (cBad, dBad) = makePair(probeBad)
    let (cGood, dGood) = makePair(probe)
    check mgr.registerBackend("bad", cBad, dBad) == reOk
    check mgr.registerBackend("good", cGood, dGood) == reOk

    # "bad" идёт первым в приоритете, но не открывается -> берём "good".
    check mgr.openPreferred(fakeConfig(), engineRender, nil, ["bad", "good"]) == bmOk
    check mgr.currentName() == "good"
    check probeBad.created == 1
    check probeBad.destroyed == 1
    check probe.created == 1
    mgr.closeBackend()
    check probe.created == probe.destroyed

    # Если доступных нет вовсе — bmUnavailable, а не падение.
    var onlyBad = initBackendManager()
    let (cB, dB) = makePair(probeBad)
    check onlyBad.registerBackend("bad", cB, dB) == reOk
    check onlyBad.openPreferred(fakeConfig(), engineRender, nil, ["bad"]) == bmUnavailable
    check not onlyBad.isOpen()

  test "hot-swap на живом AudioEngine: рендер продолжается":
    let engine = createAudioEngine(
      sampleRate = 48000.0f,
      blockSize = int32(FakeBlockSize)
    )
    check engine != nil

    let probe = newProbe()
    var (mgr, ok) = newManagerWithTwoFakes(probe)
    check ok

    let cfg = fakeConfig()
    check mgr.openBackend("a", cfg, engineRender, cast[pointer](engine)) == bmOk
    check engine.postPlay()

    var buf: array[FakeBlockSize * FakeOutChannels, float32]
    let p = cast[ptr UncheckedArray[float32]](addr buf[0])

    pump(mgr.currentApi(), p, int32(FakeBlockSize))
    check engine.currentFrame() == int64(FakeBlockSize)
    for i in 0 ..< buf.len:
      check buf[i] == 0.0f   # графа нет: движок обязан очистить выход

    # Hot-swap на control-path: движок остаётся жив и продолжает считать.
    check mgr.switchBackend("b", cfg, engineRender, cast[pointer](engine)) == bmOk
    check mgr.currentName() == "b"
    pump(mgr.currentApi(), p, int32(FakeBlockSize))
    check engine.currentFrame() == int64(FakeBlockSize * 2)

    mgr.closeBackend()
    check probe.created == probe.destroyed
    destroyAudioEngine(engine)

