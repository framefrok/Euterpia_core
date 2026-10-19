# tests/unit/test_ump.nim
#
# UMP / MIDI 2.0 (issue #38).
#
# Проверяется то, что нельзя проверить «на слух»:
#   * 32-битный MIDI 1.0 UMP разбирается без потерь (группа, канал, данные);
#   * 64-битный MIDI 2.0 Note On: 16-битная velocity сводится к 7 битам
#     округлением, нота и канал сохраняются;
#   * 32-битные CC/pitch bend сводятся к 7/14 битам по старшим разрядам;
#   * сборка MIDI 1.0 → UMP → разбор даёт те же байты;
#   * Utility/System/Data не маскируются под канал-войс;
#   * адаптер libremidi без библиотеки отдаёт meUnavailable, а не падает.

import std/[unittest, os]

import midi_api
import ump
import midi_backend_libremidi

proc midi1(group, statusByte, data1, data2: uint32): uint32 =
  ## `statusByte` — полный байт (0x90|канал), как в MIDI 1.0.
  (0x2'u32 shl 28) or (group shl 24) or (statusByte shl 16) or
  (data1 shl 8) or data2

proc midi2(group, status, channel, index, data1, data2: uint32):
    array[UmpMaxWords, uint32] =
  result[0] = (0x4'u32 shl 28) or (group shl 24) or (status shl 20) or
              (channel shl 16) or (index shl 8) or data1
  result[1] = data2

suite "ump: разбор и сборка (#38)":

  test "MIDI 1.0 UMP: группа, канал и данные без потерь":
    var words: array[UmpMaxWords, uint32]
    words[0] = midi1(3, 0x90, 60, 100)
    let pkt = umpParse(words, 1, 1.5)
    check pkt.kind == umkNoteOn
    check pkt.group == 3'u8
    check pkt.wordCount == 1

    var ev: UmpEvent
    check umpEventOf(pkt, ev)
    check ev.channel == 0'u8      # status 0x9 без канала
    check ev.data1 == 60'u32
    check ev.data2 == 100'u32
    check not ev.midi2

    # Канал в младшем ниббле статуса.
    words[0] = midi1(0, 0x9C, 61, 127)
    let pkt2 = umpParse(words, 1)
    check umpEventOf(pkt2, ev)
    check ev.channel == 12'u8
    check ev.data1 == 61'u32

  test "MIDI 2.0 Note On: velocity 16→7 бит с округлением":
    let words = midi2(1, 0x9, 5, 0, 60, 0xFFFF'u32 shl 16)
    let pkt = umpParse(words, 2, 2.0)
    check pkt.kind == umkNoteOn
    check pkt.group == 1'u8
    var ev: UmpEvent
    check umpEventOf(pkt, ev)
    check ev.midi2
    check ev.channel == 5'u8
    check ev.data1 == 60'u32
    check ev.data2 == 0xFFFF'u32

    var msg: MidiMessage
    check umpToMidiMessage(pkt, msg)
    check msg.status == 0x95'u8
    check msg.data1 == 60'u8
    check msg.data2 == 127'u8
    check msg.timestamp == 2.0

    # Половина диапазона: 0x8000 → 64 (round(0x8000*127/65535) = 64).
    let half = midi2(0, 0x9, 0, 0, 60, 0x8000'u32 shl 16)
    var msgHalf: MidiMessage
    check umpToMidiMessage(umpParse(half, 2), msgHalf)
    check msgHalf.data2 == 64'u8

  test "MIDI 2.0 CC и pitch bend: 32→7/14 бит":
    let cc = midi2(0, 0xB, 2, 7, 0, 0xFFFFFFFF'u32)
    let pkt = umpParse(cc, 2)
    check pkt.kind == umkControlChange
    var msg: MidiMessage
    check umpToMidiMessage(pkt, msg)
    check msg.status == 0xB2'u8
    check msg.data1 == 7'u8        # номер CC в index-байте
    check msg.data2 == 127'u8

    # Центр 32-битного bend = 0x80000000 → 8192 (14 бит).
    let center = midi2(0, 0xE, 1, 0, 0, 0x80000000'u32)
    var bend: MidiMessage
    check umpToMidiMessage(umpParse(center, 2), bend)
    check bend.status == 0xE1'u8
    check (int(bend.data2) shl 7 or int(bend.data1)) == 8192

    # Максимум → 16383.
    let top = midi2(0, 0xE, 1, 0, 0, 0xFFFFFFFF'u32)
    var bendTop: MidiMessage
    check umpToMidiMessage(umpParse(top, 2), bendTop)
    check (int(bendTop.data2) shl 7 or int(bendTop.data1)) == 16383

  test "MIDI 1.0 → UMP → разбор: round-trip":
    let src = MidiMessage(status: 0x93'u8, data1: 42'u8, data2: 99'u8,
                          timestamp: 0.25)
    let pkt = umpFromMidi1(src, 2'u8)
    check pkt.kind == umkNoteOn
    check pkt.group == 2'u8
    var back: MidiMessage
    check umpToMidiMessage(pkt, back)
    check back.status == src.status
    check back.data1 == src.data1
    check back.data2 == src.data2

  test "Utility/System/Data не считаются канал-войсом":
    var words: array[UmpMaxWords, uint32]
    words[0] = 0x00000000'u32          # Utility Noop
    let noop = umpParse(words, 1)
    check noop.kind == umkUtility
    var ev: UmpEvent
    check not umpEventOf(noop, ev)

    words[0] = 0x10000000'u32          # System Real Time (MT 0x1)
    let system = umpParse(words, 1)
    check system.kind == umkSystem

    words[0] = 0x30000000'u32          # Data 64 (SysEx7)
    let data = umpParse(words, 2)
    check data.kind == umkData

    words[0] = 0xD0000000'u32          # Flex Data — не поддержано
    let flex = umpParse(words, 2)
    check flex.kind == umkUnsupported

  test "длина пакета по типу сообщения":
    check umpWordCount(0x00000000'u32) == 1
    check umpWordCount(0x20000000'u32) == 1
    check umpWordCount(0x30000000'u32) == 2
    check umpWordCount(0x40000000'u32) == 2
    check umpWordCount(0x50000000'u32) == 4
    check umpWordCount(0xF0000000'u32) == 4

suite "libremidi: отсутствие библиотеки — не падение (#38)":

  test "midiInit без библиотеки даёт meUnavailable":
    let api = createLibremidiBackend()
    doAssert api != nil
    defer: destroyLibremidiBackend(api)

    # Имя заведомо несуществующей библиотеки: ветка "нет библиотеки".
    putEnv("EUTERPIA_LIBREMIDI_LIB", "/nonexistent/libeuterpia_libremidi.so")
    let err = midiInit(api, nil)
    delEnv("EUTERPIA_LIBREMIDI_LIB")
    check err == meUnavailable
    check midiDeviceCount(api, mpdInput) == 0
    check midiDeviceCount(api, mpdOutput) == 0
