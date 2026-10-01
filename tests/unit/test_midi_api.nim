# tests/unit/test_midi_api.nim
#
# Контракт MIDI-бэкенда (issue #28).
#
# Тест доказывает три вещи:
#   1. Core управляет MIDI через таблицу методов midi_api и не знает,
#      RtMidi там или ничего (fake-бэкенд определён здесь же, librtmidi
#      не нужна — `nimble test` зелёный на «чистой» машине);
#   2. nil-safe обёртки дают код ошибки, а не падение;
#   3. конвертация MIDI -> RealtimeEvent воспроизводит прежнюю реализацию
#      байт-в-байт (эталонные значения выписаны явно).

import std/[unittest, atomics, math]
import midi_api
import midi_events
import signal_types
import ring_buffer

const
  FakeInPorts = 2
  FakeOutPorts = 1

type
  FakeMidiState = object
    ring: SpscRingBuffer[MidiMessage, 128]
    opened: bool
    direction: MidiPortDirection
    outMessages: array[16, MidiMessage]
    outCount: int32

var fake: FakeMidiState

proc fakeInject(
  status, data1, data2: uint8;
  timestamp: float64;
  portId: int32 = 0
) =
  ## Имитация сообщения из callback'а драйвера.
  discard fake.ring.push(
    MidiMessage(
      status: status, data1: data1, data2: data2, reserved: 0'u8,
      timestamp: timestamp, portId: portId
    )
  )

# ----------------------------------------------------------------------------
# Реализация таблицы методов
# ----------------------------------------------------------------------------

proc fakeInit(api: ptr MidiBackendApi; log: ptr Logger): MidiError
    {.cdecl, raises: [], gcsafe.} =
  fake.ring.initRing()
  fake.opened = false
  fake.outCount = 0
  meOk

proc fakeShutdown(api: ptr MidiBackendApi) {.cdecl, raises: [], gcsafe.} =
  fake.opened = false

proc fakePortCount(api: ptr MidiBackendApi; dir: MidiPortDirection): int32
    {.cdecl, raises: [], gcsafe.} =
  if dir == mpdInput: int32(FakeInPorts) else: int32(FakeOutPorts)

proc fakePortInfo(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32;
  info: var MidiBackendPortInfo
): bool {.cdecl, raises: [], gcsafe.} =
  let limit = if dir == mpdInput: FakeInPorts else: FakeOutPorts
  if index < 0 or index >= int32(limit):
    return false
  info.id = index
  info.name = (if dir == mpdInput: "fake midi in " else: "fake midi out ") & $index
  info.direction = dir
  info.isDefault = index == 0
  true

proc fakeOpenPort(
  api: ptr MidiBackendApi;
  dir: MidiPortDirection;
  index: int32
): MidiPortHandle {.cdecl, raises: [], gcsafe.} =
  let limit = if dir == mpdInput: FakeInPorts else: FakeOutPorts
  if index < 0 or index >= int32(limit):
    return nil
  fake.ring.initRing()
  fake.opened = true
  fake.direction = dir
  cast[MidiPortHandle](addr fake)

proc fakeClosePort(api: ptr MidiBackendApi; handle: MidiPortHandle)
    {.cdecl, raises: [], gcsafe.} =
  fake.opened = false

proc fakeIsPortOpen(api: ptr MidiBackendApi; handle: MidiPortHandle): bool
    {.cdecl, raises: [], gcsafe.} =
  handle != nil and fake.opened

proc fakeSend(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  msg: ptr MidiMessage
): bool {.cdecl, raises: [], gcsafe.} =
  if not fake.opened or msg.isNil:
    return false
  if fake.outCount < int32(fake.outMessages.len):
    fake.outMessages[fake.outCount] = msg[]
    inc fake.outCount
  true

proc fakePoll(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  dst: ptr UncheckedArray[MidiMessage];
  maxCount: int32
): int32 {.cdecl, raises: [], gcsafe.} =
  if dst.isNil or maxCount <= 0:
    return 0
  var count: int32 = 0
  var msg: MidiMessage
  while count < maxCount and fake.ring.pop(msg):
    dst[count] = msg
    inc count
  count

proc fakeCreate(): ptr MidiBackendApi =
  let api = cast[ptr MidiBackendApi](allocShared0(sizeof(MidiBackendApi)))
  check api != nil
  api.backendName = cstring"fake-midi"
  api.impl = nil
  api.init = fakeInit
  api.shutdown = fakeShutdown
  api.portCount = fakePortCount
  api.portInfo = fakePortInfo
  api.openPort = fakeOpenPort
  api.closePort = fakeClosePort
  api.isPortOpen = fakeIsPortOpen
  api.send = fakeSend
  api.poll = fakePoll
  api

proc fakeDestroy(api: ptr MidiBackendApi) =
  if api.isNil:
    return
  deallocShared(cast[pointer](api))

# ==============================================================================
# Контракт
# ==============================================================================

suite "midi_api: nil-safe обёртки":
  test "нулевой указатель даёт код ошибки, а не падение":
    check midiInit(nil, nil) == meUnavailable
    check midiDeviceCount(nil, mpdInput) == 0
    var info: MidiBackendPortInfo
    check midiDeviceInfo(nil, mpdInput, 0, info) == false
    check midiOpenPort(nil, mpdInput, 0) == nil
    check midiIsPortOpen(nil, nil) == false
    var msg: MidiMessage
    check midiSend(nil, nil, addr msg) == false
    check midiPoll(nil, nil, nil, 0) == 0
    check midiBackendNameOf(nil) == "none"
    midiClosePort(nil, nil)
    midiShutdown(nil)

  test "адаптер заполняет всю таблицу методов":
    let api = fakeCreate()
    check api != nil
    check midiBackendNameOf(api) == "fake-midi"
    check api.init != nil
    check api.shutdown != nil
    check api.portCount != nil
    check api.portInfo != nil
    check api.openPort != nil
    check api.closePort != nil
    check api.isPortOpen != nil
    check api.send != nil
    check api.poll != nil
    fakeDestroy(api)

  test "перечисление портов идёт через контракт":
    let api = fakeCreate()
    check midiInit(api, nil) == meOk
    check midiDeviceCount(api, mpdInput) == int32(FakeInPorts)
    check midiDeviceCount(api, mpdOutput) == int32(FakeOutPorts)

    var info: MidiBackendPortInfo
    check midiDeviceInfo(api, mpdInput, 0, info)
    check info.name == "fake midi in 0"
    check info.direction == mpdInput
    check info.isDefault
    check midiDeviceInfo(api, mpdInput, 99, info) == false
    fakeDestroy(api)

  test "open -> poll -> close":
    let api = fakeCreate()
    discard midiInit(api, nil)

    let h = midiOpenPort(api, mpdInput, 0)
    check h != nil
    check midiIsPortOpen(api, h)

    fakeInject(0x90'u8, 60'u8, 100'u8, 0.0)

    var scratch: array[8, MidiMessage]
    let n = midiPoll(api, h, cast[ptr UncheckedArray[MidiMessage]](addr scratch[0]), 8)
    check n == 1
    check scratch[0].status == 0x90'u8
    check scratch[0].data1 == 60'u8
    check scratch[0].data2 == 100'u8

    # Кольцо опустошено: повторный poll ничего не отдаёт.
    check midiPoll(api, h, cast[ptr UncheckedArray[MidiMessage]](addr scratch[0]), 8) == 0

    midiClosePort(api, h)
    check midiIsPortOpen(api, h) == false
    fakeDestroy(api)

  test "send на выходном порту доходит до адаптера":
    let api = fakeCreate()
    discard midiInit(api, nil)
    let h = midiOpenPort(api, mpdOutput, 0)
    check h != nil

    var msg = MidiMessage(
      status: 0x90'u8, data1: 64'u8, data2: 127'u8, reserved: 0'u8
    )
    check midiSend(api, h, addr msg)
    check fake.outCount == 1
    check fake.outMessages[0].data1 == 64'u8
    fakeDestroy(api)

# ==============================================================================
# Конвертация MIDI -> RealtimeEvent (эталон прежней реализации)
# ==============================================================================

suite "midi_events: конвертация":
  test "Note On / Note Off":
    var q: EventQueue
    clearEvents(addr q)

    check pushMidiMessage(
      addr q,
      MidiMessage(status: 0x90'u8, data1: 60'u8, data2: 100'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0
    )
    check pushMidiMessage(
      addr q,
      MidiMessage(status: 0x80'u8, data1: 60'u8, data2: 0'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0
    )

    check q.count == 2
    check q.events[0].kind == evNoteOn
    check q.events[0].data[0] == 60.0f
    check abs(q.events[0].data[1] - 100.0f / 127.0f) < 1e-6f
    check q.events[1].kind == evNoteOff
    check q.events[1].data[0] == 60.0f
    check q.events[1].data[1] == 0.0f

  test "CC, Pitch Bend, Aftertouch, Program Change":
    var q: EventQueue
    clearEvents(addr q)

    check pushMidiMessage(addr q,
      MidiMessage(status: 0xB0'u8, data1: 7'u8, data2: 64'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0)
    # Центр pitch bend: data1=0, data2=0x40 -> 8192 -> ровно 0.0
    check pushMidiMessage(addr q,
      MidiMessage(status: 0xE0'u8, data1: 0'u8, data2: 0x40'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0)
    check pushMidiMessage(addr q,
      MidiMessage(status: 0xD0'u8, data1: 64'u8, data2: 0'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0)
    check pushMidiMessage(addr q,
      MidiMessage(status: 0xC0'u8, data1: 5'u8, data2: 0'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0)

    check q.count == 4
    check q.events[0].kind == evCC
    check q.events[0].data[0] == 7.0f
    check abs(q.events[0].data[1] - 64.0f / 127.0f) < 1e-6f

    check q.events[1].kind == evPitchBend
    check q.events[1].data[0] == 0.0f

    check q.events[2].kind == evAftertouch
    check abs(q.events[2].data[0] - 64.0f / 127.0f) < 1e-6f

    check q.events[3].kind == evProgramChange
    check q.events[3].data[0] == 5.0f

  test "неподдерживаемый статус пропускается":
    var q: EventQueue
    clearEvents(addr q)
    # 0xF8 — MIDI Clock (System Real-Time): не транслируется.
    check pushMidiMessage(addr q,
      MidiMessage(status: 0xF8'u8, timestamp: 0.0), 0'u8, 48000.0, 0.0) == false
    check q.count == 0

  test "channelFilter отсекает чужие каналы":
    var q: EventQueue
    clearEvents(addr q)
    # status 0x91 — канал 1, фильтр 0 -> сообщение отброшено.
    check pushMidiMessage(addr q,
      MidiMessage(status: 0x91'u8, data1: 60'u8, data2: 1'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0, channelFilter = 0) == false
    # status 0x90 — канал 0 -> проходит.
    check pushMidiMessage(addr q,
      MidiMessage(status: 0x90'u8, data1: 60'u8, data2: 1'u8, timestamp: 0.0),
      0'u8, 48000.0, 0.0, channelFilter = 0)
    check q.count == 1
    check q.events[0].channel == 0'u8

  test "frameOffset: кламп в [0, MaxBlockSize)":
    var q: EventQueue
    clearEvents(addr q)

    # Отрицательное время -> 0.
    check pushMidiMessage(addr q,
      MidiMessage(status: 0x90'u8, data1: 1'u8, data2: 1'u8, timestamp: -5.0),
      0'u8, 48000.0, 0.0)
    # Слишком далеко в будущем -> MaxBlockSize - 1.
    check pushMidiMessage(addr q,
      MidiMessage(status: 0x90'u8, data1: 2'u8, data2: 1'u8, timestamp: 10.0),
      0'u8, 48000.0, 0.0)

    check q.events[0].frameOffset == 0'u32
    check q.events[1].frameOffset == uint32(signal_types.MaxBlockSize - 1)

  test "pollMidiEvents раскладывает сообщения порта в EventQueue":
    let api = fakeCreate()
    discard midiInit(api, nil)
    let h = midiOpenPort(api, mpdInput, 0)
    check h != nil

    fakeInject(0x90'u8, 60'u8, 100'u8, 0.0)
    fakeInject(0x80'u8, 60'u8, 0'u8, 0.0)
    fakeInject(0xB0'u8, 1'u8, 127'u8, 0.0)

    var q: EventQueue
    clearEvents(addr q)
    let n = pollMidiEvents(api, h, 0'u8, 48000.0, 0.0, -1, addr q)

    check n == 3
    check q.count == 3
    check q.events[0].port == 0'u8
    check q.events[0].kind == evNoteOn
    check q.events[2].kind == evCC

    fakeDestroy(api)

# ==============================================================================
# Клампы таймстампа (issue #77)
# ==============================================================================

suite "midi_events: кламп таймстампа до приведения (#77)":
  test "«плохой» таймстамп клампится, а не даёт мусорный кадр":
    var ev: RealtimeEvent
    # Драйвер отдал время из другого источника: разница в миллионы секунд.
    # Раньше здесь был int32(1e6 * 48000) — приведение вне диапазона int32
    # (UB по стандарту C), и только потом клампы работали с мусором.
    check midiToEvent(
      MidiMessage(status: 0x90'u8, data1: 60'u8, data2: 100'u8,
                  timestamp: 1.0e6),
      0'u8, 48000.0, 0.0, ev)
    check ev.frameOffset == uint32(MaxBlockSize - 1)

    # Прошлое: ноль.
    var past: RealtimeEvent
    check midiToEvent(
      MidiMessage(status: 0x90'u8, data1: 60'u8, data2: 100'u8,
                  timestamp: -1.0e6),
      0'u8, 48000.0, 0.0, past)
    check past.frameOffset == 0'u32

    # NaN (пустое время драйвера) -> предсказуемый ноль.
    var nanEv: RealtimeEvent
    check midiToEvent(
      MidiMessage(status: 0x90'u8, data1: 60'u8, data2: 100'u8,
                  timestamp: NaN),
      0'u8, 48000.0, 0.0, nanEv)
    check nanEv.frameOffset == 0'u32

  test "нормальный таймстамп: поведение не изменилось":
    var ev: RealtimeEvent
    # Смещение ровно 64 кадра при 48 кГц.
    check midiToEvent(
      MidiMessage(status: 0x90'u8, data1: 60'u8, data2: 100'u8,
                  timestamp: 64.0 / 48000.0),
      0'u8, 48000.0, 0.0, ev)
    check ev.frameOffset == 64'u32
    check ev.kind == evNoteOn
