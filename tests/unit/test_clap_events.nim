# tests/unit/test_clap_events.nim
#
# Конвертация событий и аудио-буферов на границе Core ↔ CLAP (issue #7).
#
# Проверяется БЕЗ реального плагина: это чистые функции clap_host, поэтому
# тест входит в обычный `nimble test` (сквозной путь с mock-плагином —
# отдельно, `nimble clapMock`).
#
# Что доказывается:
#   - события EventQueue не теряются: CC / pitch bend / aftertouch /
#     program change уходят в CLAP как clap_event_midi (раньше молча
#     отбрасывались) и возвращаются тем же типом;
#   - `frameOffset` сохраняется (sample-accurate трансляция);
#   - note-on с velocity 0 трактуется как note-off (конвенция MIDI);
#   - переполнение хранилища событий отвергается, а не портит память;
#   - порты/каналы клампятся к MaxAudioPorts (1/1, 2/2, 2/4 и «толстые»
#     буферы не выходят за границы фиксированных массивов).

import std/[unittest, math]
import signal_types
import node_interface
import clap_host

proc headerOf(storage: var ClapEventStorage): ptr ClapEventHeader =
  cast[ptr ClapEventHeader](addr storage.events[0])

suite "clap events: RT → CLAP → RT":
  test "note-on/note-off сохраняют время, канал, ноту и velocity":
    var storage: ClapEventStorage
    var ev = RealtimeEvent(
      frameOffset: 64'u32, kind: evNoteOn, channel: 3'u8,
      data: [60.0f, 0.75f, 0.0f, 0.0f])

    check convertRtEventToClap(ev, storage)
    check storage.count == 1
    let hdr = headerOf(storage)
    check hdr.eventType == ClapEvtNoteOn
    check hdr.time == 64'u32

    let back = convertClapEventToRt(hdr)
    check back.kind == evNoteOn
    check back.frameOffset == 64'u32
    check back.channel == 3'u8
    check back.data[0] == 60.0f
    check abs(back.data[1] - 0.75f) < 1e-5f

  test "CC сохраняется как MIDI-сообщение и возвращается тем же типом":
    # CC: data[0] — номер контроллера, data[1] — нормированное значение.
    var storage: ClapEventStorage
    var ev = RealtimeEvent(
      frameOffset: 10'u32, kind: evCC, channel: 5'u8,
      data: [74.0f, 0.5f, 0.0f, 0.0f])
    check convertRtEventToClap(ev, storage)
    let back = convertClapEventToRt(headerOf(storage))
    check back.kind == evCC
    check back.channel == 5'u8
    check back.frameOffset == 10'u32
    check back.data[0] == 74.0f
    check abs(back.data[1] - 0.5f) < 0.01f        # 7-битная квантовка

  test "pitch bend / aftertouch / program change не теряются":
    # Pitch bend: [-1, 1] -> 14 бит и обратно.
    for v in [-1.0f, -0.25f, 0.0f, 0.25f, 1.0f]:
      var s: ClapEventStorage
      var pb = RealtimeEvent(
        frameOffset: 0'u32, kind: evPitchBend, channel: 2'u8,
        data: [v, 0.0f, 0.0f, 0.0f])
      check convertRtEventToClap(pb, s)
      let back = convertClapEventToRt(headerOf(s))
      check back.kind == evPitchBend
      check back.channel == 2'u8
      # 14-битный bend не представляет ровно +1.0 (максимум 8191/8192),
      # поэтому допуск — один шаг квантования.
      check abs(back.data[0] - v) <= 1.0f / 8192.0f + 1e-6f

    var s2: ClapEventStorage
    var at = RealtimeEvent(
      frameOffset: 1'u32, kind: evAftertouch, channel: 1'u8,
      data: [0.9f, 0.0f, 0.0f, 0.0f])
    check convertRtEventToClap(at, s2)
    let backAt = convertClapEventToRt(headerOf(s2))
    check backAt.kind == evAftertouch
    check abs(backAt.data[0] - 0.9f) < 0.01f

    var s3: ClapEventStorage
    var pc = RealtimeEvent(
      frameOffset: 2'u32, kind: evProgramChange, channel: 0'u8,
      data: [42.0f, 0.0f, 0.0f, 0.0f])
    check convertRtEventToClap(pc, s3)
    let backPc = convertClapEventToRt(headerOf(s3))
    check backPc.kind == evProgramChange
    check backPc.data[0] == 42.0f

  test "сырое MIDI-событие разбирается по статус-байту":
    # Так выглядит out-event плагина: clap_event_midi -> RealtimeEvent.
    var s: ClapEventStorage
    check pushMidiToClap(s, 7'u32, 0xB1'u8, 74'u8, 64'u8)
    let back = convertClapEventToRt(headerOf(s))
    check back.kind == evCC
    check back.channel == 1'u8
    check back.frameOffset == 7'u32
    check back.data[0] == 74.0f
    check abs(back.data[1] - 64.0f / 127.0f) < 1e-5f

  test "note-on с velocity 0 трактуется как note-off":
    var s: ClapEventStorage
    check pushMidiToClap(s, 0'u32, 0x90'u8, 60'u8, 0'u8)
    let back = convertClapEventToRt(headerOf(s))
    check back.kind == evNoteOff
    check back.data[0] == 60.0f

  test "неизвестный статус MIDI даёт evTrigger с сырыми байтами":
    var s: ClapEventStorage
    check pushMidiToClap(s, 0'u32, 0xF8'u8, 1'u8, 2'u8)
    let back = convertClapEventToRt(headerOf(s))
    check back.kind == evTrigger
    check back.data[0] == float32(0xF8)

  test "переполнение хранилища событий отвергается":
    var storage: ClapEventStorage
    let ev = RealtimeEvent(
      kind: evNoteOn, data: [60.0f, 1.0f, 0.0f, 0.0f])
    for i in 0 ..< MaxBlockEvents:
      check convertRtEventToClap(ev, storage)
    check storage.count == MaxBlockEvents
    check not convertRtEventToClap(ev, storage)
    check storage.count == MaxBlockEvents


suite "clap events: аудио-буферы и порты":
  test "setupClapAudioBuffer строит planar-указатели по каналам":
    var data: array[32, float32]
    var buf = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr data[0]),
      channels: 2, frames: 4, stride: 4)

    var ptrs: ChannelPtrs
    var clapBuf: ClapAudioBuffer
    setupClapAudioBuffer(addr buf, ptrs, clapBuf)

    check clapBuf.channelCount == 2'u32
    check clapBuf.data32 != nil
    check clapBuf.data64 == nil
    check cast[uint](ptrs[0]) == cast[uint](addr data[0])
    check cast[uint](ptrs[1]) == cast[uint](addr data[4])

  test "число каналов клампится к MaxAudioPorts (нет записи за массив)":
    var data: array[32, float32]
    # «Толстый» буфер: каналов больше, чем слотов в ChannelPtrs.
    var wide = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr data[0]),
      channels: int32(MaxAudioPorts + 4), frames: 4, stride: 4)

    var ptrs: ChannelPtrs
    var clapBuf: ClapAudioBuffer
    setupClapAudioBuffer(addr wide, ptrs, clapBuf)

    # Плагину сообщается РОВНО столько каналов, сколько есть указателей.
    check clapBuf.channelCount == uint32(MaxAudioPorts)
    check ptrs[MaxAudioPorts - 1] != nil
    check cast[uint](ptrs[MaxAudioPorts - 1]) ==
      cast[uint](addr data[(MaxAudioPorts - 1) * 4])

  test "пустой буфер даёт channelCount 0 и nil-указатели":
    var ptrs: ChannelPtrs
    var clapBuf: ClapAudioBuffer
    setupClapAudioBuffer(nil, ptrs, clapBuf)
    check clapBuf.channelCount == 0'u32
    check clapBuf.data32 == nil
    check clapBuf.data64 == nil

  test "интерлив-буфер (stride != frames) даёт последовательные каналы":
    var data: array[8, float32]
    var buf = AudioBuffer(
      data: cast[ptr UncheckedArray[float32]](addr data[0]),
      channels: 2, frames: 4, stride: 1)

    var ptrs: ChannelPtrs
    var clapBuf: ClapAudioBuffer
    setupClapAudioBuffer(addr buf, ptrs, clapBuf)

    check clapBuf.channelCount == 2'u32
    check cast[uint](ptrs[0]) == cast[uint](addr data[0])
    check cast[uint](ptrs[1]) == cast[uint](addr data[1])

