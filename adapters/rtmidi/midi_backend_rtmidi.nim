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

import std/[atomics, dynlib]
import midi_api
import ring_buffer
import logger
import ../lazy_dynlib

when defined(windows):
  const RtMidiLibDefault = "rtmidi.dll"
elif defined(macosx):
  const RtMidiLibDefault = "librtmidi.dylib"
else:
  const RtMidiLibDefault = "librtmidi.so"

const RtMidiLibEnv = "EUTERPIA_RTMIDI_LIB"
  ## Переопределение имени библиотеки для теста «библиотеки нет» (#267).

# ==============================================================================
# RtMidi C ABI
# ==============================================================================
#
# Библиотека грузится лениво в rtInit() (#267): импорт адаптера на машине
# без librtmidi не роняет процесс до main(), а midiInit возвращает
# meUnavailable. Прагма `dynlib` этого не умеет — она резолвит символы в
# инициализации модуля.

type
  RtMidiPtr = pointer
  RtMidiInPtr = pointer
  RtMidiOutPtr = pointer

  RtMidiInputCallback = proc(
    timeStamp: cdouble,
    message: ptr UncheckedArray[uint8],
    messageSize: csize_t,
    userData: pointer
  ) {.cdecl, raises: [], gcsafe.}

  RtMidiInCreateProc = proc(): RtMidiInPtr {.cdecl, raises: [], gcsafe.}
  RtMidiOutCreateProc = proc(): RtMidiOutPtr {.cdecl, raises: [], gcsafe.}
  RtMidiFreeProc = proc(device: pointer) {.cdecl, raises: [], gcsafe.}
  RtMidiGetPortCountProc = proc(device: RtMidiPtr): cuint {.cdecl, raises: [], gcsafe.}
  RtMidiGetPortNameProc = proc(
    device: RtMidiPtr,
    portNumber: cuint,
    bufOut: cstring,
    bufLen: ptr cint
  ): cint {.cdecl, raises: [], gcsafe.}
  RtMidiOpenPortProc = proc(device: RtMidiPtr, portNumber: cuint,
                            portName: cstring) {.cdecl, raises: [], gcsafe.}
  RtMidiClosePortProc = proc(device: RtMidiPtr) {.cdecl, raises: [], gcsafe.}
  RtMidiSetCallbackProc = proc(device: RtMidiInPtr,
                               callback: RtMidiInputCallback,
                               userData: pointer) {.cdecl, raises: [], gcsafe.}
  RtMidiCancelCallbackProc = proc(device: RtMidiInPtr) {.cdecl, raises: [], gcsafe.}
  RtMidiSendMessageProc = proc(device: RtMidiOutPtr,
                               message: ptr uint8,
                               length: cint): cint {.cdecl, raises: [], gcsafe.}
  RtMidiIgnoreTypesProc = proc(device: RtMidiInPtr; midiSysex: bool;
                               midiTime: bool; midiSense: bool) {.cdecl, raises: [], gcsafe.}

var
  rtLib: LazyLibrary
  rtInCreateSym: RtMidiInCreateProc
  rtOutCreateSym: RtMidiOutCreateProc
  rtInFreeSym: RtMidiFreeProc
  rtOutFreeSym: RtMidiFreeProc
  rtGetPortCountSym: RtMidiGetPortCountProc
  rtGetPortNameSym: RtMidiGetPortNameProc
  rtOpenPortSym: RtMidiOpenPortProc
  rtClosePortSym: RtMidiClosePortProc
  rtSetCallbackSym: RtMidiSetCallbackProc
  rtCancelCallbackSym: RtMidiCancelCallbackProc
  rtSendMessageSym: RtMidiSendMessageProc
  rtIgnoreTypesSym: RtMidiIgnoreTypesProc

proc loadRtMidi(): bool =
  if not rtLib.handle.isNil:
    return true
  if not openLibrary(rtLib):
    return false
  result =
    symPtr(rtLib, "rtmidi_in_create_default", rtInCreateSym) and
    symPtr(rtLib, "rtmidi_out_create_default", rtOutCreateSym) and
    symPtr(rtLib, "rtmidi_in_free", rtInFreeSym) and
    symPtr(rtLib, "rtmidi_out_free", rtOutFreeSym) and
    symPtr(rtLib, "rtmidi_get_port_count", rtGetPortCountSym) and
    symPtr(rtLib, "rtmidi_get_port_name", rtGetPortNameSym) and
    symPtr(rtLib, "rtmidi_open_port", rtOpenPortSym) and
    symPtr(rtLib, "rtmidi_close_port", rtClosePortSym) and
    symPtr(rtLib, "rtmidi_in_set_callback", rtSetCallbackSym) and
    symPtr(rtLib, "rtmidi_in_cancel_callback", rtCancelCallbackSym) and
    symPtr(rtLib, "rtmidi_out_send_message", rtSendMessageSym) and
    symPtr(rtLib, "rtmidi_in_ignore_types", rtIgnoreTypesSym)

proc rtmidi_in_create_default(): RtMidiInPtr {.inline.} = rtInCreateSym()
proc rtmidi_out_create_default(): RtMidiOutPtr {.inline.} = rtOutCreateSym()
proc rtmidi_in_free(device: RtMidiInPtr) {.inline.} = rtInFreeSym(device)
proc rtmidi_out_free(device: RtMidiOutPtr) {.inline.} = rtOutFreeSym(device)
proc rtmidi_get_port_count(device: RtMidiPtr): cuint {.inline.} =
  rtGetPortCountSym(device)
proc rtmidi_get_port_name(
  device: RtMidiPtr,
  portNumber: cuint,
  bufOut: cstring,
  bufLen: ptr cint
): cint {.inline.} =
  rtGetPortNameSym(device, portNumber, bufOut, bufLen)
proc rtmidi_open_port(device: RtMidiPtr, portNumber: cuint, portName: cstring)
  {.inline.} =
  rtOpenPortSym(device, portNumber, portName)
proc rtmidi_close_port(device: RtMidiPtr) {.inline.} = rtClosePortSym(device)
proc rtmidi_in_set_callback(
  device: RtMidiInPtr,
  callback: RtMidiInputCallback,
  userData: pointer
) {.inline.} =
  rtSetCallbackSym(device, callback, userData)
proc rtmidi_in_cancel_callback(device: RtMidiInPtr) {.inline.} =
  rtCancelCallbackSym(device)
proc rtmidi_out_send_message(
  device: RtMidiOutPtr,
  message: ptr uint8,
  length: cint
): cint {.inline.} =
  rtSendMessageSym(device, message, length)
proc rtmidi_in_ignore_types(
  device: RtMidiInPtr,
  midiSysex: bool,
  midiTime: bool,
  midiSense: bool
) {.inline.} =
  rtIgnoreTypesSym(device, midiSysex, midiTime, midiSense)

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
  # Ленивая загрузка (#267): нет библиотеки — meUnavailable, процесс жив.
  if not loadRtMidi():
    logError(addr pb.log, "rtmidi: " & libraryError(rtLib))
    return meUnavailable
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
  rtLib.setLibraryName(resolveLibraryName(RtMidiLibEnv, RtMidiLibDefault))

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
