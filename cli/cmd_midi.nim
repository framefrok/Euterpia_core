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
import cli_spec
import cmd_project

const
  MidiSpec* = CommandSpec(
    name: "midi",
    summary: "экспорт проекта в MIDI: один файл или по файлу на инструмент",
    synopsis: "midi <проект.eproj> [--out файл.mid] [--split каталог]",
    args: @[
      arg("проект.eproj", "что экспортировать; историческое `.eut` принимается"),
    ],
    options: @[
      opt("--out", "куда записать один файл формата 1", value = "файл.mid"),
      opt("--split", "по файлу на инструмент (формат 0)", value = "каталог"),
    ],
    example: "euterpia midi ensemble.eproj --out ensemble.mid",
    fields: @[
      field("project", "прочитанный проект"),
      field("files", "записанные файлы (при `--dry-run` — план)"),
      field("tracks", "сколько дорожек попало в файлы"),
      field("notes", "сколько нотных событий выгружено"),
    ],
    notes: @[
      "формат 1: дорожка-дирижёр (имя, темп, размер) + по дорожке на каждый непустой трек",
      "--split: по файлу на инструмент (формат 0), имя начинается с номера дорожки",
      "если не указан ни --out, ни --split: рядом пишется `<проект>.mid`",
      "тики проекта и SMF совпадают по разрешению (PPQ), позиции не пересчитываются",
      "клипы раскрываются как в движке: Note Off обрезается границей клипа, " &
        "зацикленный клип повторяется до конца песни",
      "--dry-run печатает план и не пишет файлов",
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
# Точка входа
# ==============================================================================

proc runMidi*(ctx: var Ctx; args: seq[string]): Report =
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
