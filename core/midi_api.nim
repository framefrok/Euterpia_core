# midi_api.nim
#
# Контракт MIDI-бэкенда для Core (issue #28).
#
#   Core -> midi_api -> adapters/<backend>
#
# До этого модуля RtMidi жил прямо в `commons/midi_io.nim`, а Commons —
# нейтральный слой, который не должен знать ни про Core, ни про внешние
# библиотеки (MANIFEST §25/§26, §41/§42). Теперь по образцу
# `core/audio_backend_api.nim` (#2):
#
#   * Core знает ТОЛЬКО этот модуль;
#   * конкретная библиотека (RtMidi, libremidi, ALSA raw, ...) живёт в
#     `adapters/` и подключается через таблицу методов;
#   * конвертация MIDI -> RealtimeEvent — обязанность Core
#     (`core/midi_events.nim`), а не Commons.
#
# Модель владения:
# - `MidiBackendApi` и его `impl` живут в shared-куче: на порт-хэндл
#   ссылается callback драйвера, поэтому время жизни не привязано к стеку;
# - поле `impl` целиком принадлежит адаптеру, Core его не читает;
# - `MidiPortHandle` — непрозрачный указатель, владелец которого адаптер;
#   Core передаёт его обратно в методы таблицы «как есть»;
# - `poll` вызывается из realtime-пути и обязан быть allocation-free,
#   lock-free и exception-free: адаптер только сливает своё кольцо.
#
# MANIFEST §8, §25, §26, §41, §42.

import logger

# `Logger` входит в публичную сигнатуру таблицы методов (init),
# поэтому контракт реэкспортирует его.
export logger

{.push raises: [].}

type
  MidiError* = enum
    meOk = 0,
    meUnavailable,    ## адаптер не смог загрузить внешнюю библиотеку
    meInitFailed,
    meNoDevice,
    meOpenFailed,
    meNotOpen         ## метод вызван без успешного openPort

  MidiPortDirection* = enum
    mpdInput = 0,     ## порт, из которого Core читает (MIDI In)
    mpdOutput         ## порт, в который Core пишет (MIDI Out)

  MidiPortHandle* = pointer
    ## Непрозрачный дескриптор открытого порта. Нулевое значение — «нет порта».

  MidiBackendPortInfo* = object
    ## Описание порта. Заполняется на control-path (перечисление портов),
    ## поэтому имя — обычная строка, а не фиксированный буфер.
    id*: int32
    name*: string
    direction*: MidiPortDirection
    isDefault*: bool

  MidiMessage* {.bycopy.} = object
    ## Одно MIDI-сообщение. Строго POD: живёт в SPSC-кольце между
    ## callback'ом драйвера и realtime-потоком, GC-полей иметь не может.
    ##
    ## `timestamp` — абсолютное время в секундах от открытия порта
    ## (как отдаёт RtMidi), `portId` — индекс порта, из которого пришло
    ## сообщение (нужен для сортировки/маршрутизации).
    status*: uint8
    data1*: uint8
    data2*: uint8
    reserved*: uint8
    timestamp*: float64
    portId*: int32

  MidiBackendApi* = object
    ## Таблица методов адаптера.
    ##
    ## Поля-процедуры опциональны: Core обязан проверять их на nil через
    ## nil-safe обёртки `midi*` ниже, а не звать напрямую.
    backendName*: cstring
    impl*: pointer

    init*: proc(api: ptr MidiBackendApi; log: ptr Logger): MidiError
      {.cdecl, raises: [], gcsafe.}

    shutdown*: proc(api: ptr MidiBackendApi)
      {.cdecl, raises: [], gcsafe.}

    portCount*: proc(api: ptr MidiBackendApi; dir: MidiPortDirection): int32
      {.cdecl, raises: [], gcsafe.}

    portInfo*: proc(
      api: ptr MidiBackendApi;
      dir: MidiPortDirection;
      index: int32;
      info: var MidiBackendPortInfo
    ): bool {.cdecl, raises: [], gcsafe.}

    openPort*: proc(api: ptr MidiBackendApi; dir: MidiPortDirection;
      index: int32): MidiPortHandle {.cdecl, raises: [], gcsafe.}

    closePort*: proc(api: ptr MidiBackendApi; handle: MidiPortHandle)
      {.cdecl, raises: [], gcsafe.}

    isPortOpen*: proc(api: ptr MidiBackendApi; handle: MidiPortHandle): bool
      {.cdecl, raises: [], gcsafe.}

    send*: proc(api: ptr MidiBackendApi; handle: MidiPortHandle;
      msg: ptr MidiMessage): bool {.cdecl, raises: [], gcsafe.}

    poll*: proc(
      api: ptr MidiBackendApi;
      handle: MidiPortHandle;
      dst: ptr UncheckedArray[MidiMessage];
      maxCount: int32
    ): int32 {.cdecl, raises: [], gcsafe.}
      ## Realtime-path: слить до maxCount сообщений из кольца порта в dst.
      ## Возвращает число реально прочитанных сообщений.

# ==============================================================================
# Nil-safe обёртки (control-path + realtime poll)
# ==============================================================================
#
# Core вызывает только их. Неполная или отсутствующая реализация даёт код
# ошибки, а не падение в audio-потоке.

proc midiInit*(api: ptr MidiBackendApi; log: ptr Logger): MidiError =
  if api.isNil or api.init.isNil:
    return meUnavailable
  api.init(api, log)

proc midiShutdown*(api: ptr MidiBackendApi) =
  if api.isNil or api.shutdown.isNil:
    return
  api.shutdown(api)

proc midiDeviceCount*(api: ptr MidiBackendApi; dir: MidiPortDirection): int32 =
  if api.isNil or api.portCount.isNil:
    return 0
  api.portCount(api, dir)

proc midiDeviceInfo*(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32;
  info: var MidiBackendPortInfo
): bool =
  if api.isNil or api.portInfo.isNil:
    return false
  api.portInfo(api, dir, index, info)

proc midiOpenPort*(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32
): MidiPortHandle =
  if api.isNil or api.openPort.isNil:
    return nil
  api.openPort(api, dir, index)

proc midiClosePort*(api: ptr MidiBackendApi; handle: MidiPortHandle) =
  if api.isNil or api.closePort.isNil or handle.isNil:
    return
  api.closePort(api, handle)

proc midiIsPortOpen*(api: ptr MidiBackendApi; handle: MidiPortHandle): bool =
  if api.isNil or api.isPortOpen.isNil or handle.isNil:
    return false
  api.isPortOpen(api, handle)

proc midiSend*(api: ptr MidiBackendApi; handle: MidiPortHandle;
  msg: ptr MidiMessage): bool =
  if api.isNil or api.send.isNil or handle.isNil or msg.isNil:
    return false
  api.send(api, handle, msg)

proc midiPoll*(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  dst: ptr UncheckedArray[MidiMessage];
  maxCount: int32
): int32 =
  ## Единственная обёртка, вызываемая из realtime-пути. Всё остальное —
  ## control-path. При любом несоответствии возвращает 0, не падая.
  if api.isNil or api.poll.isNil or handle.isNil or dst.isNil or maxCount <= 0:
    return 0
  api.poll(api, handle, dst, maxCount)

proc midiBackendNameOf*(api: ptr MidiBackendApi): string =
  ## Имя бэкенда для логов и диагностики. Control-path.
  if api.isNil or api.backendName.isNil:
    return "none"
  $api.backendName

{.pop.}

