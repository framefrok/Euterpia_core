# tests/unit/test_midi_smf.nim
#
# Нейтральный SMF-кодек Commons (issue #28).
#
# Тест фиксирует главное требование issue: `commons/midi_io.nim` больше не
# знает ни про RtMidi/dynlib, ни про signal_types, ни про собственное
# кольцо — остался чистый файловый кодек. Проверяется round-trip
# encode -> parse и устойчивость к битым данным.

import std/unittest
import midi_io

suite "commons/midi_io: VLQ":
  test "encodeVarLen/decodeVarLen — обратимые":
    for v in [0'u32, 1, 127, 128, 255, 16383, 16384, 0x0FFFFFFF'u32]:
      let enc = encodeVarLen(v)
      var pos = 0
      check decodeVarLen(enc, pos) == v
      check pos == enc.len

  test "обрыв данных не зацикливает декодер":
    let broken = @[0x80'u8]   # старший бит говорит «продолжение», а байтов нет
    var pos = 0
    discard decodeVarLen(broken, pos)
    check pos == broken.len

suite "commons/midi_io: SMF round-trip":
  test "формат 1, две дорожки, события восстанавливаются":
    var f: SmfFile
    f.format = 1
    f.division = 480

    var t0: SmfTrack
    t0.events = @[
      SmfEvent(tick: 0'u32, status: 0x90'u8, data1: 60'u8, data2: 100'u8),
      SmfEvent(tick: 480'u32, status: 0x80'u8, data1: 60'u8, data2: 0'u8)
    ]

    var t1: SmfTrack
    t1.events = @[
      SmfEvent(tick: 0'u32, status: 0xB0'u8, data1: 7'u8, data2: 64'u8),
      SmfEvent(tick: 240'u32, status: 0xE0'u8, data1: 0'u8, data2: 0x40'u8)
    ]

    f.tracks = @[t0, t1]

    let bytes = encodeSmf(f)
    check bytes.len > 14

    let parsed = parseSmf(bytes)
    check parsed.ok
    check parsed.file.format == 1'u16
    check parsed.file.division == 480'u16
    check parsed.file.tracks.len == 2

    check parsed.file.tracks[0].events.len == 2
    check parsed.file.tracks[0].events[0].tick == 0'u32
    check parsed.file.tracks[0].events[0].status == 0x90'u8
    check parsed.file.tracks[0].events[0].data1 == 60'u8
    check parsed.file.tracks[0].events[0].data2 == 100'u8
    check parsed.file.tracks[0].events[1].tick == 480'u32
    check parsed.file.tracks[0].events[1].status == 0x80'u8

    check parsed.file.tracks[1].events.len == 2
    check parsed.file.tracks[1].events[0].status == 0xB0'u8
    check parsed.file.tracks[1].events[1].tick == 240'u32
    check parsed.file.tracks[1].events[1].status == 0xE0'u8
    check parsed.file.tracks[1].events[1].data2 == 0x40'u8

  test "пустой файл (без дорожек) не считается битым":
    var f: SmfFile
    f.format = 0
    f.division = 96
    let bytes = encodeSmf(f)
    let parsed = parseSmf(bytes)
    check parsed.ok
    check parsed.file.tracks.len == 0

  test "битый заголовок -> ok = false, без падения":
    check parseSmf(@[]).ok == false
    check parseSmf(@[0x4D'u8, 0x54'u8, 0x68'u8, 0x64'u8]).ok == false
    # Правильная сигнатура, но мусор в длине заголовка.
    let bad = @[
      0x4D'u8, 0x54'u8, 0x68'u8, 0x64'u8,   # "MThd"
      0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,   # абсурдная длина
      0x00'u8, 0x00'u8
    ]
    check parseSmf(bad).ok == false
