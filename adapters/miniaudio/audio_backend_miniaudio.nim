# adapters/miniaudio/audio_backend_miniaudio.nim
#
# Адаптер miniaudio для audio_backend_api (issue #31).
#
#   Core -> audio_backend_api -> adapters/miniaudio -> miniaudio.h
#
# miniaudio — single-header C (public domain / MIT-0): WASAPI, DirectSound,
# WinMM, CoreAudio, ALSA, PulseAudio, JACK, sndio — одним заголовком и
# без внешней .so. Он НЕ заменяет Core: адаптер реализует ровно ту же
# таблицу методов AudioBackendApi, что и PortAudio (#2).
#
# Layout miniaudio-структур спрятан в C-шиме (miniaudio_impl.c), поэтому
# версия miniaudio не протекает в Nim. Сборка: TU шима подключается
# директивой {.compile.}; path к заголовку — в config.nims.
#
# Отличия от PortAudio-адаптера и почему:
#   * нет dynlib: miniaudio линкуется в бинарник, поэтому «библиотека
#     не найдена» невозможно — ошибки только про контекст/устройство;
#   * у miniaudio 0.11.25 нет публичного статуса драйвера
#     (underflow/overflow) и счётчика xrun — backend восстанавливается
#     сам. xrunCount считается шимом как (а) вызов render, не уложившийся
#     в длительность блока, и (б) notification interruption_began;
#   * входной тракт (driverIn) заполняется драйвером — контракт #3.
#
# MANIFEST §7, §8, §41, §42.

import audio_backend_api
import logger

{.push raises: [].}

# Единый TU miniaudio. Директива компилируется только при сборке
# бинарника, который импортирует адаптер; `nim check` её не выполняет.
{.compile: "miniaudio_impl.c".}

when defined(windows):
  {.passL: "-lole32 -lwinmm".}
elif defined(macosx):
  {.passL: "-framework CoreFoundation -framework CoreAudio -framework AudioToolbox".}
else:
  # ALSA/PulseAudio miniaudio грузит через dlopen; libdl нужен на старых glibc.
  {.passL: "-lm -lpthread -ldl".}

# ==============================================================================
# C-ABI шима (см. adapters/miniaudio/miniaudio_shim.h)
# ==============================================================================

type
  MaCtx = pointer   ## непрозрачный eut_ma_ctx
  MaDev = pointer   ## непрозрачный eut_ma_dev

  EutMaRenderProc = proc(
    engineCtx: pointer;
    driverIn: ptr UncheckedArray[float32];
    driverOut: ptr UncheckedArray[float32];
    frames: cint;
    inputChannels: cint;
    outputChannels: cint
  ) {.cdecl, raises: [].}

const
  MaNameCap = 256
  ## Размер блока по умолчанию, если вызывающий не задал (blockSize <= 0).
  DefaultMiniaudioBlockSize* = 256'i32

proc eut_ma_context_create(): MaCtx
  {.importc, cdecl, raises: [], gcsafe.}
proc eut_ma_context_destroy(c: MaCtx)
  {.importc, cdecl, raises: [], gcsafe.}

proc eut_ma_device_count(c: MaCtx; wantInput: cint): cint
  {.importc, cdecl, raises: [], gcsafe.}

proc eut_ma_device_info(
  c: MaCtx;
  index: cint;
  wantInput: cint;
  nameOut: cstring;
  nameCap: cint;
  isDefault: ptr cint;
  maxInputChannels: ptr cint;
  maxOutputChannels: ptr cint;
  defaultSampleRate: ptr cdouble;
  defaultLowInputLatency: ptr cdouble;
  defaultLowOutputLatency: ptr cdouble
): cint {.importc, cdecl, raises: [], gcsafe.}

proc eut_ma_device_open(
  c: MaCtx;
  sampleRate: cdouble;
  blockSize: cint;
  inputChannels: cint;
  outputChannels: cint;
  inputDevice: cint;
  outputDevice: cint;
  render: EutMaRenderProc;
  engineCtx: pointer
): MaDev {.importc, cdecl, raises: [], gcsafe.}

proc eut_ma_device_start(d: MaDev): cint
  {.importc, cdecl, raises: [], gcsafe.}
proc eut_ma_device_stop(d: MaDev)
  {.importc, cdecl, raises: [], gcsafe.}
proc eut_ma_device_close(d: MaDev)
  {.importc, cdecl, raises: [], gcsafe.}
proc eut_ma_device_is_started(d: MaDev): cint
  {.importc, cdecl, raises: [], gcsafe.}

proc eut_ma_device_xruns(d: MaDev): culonglong
  {.importc, cdecl, raises: [], gcsafe.}
proc eut_ma_device_last_flag(d: MaDev): cint
  {.importc, cdecl, raises: [], gcsafe.}
proc eut_ma_device_latency_frames(d: MaDev): cint
  {.importc, cdecl, raises: [], gcsafe.}

# ==============================================================================
# Состояние адаптера
# ==============================================================================

type
  MiniaudioBackend = object
    ## Аллоцируется в shared-куче: указатель уходит в audio callback.
    ## Не содержит GC-полей.
    ctx: MaCtx
    dev: MaDev

    render: AudioRenderProc
    engineCtx: pointer
    ## Приёмник xrun'ов для движка (issue #4). Задаётся хостом в конфиге.
    reportStatus: AudioStatusProc
    log: Logger

    requestedInputChannels: int32
    requestedOutputChannels: int32
    requestedLatencyFrames: int32
    requestedSampleRate: float64

    opened: bool
    running: bool

proc implOf(api: ptr AudioBackendApi): ptr MiniaudioBackend {.inline.} =
  if api.isNil:
    return nil
  cast[ptr MiniaudioBackend](api.impl)

# ==============================================================================
# Трамплин в AudioRenderProc
# ==============================================================================

proc maTrampoline(
  engineCtx: pointer;
  driverIn: ptr UncheckedArray[float32];
  driverOut: ptr UncheckedArray[float32];
  frames: cint;
  inputChannels: cint;
  outputChannels: cint
) {.cdecl, raises: [], gcsafe.} =
  ## Выполняется в аудио-потоке miniaudio.
  ##
  ## Запрещено: аллокации, локи, файловый I/O, логирование.
  ## Разрешено: вызов render и запись в атомарный счётчик.
  let mb = cast[ptr MiniaudioBackend](engineCtx)
  if mb.isNil:
    return

  let r = mb.render
  if r.isNil:
    # Поток открыт, но рендер не привязан: отдаём тишину.
    if driverOut != nil and outputChannels > 0:
      let total = int(frames) * int(outputChannels)
      var i = 0
      while i < total:
        driverOut[i] = 0.0f
        inc i
    return

  let xrunsBefore = if mb.dev.isNil: 0'u64 else:
    uint64(eut_ma_device_xruns(mb.dev))

  r(
    mb.engineCtx,
    driverIn,
    driverOut,
    frames.int32,
    inputChannels.int32,
    outputChannels.int32
  )

  # Отчёт о xrun'ах движку (issue #4). C-шим инкрементирует счётчик либо
  # синхронно после возврата из render (блок не уложился в свой бюджет),
  # либо из notification-callback (interruption_began) — во втором случае
  # дельту «подберёт» следующий блок. Всё на атомиках: логирования нет.
  if not mb.reportStatus.isNil and not mb.dev.isNil:
    let xrunsAfter = uint64(eut_ma_device_xruns(mb.dev))
    if xrunsAfter > xrunsBefore:
      let lastFlag = int(eut_ma_device_last_flag(mb.dev))
      # Шим отдаёт ОРДИНАЛ AudioStreamFlag (0..3), а контракт приёмника —
      # битмаск, поэтому переводим в бит.
      let flags =
        if lastFlag >= 0 and lastFlag < 32: 1'u32 shl lastFlag
        else: statusFlagMask(asfOutputUnderflow)
      var pending = xrunsAfter - xrunsBefore
      while pending > 0:
        mb.reportStatus(mb.engineCtx, flags)
        dec pending

# ==============================================================================
# Таблица методов (control-path)
# ==============================================================================

proc maInit(api: ptr AudioBackendApi; log: ptr Logger): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil:
    return abeUnavailable

  if not log.isNil:
    mb.log = log[]

  if not mb.ctx.isNil:
    return abeOk

  mb.ctx = eut_ma_context_create()
  if mb.ctx.isNil:
    logError(addr mb.log, "miniaudio: context init failed")
    return abeInitFailed

  logInfo(addr mb.log, "miniaudio: initialized")
  abeOk

proc maShutdown(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil:
    return

  if not mb.dev.isNil:
    if mb.running:
      eut_ma_device_stop(mb.dev)
      mb.running = false
    eut_ma_device_close(mb.dev)
    mb.dev = nil
  mb.opened = false

  if not mb.ctx.isNil:
    eut_ma_context_destroy(mb.ctx)
    mb.ctx = nil

proc maOpen(
  api: ptr AudioBackendApi;
  cfg: AudioStreamConfig;
  render: AudioRenderProc;
  engineCtx: pointer
): AudioBackendError {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil or mb.ctx.isNil:
    return abeNotOpen

  if render.isNil or cfg.outputChannels <= 0:
    return abeOpenFailed

  # Повторный open без close запрещён: молчаливая перезапись устройства
  # оставляет висеть старый callback.
  if mb.opened:
    return abeOpenFailed

  # Нет устройств — это abeNoDevice, а не «не удалось открыть».
  if eut_ma_device_count(mb.ctx, cint(0)) <= 0:
    logError(addr mb.log, "miniaudio: no output device")
    return abeNoDevice

  mb.render = render
  mb.engineCtx = engineCtx
  mb.reportStatus = cfg.reportStatus
  mb.requestedSampleRate = cfg.sampleRate
  mb.requestedInputChannels = cfg.inputChannels
  mb.requestedOutputChannels = cfg.outputChannels
  mb.requestedLatencyFrames =
    if cfg.blockSize > 0: cfg.blockSize else: DefaultMiniaudioBlockSize

  mb.dev = eut_ma_device_open(
    mb.ctx,
    cdouble(cfg.sampleRate),
    cint(mb.requestedLatencyFrames),
    cint(cfg.inputChannels),
    cint(cfg.outputChannels),
    cint(cfg.inputDevice),
    cint(cfg.outputDevice),
    maTrampoline,
    cast[pointer](mb)
  )

  if mb.dev.isNil:
    logError(addr mb.log, "miniaudio: ma_device_init failed")
    return abeOpenFailed

  mb.opened = true
  abeOk

proc maStart(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil or not mb.opened or mb.dev.isNil:
    return abeNotOpen

  if mb.running:
    return abeOk

  if eut_ma_device_start(mb.dev) != 0:
    logError(addr mb.log, "miniaudio: ma_device_start failed")
    return abeStartFailed

  mb.running = true
  abeOk

proc maStop(api: ptr AudioBackendApi): AudioBackendError
    {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  # Как и PortAudio-адаптер: stop на неоткрытом устройстве — abeNotOpen,
  # а не «тихий успех». Контракт одинаков у всех адаптеров.
  if mb.isNil or not mb.opened or mb.dev.isNil:
    return abeNotOpen

  eut_ma_device_stop(mb.dev)
  mb.running = false
  abeOk

proc maClose(api: ptr AudioBackendApi) {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil or not mb.opened:
    return

  if mb.running:
    eut_ma_device_stop(mb.dev)
    mb.running = false
  if not mb.dev.isNil:
    eut_ma_device_close(mb.dev)
    mb.dev = nil
  mb.opened = false
  mb.reportStatus = nil

proc maIsRunning(api: ptr AudioBackendApi): bool
    {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil:
    return false
  mb.running

proc maDeviceCount(api: ptr AudioBackendApi; wantInput: bool): int32
    {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil or mb.ctx.isNil:
    return 0
  int32(eut_ma_device_count(mb.ctx, cint(if wantInput: 1 else: 0)))

proc maDeviceInfo(
  api: ptr AudioBackendApi;
  index: int32;
  wantInput: bool;
  info: var AudioDeviceInfo
): bool {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil or mb.ctx.isNil or index < 0:
    return false

  var nameBuf: array[MaNameCap, char]
  var isDefault: cint = 0
  var maxIn: cint = 0
  var maxOut: cint = 0
  var sr: cdouble = 0.0
  var latIn: cdouble = 0.0
  var latOut: cdouble = 0.0

  let ok = eut_ma_device_info(
    mb.ctx,
    cint(index),
    cint(if wantInput: 1 else: 0),
    cast[cstring](addr nameBuf[0]),
    cint(MaNameCap),
    addr isDefault, addr maxIn, addr maxOut,
    addr sr, addr latIn, addr latOut
  )
  if ok == 0:
    return false

  info.id = index
  info.name = $cast[cstring](addr nameBuf[0])
  info.maxInputChannels = int32(maxIn)
  info.maxOutputChannels = int32(maxOut)
  info.defaultSampleRate = sr
  info.defaultLowInputLatency = latIn
  info.defaultLowOutputLatency = latOut
  info.isDefault = isDefault != 0
  true

proc maXrunCount(api: ptr AudioBackendApi): uint64
    {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil or mb.dev.isNil:
    return 0'u64
  uint64(eut_ma_device_xruns(mb.dev))

proc maLatencyFrames(api: ptr AudioBackendApi): int32
    {.cdecl, raises: [], gcsafe.} =
  let mb = implOf(api)
  if mb.isNil or mb.dev.isNil:
    return 0
  int32(eut_ma_device_latency_frames(mb.dev))

# ==============================================================================
# Создание / уничтожение (control-path)
# ==============================================================================

proc createMiniaudioBackend*(log: Logger = silentLogger()): ptr AudioBackendApi =
  ## Собирает адаптер в shared-куче.
  ##
  ## Возвращает nil, только если недоступна память: miniaudio линкуется в
  ## бинарник, поэтому «внешней библиотеки нет» как класса ошибки здесь не
  ## существует. Отсутствие backend'а/устройства проявляется как
  ## abeInitFailed / abeNoDevice из init/open.
  let api = cast[ptr AudioBackendApi](allocShared0(sizeof(AudioBackendApi)))
  if api.isNil:
    return nil

  let mb = cast[ptr MiniaudioBackend](allocShared0(sizeof(MiniaudioBackend)))
  if mb.isNil:
    deallocShared(cast[pointer](api))
    return nil

  mb.log = log

  api.backendName = cstring"miniaudio"
  api.impl = cast[pointer](mb)

  api.init = maInit
  api.shutdown = maShutdown
  api.open = maOpen
  api.start = maStart
  api.stop = maStop
  api.close = maClose
  api.isRunning = maIsRunning
  api.deviceCount = maDeviceCount
  api.deviceInfo = maDeviceInfo
  api.xrunCount = maXrunCount
  api.latencyFrames = maLatencyFrames

  api

proc destroyMiniaudioBackend*(api: ptr AudioBackendApi) =
  if api.isNil:
    return

  backendShutdown(api)

  let mb = implOf(api)
  if not mb.isNil:
    api.impl = nil
    deallocShared(cast[pointer](mb))

  deallocShared(cast[pointer](api))

{.pop.}
