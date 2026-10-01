# plugin_api.nim
#
# Контракт хостинга плагинов для Core (issue #29).
#
#   Core -> plugin_api -> adapters/<format>
#
# До этого модуля хостинг был размазан по слою `nodes/`: `clap_host.nim`,
# `plugin_host.nim`, `eut_plugin.nim` тянули свои типы и сами конвертировали
# `EventQueue` в формат плагина. Граф (`dsp_scheduler`, `compiled_pipeline`)
# косвенно зависел от выбранного формата, а LV2/VST3 были невозможны.
#
# Теперь по образцу `core/audio_backend_api.nim` (#2) и `core/midi_api.nim`
# (#28):
#
#   * Core знает ТОЛЬКО этот модуль;
#   * конкретный формат (CLAP, EUT, LV2, VST3) живёт в `adapters/` и
#     подключается через таблицу методов;
#   * конвертация `EventQueue` <-> формат плагина — обязанность адаптера,
#     а не Core;
#   * добавление второго формата не требует правок `dsp_scheduler` и
#     `compiled_pipeline`.
#
# Модель владения:
# - `PluginApi` и его `impl` живут в shared-куче: время жизни не привязано
#   к стеку, потому что на него ссылается audio callback через таблицу;
# - поле `impl` целиком принадлежит адаптеру, Core его не читает;
# - `PluginHandle` — непрозрачный указатель на инстанс плагина, владелец
#   которого адаптер; Core передаёт его обратно в методы таблицы «как есть»;
# - `process` вызывается ТОЛЬКО из аудио-потока и обязан быть
#   allocation-free, lock-free и exception-free;
# - `activate`/`deactivate`/`reset`/`param*`/`state*`/`instantiate`/
#   `destroy` — control-path.
#
# MANIFEST §8, §40, §41, §42, §56/§57, §102.

import logger
import node_interface, signal_types

# `Logger` входит в публичную сигнатуру таблицы методов (init),
# поэтому контракт реэкспортирует его.
export logger
# Контракт адресует графу типы портов/событий Core напрямую: process()
# принимает `NodeProcessContext`/`NodeAudioPorts`/`EventQueue`, поэтому
# scheduler подставляет плагин как обычный `PipelineStep` без обёрток.
export node_interface
export signal_types

{.push raises: [].}

type
  PluginError* = enum
    peOk = 0,
    peUnavailable,      ## адаптер не смог загрузить внешнюю библиотеку формата
    peLoadFailed,       ## библиотека есть, но это не валидный модуль плагина
    peNoSuchPlugin,     ## индекс/путь вне диапазона
    peInstantiateFailed,
    peNotActive,        ## метод вызван без успешного activate()
    peBadParam,
    peStateFailed

  PluginCategory* = enum
    ## Нейтральная категория плагина. Конкретный формат маппит свои флаги
    ## в это перечисление внутри адаптера.
    pcUnknown = 0,
    pcEffect,
    pcInstrument,
    pcNoteEffect,
    pcAnalyzer

  PluginParamFlag* = enum
    ppfAutomatable     ## можно вести автоматизацией
    ppfModulatable     ## принимает модуляцию (LFO, MIDI CC)
    ppfInteger         ## целочисленный (шаг >= 1)
    ppfChoice          ## дискретный набор значений
    ppfHidden          ## не показывать в UI

  PluginProcessStatus* = enum
    ## Результат обработки блока. Конкретный формат маппит свои статусы
    ## (clap_process_status, EUT_PROCESS_*) в это перечисление.
    ppsError = 0,
    ppsContinue,        ## продолжать обработку
    ppsTail,            ## плагин отдаёт хвост (реверберация/дилей)
    ppsSleep            ## плагин замолчал и не требует вызовов до события

  PluginInfo* = object
    ## Описание плагина в библиотеке. Заполняется на control-path
    ## (перечисление/скан), поэтому имена — обычные строки.
    id*: string
    name*: string
    vendor*: string
    version*: string
    category*: PluginCategory

    audioInCount*: int32
    audioOutCount*: int32
    noteInCount*: int32
    noteOutCount*: int32
    paramCount*: int32

    hasState*: bool
    hasGui*: bool
    ## Заявленная задержка в кадрах до активации (0, если формат не умеет
    ## сообщать её раньше activate()).
    reportedLatency*: int32

  PluginParamInfo* = object
    id*: uint32
    name*: string
    flags*: set[PluginParamFlag]
    minValue*: float64
    maxValue*: float64
    defaultValue*: float64
    ## Для ppfChoice — шаг перебора значений, иначе минимальный шаг
    ## пользователя при автоматизации.
    step*: float64

  PluginHandle* = pointer
    ## Непрозрачный дескриптор инстанса плагина. Нулевое значение — «нет
    ## инстанса». Владелец — адаптер.

  PluginProcessProc* = proc(
    api: ptr PluginApi;
    handle: PluginHandle;
    ctx: ptr NodeProcessContext;
    audio: ptr NodeAudioPorts;
    inEvents: ptr EventQueue;
    outEvents: ptr EventQueue
  ): PluginProcessStatus {.cdecl, raises: [], gcsafe.}
    ## Realtime-контракт обработки блока.
    ##
    ## `ctx` — транспорт и позиция; `audio` — аудио-порты ноды (planar
    ## буферы Core); `inEvents`/`outEvents` — очереди событий Core.
    ## Адаптер обязан перевести их в свой формат и обратно без аллокаций,
    ## локов и исключений.

  PluginApi* = object
    ## Таблица методов адаптера формата.
    ##
    ## Поля-процедуры опциональны: Core обязан проверять их на nil через
    ## nil-safe обёртки `plugin*` ниже, а не звать напрямую.
    backendName*: cstring
    impl*: pointer

    init*: proc(api: ptr PluginApi; log: ptr Logger): PluginError
      {.cdecl, raises: [], gcsafe.}

    shutdown*: proc(api: ptr PluginApi)
      {.cdecl, raises: [], gcsafe.}

    # -- Реестр/фабрика (control-path) --
    # Число плагинов в библиотеке по пути; < 0 — ошибка.
    pluginCount*: proc(api: ptr PluginApi; path: cstring): int32
      {.cdecl, raises: [], gcsafe.}

    pluginInfo*: proc(
      api: ptr PluginApi;
      path: cstring;
      index: int32;
      info: var PluginInfo
    ): bool {.cdecl, raises: [], gcsafe.}

    # Загружает библиотеку (если нужно), создаёт инстанс и вызывает
    # native init(). Возвращает nil при ошибке.
    instantiate*: proc(
      api: ptr PluginApi;
      path: cstring;
      index: int32
    ): PluginHandle {.cdecl, raises: [], gcsafe.}

    destroy*: proc(api: ptr PluginApi; handle: PluginHandle)
      {.cdecl, raises: [], gcsafe.}

    # -- Жизненный цикл (control-path) --
    activate*: proc(
      api: ptr PluginApi;
      handle: PluginHandle;
      sampleRate: float64;
      maxBlock: int32;
      audioIn: int32;
      audioOut: int32
    ): PluginError {.cdecl, raises: [], gcsafe.}

    deactivate*: proc(api: ptr PluginApi; handle: PluginHandle)
      {.cdecl, raises: [], gcsafe.}

    reset*: proc(api: ptr PluginApi; handle: PluginHandle)
      {.cdecl, raises: [], gcsafe.}

    # -- Realtime --
    process*: PluginProcessProc

    # -- Параметры (control-path) --
    # Поле названо `countParams`, а не `paramCount`: в nimbase.h есть
    # C-макрос `#define paramCount() cmdCount`, и proc-поле с таким
    # именем ломает C-кодогенерацию (макрос съедает вызов).
    countParams*: proc(api: ptr PluginApi; handle: PluginHandle): int32
      {.cdecl, raises: [], gcsafe.}

    paramInfo*: proc(
      api: ptr PluginApi;
      handle: PluginHandle;
      index: int32;
      info: var PluginParamInfo
    ): bool {.cdecl, raises: [], gcsafe.}

    paramGet*: proc(api: ptr PluginApi; handle: PluginHandle;
      paramId: uint32): float64 {.cdecl, raises: [], gcsafe.}

    paramSet*: proc(api: ptr PluginApi; handle: PluginHandle;
      paramId: uint32; value: float64; normalized: bool): bool
      {.cdecl, raises: [], gcsafe.}

    paramFlush*: proc(
      api: ptr PluginApi;
      handle: PluginHandle;
      inEvents: ptr EventQueue;
      outEvents: ptr EventQueue
    ): bool {.cdecl, raises: [], gcsafe.}
      # Sample-accurate применение параметров: плагин получает события
      # param-change и может вернуть события наружу.

    # -- Состояние (control-path) --
    # Пишет состояние в dst и возвращает число записанных байт
    # (<= maxLen); < 0 — ошибка.
    stateSave*: proc(api: ptr PluginApi; handle: PluginHandle;
      dst: pointer; maxLen: int): int {.cdecl, raises: [], gcsafe.}

    stateLoad*: proc(api: ptr PluginApi; handle: PluginHandle;
      src: pointer; len: int): bool {.cdecl, raises: [], gcsafe.}

    # -- Прочее --
    latencyFrames*: proc(api: ptr PluginApi; handle: PluginHandle): int32
      {.cdecl, raises: [], gcsafe.}

    onMainThread*: proc(api: ptr PluginApi; handle: PluginHandle)
      {.cdecl, raises: [], gcsafe.}
      # Плагин просил callback (request_callback) — адаптер зовёт его
      # из main-потока.

# ==============================================================================
# Nil-safe обёртки (control-path + realtime process)
# ==============================================================================
#
# Core вызывает только их. Неполная или отсутствующая реализация даёт код
# ошибки, а не падение в audio-потоке.

proc pluginInit*(api: ptr PluginApi; log: ptr Logger): PluginError =
  if api.isNil or api.init.isNil:
    return peUnavailable
  api.init(api, log)

proc pluginShutdown*(api: ptr PluginApi) =
  if api.isNil or api.shutdown.isNil:
    return
  api.shutdown(api)

proc pluginCount*(api: ptr PluginApi; path: cstring): int32 =
  if api.isNil or api.pluginCount.isNil or path.isNil:
    return -1
  api.pluginCount(api, path)

proc pluginInfo*(
  api: ptr PluginApi;
  path: cstring;
  index: int32;
  info: var PluginInfo
): bool =
  if api.isNil or api.pluginInfo.isNil or path.isNil:
    return false
  api.pluginInfo(api, path, index, info)

proc pluginInstantiate*(
  api: ptr PluginApi;
  path: cstring;
  index: int32
): PluginHandle =
  if api.isNil or api.instantiate.isNil or path.isNil:
    return nil
  api.instantiate(api, path, index)

proc pluginDestroy*(api: ptr PluginApi; handle: PluginHandle) =
  if api.isNil or api.destroy.isNil or handle.isNil:
    return
  api.destroy(api, handle)

proc pluginActivate*(
  api: ptr PluginApi;
  handle: PluginHandle;
  sampleRate: float64;
  maxBlock: int32;
  audioIn: int32;
  audioOut: int32
): PluginError =
  if api.isNil or api.activate.isNil or handle.isNil:
    return peUnavailable
  api.activate(api, handle, sampleRate, maxBlock, audioIn, audioOut)

proc pluginDeactivate*(api: ptr PluginApi; handle: PluginHandle) =
  if api.isNil or api.deactivate.isNil or handle.isNil:
    return
  api.deactivate(api, handle)

proc pluginReset*(api: ptr PluginApi; handle: PluginHandle) =
  if api.isNil or api.reset.isNil or handle.isNil:
    return
  api.reset(api, handle)

proc pluginProcess*(
  api: ptr PluginApi;
  handle: PluginHandle;
  ctx: ptr NodeProcessContext;
  audio: ptr NodeAudioPorts;
  inEvents: ptr EventQueue;
  outEvents: ptr EventQueue
): PluginProcessStatus =
  ## Единственная обёртка, вызываемая из realtime-пути. При любом
  ## несоответствии возвращает ppsError, не падая.
  if api.isNil or api.process.isNil or handle.isNil:
    return ppsError
  api.process(api, handle, ctx, audio, inEvents, outEvents)

proc pluginParamCount*(api: ptr PluginApi; handle: PluginHandle): int32 =
  if api.isNil or api.countParams.isNil or handle.isNil:
    return 0
  api.countParams(api, handle)

proc pluginParamInfo*(
  api: ptr PluginApi;
  handle: PluginHandle;
  index: int32;
  info: var PluginParamInfo
): bool =
  if api.isNil or api.paramInfo.isNil or handle.isNil:
    return false
  api.paramInfo(api, handle, index, info)

proc pluginParamGet*(api: ptr PluginApi; handle: PluginHandle;
  paramId: uint32): float64 =
  if api.isNil or api.paramGet.isNil or handle.isNil:
    return 0.0
  api.paramGet(api, handle, paramId)

proc pluginParamSet*(api: ptr PluginApi; handle: PluginHandle;
  paramId: uint32; value: float64; normalized = false): bool =
  if api.isNil or api.paramSet.isNil or handle.isNil:
    return false
  api.paramSet(api, handle, paramId, value, normalized)

proc pluginParamFlush*(
  api: ptr PluginApi;
  handle: PluginHandle;
  inEvents: ptr EventQueue;
  outEvents: ptr EventQueue
): bool =
  if api.isNil or api.paramFlush.isNil or handle.isNil:
    return false
  api.paramFlush(api, handle, inEvents, outEvents)

proc pluginStateSave*(api: ptr PluginApi; handle: PluginHandle;
  dst: pointer; maxLen: int): int =
  if api.isNil or api.stateSave.isNil or handle.isNil or dst.isNil or maxLen <= 0:
    return -1
  api.stateSave(api, handle, dst, maxLen)

proc pluginStateLoad*(api: ptr PluginApi; handle: PluginHandle;
  src: pointer; len: int): bool =
  if api.isNil or api.stateLoad.isNil or handle.isNil or src.isNil or len <= 0:
    return false
  api.stateLoad(api, handle, src, len)

proc pluginLatencyFrames*(api: ptr PluginApi; handle: PluginHandle): int32 =
  if api.isNil or api.latencyFrames.isNil or handle.isNil:
    return 0
  api.latencyFrames(api, handle)

proc pluginOnMainThread*(api: ptr PluginApi; handle: PluginHandle) =
  if api.isNil or api.onMainThread.isNil or handle.isNil:
    return
  api.onMainThread(api, handle)

proc pluginBackendNameOf*(api: ptr PluginApi): string =
  ## Имя формата для логов и диагностики. Control-path.
  if api.isNil or api.backendName.isNil:
    return "none"
  $api.backendName

{.pop.}
