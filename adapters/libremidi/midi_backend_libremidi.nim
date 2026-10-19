# adapters/libremidi/midi_backend_libremidi.nim
#
# Адаптер libremidi для `core/midi_api` (issue #38).
#
# Это ЕДИНСТВЕННЫЙ файл дерева, который знает про libremidi (MANIFEST §41,
# §42). Core видит только таблицу методов `MidiBackendApi`; маппинг UMP →
# `MidiMessage`/`RealtimeEvent` живёт в Core (`core/ump.nim`,
# `core/midi_events.nim`), а не здесь.
#
# Почему C-фасад, а не прямой вызов C++:
#   libremidi — C++-библиотека. Тонкий C-фасад с устойчивым ABI (те же
#   приёмы, что у VST3-моста по MANIFEST) отделяет Nim/C-код от исключений
#   и шаблонов C++. Заголовок ABI — `libremidi_shim.h`; реализация —
#   `libremidi_shim.cpp` (собирается ТОЛЬКО когда библиотека вендорена:
#   `-DEUTERPIA_WITH_LIBREMEDI`).
#
# Ленивая загрузка (issue #267): библиотека грузится в `lrmInit`, имя —
# `EUTERPIA_LIBREMIDI_LIB`. Нет библиотеки — `meUnavailable`, а не падение
# до `main()`. Это же позволяет CI проверять ветку «библиотеки нет».
#
# Realtime-дисциплина: callback фасада только разбирает UMP в POD и делает
# `ring.push` — ни аллокаций, ни локов. `poll`/`pollUmp` сливают кольцо в
# realtime-потоке Core.
#
# MANIFEST §8, §28, §41, §42.

import midi_api
import logger
import ring_buffer
import ump
import lazy_dynlib

{.push raises: [].}

const
  LrmBackendName* = "libremidi"

  LrmLibDefault =
    when defined(windows): "euterpia_libremidi.dll"
    elif defined(macosx): "libeuterpia_libremidi.dylib"
    else: "libeuterpia_libremidi.so"

  LrmLibEnv = "EUTERPIA_LIBREMIDI_LIB"
    ## Переопределение имени библиотеки для теста «библиотеки нет» (#267).

  MaxLrmPorts* = 8
  LrmRingCapacity* = 256
  LrmNameMax = 256

type
  LrmUmpWire* {.bycopy.} = object
    ## ABI-форма одного UMP-пакета из фасада.
    ##
    ## Раскладка совпадает с `eut_lrm_ump` в `libremidi_shim.h`:
    ## words (16) + word_count (4) + выравнивание (4) + timestamp (8) = 32.
    ## `reserved` — явное выравнивание, а не данные.
    words*: array[UmpMaxWords, uint32]
    wordCount*: int32
    reserved*: int32
    timestamp*: float64

  LrmUmpCallback* = proc(msg: ptr LrmUmpWire; user: pointer)
    {.cdecl, raises: [], gcsafe.}

  # --- C-фасад: сигнатуры ---
  LrmInitProc = proc(): cint {.cdecl, raises: [], gcsafe.}
  LrmShutdownProc = proc() {.cdecl, raises: [], gcsafe.}
  LrmPortCountProc = proc(dir: cint): cint {.cdecl, raises: [], gcsafe.}
  LrmPortNameProc = proc(dir, index: cint; buf: cstring; len: cint): cint
    {.cdecl, raises: [], gcsafe.}
  LrmOpenProc = proc(dir, index: cint): pointer {.cdecl, raises: [], gcsafe.}
  LrmCloseProc = proc(port: pointer) {.cdecl, raises: [], gcsafe.}
  LrmSendMidi1Proc = proc(port: pointer; data: ptr UncheckedArray[uint8];
    len: cint): cint {.cdecl, raises: [], gcsafe.}
  LrmSendUmpProc = proc(port: pointer; words: ptr UncheckedArray[uint32];
    count: cint): cint {.cdecl, raises: [], gcsafe.}
  LrmSetCallbackProc = proc(port: pointer; cb: LrmUmpCallback;
    user: pointer): cint {.cdecl, raises: [], gcsafe.}
  LrmPollProc = proc(port: pointer;
    dst: ptr UncheckedArray[LrmUmpWire]; maxCount: cint): cint
    {.cdecl, raises: [], gcsafe.}
  LrmEnableUmpProc = proc(port: pointer; enabled: cint): cint
    {.cdecl, raises: [], gcsafe.}

var
  lrmLib: LazyLibrary
  lrmInitSym: LrmInitProc
  lrmShutdownSym: LrmShutdownProc
  lrmPortCountSym: LrmPortCountProc
  lrmPortNameSym: LrmPortNameProc
  lrmOpenSym: LrmOpenProc
  lrmCloseSym: LrmCloseProc
  lrmSendMidi1Sym: LrmSendMidi1Proc
  lrmSendUmpSym: LrmSendUmpProc
  lrmSetCallbackSym: LrmSetCallbackProc
  lrmPollSym: LrmPollProc
  lrmEnableUmpSym: LrmEnableUmpProc

proc loadLrm(): bool =
  ## Control-path: загрузить фасад и резолвить символы. Повторный вызов
  ## после успеха — no-op.
  if not lrmLib.handle.isNil:
    return true
  if not openLibrary(lrmLib):
    return false
  result =
    symPtr(lrmLib, "eut_lrm_init", lrmInitSym) and
    symPtr(lrmLib, "eut_lrm_shutdown", lrmShutdownSym) and
    symPtr(lrmLib, "eut_lrm_port_count", lrmPortCountSym) and
    symPtr(lrmLib, "eut_lrm_port_name", lrmPortNameSym) and
    symPtr(lrmLib, "eut_lrm_open", lrmOpenSym) and
    symPtr(lrmLib, "eut_lrm_close", lrmCloseSym) and
    symPtr(lrmLib, "eut_lrm_send_midi1", lrmSendMidi1Sym) and
    symPtr(lrmLib, "eut_lrm_send_ump", lrmSendUmpSym) and
    symPtr(lrmLib, "eut_lrm_set_callback", lrmSetCallbackSym) and
    symPtr(lrmLib, "eut_lrm_poll", lrmPollSym) and
    symPtr(lrmLib, "eut_lrm_enable_ump", lrmEnableUmpSym)

type
  LrmPort = object
    ## Слот открытого порта. Живёт в shared-куче (внутри backend), поэтому
    ## адрес стабилен: его получает callback фасада.
    inUse: bool
    dir: MidiPortDirection
    handle: pointer
    portId: int32
    umpEnabled: bool
    ring: SpscRingBuffer[UmpMessage, LrmRingCapacity]

  LrmBackend = object
    log: Logger
    initialized: bool
    ports: array[MaxLrmPorts, LrmPort]

proc implOf(api: ptr MidiBackendApi): ptr LrmBackend {.inline.} =
  if api.isNil: nil else: cast[ptr LrmBackend](api.impl)

proc slotOf(handle: MidiPortHandle): ptr LrmPort {.inline.} =
  if handle.isNil: nil else: cast[ptr LrmPort](handle)

proc resetSlots(pb: ptr LrmBackend) =
  for i in 0 ..< MaxLrmPorts:
    pb.ports[i].inUse = false
    pb.ports[i].handle = nil
    pb.ports[i].portId = int32(i)
    pb.ports[i].umpEnabled = false
    pb.ports[i].ring.initRing()


# ==============================================================================
# Callback фасада: поток библиотеки -> кольцо порта
# ==============================================================================

proc lrmCallback(msg: ptr LrmUmpWire; user: pointer)
    {.cdecl, raises: [], gcsafe.} =
  ## Запрещено: аллокации, локи, I/O, логирование.
  let slot = slotOf(cast[MidiPortHandle](user))
  if slot.isNil or msg.isNil:
    return
  if msg.wordCount <= 0 or msg.wordCount > int32(UmpMaxWords):
    return
  let parsed = umpParse(msg.words, msg.wordCount, msg.timestamp)
  discard slot.ring.push(parsed)

# ==============================================================================
# Таблица методов
# ==============================================================================

proc lrmInit(api: ptr MidiBackendApi; log: ptr Logger): MidiError
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil:
    return meInitFailed
  if not log.isNil:
    pb.log = log[]
  if pb.initialized:
    return meOk
  if not loadLrm():
    return meUnavailable
  if lrmInitSym() != 0:
    return meInitFailed
  resetSlots(pb)
  pb.initialized = true
  meOk

proc closeSlot(slot: ptr LrmPort) =
  if slot.isNil or not slot.inUse:
    return
  discard lrmSetCallbackSym(slot.handle, nil, nil)
  lrmCloseSym(slot.handle)
  slot.handle = nil
  slot.inUse = false
  slot.umpEnabled = false
  slot.ring.initRing()

proc lrmShutdown(api: ptr MidiBackendApi) {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.initialized:
    return
  for i in 0 ..< MaxLrmPorts:
    closeSlot(addr pb.ports[i])
  lrmShutdownSym()
  pb.initialized = false

proc lrmPortCount(api: ptr MidiBackendApi; dir: MidiPortDirection): int32
    {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.initialized:
    return 0
  let count = lrmPortCountSym(cint(ord(dir)))
  if count < 0: 0 else: int32(count)

proc lrmPortInfo(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32;
  info: var MidiBackendPortInfo
): bool {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.initialized or index < 0:
    return false
  var buf: array[LrmNameMax, char]
  let written = lrmPortNameSym(cint(ord(dir)), cint(index),
                               cast[cstring](addr buf[0]), cint(LrmNameMax))
  if written < 0:
    return false
  var name = ""
  var i = 0
  while i < LrmNameMax and buf[i] != '\0':
    name.add buf[i]
    inc i
  info.id = index
  info.name = name
  info.direction = dir
  info.isDefault = index == 0
  true

proc lrmOpenPort(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32
): MidiPortHandle {.cdecl, raises: [], gcsafe.} =
  let pb = implOf(api)
  if pb.isNil or not pb.initialized or index < 0:
    return nil
  var slot: ptr LrmPort = nil
  for i in 0 ..< MaxLrmPorts:
    if not pb.ports[i].inUse:
      slot = addr pb.ports[i]
      break
  if slot.isNil:
    logError(addr pb.log, "libremidi: нет свободных слотов портов")
    return nil

  slot.ring.initRing()
  slot.portId = index
  slot.dir = dir
  slot.umpEnabled = false
  let port = lrmOpenSym(cint(ord(dir)), cint(index))
  if port.isNil:
    logError(addr pb.log, "libremidi: не удалось открыть порт")
    return nil

  slot.handle = port
  slot.inUse = true
  if dir == mpdInput:
    # Callback ставим последним: слот полностью готов до первого пакета.
    if lrmSetCallbackSym(port, lrmCallback, cast[pointer](slot)) != 0:
      closeSlot(slot)
      return nil
  cast[MidiPortHandle](slot)

proc lrmClosePort(api: ptr MidiBackendApi; handle: MidiPortHandle)
    {.cdecl, raises: [], gcsafe.} =
  closeSlot(slotOf(handle))

proc lrmIsPortOpen(api: ptr MidiBackendApi; handle: MidiPortHandle): bool
    {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  slot != nil and slot.inUse

proc lrmSend(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  msg: ptr MidiMessage
): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or not slot.inUse or msg.isNil or
     slot.dir != mpdOutput or slot.handle.isNil:
    return false
  if slot.umpEnabled:
    let pkt = umpFromMidi1(msg[])
    var words: array[UmpMaxWords, uint32]
    for i in 0 ..< UmpMaxWords:
      words[i] = pkt.words[i]
    return lrmSendUmpSym(slot.handle,
      cast[ptr UncheckedArray[uint32]](addr words[0]),
      cint(pkt.wordCount)) == 0

  var data: array[3, uint8] = [msg.status, msg.data1, msg.data2]
  let status = msg.status and 0xF0'u8
  let length = if status == 0xC0'u8 or status == 0xD0'u8: 2 else: 3
  lrmSendMidi1Sym(slot.handle,
    cast[ptr UncheckedArray[uint8]](addr data[0]), cint(length)) == 0

proc lrmPoll(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  dst: ptr UncheckedArray[MidiMessage];
  maxCount: int32
): int32 {.cdecl, raises: [], gcsafe.} =
  ## MIDI 1.0 fallback: UMP сводится к `MidiMessage`. Пакеты, которые в
  ## MIDI 1.0 не выражаются (SysEx/Utility), пропускаются.
  let slot = slotOf(handle)
  if slot.isNil or not slot.inUse or dst.isNil or maxCount <= 0:
    return 0
  var count: int32 = 0
  var pkt: UmpMessage
  while count < maxCount and slot.ring.pop(pkt):
    var msg: MidiMessage
    if umpToMidiMessage(pkt, msg):
      dst[count] = msg
      inc count
  count

proc lrmPollUmp(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  dst: ptr UncheckedArray[UmpMessage];
  maxCount: int32
): int32 {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or not slot.inUse or dst.isNil or maxCount <= 0:
    return 0
  var count: int32 = 0
  var pkt: UmpMessage
  while count < maxCount and slot.ring.pop(pkt):
    dst[count] = pkt
    inc count
  count

proc lrmEnableUmp(api: ptr MidiBackendApi; handle: MidiPortHandle;
                  enabled: bool): bool {.cdecl, raises: [], gcsafe.} =
  let slot = slotOf(handle)
  if slot.isNil or not slot.inUse or slot.handle.isNil:
    return false
  if lrmEnableUmpSym(slot.handle, cint(if enabled: 1 else: 0)) != 0:
    return false
  slot.umpEnabled = enabled
  true

# ==============================================================================
# Создание / уничтожение (control-path)
# ==============================================================================

proc createLibremidiBackend*(log: Logger = silentLogger()): ptr MidiBackendApi =
  ## Собрать адаптер в shared-куче. Отсутствие библиотеки здесь не ошибка:
  ## `midiInit` вернёт `meUnavailable` (issue #267).
  let api = cast[ptr MidiBackendApi](allocShared0(sizeof(MidiBackendApi)))
  if api.isNil:
    return nil
  let pb = cast[ptr LrmBackend](allocShared0(sizeof(LrmBackend)))
  if pb.isNil:
    deallocShared(cast[pointer](api))
    return nil
  pb.log = log
  pb.initialized = false
  resetSlots(pb)
  lrmLib.setLibraryName(resolveLibraryName(LrmLibEnv, LrmLibDefault))

  api.backendName = cstring(LrmBackendName)
  api.impl = cast[pointer](pb)
  api.init = lrmInit
  api.shutdown = lrmShutdown
  api.portCount = lrmPortCount
  api.portInfo = lrmPortInfo
  api.openPort = lrmOpenPort
  api.closePort = lrmClosePort
  api.isPortOpen = lrmIsPortOpen
  api.send = lrmSend
  api.poll = lrmPoll
  api.enableUmp = lrmEnableUmp
  api.pollUmp = lrmPollUmp
  api

proc destroyLibremidiBackend*(api: ptr MidiBackendApi) =
  if api.isNil:
    return
  midiShutdown(api)
  let pb = implOf(api)
  if not pb.isNil:
    api.impl = nil
    deallocShared(cast[pointer](pb))
  deallocShared(cast[pointer](api))

{.pop.}

