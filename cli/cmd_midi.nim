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

import std/[json, os]

import context
import project
import midi_export

const
  MidiKeys* = @["--out", "--split"]
    ## Ключи `midi` — для справки и автодополнения (#259).

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
# Точка входа
# ==============================================================================

proc runMidi*(ctx: var Ctx; args: seq[string]): Report =
  let sc = scanArgs(args)
  if not sc.ok:
    return sc.rep

  let loaded = loadProject(sc.input)
  if not loaded.success:
    let kind = loaded.error.kind
    let env = kind in {pekFileNotFound, pekIOError}
    return errReport(
      if env: exEnv else: exUsage,
      if env: "io" else: "project",
      "не удалось открыть проект: " & loaded.error.message,
      "нужен файл формата euterpia-project (*.eproj; исторический *.eut " &
        "принимается) — см. `euterpia project show`")

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
      return errReport(exEnv, "io", "не удалось записать MIDI: " & e.msg,
        "проверьте права и путь: " & (if splitDir.len > 0: splitDir else: outFile))

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
