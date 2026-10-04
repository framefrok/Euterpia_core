# tests/unit/test_midi_export.nim
#
# Экспорт проекта EUTERPIA в Standard MIDI File (libs/midi_export).
#
# Что фиксирует тест:
#   * проект → SMF: формат 1 (дорожка-дирижёр + по дорожке на трек с нотами);
#   * позиции не пересчитываются: тики совпадают с проектом (PPQ);
#   * клип обрезает ноты своей границей — как `core/sequencer`;
#   * зацикленный клип повторяется до конца песни;
#   * мета-события (имя, темп, размер) пишутся и читаются обратно;
#   * разбивка на файлы: по файлу на инструмент, каждый валиден;
#   * проект без нот не роняет экспорт (валидный файл с дирижёром).

import std/[os, strutils, unittest]

import project
import transport
import midi_io
import midi_export

# ==============================================================================
# Помощники сборки проекта
# ==============================================================================

proc note(pitch: int; startTick, duration: int32; vel = 100; ch = 0): NoteFormat =
  NoteFormat(startTick: startTick, duration: duration, pitch: uint8(pitch),
             velocity: uint8(vel), channel: uint8(ch))

proc track(name: string; id: int32; clips: seq[ClipFormat]): TrackFormat =
  TrackFormat(id: id, name: name, trackType: 0, clips: clips,
              volume: 1.0f32, pan: 0.0f32)

proc clip(id: int32; name: string; startTick, lengthTicks: int32;
          looped: bool; notes: seq[NoteFormat]): ClipFormat =
  ClipFormat(id: id, clipType: 0, name: name, startTick: startTick,
             lengthTicks: lengthTicks, loopEnabled: looped, notes: notes,
             audioBufferId: -1)

proc project(name: string; tempo: float32; tracks: seq[TrackFormat]): ProjectFormat =
  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.metadata = ProjectMetadata(
    name: name, author: "", sampleRate: 48000.0f32, tempo: tempo,
    timeSignature: TimeSignatureFormat(numerator: 4, denominator: 4),
    created: "", modified: "")
  result.sequencer.tracks = tracks

proc countNotes(t: SmfTrack): int =
  ## Число Note On (0x9n с ненулевой velocity) — «сколько нот в дорожке».
  for e in t.events:
    if (e.status and 0xF0'u8) == 0x90'u8 and e.data2 > 0'u8:
      inc result

proc onTicks(t: SmfTrack): seq[uint32] =
  for e in t.events:
    if (e.status and 0xF0'u8) == 0x90'u8 and e.data2 > 0'u8:
      result.add e.tick

proc metaOf(t: SmfTrack; metaType: uint8): seq[byte] =
  for m in t.meta:
    if m.metaType == metaType:
      return m.data

# ==============================================================================

suite "midi_export: проект → SMF":
  test "формат 1: дирижёр + дорожка на каждый непустой трек":
    let ppq = PpqTicksPerQuarter
    let p = project("Test", 100.0f32, @[
      track("harp", 1, @[clip(1, "harp", 0, 4 * ppq, false,
        @[note(60, 0, ppq), note(64, ppq, ppq)])]),
      track("lute", 2, @[clip(1, "lute", 0, 4 * ppq, false,
        @[note(62, ppq * 2, ppq)])]),
      # пустая дорожка не должна попасть в файл
      track("silent", 3, @[clip(1, "silent", 0, 4 * ppq, false, @[])])
    ])

    let f = toSmf(p)
    check f.format == 1'u16
    check f.division == uint16(ppq)
    check f.tracks.len == 3          # дирижёр + harp + lute (silent пропущен)
    check f.tracks[1].countNotes == 2
    check f.tracks[2].countNotes == 1

  test "позиции нот равны тикам проекта, Note Off учитывает длительность":
    let ppq = PpqTicksPerQuarter
    let p = project("T", 120.0f32, @[
      track("a", 1, @[clip(1, "a", ppq, 4 * ppq, false,
        @[note(60, 0, ppq div 2)])])])
    let f = toSmf(p)
    let t = f.tracks[1]
    check t.onTicks == @[uint32(ppq)]
    # Note Off — на позицию клипа + длительность ноты
    var offTick = 0'u32
    for e in t.events:
      if (e.status and 0xF0'u8) == 0x80'u8:
        offTick = e.tick
    check offTick == uint32(ppq + ppq div 2)

  test "клип обрезает ноту своей границей":
    let ppq = PpqTicksPerQuarter
    # нота длиной 4 доли, но клип всего 1 доля
    let p = project("T", 120.0f32, @[
      track("a", 1, @[clip(1, "a", 0, ppq, false, @[note(60, 0, 4 * ppq)])])])
    let t = toSmf(p).tracks[1]
    var offTick = 0'u32
    for e in t.events:
      if (e.status and 0xF0'u8) == 0x80'u8:
        offTick = e.tick
    check offTick == uint32(ppq)     # обрезано границей клипа, а не 4 долями

  test "зацикленный клип повторяется до конца песни":
    let ppq = PpqTicksPerQuarter
    let p = project("T", 120.0f32, @[
      track("loop", 1, @[clip(1, "loop", 0, ppq, true, @[note(60, 0, ppq div 2)])]),
      track("long", 2, @[clip(1, "long", 0, 4 * ppq, false, @[note(48, 0, ppq)])])])
    let t = toSmf(p).tracks[1]
    # песня длиной 4 такта (второй трек), клип 1 доля -> 4 повтора
    check t.countNotes == 4
    check t.onTicks == @[0'u32, uint32(ppq), uint32(2 * ppq), uint32(3 * ppq)]

  test "проект без нот даёт валидный файл с темпом":
    let p = project("Empty", 96.0f32, @[
      track("a", 1, @[clip(1, "a", 0, 4 * PpqTicksPerQuarter, false, @[])])])
    let f = toSmf(p)
    check f.format == 0'u16
    check f.tracks.len == 1
    check f.tracks[0].metaOf(0x51'u8).len == 3
    check f.tracks[0].countNotes == 0

suite "midi_export: байты и файлы":
  test "encode → parse: мета и ноты выживают":
    let ppq = PpqTicksPerQuarter
    let p = project("Round", 100.0f32, @[
      track("harp", 1, @[clip(1, "harp", 0, 4 * ppq, false,
        @[note(60, 0, ppq, 100, 3), note(64, ppq, ppq, 90, 3)])])])
    let bytes = encodeSmf(toSmf(p))
    let parsed = parseSmf(bytes)
    check parsed.ok
    check parsed.file.format == 1'u16
    check parsed.file.division == uint16(ppq)
    check parsed.file.tracks.len == 2
    # Дирижёр: темп 100 BPM = 600000 мкс/четверть = 0x09 0x27 0xC0.
    check parsed.file.tracks[0].metaOf(0x51'u8) == @[byte(0x09), byte(0x27), byte(0xC0)]
    # Размер 4/4: nn=4, dd=log2(4)=2, cc=24, bb=8.
    check parsed.file.tracks[0].metaOf(0x58'u8) == @[byte(4), byte(2), byte(24), byte(8)]
    # Имя дорожки «harp».
    var nameBytes: seq[byte] = @[]
    for ch in "harp":
      nameBytes.add byte(ord(ch))
    check parsed.file.tracks[1].metaOf(0x03'u8) == nameBytes
    # Ноты и тики.
    check parsed.file.tracks[1].countNotes == 2
    check parsed.file.tracks[1].onTicks == @[0'u32, uint32(ppq)]
    # Канал из проекта (3) сохранён в статусе 0x9n.
    var ch = -1
    for e in parsed.file.tracks[1].events:
      if (e.status and 0xF0'u8) == 0x90'u8 and e.data2 > 0'u8:
        ch = int(e.status and 0x0F'u8)
    check ch == 3

  test "один файл и разбивка по инструментам читаются обратно":
    let ppq = PpqTicksPerQuarter
    let p = project("Files", 100.0f32, @[
      track("harp", 1, @[clip(1, "harp", 0, 4 * ppq, false, @[note(60, 0, ppq)])]),
      track("lute", 2, @[clip(1, "lute", 0, 4 * ppq, false,
        @[note(62, 0, ppq), note(64, ppq, ppq)])])])

    let dir = getTempDir() / "eut_midi_export_test"
    if dirExists(dir):
      removeDir(dir)

    let one = writeMidi(p, dir / "all.mid")
    check one.files.len == 1
    check one.tracks == 2
    check one.notes == 3
    let parsed1 = parseSmf(cast[seq[byte]](readFile(dir / "all.mid")))
    check parsed1.ok
    check parsed1.file.tracks.len == 3          # дирижёр + harp + lute
    check parsed1.file.tracks[1].countNotes == 1
    check parsed1.file.tracks[2].countNotes == 2

    let split = writeMidiTracks(p, dir / "split")
    check split.files.len == 2
    check split.tracks == 2
    check split.notes == 3
    for f in split.files:
      let parsed = parseSmf(cast[seq[byte]](readFile(f)))
      check parsed.ok
      check parsed.file.format == 0'u16
      check parsed.file.tracks.len == 1
      check parsed.file.tracks[0].metaOf(0x51'u8).len == 3
      check parsed.file.tracks[0].countNotes > 0
    # Имя файла начинается с номера дорожки: порядок воспроизводится.
    check split.files[0].extractFilename.startsWith("01_")
    check split.files[1].extractFilename.startsWith("02_")

    removeDir(dir)

  test "нота, кончающаяся ровно в начале следующей, не гасит её":
    let ppq = PpqTicksPerQuarter
    let p = project("Adj", 120.0f32, @[
      track("a", 1, @[clip(1, "a", 0, 4 * ppq, false,
        @[note(60, 0, ppq), note(60, ppq, ppq)])])])
    let t = toSmf(p).tracks[1]
    # Два On и два Off: Note Off первой стоит раньше Note On второй
    # при одном тике (иначе вторая нота была бы «съедена»).
    let bytes = encodeSmf(toSmf(p))
    let parsed = parseSmf(bytes)
    check parsed.ok
    check parsed.file.tracks[1].countNotes == 2
    check t.onTicks == @[0'u32, uint32(ppq)]

