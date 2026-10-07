# cli/cmd_import.nim
#
# `import` — импорт аудиофайла в проект как audio-клип трека (issue #107).
#
# Границы (§20, §58):
#   - форматом проекта владеет Core (`core/project`): команда пишет ССЫЛКУ на
#     файл (секция `resources`, версия формата v2), а не сэмплы;
#   - чтение файла (заголовок, кадры, SR) — Core (`core/audio_file_io`);
#   - CLI разбирает аргументы и печатает отчёт, но не решает, что такое
#     «валидный WAV» — это делает кодек.
#
# Решение по хранению (§58, «зафиксировать явно»):
#   по умолчанию — ССЫЛКА на исходный файл (путь хранится как задан);
#   `--copy` — файл копируется в каталог проекта, хранится имя копии.
#   Сэмплы в проект не встраиваются: миллионы float в JSON раздували бы файл
#   и ломали совместимость с внешними редакторами.
#
# Ресемплинг при несовпадении SR (issue #8) ещё не реализован: импорт файла с
# другим SR — ЯВНАЯ ошибка, а не молчаливое «ускорение» (критерий #107).

import std/[json, math, os, strutils]

import project
import transport
import audio_file_io
import codec_api

import context
import cmd_project
import cli_spec

const
  ImportOptions* = @[
    opt("--file", "проект: " & projectSuffixesHint() & "; по умолчанию " &
        DefaultProjectFile, value = "проект.eproj"),
    opt("--track", "индекс дорожки с нуля; дорожка создаётся при необходимости",
        value = "число"),
    opt("--at-bar", "такт начала клипа; по умолчанию 1", value = "число",
        default = "1"),
    opt("--name", "имя клипа (по умолчанию — имя файла)", value = "строка"),
    switch("--copy", "скопировать файл в каталог проекта (иначе — ссылка)"),
  ]
  ImportKeys* = keysOf(ImportOptions)

  ImportSpec* = CommandSpec(
    name: "import",
    summary: "импортировать аудиофайл в проект как audio-клип",
    synopsis: "import <файл> [проект.eproj] [--track N] [--at-bar N] [--copy] [--name имя]",
    options: ImportOptions,
    args: @[
      arg("файл", "аудиофайл для импорта (WAV 16/24/32-bit, моно/стерео)"),
      arg("проект", "проект: " & projectSuffixesHint() &
        "; по умолчанию " & DefaultProjectFile),
    ],
    example: "euterpia import kick.wav song.eproj --track 1 --at-bar 1",
    fields: @[
      field("path", "проект, в который импортирован клип"),
      field("file", "исходный аудиофайл"),
      field("imported", "кадры, каналы, SR, биты, длительность (сек)"),
      field("resource", "ресурс: id, хранимый путь, копия/ссылка"),
      field("clip", "клип: id, трек, начало (тики), длина (тики)"),
      field("resampled", "был ли ресемплинг (пока всегда false)"),
    ],
    notes: @[
      "сэмплы в проект НЕ встраиваются: хранится ссылка на файл (секция resources, формат v2)",
      "`--copy` копирует файл в каталог проекта (клип переживёт перемещение оригинала)",
      "SR файла ≠ SR проекта — явная ошибка (ресемплинг — issue #8), а не молчаливое ускорение",
      "неподдерживаемый формат или битый файл — отказ без создания клипа",
    ])

# =============================================================================
# Разбор аргументов
# =============================================================================

type
  ImportScan = object
    ok: bool
    rep: Report
    path: string
      ## Проект.
    audioFile: string
      ## Импортируемый аудиофайл.
    track: int
    haveTrack: bool
    atBar: int
    name: string
      ## Пусто — имя клипа берётся из имени файла.
    copy: bool

proc looksLikeInt(s: string): bool =
  if s.len == 0:
    return false
  var i = 0
  if s[0] in {'+', '-'}:
    inc i
  var digits = 0
  while i < s.len:
    if s[i] in {'0'..'9'}:
      inc digits
    else:
      return false
    inc i
  digits > 0

proc scanImport(args: seq[string]): ImportScan =
  result.path = DefaultProjectFile
  result.atBar = 1
  var haveFile = false
  var positionals: seq[string] = @[]
  var i = 0
  while i < args.len:
    let token = args[i]
    var key = token
    var value = ""
    var haveInline = false
    let eq = token.find('=')
    if token.startsWith("--") and eq > 0:
      key = token[0 ..< eq]
      value = token[eq + 1 .. ^1]
      haveInline = true

    if key in ImportKeys:
      if key == "--copy":
        result.copy = true
        inc i
        continue
      if not haveInline:
        if i + 1 >= args.len:
          result.rep = usageError(key & " требует значение",
                                  "например: euterpia import in.wav --track 1")
          return
        inc i
        value = args[i]
      case key
      of "--file":
        result.path = value
        haveFile = true
      of "--track":
        if not looksLikeInt(value):
          result.rep = usageError("--track принимает id трека (число), получено: " & value)
          return
        result.track = parseInt(value)
        result.haveTrack = true
      of "--at-bar":
        if not looksLikeInt(value) or parseInt(value) < 1:
          result.rep = usageError("--at-bar принимает номер такта ≥ 1, получено: " & value)
          return
        result.atBar = parseInt(value)
      of "--name":
        result.name = value
      else:
        result.rep = usageError("неизвестный ключ import: " & key,
                                "ключи: " & ImportKeys.join(", "))
        return
    elif token.startsWith("--"):
      result.rep = usageError("неизвестный ключ: " & token,
                              "ключи: " & ImportKeys.join(", "))
      return
    else:
      positionals.add token
    inc i

  # Позиционные: аудиофайл и (необязательно) проект по расширению.
  for token in positionals:
    if isProjectPath(token):
      if haveFile:
        result.rep = usageError("проект указан дважды: --file и " & token,
                                "оставьте что-то одно")
        return
      result.path = token
    elif result.audioFile.len == 0:
      result.audioFile = token
    else:
      result.rep = usageError("лишний аргумент: " & token,
                              "например: euterpia import in.wav song.eproj --track 1")
      return

  if result.audioFile.len == 0:
    result.rep = usageError("import требует аудиофайл",
                            "например: euterpia import in.wav --track 1")
    return
  if not result.haveTrack:
    result.rep = usageError("import требует --track",
                            "например: euterpia import in.wav --track 1")
    return
  result.ok = true


# =============================================================================
# import
# =============================================================================

proc nextResourceId(resources: seq[AudioResourceFormat]): int32 =
  result = 1
  for r in resources:
    if r.id + 1 > result:
      result = r.id + 1

proc nextClipId(clips: seq[ClipFormat]): int32 =
  result = 1
  for c in clips:
    if c.id + 1 > result:
      result = c.id + 1

proc runImport*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia import <файл> [проект] --track <индекс> [--at-bar N] [--copy]`.
  let scan = scanImport(args)
  if not scan.ok:
    return scan.rep

  # Заголовок файла читает кодек (Core). Неподдерживаемый формат/битый файл —
  # отказ ДО правки проекта: клип не создаётся на «половине».
  var info: AudioFileInfo
  try:
    var dec = openDecoder(scan.audioFile)
    info = dec.getInfo()
    dec.close()
  except CatchableError as e:
    return envError("не удалось прочитать аудиофайл: " & scan.audioFile &
                    " (" & e.msg & ")",
                    "поддерживается WAV, FLAC, MP3, OGG Vorbis и AIFF (#10)",
                    code = ecEnvironment, errorKind = "io")

  if info.numFrames <= 0 or info.channels <= 0:
    return usageError("аудиофайл пуст: " & scan.audioFile,
                      "нужен файл хотя бы с одним кадром")

  let loaded = loadAt(scan.path)
  if not loaded.ok:
    return loaded.rep
  var proj = loaded.proj

  # SR файла и проекта обязаны совпадать: ресемплинг (#8) ещё не реализован,
  # а молчаливое «ускорение» звука — недопустимо (критерий #107).
  if abs(float(info.sampleRate) - float(proj.metadata.sampleRate)) > 0.5:
    return envError(
      "SR файла (" & $info.sampleRate & ") не совпадает с SR проекта (" &
        $proj.metadata.sampleRate & ")",
      "ресемплинг ещё не реализован (issue #8): импортируйте файл с тем же SR",
      code = ecEnvironment, errorKind = "io")

  # Дорожка: индекс с нуля, как у `notation import`; создаётся при необходимости
  # (audio-тип). Ноль дорожек в проекте — не ошибка пользователя.
  if scan.track < 0:
    return usageError("--track не может быть отрицательным: " & $scan.track)
  while proj.sequencer.tracks.len <= scan.track:
    var trackId = int32(1)
    for t in proj.sequencer.tracks:
      if t.id + 1 > trackId:
        trackId = t.id + 1
    proj.sequencer.tracks.add TrackFormat(
      id: trackId, name: "Audio " & $trackId, trackType: 1,  # ttAudio
      volume: 1.0f, pan: 0.0f)

  # Хранение: ссылка или копия рядом с проектом (§58 — решение явное).
  var storedPath = scan.audioFile
  if scan.copy:
    let dest = parentDir(scan.path) / extractFilename(scan.audioFile)
    if not fileExists(dest) or absolutePath(dest) != absolutePath(scan.audioFile):
      copyFile(scan.audioFile, dest)
    storedPath = extractFilename(scan.audioFile)

  let resId = nextResourceId(proj.resources)
  proj.resources.add AudioResourceFormat(
    id: resId, path: storedPath, sampleRate: info.sampleRate,
    channels: info.channels, numFrames: info.numFrames,
    bitsPerSample: info.bitsPerSample, isFloat: info.isFloat,
    copy: scan.copy)

  # Клип: позиция в тактах, длина — из длительности файла и темпа проекта.
  let num = max(1, int(proj.metadata.timeSignature.numerator))
  let den = max(1, int(proj.metadata.timeSignature.denominator))
  let ticksPerBar = int64(PpqTicksPerQuarter) * int64(num) * 4'i64 div int64(den)
  let startTick = int32((int64(scan.atBar) - 1) * ticksPerBar)
  let seconds = float64(info.numFrames) / float64(info.sampleRate)
  let ticksPerSecond = float64(proj.metadata.tempo) / 60.0 *
                       float64(PpqTicksPerQuarter)
  let lengthTicks = int32(max(1'i64, int64(round(seconds * ticksPerSecond))))

  let trackIdx = scan.track
  let clipId = nextClipId(proj.sequencer.tracks[trackIdx].clips)
  let clipName =
    if scan.name.len > 0: scan.name
    else: extractFilename(scan.audioFile)
  proj.sequencer.tracks[trackIdx].clips.add ClipFormat(
    id: clipId, clipType: 1,  # ctAudio
    name: clipName, startTick: startTick, lengthTicks: lengthTicks,
    loopEnabled: false, resourceId: resId, offsetFrames: 0'i64,
    audioBufferId: -1)

  # Проект теперь несёт аудио-ресурсы — это формат v2 (миграция v1→v2: v1
  # читается с пустым `resources`, поэтому понижать версию нельзя).
  proj.version = ProjectFormatVersion
  proj.metadata.modified = nowStamp()

  var body = %*{
    "path": scan.path,
    "file": scan.audioFile,
    "imported": {
      "frames": info.numFrames, "channels": info.channels,
      "sampleRate": info.sampleRate, "bitsPerSample": info.bitsPerSample,
      "seconds": seconds, "float": info.isFloat,
    },
    "resource": {"id": resId, "path": storedPath, "copy": scan.copy},
    "clip": {"id": clipId, "track": trackIdx, "startTick": startTick,
             "lengthTicks": lengthTicks},
    "resampled": false,
  }
  var lines: seq[string] = @[
    "файл: " & scan.audioFile,
    "импорт: " & $info.numFrames & " кадров, " & $info.channels & " канал(ов), " &
      $info.sampleRate & " Гц" &
      (if info.isFloat: ", float" else: ", " & $info.bitsPerSample & " бит"),
    "ресурс #" & $resId & ": " & storedPath &
      (if scan.copy: " (копия)" else: " (ссылка)"),
    "клип #" & $clipId & " на дорожке " & $trackIdx & " «" &
      proj.sequencer.tracks[trackIdx].name & "», такт " & $scan.atBar,
  ]

  if ctx.dryRun:
    lines.add "не записан: " & scan.path & " (--dry-run)"
    return okReport(body = body, lines = lines)

  let saved = writeAtomic(scan.path, proj)
  if not saved.success:
    return saveError(saved, scan.path)
  lines.add "записан: " & scan.path
  okReport(body = body, lines = lines)

