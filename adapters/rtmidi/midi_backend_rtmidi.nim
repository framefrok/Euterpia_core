# adapters/rtmidi/midi_backend_rtmidi.nim
#
# Адаптер RtMidi для midi_api (issue #28).
#
# Это ЕДИНСТВЕННЫЙ файл дерева, который знает про RtMidi
# (MANIFEST §41, §42). Core о нём не знает: он видит только таблицу
# методов MidiBackendApi, а трансляцию MIDI -> RealtimeEvent делает
# core/midi_events.nim.
#
# Отличия от прежней версии, лежавшей в commons/midi_io.nim:
# - нет ни одного echo: диагностика идёт через Logger (MANIFEST §6, §43);
# - кольцо сообщений — общий realtime-примитив core/ring_buffer.nim,
#   а не собственная реализация в Commons (issue #37);
# - port-хэндл владеет адаптер, Core передаёт его непрозрачно;
# - библиотека грузится через dynlib при первом вызове: отсутствие
#   librtmidi — это meUnavailable/meInitFailed, а не крэш на старте.

import std/atomics
import midi_api
import ring_buffer
import logger

when defined(windows):
  const RtMidiLib = "rtmidi.dll"
elif defined(macosx):
  const RtMidiLib = "librtmidi.dylib"
else:
  const RtMidiLib = "librtmidi.so"

# ==============================================================================
# RtMidi C ABI
# ==============================================================================

type
  RtMidiPtr = pointer
  RtMidiInPtr = pointer
  RtMidiOutPtr = pointer

  RtMidiInputCallback = proc(
    timeStamp: cdouble,
    message: ptr UncheckedArray[uint8],
    messageSize: csize_t,
    userData: pointer
  ) {.cdecl.}

{.pragma: rtmidi_import, importc, dynlib: RtMidiLib.}

proc rtmidi_in_create_default(): RtMidiInPtr {.rtmidi_import.}
proc rtmidi_out_create_default(): RtMidiOutPtr {.rtmidi_import.}
proc rtmidi_in_free(device: RtMidiInPtr) {.rtmidi_import.}
proc rtmidi_out_free(device: RtMidiOutPtr) {.rtmidi_import.}
proc rtmidi_get_port_count(device: RtMidiPtr): cuint {.rtmidi_import.}
proc rtmidi_get_port_name(
  device: RtMidiPtr,
  portNumber: cuint,
  bufOut: cstring,
  bufLen: ptr cint
): cint {.rtmidi_import.}
proc rtmidi_open_port(device: RtMidiPtr, portNumber: cuint, portName: cstring)
  {.rtmidi_import.}
proc rtmidi_close_port(device: RtMidiPtr) {.rtmidi_import.}
proc rtmidi_in_set_callback(
  device: RtMidiInPtr,
  callback: RtMidiInputCallback,
  userData: pointer
) {.rtmidi_import.}
proc rtmidi_in_cancel_callback(device: RtMidiInPtr) {.rtmidi_import.}
proc rtmidi_out_send_message(
  device: RtMidiOutPtr,
  message: ptr uint8,
  length: cint
): cint {.rtmidi_import.}
proc rtmidi_in_ignore_types(
  device: RtMidiInPtr,
  midiSysex: bool,
  midiTime: bool,
  midiSense: bool
) {.rtmidi_import.}

# ==============================================================================
# Состояние адаптера
# ==============================================================================

const
  MaxRtMidiPorts* = 64
  MidiRingCapacity* = 1024

type
  RtMidiPortSlot = object
    ## Слот открытого порта. Аллоцирован внутри RtMidiBackend (shared-куча).
    ##
    ## `ring` — единственная точка обмена между callback'ом RtMidi (thread
    ## драйвера) и realtime-потоком Core. Кольцо намеренно SOP: producer —
    ## callback, consumer — poll из audio callback.
    inUse: bool
    dir: MidiPortDirection
    inDev: RtMidiInPtr
    outDev: RtMidiOutPtr
    portId: int32
    timeAccumulator: float64
    ring: SpscRingBuffer[MidiMessage, MidiRingCapacity]

  RtMidiBackend = object
    log: Logger
    initialized: bool
    slots: array[MaxRtMidiPorts, RtMidiPortSlot]

proc implOf(api: ptr MidiBackendApi): ptr RtMidiBackend {.inline.} =
  if api.isNil:
    return nil
  cast[ptr RtMidiBackend](api.impl)

proc slotOf(handle: MidiPortHandle): ptr RtMidiPortSlot {.inline.} =
  if handle.isNil:
    return nil
  cast[ptr RtMidiPortSlot](handle)

proc initSlots(pb: ptr RtMidiBackend) =
  for i in 0 ..< MaxRtMidiPorts:
    pb.slots[i].inUse = false
    pb.slots[i].inDev = nil
    pb.slots[i].outDev = nil
    pb.slots[i].portId = int32(i)
    pb.slots[i].timeAccumulator = 0.0
    pb.slots[i].ring.initRing()

proc portName(device: RtMidiPtr, portNumber: cuint): string =
  var bufLen: cint = 0
  discard rtmidi_get_port_name(device, portNumber, nil, addr bufLen)
  if bufLen <= 0:
    return ""
  var buf = newString(bufLen)
  discard rtmidi_get_port_name(device, portNumber, cstring(buf), addr bufLen)
  result = buf
  if result.len > 0 and result[^1] == '\0':
    result.setLen(result.len - 1)

# ==============================================================================
# Callback драйвера: поток RtMidi -> кольцо порта
# ==============================================================================

proc rtInputCallback(
  timeStamp: cdouble;
  message: ptr UncheckedArray[uint8];
  messageSize: csize_t;
  userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  ## Выполняется в потоке RtMidi.
  ##
  ## Запрещено: аллокации, локи, файловый I/O, логирование.
  ## Разрешено: запись в атомарное кольцо.
  let slot = cast[ptr RtMidiPortSlot](userData)
  if slot.isNil:
    return

  slot.timeAccumulator += timeStamp

  if messageSize == 0 or message.isNil:
    return

  let status = message[0]
  let data1 = if messageSize > 1 and status < 0xF0'u8: message[1] else: 0'u8
  let data2 = if messageSize > 2 and status < 0xF0'u8: message[2] else: 0'u8

  # Note On с velocity 0 — это Note Off (требование MIDI-спецификации).
  var finalStatus = status
  var finalData2 = data2
  if (status and 0xF0'u8) == 0x90'u8 and data2 == 0'u8:
    finalStatus = 0x80'u8 or (status and 0x0F'u8)
    finalData2 = 0'u8

  let msg = MidiMessage(
    status: finalStatus,
    data1: data1,
    data2: finalData2,
    reserved: 0'u8,
    timestamp: slot.timeAccumulator,
    portId: slot.portId
  )

  # Кольцо переполнено — сообщение теряется, но непрочитанные не портятся.
  discard slot.ring.push(msg)

# ==============================================================================
# Таблица методов
# ==============================================================================

# Forward-декларация: rtShutdown закрывает порты через rtClosePort,
# определённый ниже (взаимная ссылка по порядку).
proc rtClosePort(api: ptr MidiBackendApi; handle: MidiPortHandle)
    {.cdecl, raises: [], gcsafe.}

proc rtInit(api: ptr MidiBackendApi; log: ptr Logger): MidiError
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return meUnavailable
  if not log.isNil:
    pb.log = log[]
  pb.initialized = true
  meOk

proc rtShutdown(api: ptr MidiBackendApi) {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return

  for i in 0 ..< MaxRtMidiPorts:
    if pb.slots[i].inUse:
      rtClosePort(api, cast[MidiPortHandle](addr pb.slots[i]))

  pb.initialized = false

proc rtPortCount(api: ptr MidiBackendApi; dir: MidiPortDirection): int32
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.initialized:
    return 0

  let device: RtMidiPtr =
    if dir == mpdInput: rtmidi_in_create_default()
    else: rtmidi_out_create_default()

  if device.isNil:
    return 0

  let count = rtmidi_get_port_count(device)

  if dir == mpdInput:
    rtmidi_in_free(cast[RtMidiInPtr](device))
  else:
    rtmidi_out_free(cast[RtMidiOutPtr](device))

  if count > 0x7FFF'u32: 0'i32 else: int32(count)

proc rtPortInfo(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32;
  info: var MidiBackendPortInfo
): bool {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.initialized or index < 0:
    return false

  let device: RtMidiPtr =
    if dir == mpdInput: rtmidi_in_create_default()
    else: rtmidi_out_create_default()

  if device.isNil:
    return false

  let count = int32(rtmidi_get_port_count(device))

  if index >= count:
    if dir == mpdInput: rtmidi_in_free(cast[RtMidiInPtr](device))
    else: rtmidi_out_free(cast[RtMidiOutPtr](device))
    return false

  info.id = index
  info.name = portName(device, cuint(index))
  info.direction = dir
  # У RtMidi нет понятия «порт по умолчанию»; считаем им первый.
  info.isDefault = index == 0

  if dir == mpdInput:
    rtmidi_in_free(cast[RtMidiInPtr](device))
  else:
    rtmidi_out_free(cast[RtMidiOutPtr](device))

  true

proc rtOpenPort(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32
): MidiPortHandle {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.initialized or index < 0:
    return nil

  var slot: ptr RtMidiPortSlot = nil
  for i in 0 ..< MaxRtMidiPorts:
    if not pb.slots[i].inUse:
      slot = addr pb.slots[i]
      break

  if slot.isNil:
    logError(addr pb.log, "rtmidi: нет свободных слотов портов")
    return nil

  slot.ring.initRing()
  slot.timeAccumulator = 0.0
  slot.dir = dir
  slot.portId = index

  if dir == mpdInput:
    let dev = rtmidi_in_create_default()
    if dev.isNil:
      logError(addr pb.log, "rtmidi: не удалось создать MIDI In")
      return nil
    rtmidi_open_port(dev, cuint(index), cstring"Euterpia MIDI In")
    rtmidi_in_ignore_types(dev, true, true, true)
    slot.inDev = dev
    slot.inUse = true
    # Callback ставим последним: слот полностью готов до первого сообщения.
    rtmidi_in_set_callback(dev, rtInputCallback, cast[pointer](slot))
  else:
    let dev = rtmidi_out_create_default()
    if dev.isNil:
      logError(addr pb.log, "rtmidi: не удалось создать MIDI Out")
      return nil
    rtmidi_open_port(dev, cuint(index), cstring"Euterpia MIDI Out")
    slot.outDev = dev
    slot.inUse = true

  cast[MidiPortHandle](slot)

proc rtClosePort(api: ptr MidiBackendApi; handle: MidiPortHandle)
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or not slot.inUse:
    return

  if slot.dir == mpdInput and not slot.inDev.isNil:
    rtmidi_in_cancel_callback(slot.inDev)
    rtmidi_close_port(slot.inDev)
    rtmidi_in_free(slot.inDev)
    slot.inDev = nil
  elif not slot.outDev.isNil:
    rtmidi_close_port(slot.outDev)
    rtmidi_out_free(slot.outDev)
    slot.outDev = nil

  slot.inUse = false

proc rtIsPortOpen(api: ptr MidiBackendApi; handle: MidiPortHandle): bool
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil:
    return false
  slot.inUse

proc rtSend(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  msg: ptr MidiMessage
): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or not slot.inUse or msg.isNil:
    return false
  if slot.dir != mpdOutput or slot.outDev.isNil:
    return false

  var data: array[3, uint8] = [msg.status, msg.data1, msg.data2]
  # Program Change (0xC0) и Channel Aftertouch (0xD0) — двухбайтовые.
  let status = msg.status and 0xF0'u8
  let length = if status == 0xC0'u8 or status == 0xD0'u8: 2 else: 3

  rtmidi_out_send_message(slot.outDev, addr data[0], cint(length)) == 0

proc rtPoll(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  dst: ptr UncheckedArray[MidiMessage];
  maxCount: int32
): int32 {.cdecl, raises: [], gcsafe.} =
  ## Realtime-path: сливаем кольцо порта. Ни аллокаций, ни блокировок.
  let slot = slotOf(handle)
  if slot.isNil or not slot.inUse or dst.isNil or maxCount <= 0:
    return 0

  var count: int32 = 0
  var msg: MidiMessage
  while count < maxCount and slot.ring.pop(msg):
    dst[count] = msg
    inc count

  count

# ==============================================================================
# Создание / уничтожение (control-path)
# ==============================================================================

proc createRtMidiBackend*(log: Logger = silentLogger()): ptr MidiBackendApi =
  ## Собирает адаптер в shared-куче.
  ##
  ## Отсутствие установленной librtmidi здесь НЕ ошибка: библиотека
  ## грузится через dynlib при первом вызове RtMidi. Недоступность
  ## проявится как исключение dynlib на control-path — вызывающий обязан
  ## обработать его и получить meUnavailable/meInitFailed.
  let api = cast[ptr MidiBackendApi](allocShared0(sizeof(MidiBackendApi)))
  if api.isNil:
    return nil

  let pb = cast[ptr RtMidiBackend](allocShared0(sizeof(RtMidiBackend)))
  if pb.isNil:
    deallocShared(cast[pointer](api))
    return nil

  pb.log = log
  pb.initialized = false
  initSlots(pb)

  api.backendName = cstring"rtmidi"
  api.impl = cast[pointer](pb)

  api.init = rtInit
  api.shutdown = rtShutdown
  api.portCount = rtPortCount
  api.portInfo = rtPortInfo
  api.openPort = rtOpenPort
  api.closePort = rtClosePort
  api.isPortOpen = rtIsPortOpen
  api.send = rtSend
  api.poll = rtPoll

  api

proc destroyRtMidiBackend*(api: ptr MidiBackendApi) =
  if api.isNil:
    return

  midiShutdown(api)

  let pb = implOf(api)
  if not pb.isNil:
    api.impl = nil
    deallocShared(cast[pointer](pb))

  deallocShared(cast[pointer](api))
