# midi_events.nim
#
# Конвертация MIDI -> RealtimeEvent (issue #28).
#
# Почему это Core, а не Commons:
#   Прежний `commons/midi_io.nim` импортировал `signal_types` и сам
#   превращал MIDI в `RealtimeEvent` — то есть Commons знал про Core
#   (MANIFEST §25/§26). Теперь трансляция живёт здесь, рядом с типами
#   событий, а Commons остаётся нейтральным.
#
# Логика перевода сохранена байт-в-байт от прежней реализации, чтобы
# поведение не «поехало» при переносе:
#   status = msg.status and 0xF0, channel = msg.status and 0x0F,
#   frameOffset = (timestamp - hostTime) * sampleRate c клампом в [0, MaxBlock],
#   0xE0 Pitch Bend нормализуется в [-1, 1] от центра 8192.
#
# Realtime-path: `pollMidiEvents` не аллоцирует (scratch — на стеке),
# не блокируется и не бросает исключений.

import signal_types
import midi_api

{.push raises: [].}

proc midiToEvent*(
  msg: MidiMessage;
  portIndex: uint8;
  sampleRate: float64;
  currentHostTimeSec: float64;
  ev: var RealtimeEvent
): bool =
  ## Переводит одно MIDI-сообщение в RealtimeEvent.
  ##
  ## Возвращает false для неподдерживаемых статусов (System Common/RealTime,
  ## Sysex): такие сообщения молча пропускаются, как и раньше.
  let status = msg.status and 0xF0'u8
  let channel = msg.status and 0x0F'u8

  # Абсолютное время MIDI (секунды) -> относительное смещение в кадрах блока.
  let timeDiffSec = msg.timestamp - currentHostTimeSec
  var frameOffset = int32(timeDiffSec * sampleRate)

  if frameOffset < 0:
    frameOffset = 0
  if frameOffset >= signal_types.MaxBlockSize:
    frameOffset = signal_types.MaxBlockSize - 1

  ev.frameOffset = uint32(frameOffset)
  ev.subFrame = 0.0f
  ev.port = portIndex
  ev.channel = channel

  case status
  of 0x90'u8:                       # Note On
    ev.kind = evNoteOn
    ev.data[0] = float32(msg.data1)
    ev.data[1] = float32(msg.data2) / 127.0f
  of 0x80'u8:                       # Note Off
    ev.kind = evNoteOff
    ev.data[0] = float32(msg.data1)
    ev.data[1] = 0.0f
  of 0xB0'u8:                       # Control Change
    ev.kind = evCC
    ev.data[0] = float32(msg.data1)
    ev.data[1] = float32(msg.data2) / 127.0f
  of 0xE0'u8:                       # Pitch Bend (14 бит, центр 8192)
    ev.kind = evPitchBend
    let bend = (int32(msg.data2) shl 7) or int32(msg.data1)
    ev.data[0] = float32(bend - 8192) / 8192.0f
  of 0xD0'u8:                       # Channel Aftertouch
    ev.kind = evAftertouch
    ev.data[0] = float32(msg.data1) / 127.0f
  of 0xC0'u8:                       # Program Change
    ev.kind = evProgramChange
    ev.data[0] = float32(msg.data1)
  else:
    return false

  true

proc pushMidiMessage*(
  output: ptr EventQueue;
  msg: MidiMessage;
  portIndex: uint8;
  sampleRate: float64;
  currentHostTimeSec: float64;
  channelFilter: int32 = -1
): bool =
  ## Фильтр по каналу + перевод + push в очередь событий.
  ##
  ## channelFilter < 0 — фильтра нет (прежнее поведение).
  let channel = msg.status and 0x0F'u8

  if channelFilter >= 0 and int32(channel) != channelFilter:
    return false

  var ev: RealtimeEvent
  if midiToEvent(msg, portIndex, sampleRate, currentHostTimeSec, ev):
    return output.pushEvent(ev)
  false

const
  # Размер «спарклайна» для одного вызова poll: сообщения из драйвера
  # за блок редко превышают десятки, больше 256 — уже аномалия.
  MidiPollScratchSize* = 256

proc pollMidiEvents*(
  api: ptr MidiBackendApi;
  handle: MidiPortHandle;
  portIndex: uint8;
  sampleRate: float64;
  currentHostTimeSec: float64;
  channelFilter: int32;
  output: ptr EventQueue
): int32 =
  ## Realtime-path: слить порт и разложить сообщения по очереди событий.
  ##
  ## НЕ очищает и НЕ сортирует `output`: этим владеет вызывающий (см.
  ## прежний `pollMidiEvents`, который сам делал clearEvents/sortEvents
  ## по всем портам сразу).
  if output.isNil:
    return 0

  var scratch: array[MidiPollScratchSize, MidiMessage]
  let n = midiPoll(
    api,
    handle,
    cast[ptr UncheckedArray[MidiMessage]](addr scratch[0]),
    int32(MidiPollScratchSize)
  )

  var i: int32 = 0
  var pushed: int32 = 0
  while i < n:
    if pushMidiMessage(
      output,
      scratch[i],
      portIndex,
      sampleRate,
      currentHostTimeSec,
      channelFilter
    ):
      inc pushed
    inc i

  pushed

{.pop.}
