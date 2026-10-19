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

import std/[json, os, strutils, times]

import context
import project
import midi_export
import cli_spec
import cmd_project

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
