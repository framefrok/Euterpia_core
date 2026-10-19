# cli/cmd_midi.nim
#
# `euterpia midi <проект.eproj>` — проект как Standard MIDI File (issue: экспорт).
#
# Зачем команда: наш проект — это граф и дорожки, а не «миди-секвенция». Чтобы
# отдать музыку в чужой DAW/нотатор, нужен SMF. Команда делает ровно это и
# ничего не «улучшает»: тики проекта и SMF совпадают по разрешению, клипы
# раскрываются так же, как их играет движок (`core/sequencer`).
#
# Две раскладки вывода:
#   * `--out <файл.mid>` — один файл формата 1: дорожка-дирижёр (темп, размер,
#     имя) + по дорожке на каждый трек;
#   * `--split <каталог>` — по файлу на инструмент (формат 0), имя начинается
#     с номера дорожки.
# Можно указать оба; если не указан ни один — пишется `<проект>.mid` рядом.
#
# Границы (§20): CLI не разбирает проект сам — это Core (`core/project`), и не
# кодирует MIDI сам — это Commons (`commons/midi_io`). Здесь только выбор
# файлов, отчёт и код возврата.
#
# Коды возврата (#88): 0 — успех, 1 — ошибка данных/использования,
# 2 — среда (файл проекта не читается, каталог недоступен), 3 — внутренняя.

import std/[algorithm, json, math, os, strutils, tables, times]

import context
import project
import sequencer
import midi_export
import midi_io
import cli_spec
import cmd_project
import control/document
import control/commands
import control/history
import control_bridge
import history_file

import midi_api
import logger
import midi_backend_rtmidi

when defined(posix):
  import std/posix

const
  MidiSpec* = CommandSpec(
    name: "midi",
    summary: "MIDI: экспорт проекта в SMF, список портов и монитор событий",
    synopsis: "midi <проект.eproj> [--out файл.mid] [--split каталог] | " &
              "midi import <проект> <файл.mid> | " &
              "midi list | midi monitor [--in N] [--seconds S]",
    args: @[
      arg("проект.eproj", "что экспортировать; историческое `.eut` принимается"),
      arg("подкоманда", "`list` — порты входа/выхода; `monitor` — поток событий"),
    ],
    options: @[
      opt("--out", "куда записать один файл формата 1", value = "файл.mid"),
      opt("--split", "по файлу на инструмент (формат 0)", value = "каталог"),
      opt("--in", "порт входа для `monitor` (индекс из `midi list`)", value = "N"),
      opt("--seconds", "сколько слушать `monitor`; без ключа — до SIGINT",
          value = "секунды"),
      opt("--channel", "фильтр `monitor` по MIDI-каналу 1…16", value = "N"),
      opt("--only", "фильтр `monitor` по типу: note,cc,pitchbend,aftertouch,program",
          value = "типы"),
      opt("--track", "`import`: дорожка проекта (по умолчанию — в конец)",
          value = "N"),
      opt("--map", "`import`: сопоставление SMF:проект (можно несколько)",
          value = "SMF:проект"),
    ],
    example: "euterpia midi ensemble.eproj --out ensemble.mid",
    fields: @[
      field("project", "прочитанный проект (экспорт)"),
      field("files", "записанные файлы (при `--dry-run` — план)"),
      field("tracks", "сколько дорожек попало в файлы"),
      field("notes", "сколько нотных событий выгружено"),
      field("backend", "имя MIDI-адаптера (`midi list`/`monitor`)"),
      field("inputs", "порты входа `midi list`"),
      field("outputs", "порты выхода `midi list`"),
      field("events", "сколько событий напечатал `monitor`"),
      field("importedTracks", "`import`: сколько SMF-дорожек попало в проект"),
      field("importedNotes", "`import`: сколько нот создано"),
      field("ignoredEvents", "`import`: CC/PB и прочее, что формат клипа не хранит"),
      field("ppq", "`import`: разрешение SMF и пересчёт в PPQ проекта"),
      field("tempo", "`import`: темп из SMF, записанный в проект"),
    ],
    notes: @[
      "формат 1: дорожка-дирижёр (имя, темп, размер) + по дорожке на каждый непустой трек",
      "--split: по файлу на инструмент (формат 0), имя начинается с номера дорожки",
      "если не указан ни --out, ни --split: рядом пишется `<проект>.mid`",
      "тики проекта и SMF совпадают по разрешению (PPQ), позиции не пересчитываются",
      "клипы раскрываются как в движке: Note Off обрезается границей клипа, " &
        "зацикленный клип повторяется до конца песни",
      "--dry-run печатает план и не пишет файлов",
      "`midi list`: нет librtmidi — пустой список и код 0; это «адаптера нет», а не ошибка данных",
      "`midi monitor` печатает относительное время от открытия порта (без времени суток)",
      "`--json` у monitor — NDJSON: одна строка на событие, затем итоговый конверт",
      "`midi import` берёт ноты, имя дорожки, первый темп и размер; PPQ пересчитывается в 960",
      "CC/PB/aftertouch/program не входят в формат клипа: их число печатается в `ignoredEvents`",
      "SMF format 2, SMPTE-тайминг и несколько темпов/размеров отвергаются явно",
      "`--map SMF:проект` адресует дорожки; `--track N` — только для одной дорожки",
      "импорт — одна транзакция истории: `euterpia undo` возвращает проект до него",
      "раскодировать обратно можно тем же кодеком: `commons/midi_io.parseSmf`",
    ])

type
  MidiScan = object
    ok: bool
    rep: Report
    input: string
    outFile: string
    splitDir: string

# ==============================================================================
# Разбор аргументов
# ==============================================================================

proc scanArgs(args: seq[string]): MidiScan =
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--out":
      inc i
      if i >= args.len:
        return MidiScan(ok: false, rep: usageError("--out: нужен путь к .mid"))
      result.outFile = args[i]
    elif a == "--split":
      inc i
      if i >= args.len:
        return MidiScan(ok: false, rep: usageError("--split: нужен каталог"))
      result.splitDir = args[i]
    elif a.len > 1 and a[0] == '-':
      return MidiScan(ok: false, rep: usageError("неизвестный ключ: " & a))
    elif result.input.len == 0:
      result.input = a
    else:
      return MidiScan(ok: false, rep: usageError("лишний аргумент: " & a))
    inc i

  if result.input.len == 0:
    return MidiScan(ok: false,
      rep: usageError("нужен файл проекта: euterpia midi <проект.eproj>",
                      "пример: euterpia midi ensemble.eproj --out ensemble.mid"))
  result.ok = true

# ==============================================================================
# Импорт SMF в клипы проекта (#111)
# ==============================================================================
#
# Кодек SMF живёт в Commons (`midi_io`), клипы — в Core (`project`), а
# связывает их control-слой: импорт — та же транзакция, что у Editor, и
# попадает в историю (одна `undo` возвращает проект до импорта).
#
# Что импортируется: ноты (Note On/Off), имя дорожки, первый темп и размер.
# Что НЕ импортируется и считается в отчёте: CC, Pitch Bend, aftertouch,
# program change — формат клипа хранит только ноты. Молча терять их нельзя,
# поэтому `ignoredEvents` называет число.
#
# Разрешение: SMF division (PPQ) пересчитывается в PPQ проекта (960) с
# округлением до тика. SMPTE-тайминг и формат 2 отвергаются явно: их
# семантика не выражается сеткой проекта.

const
  ProjectPpq = 960
    ## Разрешение проекта (`transport.PpqTicksPerQuarter`).
  MaxMidiImportNotes = 65535
    ## Потолок на клип: формат проекта хранит `int32`, но импорт с миллионом
    ## нот — это ошибка выбора файла, а не рабочий сценарий.

type
  MidiImportScan = object
    ok: bool
    rep: Report
    projectPath: string
    midiPath: string
    track: int
    haveTrack: bool
    map: Table[int, int]

  PendingNote = object
    tick: int32
    velocity: uint8

proc addImportNote(notes: var seq[NoteFormat]; channel, pitch: int;
                   onTick: int32; offTick: int32; velocity: uint8) =
  var dur = offTick - onTick
  if dur < 1:
    dur = 1
  notes.add NoteFormat(startTick: onTick, duration: dur,
                       pitch: uint8(pitch and 0x7F),
                       velocity: velocity,
                       channel: uint8(channel and 0x0F))

proc scanImportArgs(args: seq[string]): MidiImportScan =
  result.track = -1
  result.map = initTable[int, int]()
  var i = 0
  while i < args.len:
    let key = args[i]
    if key in ["--track", "--map"]:
      if i + 1 >= args.len:
        return MidiImportScan(ok: false,
          rep: usageError(key & ": нужно значение",
            "например: euterpia midi import project.eproj song.mid --map 0:2"))
      let value = args[i + 1]
      if key == "--track":
        try:
          let n = parseInt(value)
          if n < 0:
            return MidiImportScan(ok: false,
              rep: usageError("--track: индекс не может быть отрицательным",
                "дорожки нумеруются с 0"))
          result.track = n
          result.haveTrack = true
        except ValueError:
          return MidiImportScan(ok: false,
            rep: usageError("--track: ожидается целое, получено: " & value,
              "например: --track 0"))
      else:
        let parts = value.split(':')
        if parts.len != 2:
          return MidiImportScan(ok: false,
            rep: usageError("--map: ожидается SMF:проект, получено: " & value,
              "например: --map 0:2"))
        try:
          let smf = parseInt(parts[0].strip())
          let proj = parseInt(parts[1].strip())
          if smf < 0 or proj < 0:
            return MidiImportScan(ok: false,
              rep: usageError("--map: индексы неотрицательны", value))
          if result.map.hasKey(smf):
            return MidiImportScan(ok: false,
              rep: usageError("--map: SMF-дорожка " & $smf & " указана дважды",
                "одна SMF-дорожка — один клип"))
          result.map[smf] = proj
        except ValueError:
          return MidiImportScan(ok: false,
            rep: usageError("--map: ожидаются числа, получено: " & value,
              "например: --map 0:2"))
      i += 2
      continue
    if key.startsWith("-"):
      return MidiImportScan(ok: false,
        rep: usageError("неизвестный ключ: " & key,
          "ключи import: --track, --map"))
    if result.projectPath.len == 0 and isProjectPath(key):
      result.projectPath = key
    elif result.midiPath.len == 0:
      let lower = key.toLowerAscii()
      if not (lower.endsWith(".mid") or lower.endsWith(".midi")):
        return MidiImportScan(ok: false,
          rep: usageError("ожидается .mid/.midi, получено: " & key,
            "например: euterpia midi import project.eproj song.mid"))
      result.midiPath = key
    else:
      return MidiImportScan(ok: false,
        rep: usageError("лишний аргумент: " & key,
          "форма: euterpia midi import <проект> <файл.mid>"))
    inc i

  if result.projectPath.len == 0:
    return MidiImportScan(ok: false,
      rep: usageError("midi import: не указан проект",
        "например: euterpia midi import project.eproj song.mid"))
  if result.midiPath.len == 0:
    return MidiImportScan(ok: false,
      rep: usageError("midi import: не указан SMF-файл",
        "например: euterpia midi import project.eproj song.mid"))
  result.ok = true

proc scaledTick(tick: uint32; scale: float64): int32 =
  let value = float64(tick) * scale
  if value >= float64(high(int32)): high(int32)
  else: int32(round(value))

proc roundToBar(ticks: int32; num, den: int32): int32 =
  if ticks <= 0:
    return 1
  let safeDen = if den > 0: den else: 4'i32
  let bar = int64(ProjectPpq) * 4 * int64(if num > 0: num else: 4'i32) div
            int64(safeDen)
  if bar <= 0:
    return ticks
  let bars = (int64(ticks) + bar - 1) div bar
  let rounded = bars * bar
  if rounded >= int64(high(int32)): high(int32) else: int32(rounded)

proc runMidiImport(ctx: var Ctx; args: seq[string]): Report =
  let sc = scanImportArgs(args)
  if not sc.ok:
    return sc.rep

  # --- файл и разбор --------------------------------------------------------
  var raw = ""
  try:
    raw = readFile(sc.midiPath)
  except CatchableError as e:
    return envError("не удалось прочитать MIDI-файл: " & e.msg,
      "проверьте путь " & sc.midiPath, errorKind = "io")

  let parsed =
    if raw.len > 0: parseSmf(toOpenArrayByte(raw, 0, raw.len - 1))
    else: (ok: false, file: SmfFile())
  if not parsed.ok:
    return usageError("битый или не-SMF файл: " & sc.midiPath,
      "нужен Standard MIDI File (форматы 0/1); файл не изменён")
  let smf = parsed.file

  if smf.format == 2'u16:
    return usageError("SMF format 2 не поддержан: " & sc.midiPath,
      "format 2 — независимые последовательности; сведите их в format 1")
  if (smf.division and 0x8000'u16) != 0'u16:
    return usageError("SMPTE-тайминг SMF не поддержан: " & sc.midiPath,
      "нужен musical timing (ticks per quarter), а не кадры")
  if smf.division == 0'u16:
    return usageError("SMF division == 0: разрешение не задано",
      "файл повреждён или собран не по спецификации")

  let scale = float64(ProjectPpq) / float64(smf.division)

  # --- темп и размер --------------------------------------------------------
  var tempos: seq[uint32] = @[]
  var meters: seq[(int32, int32)] = @[]
  for tr in smf.tracks:
    for meta in tr.meta:
      if meta.metaType == 0x51'u8 and meta.data.len >= 3:
        let micros = (uint32(meta.data[0]) shl 16) or
                     (uint32(meta.data[1]) shl 8) or uint32(meta.data[2])
        if micros > 0 and micros notin tempos:
          tempos.add micros
      elif meta.metaType == 0x58'u8 and meta.data.len >= 2:
        let num = int32(meta.data[0])
        let den = int32(1 shl int(meta.data[1]))
        if num > 0 and den > 0 and (num, den) notin meters:
          meters.add (num, den)

  if tempos.len > 1:
    return usageError("в SMF " & $tempos.len & " разных темпов: темповая карта " &
      "не поддержана",
      "проект хранит один темп; разбейте файл по темпам или задайте темп вручную")
  if meters.len > 1:
    return usageError("в SMF " & $meters.len & " разных размеров: карта размеров " &
      "не поддержана",
      "проект хранит один размер; разбейте файл по размерам")

  let smfTempo =
    if tempos.len == 1: 60_000_000.0 / float64(tempos[0])
    else: 0.0
  var sigNum = 4'i32
  var sigDen = 4'i32
  if meters.len == 1:
    sigNum = meters[0][0]
    sigDen = meters[0][1]

  # --- ноты по SMF-дорожкам -------------------------------------------------
  var trackNotes: seq[seq[NoteFormat]] = @[]
  var trackNames: seq[string] = @[]
  var ignored = 0
  var maxEnd = 0'i32

  for index, tr in smf.tracks:
    var notes: seq[NoteFormat] = @[]
    var pending = initTable[(int, int), PendingNote]()
    var name = ""
    var lastTick = 0'u32

    for meta in tr.meta:
      if meta.metaType == 0x03'u8 and name.len == 0 and meta.data.len > 0:
        var text = ""
        for b in meta.data:
          if b >= 0x20'u8 and b < 0x7F'u8:
            text.add char(b)
        name = text.strip()

    for ev in tr.events:
      lastTick = max(lastTick, ev.tick)
      let hi = ev.status and 0xF0'u8
      let channel = int(ev.status and 0x0F'u8)
      let pitch = int(ev.data1 and 0x7F'u8)
      let key = (channel, pitch)
      if hi == 0x90'u8 and ev.data2 > 0'u8:
        pending[key] = PendingNote(tick: scaledTick(ev.tick, scale),
                                   velocity: ev.data2)
      elif hi == 0x80'u8 or (hi == 0x90'u8 and ev.data2 == 0'u8):
        if pending.hasKey(key):
          let on = pending[key]
          pending.del key
          addImportNote(notes, channel, pitch, on.tick,
                        scaledTick(ev.tick, scale), on.velocity)
      elif hi notin {0xF0'u8}:
        # CC/PB/aftertouch/program: формат клипа их не хранит. Это не
        # «проглотили молча» — число уходит в отчёт.
        inc ignored

    if notes.len > 0 and pending.len > 0:
      # Незакрытые ноты закрываем концом дорожки: терять их нельзя.
      let offTick = scaledTick(lastTick + 1'u32, scale)
      var leftovers: seq[tuple[key: (int, int); val: PendingNote]] = @[]
      for key, val in pending:
        leftovers.add((key, val))
      for item in leftovers:
        addImportNote(notes, item.key[0], item.key[1], item.val.tick,
                      offTick, item.val.velocity)

    if notes.len > MaxMidiImportNotes:
      return usageError("дорожка SMF #" & $index & ": " & $notes.len &
        " нот — больше потолка клипа " & $MaxMidiImportNotes,
        "разделите партию на несколько SMF-дорожек")
    if notes.len > 0:
      for note in notes:
        let endTick = int32(note.startTick + note.duration)
        if endTick > maxEnd:
          maxEnd = endTick
      trackNotes.add notes
      trackNames.add(if name.len > 0: name else: "SMF " & $index)
    else:
      trackNotes.add @[]
      trackNames.add name

  # --- какие SMF-дорожки несут ноты ----------------------------------------
  var nonEmpty: seq[int] = @[]
  for i in 0 ..< trackNotes.len:
    if trackNotes[i].len > 0:
      nonEmpty.add i
  if nonEmpty.len == 0:
    return usageError("в SMF нет нот: импортировать нечего",
      "файл содержит только мета-события или CC/PB")
  if sc.haveTrack and nonEmpty.len > 1:
    return usageError("--track задаёт одну дорожку, а в SMF их " &
      $nonEmpty.len,
      "сопоставьте дорожки ключом --map SMF:проект")

  for smfIdx in sc.map.keys:
    if smfIdx >= trackNotes.len or trackNotes[smfIdx].len == 0:
      return usageError("--map: SMF-дорожка " & $smfIdx & " пуста или не существует",
        "в файле дорожек: " & $trackNotes.len & ", из них с нотами: " &
        $nonEmpty.len)

  let loaded = loadAt(sc.projectPath)
  if not loaded.ok:
    return loaded.rep
  var proj = loaded.proj

  # Темп/размер — часть импорта: иначе ноты приехали бы с неверной сеткой.
  var tempoWritten = 0.0
  if smfTempo > 0.0:
    let applied = setField(proj, "tempo", formatFloat(smfTempo, ffDecimal, 3))
    if not applied.ok:
      return usageError("темп из SMF не принят: " & applied.message,
        "проверьте темп в файле")
    tempoWritten = smfTempo
  if meters.len == 1:
    let applied = setField(proj, "time-signature", $sigNum & "/" & $sigDen)
    if not applied.ok:
      return usageError("размер из SMF не принят: " & applied.message,
        "проверьте размер в файле")

  var doc = openDocument(sc.projectPath, proj)
  let trackCountBefore = doc.proj.sequencer.tracks.len
  let base = if sc.haveTrack: sc.track else: trackCountBefore
  if sc.haveTrack and sc.track > trackCountBefore:
    return usageError("дорожка #" & $sc.track & " недостижима: в проекте " &
      $trackCountBefore & " дорожек",
      "дорожки создаются по порядку: следующий доступный индекс — " &
      $trackCountBefore)

  var cmds: seq[ControlCommand] = @[]
  var createdTracks = 0
  var nextClip = initTable[int, int]()
  var mapping = newJArray()
  var importedNotes = 0

  var order = nonEmpty
  order.sort()

  for pos, smfIdx in order:
    let target =
      if sc.map.hasKey(smfIdx): sc.map[smfIdx]
      elif sc.haveTrack: sc.track
      else: base + pos
    if target < 0:
      return usageError("--map: дорожка проекта не может быть отрицательной", "")

    if not nextClip.hasKey(target):
      let existing =
        if target < trackCountBefore:
          doc.proj.sequencer.tracks[target].clips.len
        else:
          0
      nextClip[target] = existing
    let clipIndex = nextClip[target]
    nextClip[target] = clipIndex + 1

    while trackCountBefore + createdTracks <= target:
      cmds.add addTrack(trackNames[smfIdx], int32(ord(ttMidi)))
      inc createdTracks

    let notes = trackNotes[smfIdx]
    var endTick = 0'i32
    for note in notes:
      endTick = max(endTick, int32(note.startTick + note.duration))
    let lengthTicks = roundToBar(endTick, sigNum, sigDen)

    cmds.add addClip(int32(target), int32(ord(ctMidi)), "", 0'i32,
                     lengthTicks, false, 0x6BB6FF'u32)
    cmds.add setClip(int32(target), int32(clipIndex), notes, lengthTicks,
                     false, trackNames[smfIdx], true)
    importedNotes += notes.len
    mapping.add %*{
      "smfTrack": smfIdx,
      "projectTrack": target,
      "clip": clipIndex,
      "name": trackNames[smfIdx],
      "notes": notes.len,
      "lengthTicks": int(lengthTicks),
    }

  let plan = doc.applyTransaction(cmds, "midi import " & sc.midiPath)
  if not plan.frame.isOk():
    return frameReport(plan.frame)

  var body = %*{
    "project": sc.projectPath,
    "file": sc.midiPath,
    "format": int(smf.format),
    "ppq": %*{"source": int(smf.division), "project": ProjectPpq,
              "scale": scale},
    "tempo": tempoWritten,
    "timeSignature": %*{"numerator": sigNum, "denominator": sigDen},
    "importedTracks": mapping.len,
    "importedNotes": importedNotes,
    "ignoredEvents": ignored,
    "map": mapping,
    "dryRun": ctx.dryRun,
    "written": not ctx.dryRun,
  }

  var lines: seq[string] = @[
    CliName & " midi import — SMF в клипы проекта",
    "файл: " & sc.midiPath & " (PPQ " & $smf.division & " → " &
      $ProjectPpq & ")",
    "проект: " & sc.projectPath,
  ]
  if tempoWritten > 0.0:
    lines.add "темп: " & formatFloat(tempoWritten, ffDecimal, 3) & " BPM"
  if meters.len == 1:
    lines.add "размер: " & $sigNum & "/" & $sigDen
  for item in mapping:
    lines.add "  SMF #" & $item["smfTrack"].getInt & " «" &
      item["name"].getStr & "» → дорожка #" & $item["projectTrack"].getInt &
      ", клип #" & $item["clip"].getInt & ", нот: " &
      $item["notes"].getInt
  if ignored > 0:
    lines.add "не импортировано CC/PB/aftertouch/program: " & $ignored &
      " (формат клипа хранит только ноты)"
  if ctx.dryRun:
    return okReport(body = body,
      lines = lines & @["не записан: " & sc.projectPath & " (--dry-run)"])

  let saved = writeAtomic(sc.projectPath, doc.proj)
  if not saved.success:
    return saveError(saved, sc.projectPath)
  let entry = HistoryEntry(redo: plan.redo, undo: plan.undo,
                           description: plan.description)
  let recorded = recordEntry(sc.projectPath, entry)
  if not recorded.isOk():
    return frameReport(recorded)
  lines.add "записан: " & sc.projectPath
  okReport(body = body, lines = lines)

# ==============================================================================
# MIDI-порты и монитор (issue #93)
# ==============================================================================
#
# Почему команда живёт здесь, а не отдельным `midi_monitor`: пользователь
# думает «MIDI», а не «экспорт». Один вход — `midi`, подкоманды `list` и
# `monitor`, исторический вызов `midi <проект>` остаётся экспортом.
#
# Границы (§20): CLI не трогает RtMidi напрямую (это делает адаптер) и не
# конвертирует сообщения в события графа — конвертация в Core
# (`midi_events`). Здесь только выбор порта, фильтры и печать.

const
  MaxMidiMonitorSeconds = 24.0 * 3600.0
    ## Потолок `--seconds`: опечатка не должна держать порт сутками.
  MidiMonitorSleepMs = 2
    ## Период опроса кольца. Адаптер копит сообщения в SPSC-кольце, поэтому
    ## опрос не конкурирует с callback'ом драйвера.

type
  MidiWatchKind = enum
    mwkNote
    mwkCc
    mwkPitchbend
    mwkAftertouch
    mwkProgram

  MidiPortsScan = object
    ok: bool
    rep: Report
    portIndex: int
    havePort: bool
    seconds: float64
    channel: int
    only: set[MidiWatchKind]
    onlyGiven: bool

var gMidiStop {.volatile.}: bool

when defined(posix):
  proc onMidiStopSignal(sig: cint) {.noconv.} =
    gMidiStop = true

  proc installMidiStopHandlers() =
    discard signal(SIGINT, onMidiStopSignal)
    discard signal(SIGTERM, onMidiStopSignal)

proc parseMidiWatch(text: string; dst: var set[MidiWatchKind]): bool =
  ## `note,cc,pitchbend` → множество. Пустой список — ошибка
  ## использования: «слушать ничего» почти наверняка опечатка.
  for raw in text.split(','):
    let token = raw.strip().toLowerAscii()
    if token.len == 0:
      continue
    case token
    of "note", "notes": dst.incl mwkNote
    of "cc", "control": dst.incl mwkCc
    of "pitchbend", "pb": dst.incl mwkPitchbend
    of "aftertouch", "at": dst.incl mwkAftertouch
    of "program", "pc": dst.incl mwkProgram
    else:
      return false
  dst.card > 0

proc scanPortsArgs(args: seq[string]): MidiPortsScan =
  var i = 0
  while i < args.len:
    let key = args[i]
    if key in ["--in", "--seconds", "--channel", "--only"]:
      if i + 1 >= args.len:
        return MidiPortsScan(ok: false,
          rep: usageError(key & ": нужно значение",
            "например: euterpia midi monitor --in 0 --seconds 5"))
      let value = args[i + 1]
      case key
      of "--in":
        try:
          let n = parseInt(value)
          if n < 0:
            return MidiPortsScan(ok: false,
              rep: usageError("--in: индекс порта не может быть отрицательным",
                "индекс берётся из `euterpia midi list`"))
          result.portIndex = n
          result.havePort = true
        except ValueError:
          return MidiPortsScan(ok: false,
            rep: usageError("--in: ожидается целое число, получено: " & value,
              "например: --in 0"))
      of "--seconds":
        try:
          let s = parseFloat(value)
          if s < 0.0 or s > MaxMidiMonitorSeconds:
            return MidiPortsScan(ok: false,
              rep: usageError("--seconds: допустимо 0 … " &
                $int(MaxMidiMonitorSeconds), "без ключа — до SIGINT"))
          result.seconds = s
        except ValueError:
          return MidiPortsScan(ok: false,
            rep: usageError("--seconds: ожидается число, получено: " & value,
              "например: --seconds 10"))
      of "--channel":
        try:
          let ch = parseInt(value)
          if ch < 1 or ch > 16:
            return MidiPortsScan(ok: false,
              rep: usageError("--channel: допустимо 1…16, получено: " & value,
                "MIDI-каналы нумеруются с 1"))
          result.channel = ch
        except ValueError:
          return MidiPortsScan(ok: false,
            rep: usageError("--channel: ожидается число, получено: " & value,
              "например: --channel 10"))
      else: # --only
        if not parseMidiWatch(value, result.only):
          return MidiPortsScan(ok: false,
            rep: usageError("--only: неизвестный тип в «" & value & "»",
              "допустимо: note, cc, pitchbend, aftertouch, program"))
        result.onlyGiven = true
      i += 2
    elif key.startsWith("-"):
      return MidiPortsScan(ok: false,
        rep: usageError("неизвестный ключ: " & key,
          "ключи: --in, --seconds, --channel, --only"))
    else:
      return MidiPortsScan(ok: false,
        rep: usageError("лишний аргумент: " & key,
          "`midi list` и `midi monitor` не принимают позиционных путей"))
    inc i
  result.ok = true

proc portJson(info: MidiBackendPortInfo): JsonNode =
  %*{
    "id": info.id,
    "name": info.name,
    "direction": (if info.direction == mpdInput: "input" else: "output"),
    "default": info.isDefault,
  }

proc midiPorts(api: ptr MidiBackendApi;
               dir: MidiPortDirection): seq[MidiBackendPortInfo] =
  let count = midiDeviceCount(api, dir)
  result = @[]
  for i in 0 ..< count:
    var info: MidiBackendPortInfo
    if midiDeviceInfo(api, dir, i, info):
      result.add info


proc midiWatchKind(status: uint8): tuple[kind: MidiWatchKind; name: string] =
  case status and 0xF0'u8
  of 0x80'u8: (mwkNote, "noteOff")
  of 0x90'u8: (mwkNote, "noteOn")
  of 0xA0'u8: (mwkAftertouch, "aftertouch")
  of 0xB0'u8: (mwkCc, "cc")
  of 0xC0'u8: (mwkProgram, "program")
  of 0xD0'u8: (mwkAftertouch, "channelAftertouch")
  of 0xE0'u8: (mwkPitchbend, "pitchbend")
  else: (mwkCc, "unknown")

proc midiEventJson(msg: MidiMessage): JsonNode =
  let channel = int(msg.status and 0x0F'u8) + 1
  result = %*{
    "timeMs": msg.timestamp * 1000.0,
    "port": msg.portId,
    "direction": "in",
    "type": midiWatchKind(msg.status).name,
    "channel": channel,
    "status": int(msg.status),
    "data1": int(msg.data1),
    "data2": int(msg.data2),
  }

proc midiEventLine(msg: MidiMessage): string =
  let channel = int(msg.status and 0x0F'u8) + 1
  let ms = formatFloat(msg.timestamp * 1000.0, ffDecimal, 3)
  # Формат стабилен: время, порт, тип, канал, данные. Никакого времени суток —
  # иначе вывод недетерминирован и непригоден для сравнения/тестов.
  result = ms & " ms  in" & $msg.portId & "  " & midiWatchKind(msg.status).name &
           "  ch" & $channel & "  " & $int(msg.data1)
  if (msg.status and 0xF0'u8) notin {0xC0'u8, 0xD0'u8}:
    result.add " " & $int(msg.data2)

proc eventWanted(sc: MidiPortsScan; msg: MidiMessage): bool =
  if sc.onlyGiven and midiWatchKind(msg.status).kind notin sc.only:
    return false
  if sc.channel > 0 and (int(msg.status and 0x0F'u8) + 1) != sc.channel:
    return false
  true

proc runMidiPorts(ctx: var Ctx; args: seq[string]; monitor: bool): Report =
  let sc = scanPortsArgs(args)
  if not sc.ok:
    return sc.rep

  var log = silentLogger()
  let api = createRtMidiBackend(log)
  if api.isNil:
    return envError("MIDI-адаптер не создан",
      "проверьте librtmidi (EUTERPIA_RTMIDI_LIB) и `euterpia doctor`")
  defer:
    destroyRtMidiBackend(api)

  let initErr = midiInit(api, addr log)
  let backendName = midiBackendNameOf(api)

  if not monitor:
    var inputs = newJArray()
    var outputs = newJArray()
    var lines: seq[string] = @[]
    if initErr != meOk:
      lines.add "MIDI-адаптер недоступен: " & $initErr
      lines.add "портов нет; это не ошибка данных (код 0)"
    else:
      let ins = midiPorts(api, mpdInput)
      let outs = midiPorts(api, mpdOutput)
      for info in ins: inputs.add portJson(info)
      for info in outs: outputs.add portJson(info)
      lines.add "бэкенд: " & backendName & "; входов: " & $ins.len &
                "; выходов: " & $outs.len
      for info in ins:
        lines.add "  in#" & $info.id & " " & info.name &
          (if info.isDefault: " (по умолчанию)" else: "")
      for info in outs:
        lines.add "  out#" & $info.id & " " & info.name &
          (if info.isDefault: " (по умолчанию)" else: "")
    return okReport(
      body = %*{
        "backend": backendName,
        "inputs": inputs,
        "outputs": outputs,
        "initError": (if initErr == meOk: "" else: $initErr),
      },
      lines = lines)

  # --- monitor ---------------------------------------------------------------
  if initErr != meOk:
    # Отсутствие библиотеки — среда, но команда не падает: события не
    # пришли, отчёт честно говорит почему.
    return okReport(
      body = %*{"backend": backendName, "port": -1, "events": 0,
                "initError": $initErr},
      lines = @["MIDI-адаптер недоступен: " & $initErr,
                "событий нет (код 0)"])

  let available = int(midiDeviceCount(api, mpdInput))
  if available <= 0:
    return okReport(
      body = %*{"backend": backendName, "port": -1, "events": 0,
                "inputs": 0},
      lines = @["MIDI-входов нет — слушать нечего (код 0)"])

  let index = if sc.havePort: sc.portIndex else: 0
  if index >= available:
    return envError(
      "порт входа " & $index & " не найден",
      "доступно входов: " & $available & " (0…" & $(available - 1) &
        "); список — `euterpia midi list`")

  let handle = midiOpenPort(api, mpdInput, int32(index))
  if handle.isNil:
    return envError("не удалось открыть порт входа " & $index,
      "порт занят другим приложением или отключён")
  defer:
    midiClosePort(api, handle)

  when defined(posix):
    installMidiStopHandlers()

  var messages: array[64, MidiMessage]
  var events = 0
  var firstAt = -1.0
  let started = epochTime()
  let deadline = if sc.seconds > 0.0: started + sc.seconds else: 0.0

  while not gMidiStop:
    let got = midiPoll(api, handle,
      cast[ptr UncheckedArray[MidiMessage]](addr messages[0]),
      int32(messages.len))
    var j = 0
    while j < got:
      let msg = messages[j]
      if eventWanted(sc, msg):
        if events == 0:
          firstAt = msg.timestamp
        inc events
        if ctx.mode == omJson:
          cliStdout($midiEventJson(msg))
        else:
          cliStdout(midiEventLine(msg))
      inc j
    if deadline > 0.0 and epochTime() >= deadline:
      break
    sleep(MidiMonitorSleepMs)

  let elapsed = epochTime() - started
  var lines: seq[string] = @[]
  if events == 0:
    lines.add "порт входа " & $index & ": событий не было за " &
              formatFloat(elapsed, ffDecimal, 2) & " с"
  else:
    lines.add "порт входа " & $index & ": " & $events & " событий за " &
              formatFloat(elapsed, ffDecimal, 2) & " с"
    lines.add "первое событие на " &
              formatFloat(firstAt * 1000.0, ffDecimal, 3) & " мс от открытия"

  okReport(
    body = %*{
      "backend": backendName,
      "port": index,
      "events": events,
      "seconds": elapsed,
    },
    lines = lines)


# ==============================================================================
# Точка входа
# ==============================================================================

proc runMidi*(ctx: var Ctx; args: seq[string]): Report =
  # Подкоманды портов/монитора (#93) идут ДО разбора экспорта: `list` и
  # `monitor` — не пути к проекту, и угадывать это по расширению нельзя.
  # Мониторные ключи без явной подкоманды тоже относятся к монитору: иначе
  # объявленный в справке `--in` отвергался бы как «неизвестный ключ».
  const MonitorKeys = ["--in", "--seconds", "--channel", "--only"]
  if args.len > 0:
    if args[0] == "import":
      return runMidiImport(ctx, args[1 .. ^1])
    if args[0] in ["--track", "--map"]:
      # Ключи импорта без явной подкоманды: справка их объявляет, значит
      # «неизвестный ключ» на них — ложь. Форма без проекта даст понятный
      # отказ «не указан проект».
      return runMidiImport(ctx, args)
    if args[0] == "list":
      return runMidiPorts(ctx, args[1 .. ^1], false)
    if args[0] == "monitor":
      return runMidiPorts(ctx, args[1 .. ^1], true)
    if args[0] in MonitorKeys:
      return runMidiPorts(ctx, args, true)

  let sc = scanArgs(args)
  if not sc.ok:
    return sc.rep

  let loaded = loadProject(sc.input)
  if not loaded.success:
    # Причина и код возврата — из таблицы `cli/exit_codes.nim` (#332): битый
    # формат — данные (1), недоступный файл — среда (2). Класс ответа (`io` у
    # файловых сбоев) называет клиент.
    let ec = errorCodeFor(loaded.error.kind)
    let message = "не удалось открыть проект: " & loaded.error.message
    let hint = "нужен файл формата euterpia-project (*.eproj; исторический " &
      "*.eut принимается) — см. `euterpia project show`"
    if exitCodeFor(ec) == exEnv:
      return envError(message, hint, ec, errorKind = "io")
    return usageError(message, hint, ec)

  let proj = loaded.value

  var outFile = sc.outFile
  var splitDir = sc.splitDir
  if outFile.len == 0 and splitDir.len == 0:
    outFile = changeFileExt(sc.input, ".mid")

  var files: seq[string] = @[]
  var tracks = 0
  var notes = 0

  if not ctx.dryRun:
    try:
      if splitDir.len > 0:
        let r = writeMidiTracks(proj, splitDir)
        files.add r.files
        tracks = max(tracks, r.tracks)
        notes = max(notes, r.notes)
      if outFile.len > 0:
        let r = writeMidi(proj, outFile)
        files.add r.files
        tracks = max(tracks, r.tracks)
        notes = max(notes, r.notes)
    except CatchableError as e:
      return envError("не удалось записать MIDI: " & e.msg,
        "проверьте права и путь: " & (if splitDir.len > 0: splitDir else: outFile),
        errorKind = "io")

  var jf = newJArray()
  for f in files:
    jf.add %f

  var lines: seq[string] = @[]
  if ctx.dryRun:
    lines.add "midi: сухой прогон, файлы не записаны"
    if outFile.len > 0:
      lines.add "  был бы записан: " & outFile
    if splitDir.len > 0:
      lines.add "  был бы разбит в: " & splitDir
  else:
    for f in files:
      lines.add "записан " & f
    lines.add "итого: " & $tracks & " дорожек, " & $notes & " нот"

  okReport(
    body = %*{
      "project": sc.input,
      "files": jf,
      "tracks": tracks,
      "notes": notes,
      "dryRun": ctx.dryRun,
    },
    lines = lines)
