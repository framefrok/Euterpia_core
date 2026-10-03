# libs/midi_export.nim
#
# Проект EUTERPIA → Standard MIDI File (SMF).
#
# Зачем отдельный модуль: чтобы получить MIDI из проекта, надо знать ОБА мира —
# формат проекта (`core/project`) и файловый кодек (`commons/midi_io`). Ядро
# не имеет права импортировать Commons (§25/§26), а кодек нейтрален и про
# проект не знает. Единственное место, где обе стороны видны сразу, — верхний
# слой `libs` (зависимости: Core ← Nodes ← libs ← CLI).
#
# Что даётся:
#   * `toSmf` — проект как один SMF-файл формата 1: дорожка-дирижёр (имя,
#     темп, размер) + по дорожке на каждый непустой трек проекта;
#   * `writeMidi` — то же на диск одним файлом;
#   * `writeMidiTracks` — по файлу на инструмент (разбить партии).
#
# Верность переноса:
#   * тики проекта и SMF совпадают по разрешению (`PpqTicksPerQuarter`),
#     поэтому позиции не пересчитываются и не «плывут»;
#   * раскрытие клипов повторяет `core/sequencer.expandClipEvents`: Note Off
#     обрезается границей клипа, зацикленный клип повторяется до конца песни;
#   * мета-события (имя дорожки, темп, размер) пишутся, чтобы чужой DAW
#     открыл файл с правильным темпом и подписями.

import std/[math, os, strutils]

import project
import midi_io
import transport

export midi_io   ## `SmfFile`/`SmfTrack` — тип возврата `toSmf`, значит видны и тут.

{.push raises: [].}

type
  MidiExportReport* = object
    ## Что получилось: пути файлов и счётчики для отчёта CLI.
    files*: seq[string]
    tracks*: int
    notes*: int

# ==============================================================================
# Внутреннее
# ==============================================================================

proc tempoMicrosPerQuarter(tempo: float32): uint32 =
  ## Темп как микросекунды на четверть (SMF 0x51). 120 BPM = 500000.
  let t = if tempo > 1.0f32: float64(tempo) else: 120.0
  uint32(clamp(round(60_000_000.0 / t), 1.0, 16_777_215.0))

proc safeName(name: string; fallback: string): string =
  ## Имя файла без разделителей пути и управляющих символов.
  var res = ""
  for ch in name:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      res.add ch
    elif ch in {' ', '.', '+', '#'}:
      res.add '_'
  if res.len == 0:
    res = fallback
  res

proc trackLabel(t: TrackFormat; index: int): string =
  if t.name.len > 0: t.name else: "Track " & $(index + 1)

proc notesIn(t: TrackFormat): int =
  for cl in t.clips:
    result += cl.notes.len

proc velOf(v: uint8): uint8 {.inline.} =
  uint8(max(1, min(127, int(v))))

proc songEndTicks(p: ProjectFormat): int32 =
  ## Граница песни — то же, что `maxSongTicks` в движке: дальше зацикленный
  ## клип повторять некуда. Считается по длинам клипов, а для клипов без
  ## длины — по фактическому концу нот.
  for tr in p.sequencer.tracks:
    for cl in tr.clips:
      if cl.lengthTicks > 0:
        result = max(result, cl.startTick + cl.lengthTicks)
      else:
        for nt in cl.notes:
          result = max(result, cl.startTick + nt.startTick + nt.duration)

proc addClipNotes(st: var SmfTrack; cl: ClipFormat; songEnd: int32) =
  ## Ноты одного клипа. Повторяет поведение движка: не зацикленный клип
  ## обрезает ноты своей границей, зацикленный — повторяется до конца песни.
  ## Клип нулевой длины трактуется как «просто запись»: его ноты сохраняются
  ## как есть (иначе рукописный проект отдал бы пустой файл).
  let base = max(cl.startTick, 0'i32)

  if cl.lengthTicks <= 0:
    for nt in cl.notes:
      st.addNote(uint32(max(0'i32, base + nt.startTick)), int(nt.channel) and 0x0F,
                 nt.pitch, velOf(nt.velocity), uint32(max(1'i32, nt.duration)))
    return

  let clipEnd = base + cl.lengthTicks
  if not cl.loopEnabled:
    for nt in cl.notes:
      let a0 = base + nt.startTick
      let a1 = min(a0 + nt.duration, clipEnd)
      if a1 <= a0:
        continue
      st.addNote(uint32(max(0'i32, a0)), int(nt.channel) and 0x0F,
                 nt.pitch, velOf(nt.velocity), uint32(a1 - a0))
    return

  let limit = if songEnd > base: songEnd else: clipEnd
  var iter = base
  while iter < limit:
    for nt in cl.notes:
      let a0 = iter + nt.startTick
      if a0 >= limit:
        continue
      let a1 = min(a0 + nt.duration, iter + cl.lengthTicks)
      if a1 <= a0:
        continue
      st.addNote(uint32(max(0'i32, a0)), int(nt.channel) and 0x0F,
                 nt.pitch, velOf(nt.velocity), uint32(a1 - a0))
    iter += max(cl.lengthTicks, 1'i32)

proc addTrackNotes(st: var SmfTrack; t: TrackFormat; songEnd: int32) =
  ## Ноты всех клипов дорожки.
  for cl in t.clips:
    st.addClipNotes(cl, songEnd)

proc conductorTrack(p: ProjectFormat): SmfTrack =
  result.addTrackName(0'u32,
    if p.metadata.name.len > 0: p.metadata.name else: "EUTERPIA")
  result.addTempo(0'u32, tempoMicrosPerQuarter(p.metadata.tempo))
  let num = if p.metadata.timeSignature.numerator > 0:
              int(p.metadata.timeSignature.numerator) else: 4
  let den = if p.metadata.timeSignature.denominator > 0:
              int(p.metadata.timeSignature.denominator) else: 4
  result.addTimeSignature(0'u32, num, den)

# ==============================================================================
# Проект → SMF
# ==============================================================================

proc toSmf*(p: ProjectFormat): SmfFile =
  ## Проект как один SMF-файл. Формат 1: дорожка 0 — дирижёр (имя, темп,
  ## размер), дальше по дорожке на каждый трек, в котором есть ноты.
  ## Тишина в файл не попадает: пустая дорожка ничего не сообщает.
  let ppq = if PpqTicksPerQuarter > 0: PpqTicksPerQuarter else: 480'i32
  result.division = uint16(min(ppq, 0xFFFF'i32))

  let songEnd = songEndTicks(p)
  var music: seq[SmfTrack]
  for i, tr in p.sequencer.tracks:
    var st: SmfTrack
    st.addTrackName(0'u32, trackLabel(tr, i))
    st.addTrackNotes(tr, songEnd)
    if st.events.len > 0:
      music.add st

  if music.len == 0:
    # Нот нет — всё равно валидный файл с дирижёром: темп и размер нужны,
    # например, чтобы проект можно было открыть и добрать ноты.
    result.format = 0'u16
    result.tracks = @[conductorTrack(p)]
    return

  result.format = 1'u16
  result.tracks.add conductorTrack(p)
  for m in music:
    result.tracks.add m

# ==============================================================================
# Запись на диск
# ==============================================================================

proc writeMidi*(p: ProjectFormat; path: string): MidiExportReport
    {.raises: [IOError, OSError].} =
  ## Один MIDI-файл на весь проект. Каталог создаётся при необходимости:
  ## `--out build/midi/song.mid` не должен требовать ручного `mkdir`.
  let smf = toSmf(p)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, cast[string](encodeSmf(smf)))
  result.files = @[path]
  result.tracks = max(0, smf.tracks.len - 1)   # без дорожки-дирижёра
  for tr in p.sequencer.tracks:
    result.notes += notesIn(tr)

proc writeMidiTracks*(p: ProjectFormat; dir: string): MidiExportReport
    {.raises: [IOError, OSError].} =
  ## По файлу на инструмент: каждая непустая дорожка проекта — отдельный SMF
  ## формата 0 (имя, темп, размер и ноты в одном чанке). Имя файла начинается
  ## с номера дорожки, поэтому порядок воспроизводится, даже если имя пустое.
  let tempoMicros = tempoMicrosPerQuarter(p.metadata.tempo)
  let num = if p.metadata.timeSignature.numerator > 0:
              int(p.metadata.timeSignature.numerator) else: 4
  let den = if p.metadata.timeSignature.denominator > 0:
              int(p.metadata.timeSignature.denominator) else: 4
  let songEnd = songEndTicks(p)

  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  for i, tr in p.sequencer.tracks:
    if notesIn(tr) == 0:
      continue
    var st: SmfTrack
    st.addTrackName(0'u32, trackLabel(tr, i))
    st.addTempo(0'u32, tempoMicros)
    st.addTimeSignature(0'u32, num, den)
    st.addTrackNotes(tr, songEnd)

    var f: SmfFile
    f.format = 0'u16
    f.division = uint16(min(max(PpqTicksPerQuarter, 1'i32), 0xFFFF'i32))
    f.tracks = @[st]

    let label = safeName(trackLabel(tr, i), "track")
    let path = dir / align($(i + 1), 2, '0') & "_" & label & ".mid"
    writeFile(path, cast[string](encodeSmf(f)))
    result.files.add path
    inc result.tracks
    result.notes += notesIn(tr)

{.pop.}


