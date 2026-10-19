# core/ump.nim
#
# Universal MIDI Packet (UMP) — разбор и сборка (issue #38).
#
# Зачем в Core, а не в адаптере:
#   UMP — это не свойство библиотеки libremidi, а формат MIDI 2.0. Маппинг
#   UMP → `MidiMessage`/`RealtimeEvent` обязан жить там же, где маппинг
#   MIDI 1.0 (`core/midi_events.nim`), иначе Core начнёт зависеть от
#   конкретного бэкенда (§8, §27, §41, §42). Адаптер отдаёт «сырые» слова
#   UMP, а перевод — здесь.
#
# Что поддержано:
#   * MT 0x0 — Utility (JR Clock/Timestamp, Delta Clockstamp, Noop);
#   * MT 0x2 — MIDI 1.0 Channel Voice (32 бита);
#   * MT 0x4 — MIDI 2.0 Channel Voice (64 бита): 16-битные velocity/pressure,
#     32-битные CC/pitch bend;
#   * MT 0x3 — Data 64 (SysEx7) и MT 0x5 (Data 128) распознаются как
#     «данные», но в `MidiMessage` не конвертируются (у Core нет SysEx-канала);
#   * остальные типы (Flex Data, Stream, UMP Stream) — `ukUnsupported`.
#
# Потери при MIDI 2.0 → MIDI 1.0:
#   16-битная velocity/давление сводится к 7 битам округлением, 32-битный
#   CC — к 7 битам по старшим разрядам, pitch bend — к 14 битам. Это
#   документированный fallback: адаптер, которому нужны полные данные,
#   читает UMP напрямую (`midiPollUmp`).
#
# Модуль чистый (без I/O и без состояния): одна функция — один пакет.

import midi_api

# Типы UMP объявлены в контракте `midi_api` (там же их видят адаптеры),
# а разбор и сборка — здесь.
export midi_api

{.push raises: [].}

proc umpType*(word0: uint32): uint8 {.inline.} =
  ## Message Type: старшие 4 бита первого слова.
  uint8(word0 shr 28)

proc umpWordCount*(word0: uint32): int32 =
  ## Длина пакета по типу сообщения (по спецификации UMP 1.1).
  case umpType(word0)
  of 0x0, 0x1, 0x2: 1
  of 0x3, 0x4: 2
  of 0x5: 4
  of 0xB, 0xC: 3
  of 0xD, 0xF: 4
  else: 1

proc umpScale16To7*(value: uint32): uint8 {.inline.} =
  ## 16-битное значение MIDI 2.0 → 7 бит с округлением к ближайшему.
  ## `(v * 127 + 32767) div 65535` — без переполнения uint32.
  uint8(min(127'u32, (value * 127'u32 + 32767'u32) div 65535'u32))

proc umpScale32To7*(value: uint32): uint8 {.inline.} =
  ## 32-битное значение → 7 бит по старшим разрядам.
  uint8(value shr 25)

proc parseMidi1Channel(
  words: array[UmpMaxWords, uint32];
  outEvent: var UmpEvent
): bool =
  ## MT 0x2: MIDI 1.0 Channel Voice.
  let w = words[0]
  let status = uint8((w shr 20) and 0x0F'u32)
  outEvent.kind =
    case status
    of 0x8: umkNoteOff
    of 0x9: umkNoteOn
    of 0xA: umkPolyPressure
    of 0xB: umkControlChange
    of 0xC: umkProgramChange
    of 0xD: umkChannelPressure
    of 0xE: umkPitchBend
    else: umkUnsupported
  if outEvent.kind == umkUnsupported:
    return false
  outEvent.channel = uint8((w shr 16) and 0x0F'u32)
  outEvent.data1 = (w shr 8) and 0x7F'u32
  outEvent.data2 = w and 0x7F'u32
  outEvent.midi2 = false
  true

proc parseMidi2Channel(
  words: array[UmpMaxWords, uint32];
  outEvent: var UmpEvent
): bool =
  ## MT 0x4: MIDI 2.0 Channel Voice (64 бита).
  let w0 = words[0]
  let status = uint8((w0 shr 20) and 0x0F'u32)
  outEvent.kind =
    case status
    of 0x8: umkNoteOff
    of 0x9: umkNoteOn
    of 0xA: umkPolyPressure
    of 0xB: umkControlChange
    of 0xC: umkProgramChange
    of 0xD: umkChannelPressure
    of 0xE: umkPitchBend
    else: umkUnsupported
  if outEvent.kind == umkUnsupported:
    return false
  outEvent.channel = uint8((w0 shr 16) and 0x0F'u32)
  # Байт 2 (index) и байт 3 (data1) первого слова.
  let index = (w0 shr 8) and 0xFF'u32
  let data1 = w0 and 0xFF'u32
  outEvent.midi2 = true

  case outEvent.kind
  of umkNoteOn, umkNoteOff:
    # velocity — старшие 16 бит второго слова.
    outEvent.data1 = data1
    outEvent.data2 = words[1] shr 16
  of umkPolyPressure:
    outEvent.data1 = data1
    outEvent.data2 = words[1] shr 16
  of umkControlChange:
    outEvent.data1 = index
    outEvent.data2 = words[1]
  of umkProgramChange:
    outEvent.data1 = data1
    outEvent.data2 = 0
  of umkChannelPressure:
    outEvent.data1 = 0
    outEvent.data2 = words[1] shr 16
  of umkPitchBend:
    outEvent.data1 = 0
    outEvent.data2 = words[1]
  else:
    return false
  true


# ==============================================================================
# Разбор пакета
# ==============================================================================

proc umpParse*(
  words: array[UmpMaxWords, uint32];
  wordCount: int32;
  timestamp: float64 = 0.0
): UmpMessage =
  ## Разобрать пакет. `wordCount` отдаёт адаптер (он знает, сколько слов
  ## реально пришло); если он меньше требуемого по типу — пакет считается
  ## неполным и помечается `umkUnsupported`.
  result.words = words
  result.wordCount = wordCount
  result.timestamp = timestamp
  if wordCount <= 0:
    result.kind = umkUnsupported
    return
  let mt = umpType(words[0])
  result.group = uint8((words[0] shr 24) and 0x0F'u32)
  case mt
  of 0x0:
    result.kind = umkUtility
  of 0x1:
    result.kind = umkSystem
  of 0x2:
    var ev: UmpEvent
    if not parseMidi1Channel(words, ev):
      result.kind = umkUnsupported
    else:
      result.kind = ev.kind
  of 0x3, 0x5:
    result.kind = umkData
  of 0x4:
    var ev: UmpEvent
    if wordCount < 2 or not parseMidi2Channel(words, ev):
      result.kind = umkUnsupported
    else:
      result.kind = ev.kind
  else:
    result.kind = umkUnsupported

proc umpEventOf*(msg: UmpMessage; ev: var UmpEvent): bool =
  ## Разобрать канал-войс-пакет в терминах Core. `false` — пакет не
  ## канал-войс (utility/data/system, неподдержанный тип).
  ev = UmpEvent(group: msg.group)
  case umpType(msg.words[0])
  of 0x2:
    parseMidi1Channel(msg.words, ev)
  of 0x4:
    if msg.wordCount < 2:
      return false
    parseMidi2Channel(msg.words, ev)
  else:
    return false

# ==============================================================================
# UMP → MIDI 1.0 (fallback для контракта midi_api)
# ==============================================================================

proc umpToMidiMessage*(
  msg: UmpMessage;
  dst: var MidiMessage
): bool =
  ## Перевести пакет в `MidiMessage` (MIDI 1.0). Для MIDI 2.0 значения
  ## сводятся к 7/14 битам — это документированный fallback.
  dst = MidiMessage(timestamp: msg.timestamp, portId: int32(msg.group))
  let mt = umpType(msg.words[0])
  if mt == 0x1:
    # System Common/Real Time: байт статуса лежит в битах 23..16.
    let status = uint8((msg.words[0] shr 16) and 0xFF'u32)
    dst.status = status
    dst.data1 = uint8((msg.words[0] shr 8) and 0x7F'u32)
    dst.data2 = uint8(msg.words[0] and 0x7F'u32)
    return status >= 0xF0'u8

  var ev: UmpEvent
  if not umpEventOf(msg, ev):
    return false
  let status =
    case ev.kind
    of umkNoteOff: 0x80'u8
    of umkNoteOn: 0x90'u8
    of umkPolyPressure: 0xA0'u8
    of umkControlChange: 0xB0'u8
    of umkProgramChange: 0xC0'u8
    of umkChannelPressure: 0xD0'u8
    of umkPitchBend: 0xE0'u8
    else: return false
  dst.status = status or (ev.channel and 0x0F'u8)
  if not ev.midi2:
    dst.data1 = uint8(ev.data1 and 0x7F'u32)
    dst.data2 = uint8(ev.data2 and 0x7F'u32)
    return true

  case ev.kind
  of umkNoteOn, umkNoteOff, umkPolyPressure:
    dst.data1 = uint8(ev.data1 and 0x7F'u32)
    dst.data2 = umpScale16To7(ev.data2)
  of umkControlChange:
    dst.data1 = uint8(ev.data1 and 0x7F'u32)
    dst.data2 = umpScale32To7(ev.data2)
  of umkProgramChange:
    dst.data1 = uint8(ev.data1 and 0x7F'u32)
    dst.data2 = 0'u8
  of umkChannelPressure:
    dst.data1 = umpScale16To7(ev.data2)
    dst.data2 = 0'u8
  of umkPitchBend:
    # 32 бита → 14 бит (центр 0x80000000 → 8192).
    let bend = ev.data2 shr 18
    dst.data1 = uint8(bend and 0x7F'u32)
    dst.data2 = uint8((bend shr 7) and 0x7F'u32)
  else:
    return false
  true

# ==============================================================================
# MIDI 1.0 → UMP (отправка)
# ==============================================================================

proc umpFromMidi1*(msg: MidiMessage; group: uint8 = 0'u8): UmpMessage =
  ## Собрать 32-битный UMP MT 0x2 из MIDI 1.0 сообщения. Так адаптер
  ## отправляет в порт, умеющий только UMP.
  result.wordCount = 1
  result.group = group and 0x0F'u8
  result.timestamp = msg.timestamp
  result.words[0] = (0x2'u32 shl 28) or
                    (uint32(result.group) shl 24) or
                    (uint32(msg.status) shl 16) or
                    (uint32(msg.data1 and 0x7F'u8) shl 8) or
                    uint32(msg.data2 and 0x7F'u8)
  var ev: UmpEvent
  if parseMidi1Channel(result.words, ev):
    result.kind = ev.kind
  else:
    result.kind = umkUnsupported

{.pop.}
