# audio_backend_api.nim
#
# Контракт аудио-бэкенда для Core (MANIFEST §8, §40, §41, §42).
#
#   Core -> audio_backend_api -> adapters/<backend>
#
# Core знает ТОЛЬКО этот модуль. Внешняя библиотека (аудио-бэкенд любого
# вида) в Core не проникает: она живёт в отдельном каталоге adapters/ и
# подключается через таблицу методов. Перечень заменяемых бэкендов — в
# MANIFEST §8. Заменить библиотеку можно, не трогая AudioEngine.
#
# Модель владения:
# - `AudioBackendApi` и его `impl` живут в shared-куче: на указатель
#   ссылается audio callback, поэтому время жизни не привязано к стеку;
# - поле `impl` целиком принадлежит адаптеру, Core его не читает;
# - `render` вызывается ТОЛЬКО из аудио-потока и обязан быть
#   allocation-free, lock-free и exception-free;
# - все остальные методы таблицы — control-path.

import logger

# `Logger` входит в публичную сигнатуру таблицы методов (init/…),
# поэтому контракт реэкспортирует его: импортирующий модуль не обязан
# отдельно тянуть core/logger.
export logger

{.push raises: [].}

const
  DefaultDeviceIndex* = -1'i32
    ## «Выбрать устройство по умолчанию».

type
  AudioBackendError* = enum
    abeOk = 0,
    abeUnavailable,   ## адаптер не смог загрузить внешнюю библиотеку
    abeInitFailed,
    abeNoDevice,
    abeOpenFailed,
    abeStartFailed,
    abeNotOpen        ## метод вызван без успешного open()

  AudioStreamFlag* = enum
    ## Статус, который драйвер отдаёт в audio callback.
    asfInputUnderflow,
    asfInputOverflow,
    asfOutputUnderflow,
    asfOutputOverflow

  AudioDeviceInfo* = object
    ## Описание устройства.
    ##
    ## Заполняется на control-path (перечисление устройств), поэтому имя —
    ## обычная строка, а не фиксированный буфер.
    id*: int32
    name*: string
    maxInputChannels*: int32
    maxOutputChannels*: int32
    defaultSampleRate*: float64
    defaultLowInputLatency*: float64
    defaultLowOutputLatency*: float64
    isDefault*: bool

  AudioStatusProc* = proc(engineCtx: pointer; statusFlags: uint32)
    {.cdecl, raises: [].}
    ## Realtime-safe приёмник статуса драйвера (issue #4).
    ##
    ## Вызывается адаптером из audio callback при обнаружении xrun'а.
    ## `statusFlags` — БИТМАСК, в котором бит N соответствует ординалу
    ## `AudioStreamFlag` N (см. `statusFlagMask`). Конвенция выбрана так,
    ## чтобы нативные флаги драйверов (обычно 0x1, 0x2, 0x4, 0x8) совпадали
    ## с ней один в один, а C-шим отдавал ординал 0..3.
    ##
    ## Обязан быть без аллокаций, локов и логирования: обычно это
    ## `engine.noteStatus`.

  AudioStreamConfig* = object
    ## Параметры открываемого потока.
    sampleRate*: float64
    blockSize*: int32
    inputChannels*: int32
    outputChannels*: int32
    inputDevice*: int32          ## DefaultDeviceIndex == по умолчанию
    outputDevice*: int32
    suggestedInputLatency*: float64   ## 0.0 == выбрать адаптивно
    suggestedOutputLatency*: float64
    ## Куда адаптер сообщает xrun'ы. `nil` — статус не сообщается
    ## (движок тогда остаётся с нулевым счётчиком, как раньше).
    reportStatus*: AudioStatusProc

  AudioRenderProc* = proc(
    engineCtx: pointer;
    driverIn: ptr UncheckedArray[float32];    ## interleaved, может быть nil
    driverOut: ptr UncheckedArray[float32];   ## interleaved
    frames: int32;
    inputChannels: int32;
    outputChannels: int32
  ) {.cdecl, raises: [].}
    ## Контракт рендера блока.
    ##
    ## Сознательно БЕЗ `gcsafe`: ядро пока не доказывает GC-чистоту
    ## realtime-пути (индиректные вызовы ProcessProc / PipelineRenderProc
    ## не помечены gcsafe). Включить прагму можно будет после аудита —
    ## см. issue про gcsafe-аудит audio-пути.
    ##
    ## `driverIn` уже присутствует в контракте, хотя входной тракт ещё не
    ## реализован (issue #3): адаптеру не придётся менять ABI, когда вход
    ## появится.

  AudioBackendApi* = object
    ## Таблица методов адаптера.
    ##
    ## Поля-процедуры опциональны: Core обязан проверять их на nil через
    ## обёртки `backend*` ниже, а не звать напрямую.
    backendName*: cstring
    impl*: pointer

    init*: proc(api: ptr AudioBackendApi; log: ptr Logger): AudioBackendError
      {.cdecl, raises: [], gcsafe.}

    shutdown*: proc(api: ptr AudioBackendApi)
      {.cdecl, raises: [], gcsafe.}

    open*: proc(
      api: ptr AudioBackendApi;
      cfg: AudioStreamConfig;
      render: AudioRenderProc;
      engineCtx: pointer
    ): AudioBackendError {.cdecl, raises: [], gcsafe.}

    start*: proc(api: ptr AudioBackendApi): AudioBackendError
      {.cdecl, raises: [], gcsafe.}

    stop*: proc(api: ptr AudioBackendApi): AudioBackendError
      {.cdecl, raises: [], gcsafe.}

    close*: proc(api: ptr AudioBackendApi)
      {.cdecl, raises: [], gcsafe.}

    isRunning*: proc(api: ptr AudioBackendApi): bool
      {.cdecl, raises: [], gcsafe.}

    deviceCount*: proc(api: ptr AudioBackendApi; wantInput: bool): int32
      {.cdecl, raises: [], gcsafe.}

    deviceInfo*: proc(
      api: ptr AudioBackendApi;
      index: int32;
      wantInput: bool;
      info: var AudioDeviceInfo
    ): bool {.cdecl, raises: [], gcsafe.}

    ## Диагностика. Растёт в audio callback, читается на control-path.
    xrunCount*: proc(api: ptr AudioBackendApi): uint64
      {.cdecl, raises: [], gcsafe.}

    latencyFrames*: proc(api: ptr AudioBackendApi): int32
      {.cdecl, raises: [], gcsafe.}

proc statusFlagMask*(flag: AudioStreamFlag): uint32 {.inline.} =
  ## Бит статуса драйвера для данного вида xrun'а. Один бит — один ординал
  ## `AudioStreamFlag` (issue #4).
  1'u32 shl ord(flag)

# ==============================================================================
# Nil-safe обёртки (control-path)
# ==============================================================================
#
# Core вызывает только их. Это гарантирует, что неполная или отсутствующая
# реализация даёт код ошибки, а не падение в audio-потоке.

proc backendInit*(api: ptr AudioBackendApi; log: ptr Logger): AudioBackendError =
  if api.isNil or api.init.isNil:
    return abeUnavailable
  api.init(api, log)

proc backendShutdown*(api: ptr AudioBackendApi) =
  if api.isNil or api.shutdown.isNil:
    return
  api.shutdown(api)

proc backendOpen*(
  api: ptr AudioBackendApi;
  cfg: AudioStreamConfig;
  render: AudioRenderProc;
  engineCtx: pointer
): AudioBackendError =
  if api.isNil or api.open.isNil:
    return abeUnavailable
  api.open(api, cfg, render, engineCtx)

proc backendStart*(api: ptr AudioBackendApi): AudioBackendError =
  if api.isNil or api.start.isNil:
    return abeUnavailable
  api.start(api)

proc backendStop*(api: ptr AudioBackendApi): AudioBackendError =
  if api.isNil or api.stop.isNil:
    return abeOk
  api.stop(api)

proc backendClose*(api: ptr AudioBackendApi) =
  if api.isNil or api.close.isNil:
    return
  api.close(api)

proc backendIsRunning*(api: ptr AudioBackendApi): bool =
  if api.isNil or api.isRunning.isNil:
    return false
  api.isRunning(api)

proc backendDeviceCount*(api: ptr AudioBackendApi; wantInput: bool): int32 =
  if api.isNil or api.deviceCount.isNil:
    return 0
  api.deviceCount(api, wantInput)

proc backendDeviceInfo*(
  api: ptr AudioBackendApi;
  index: int32;
  wantInput: bool;
  info: var AudioDeviceInfo
): bool =
  if api.isNil or api.deviceInfo.isNil:
    return false
  api.deviceInfo(api, index, wantInput, info)

proc backendXrunCount*(api: ptr AudioBackendApi): uint64 =
  if api.isNil or api.xrunCount.isNil:
    return 0'u64
  api.xrunCount(api)

proc backendLatencyFrames*(api: ptr AudioBackendApi): int32 =
  if api.isNil or api.latencyFrames.isNil:
    return 0
  api.latencyFrames(api)

proc backendNameOf*(api: ptr AudioBackendApi): string =
  ## Имя бэкенда для логов и диагностики. Control-path.
  if api.isNil or api.backendName.isNil:
    return "none"
  $api.backendName

{.pop.}

