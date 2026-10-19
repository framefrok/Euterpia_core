# src_api.nim
#
# Контракт ресемплинга частоты дискретизации (issue #8).
#
#   Core -> src_api -> adapters/resample
#
# Зачем отдельный контракт, а не прямой вызов адаптера:
#   * Core не имеет права знать, какая библиотека ресемплинга используется
#     (libsamplerate, speexdsp, собственный polyphase). Это то же правило,
#     что у `audio_backend_api` (#2), `midi_api` (#28) и `plugin_api` (#29);
#   * ресемплер нужен в двух местах с разными требованиями: живой путь
#     (device SR != project SR) и офлайн-путь (bounce на другом SR).
#     Оба места видят одну таблицу методов.
#
# Модель владения:
# - `SrcApi` и его `impl` живут в shared-куче: время жизни не привязано
#   к стеку, потому что на таблицу ссылается audio callback;
# - `SrcHandle` — непрозрачный дескриптор потока-реземплера, владелец
#   которого адаптер; Core передаёт его обратно в методы таблицы «как есть»;
# - `process` вызывается ТОЛЬКО из audio-потока и обязан быть
#   allocation-free, lock-free и exception-free. Все буферы истории и
#   коэффициенты выделяются в `createConverter` (control-path).
#
# MANIFEST §8, §27, §41, §42, §78.

import logger

# `Logger` входит в публичную сигнатуру таблицы методов (init),
# поэтому контракт реэкспортирует его.
export logger

{.push raises: [].}

type
  SrcError* = enum
    seOk = 0,
    seUnavailable,      ## адаптер не смог загрузить внешнюю библиотеку
    seBadRate,          ## частота <= 0 или отношение вне допустимого
    seBadChannels,      ## число каналов вне 1..MaxSrcChannels
    seNoMemory,         ## не удалось выделить арену истории
    seBadHandle         ## метод вызван без успешного createConverter

  SrcHandle* = pointer
    ## Непрозрачный дескриптор потока-ресемплера. Нулевое значение —
    ## «потока нет».

  SrcApi* = object
    ## Таблица методов адаптера.
    ##
    ## Поля-процедуры опциональны: Core обязан проверять их на nil через
    ## nil-safe обёртки `src*` ниже, а не звать напрямую.
    backendName*: cstring
    impl*: pointer

    init*: proc(api: ptr SrcApi; log: ptr Logger): SrcError
      {.cdecl, raises: [], gcsafe.}

    shutdown*: proc(api: ptr SrcApi)
      {.cdecl, raises: [], gcsafe.}

    createConverter*: proc(
      api: ptr SrcApi;
      inRate, outRate: float64;
      channels: int32;
      maxInputFrames: int32
    ): SrcHandle {.cdecl, raises: [], gcsafe.}
      ## Создать поток. `maxInputFrames` — верхняя граница входного блока:
      ## по ней выделяется история, поэтому в `process` аллокаций нет.

    destroyConverter*: proc(api: ptr SrcApi; handle: SrcHandle)
      {.cdecl, raises: [], gcsafe.}

    reset*: proc(api: ptr SrcApi; handle: SrcHandle)
      {.cdecl, raises: [], gcsafe.}
      ## Сбросить историю и фазу: следующий блок начинается «с чистого
      ## листа». Позиция транспорта при этом не меняется — это забота Core.

    process*: proc(
      api: ptr SrcApi;
      handle: SrcHandle;
      src: ptr UncheckedArray[float32];
      srcStride: int32;
      inFrames: int32;
      dst: ptr UncheckedArray[float32];
      dstStride: int32;
      maxOutFrames: int32
    ): int32 {.cdecl, raises: [], gcsafe.}
      ## Realtime-path: перевести до `inFrames` кадров planar-входа в
      ## planar-выход. Возвращает число записанных кадров (0 — не хватило
      ## места в dst, данные НЕ теряются: фаза не сдвигается).
      ##
      ## Раскладка обоих буферов — planar: канал `ch` лежит по
      ## `src[ch * srcStride + frame]`.

    latencyFrames*: proc(api: ptr SrcApi; handle: SrcHandle): int32
      {.cdecl, raises: [], gcsafe.}
      ## Задержка ресемплера в кадрах ВЫХОДНОЙ частоты. Нужна PDC:
      ## без неё параллельные ветви графа разъезжаются по фазе.

# ==============================================================================
# Nil-safe обёртки (control-path + realtime process)
# ==============================================================================

proc srcInit*(api: ptr SrcApi; log: ptr Logger): SrcError =
  if api.isNil or api.init.isNil:
    return seUnavailable
  api.init(api, log)

proc srcShutdown*(api: ptr SrcApi) =
  if api.isNil or api.shutdown.isNil:
    return
  api.shutdown(api)

proc srcCreateConverter*(
  api: ptr SrcApi;
  inRate, outRate: float64;
  channels: int32;
  maxInputFrames: int32
): SrcHandle =
  if api.isNil or api.createConverter.isNil:
    return nil
  api.createConverter(api, inRate, outRate, channels, maxInputFrames)

proc srcDestroyConverter*(api: ptr SrcApi; handle: SrcHandle) =
  if api.isNil or api.destroyConverter.isNil or handle.isNil:
    return
  api.destroyConverter(api, handle)

proc srcReset*(api: ptr SrcApi; handle: SrcHandle) =
  if api.isNil or api.reset.isNil or handle.isNil:
    return
  api.reset(api, handle)

proc srcProcess*(
  api: ptr SrcApi;
  handle: SrcHandle;
  src: ptr UncheckedArray[float32];
  srcStride: int32;
  inFrames: int32;
  dst: ptr UncheckedArray[float32];
  dstStride: int32;
  maxOutFrames: int32
): int32 =
  ## Единственная обёртка, вызываемая из realtime-пути. При любом
  ## несоответствии возвращает 0, не падая.
  if api.isNil or api.process.isNil or handle.isNil or
     src.isNil or dst.isNil or inFrames <= 0 or maxOutFrames <= 0:
    return 0
  api.process(api, handle, src, srcStride, inFrames, dst, dstStride,
              maxOutFrames)

proc srcLatencyFrames*(api: ptr SrcApi; handle: SrcHandle): int32 =
  if api.isNil or api.latencyFrames.isNil or handle.isNil:
    return 0
  api.latencyFrames(api, handle)

proc srcBackendNameOf*(api: ptr SrcApi): string =
  ## Имя реализации для логов и диагностики. Control-path.
  if api.isNil or api.backendName.isNil:
    return "none"
  $api.backendName

{.pop.}
