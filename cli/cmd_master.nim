 # cli/cmd_master.nim
#
# CLI «master» — сдача материала: метрики, нормализация,
# dither, метаданные, стемы и манифест (issue #209).
#
# Границы:
#   * метрики и обработка — Core (`core/loudness`), не CLI;
#   * рендер проекта — существующая команда `render` (её контракт: файл,
#     длительность, автоматизация), а не вторая копия той же логики;
#   * стемы — `render --solo-track`, дорожки и их имена берутся из проекта.
#
# Почему мастер работает через 32-битный промежуточный файл: усиление и
# лимитер на 16-битном материале добавили бы шум квантования дважды.
# Финальная глубина и dither выбираются при записи результата.
#
# Формат `--json` — обычный конверт CLI: команда конечная (в отличие от
# `play`), поэтому поток не нужен.

{.push warning[Deprecated]: off.}
# std/sha1: SHA-1 нужен только как контрольная сумма пакета; внешний
# пакет `checksums` ядро не тянет (зависимостей нет вообще).
import std/[json, math, os, strutils, sha1]
{.pop.}

import context
import cli_spec
import cmd_project
import cmd_render
import control/query
import control_bridge
import audio_file_io
import signal_types
import loudness
import project

const
  DefaultTargetLufs* = -14.0
  DefaultCeilingDb* = -1.0
  MasterBitsDefault* = 16
  MasterBitsAllowed = [16, 24, 32]
  MasterFormats = @[".wav"]
    ## Сдача: WAV. FLAC-энкодера в ядре нет — обещать его нельзя (#10).

  MasterSpec* = CommandSpec(
    name: "master",
    summary: "сдача: LUFS/true peak, нормализация, dither, метаданные, стемы",
    synopsis: "master [проект.eproj | вход.wav] [ключи]",
    args: @[
      arg("вход", "проект или готовый WAV"),
    ],
    options: @[
      opt("--file", "вход, если он не задан позиционно", value = "путь"),
      opt("--out", "файл мастера", value = "файл.wav"),
      opt("--dir", "каталог сдачи (мастер + стемы + манифест)", value = "каталог"),
      opt("--target", "целевая громкость, LUFS", value = "LUFS",
          default = $DefaultTargetLufs),
      opt("--ceiling", "потолок true peak, dBTP", value = "dBTP",
          default = $DefaultCeilingDb),
      opt("--bits", "глубина итогового WAV", value = "16|24|32",
          default = $MasterBitsDefault),
      switch("--dither", "TPDF-dither (по умолчанию включён для 16 бит)"),
      switch("--no-dither", "выключить dither"),
      switch("--stems", "отрендерить стемы по дорожкам проекта"),
      opt("--meta", "метаданные: ключ=значение (можно несколько)", value = "ключ=значение"),
      opt("--seconds", "длительность рендера проекта", value = "секунды"),
      opt("--tail", "добавка после последней ноты, секунды", value = "секунды"),
      opt("--sample-rate", "частота рендера проекта", value = "Гц"),
      opt("--block", "размер блока рендера", value = "кадры"),
      opt("--master", "id мастер-ноды проекта", value = "id ноды"),
    ],
    example: "euterpia master demo.eproj --target -14 --stems --dir delivery",
    fields: @[
      field("input", "вход: проект или WAV"),
      field("out", "файл мастера"),
      field("format", "формат вывода: `wav`"),
      field("bitsPerSample", "глубина итогового файла"),
      field("sampleRate", "частота"),
      field("dither", "включён ли TPDF-dither"),
      field("targetLufs", "цель нормализации"),
      field("ceilingDb", "потолок true peak"),
      field("inputLufs", "громкость входа"),
      field("outputLufs", "громкость результата"),
      field("gainDb", "усиление по громкости"),
      field("appliedGainDb", "итоговое усиление"),
      field("truePeakDb", "true peak результата"),
      field("samplePeakDb", "sample peak результата"),
      field("limitedFrames", "кадров, затронутых лимитером"),
      field("lra", "динамический диапазон (LRA, LU)"),
      field("stems", "стемы: имя, файл, метрики"),
      field("manifest", "манифест сдачи с хешами файлов"),
      field("metadata", "записанные метаданные"),
    ],
    notes: @[
      "метрики — BS.1770/EBU R128: LUFS, short-term, LRA, true peak (×4 oversampling) (#209)",
      "dither — TPDF, детерминированный: повторная сдача даёт те же байты",
      "стемы рендерятся по дорожкам проекта (render --solo-track) и суммируются в мастер",
      "манифест содержит SHA-1 каждого файла: это контроль целостности пакета, не подпись",
      "FLAC-энкодера в ядре нет; формат отвергается с указанием причины (#10)",
    ])

type
  MetaKey = tuple[key, value: string]

  MasterScan = object
    ok: bool
    rep: Report
    path: string
    outPath: string
    dir: string
    haveOut: bool
    target: float64
    ceiling: float64
    bits: int
    dither: bool
    ditherSet: bool
    stems: bool
    meta: seq[MetaKey]
    seconds: float64
    haveSeconds: bool
    tail: float64
    sampleRate: int
    blockSize: int
    master: int

# =============================================================================
# Разбор аргументов
# =============================================================================

proc numArg(text, key: string; low, high: float64):
    tuple[ok: bool; value: float64; message: string] =
  try:
    let v = parseFloat(text.strip())
    if v != v or v < low or v > high:
      return (false, 0.0, key & ": диапазон " & $low & ".." & $high &
              ", получено «" & text & "»")
    (true, v, "")
  except ValueError:
    (false, 0.0, key & ": ожидается число, получено «" & text & "»")

proc intArg(text, key: string; low, high: int):
    tuple[ok: bool; value: int; message: string] =
  try:
    let v = parseInt(text.strip())
    if v < low or v > high:
      return (false, 0, key & ": диапазон " & $low & ".." & $high)
    (true, v, "")
  except ValueError:
    (false, 0, key & ": ожидается целое, получено «" & text & "»")

proc scanArgs(args: seq[string]): MasterScan =
  result.target = DefaultTargetLufs
  result.ceiling = DefaultCeilingDb
  result.bits = MasterBitsDefault
  result.tail = -1.0
  result.sampleRate = 0
  result.blockSize = 0
  result.master = -1

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

    if key == "--dither" or key == "--no-dither" or key == "--stems":
      if haveInline:
        result.rep = usageError(key & " — флаг и не принимает значение",
          "например: euterpia master project.eproj " & key)
        return
      case key
      of "--dither": result.dither = true; result.ditherSet = true
      of "--no-dither": result.dither = false; result.ditherSet = true
      else: result.stems = true
      inc i
      continue

    if key notin MasterSpec.optionKeys:
      if token.startsWith("-") and token.len > 1:
        result.rep = usageError("неизвестный ключ: " & token,
          "ключи master: " & MasterSpec.optionKeys.join(", "))
        return
      if result.path.len > 0:
        result.rep = usageError("вход указан дважды: " & result.path &
                                " и " & token)
        return
      result.path = token
      inc i
      continue

    if not haveInline:
      if i + 1 >= args.len:
        result.rep = usageError(key & " требует значение",
          "например: euterpia master " & key & " …")
        return
      inc i
      value = args[i]

    case key
    of "--file":
      result.path = value
    of "--out":
      result.outPath = value
      result.haveOut = true
    of "--dir":
      result.dir = value
    of "--target":
      let parsed = numArg(value, key, -70.0, 0.0)
      if not parsed.ok:
        result.rep = usageError(parsed.message,
          "цель нормализации, например -14 для стриминга")
        return
      result.target = parsed.value
    of "--ceiling":
      let parsed = numArg(value, key, -20.0, 0.0)
      if not parsed.ok:
        result.rep = usageError(parsed.message,
          "потолок true peak, например -1.0 dBTP")
        return
      result.ceiling = parsed.value
    of "--bits":
      let parsed = intArg(value, key, 16, 32)
      if not parsed.ok or parsed.value notin MasterBitsAllowed:
        result.rep = usageError("--bits принимает 16, 24 или 32",
          "получено: " & value)
        return
      result.bits = parsed.value
    of "--meta":
      let eqm = value.find('=')
      if eqm <= 0:
        result.rep = usageError("--meta: ожидается ключ=значение",
          "например: --meta artist=\"Euterpia\"")
        return
      result.meta.add (value[0 ..< eqm].strip(), value[eqm + 1 .. ^1])
    of "--seconds":
      let parsed = numArg(value, key, 0.001, 36_000.0)
      if not parsed.ok:
        result.rep = usageError(parsed.message)
        return
      result.seconds = parsed.value
      result.haveSeconds = true
    of "--tail":
      let parsed = numArg(value, key, 0.0, 36_000.0)
      if not parsed.ok:
        result.rep = usageError(parsed.message)
        return
      result.tail = parsed.value
    of "--sample-rate":
      let parsed = intArg(value, key, 1, 1_000_000)
      if not parsed.ok:
        result.rep = usageError(parsed.message)
        return
      result.sampleRate = parsed.value
    of "--block":
      let parsed = intArg(value, key, 1, MaxBlockSize)
      if not parsed.ok:
        result.rep = usageError(parsed.message)
        return
      result.blockSize = parsed.value
    of "--master":
      let parsed = intArg(value, key, 1, high(int))
      if not parsed.ok:
        result.rep = usageError(parsed.message)
        return
      result.master = parsed.value
    else:
      result.rep = usageError("неизвестный ключ: " & key)
      return
    inc i

  if result.path.len == 0:
    result.rep = usageError("master: не указан вход",
      "например: euterpia master project.eproj --target -14")
    return

  # dither по умолчанию включается для 16 бит: это сдача, а не черновик.
  if not result.ditherSet:
    result.dither = result.bits == 16

  if result.haveOut and result.outPath.toLowerAscii().rfind(".wav") < 0:
    result.rep = usageError("формат вывода не поддержан: " & result.outPath,
      "мастер пишется в WAV; FLAC-энкодера в ядре нет (#10)")
    return

  result.ok = true

# =============================================================================
# Ввод/вывод
# =============================================================================

type
  AudioData = object
    ok: bool
    error: string
    samples: seq[float32]
    channels: int
    sampleRate: int

proc decoderChannels(dec: AudioDecoder): int =
  case dec.format
  of afWav: int(dec.wavReader.info.channels)
  else: int(dec.packedInfo.channels)

proc decoderSampleRate(dec: AudioDecoder): int =
  case dec.format
  of afWav: int(dec.wavReader.info.sampleRate)
  else: int(dec.packedInfo.sampleRate)

proc readAudio(path: string): AudioData =
  ## Прочитать WAV/FLAC/MP3/OGG/AIFF в interleaved float. Моно дублируется
  ## в стерео: мастер всегда стерео (`MaxAudioChannels`), и «сколько каналов
  ## на выходе» не должно зависеть от входного файла.
  if not fileExists(path):
    return AudioData(error: "файл не найден: " & path)
  var dec: AudioDecoder
  try:
    dec = openDecoder(path)
  except CatchableError as e:
    return AudioData(error: "не удалось прочитать аудио: " & e.msg)

  let channels = decoderChannels(dec)
  result.sampleRate = decoderSampleRate(dec)
  if channels <= 0 or result.sampleRate <= 0:
    close(dec)
    return AudioData(error: "битый заголовок аудиофайла: " & path)
  if channels > MaxAudioChannels:
    close(dec)
    return AudioData(error: "каналов " & $channels & ": мастер работает со " &
                            "стерео (MaxAudioChannels = " &
                            $MaxAudioChannels & ")")

  const ChunkFrames = 16384
  var raw = newSeq[uint8](ChunkFrames * channels * 4)
  var buf = newSeq[float32](ChunkFrames * channels)
  while true:
    let n = readFrames(dec, cast[ptr UncheckedArray[uint8]](addr raw[0]),
                       cast[ptr UncheckedArray[float32]](addr buf[0]),
                       ChunkFrames)
    if n <= 0:
      break
    for i in 0 ..< n * channels:
      result.samples.add buf[i]
  close(dec)

  if result.samples.len == 0:
    return AudioData(error: "в файле нет сэмплов: " & path)

  if channels == 1:
    let frames = result.samples.len
    var stereo = newSeq[float32](frames * 2)
    for i in 0 ..< frames:
      stereo[i * 2] = result.samples[i]
      stereo[i * 2 + 1] = result.samples[i]
    result.samples = stereo
    result.channels = 2
  else:
    result.channels = channels
  result.ok = true

proc writeWav(path: string; data: seq[float32]; channels, sampleRate, bits: int;
              dither: bool; meta: WavMetadata): tuple[ok: bool; error: string] =
  ## Записать итоговый WAV через фасад ядра: dither и INFO-чанк — свойства
  ## `AudioFileInfo`, а не отдельного писателя в CLI.
  var enc: AudioEncoder
  try:
    enc = openEncoder(path, AudioFileInfo(
      sampleRate: int32(sampleRate), channels: int16(channels),
      bitsPerSample: int16(bits), isFloat: false,
      metadata: meta, dither: dither))
  except CatchableError as e:
    return (false, "не удалось создать файл: " & e.msg)

  let frames = data.len div channels
  var offset = 0
  const ChunkFrames = 16384
  try:
    while offset < frames:
      let n = min(ChunkFrames, frames - offset)
      writeFrames(enc,
        cast[ptr UncheckedArray[float32]](unsafeAddr data[offset * channels]),
        int32(n))
      offset += n
    close(enc)
  except CatchableError as e:
    try: close(enc)
    except CatchableError: discard
    return (false, "ошибка записи: " & e.msg)
  (true, "")

proc safeStemName(track: TrackInfo; index: int): string =
  var name = ""
  for ch in track.name:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      name.add ch
    elif ch in {' ', '.', '#', '+'}:
      name.add '_'
  if name.len == 0:
    name = "track-" & $(index + 1)
  name

proc sha1Of(path: string): string =
  ## Контроль целостности пакета, не подпись: SHA-1 достаточно для
  ## обнаружения обрезанного/подменённого файла и есть в std.
  $secureHash(readFile(path))

proc hasContent(track: TrackInfo): bool =
  ## Стем имеет смысл, только если в дорожке что-то есть. Аудиодорожка
  ## определяется видом, MIDI — нотами хотя бы одного клипа.
  if track.trackType == 1 and track.clips.len > 0:
    return true
  for clip in track.clips:
    if clip.notes > 0:
      return true
  false

proc renderArgs(path, outPath: string; scan: MasterScan;
                soloTrack: int32 = -1): seq[string] =
  ## Аргументы существующей команды `render`: мастер не дублирует её логику
  ## длительности, автоматизации и прогресса.
  result = @["--file", path, "--out", outPath, "--bits", "32", "--no-progress"]
  if scan.haveSeconds:
    result.add @["--seconds", $scan.seconds]
  if scan.tail >= 0.0:
    result.add @["--tail", $scan.tail]
  if scan.sampleRate > 0:
    result.add @["--sample-rate", $scan.sampleRate]
  if scan.blockSize > 0:
    result.add @["--block", $scan.blockSize]
  if scan.master >= 0:
    result.add @["--master", $scan.master]
  if soloTrack >= 0:
    result.add @["--solo-track", $soloTrack]

proc renderProject(ctx: var Ctx; path, outPath: string; scan: MasterScan;
                   soloTrack: int32 = -1): Report =
  ## Прогон `render` в этом же процессе. Возвращается его отчёт: ошибки
  ## данных/среды не теряются и не подменяются «мастер не удался».
  runRender(ctx, renderArgs(path, outPath, scan, soloTrack))

proc metaFrom(meta: MetadataInfo; pairs: seq[MetaKey]): WavMetadata =
  ## Метаданные сдачи: из проекта (Query API), затем явные `--meta` — они
  ## сильнее. Прямое чтение `proj.metadata` запрещено §63.
  result.title = meta.name
  result.artist = meta.author
  for item in pairs:
    let value = item.value.strip()
    case item.key
    of "title", "name": result.title = value
    of "artist", "author": result.artist = value
    of "genre": result.genre = value
    of "comment": result.comment = value
    of "date": result.date = value
    of "software": result.software = value
    else: discard

proc metaFromPairs(pairs: seq[MetaKey]): WavMetadata =
  ## `--meta` для готового файла: проекта нет, метаданные задаются только
  ## ключами. Пустой DTO здесь — не «забыли», а «источника нет».
  metaFrom(MetadataInfo(), pairs)

proc unknownMeta(pairs: seq[MetaKey]): string =
  const Known = ["title", "name", "artist", "author", "genre", "comment",
                 "date", "software"]
  for item in pairs:
    if item.key notin Known:
      return item.key
  ""


# =============================================================================
# master
# =============================================================================

proc gainAtIndex(envelope: seq[float32]; index: int; fallbackDb: float64):
    float32 =
  if envelope.len == 0:
    return float32(pow(10.0, fallbackDb / 20.0))
  envelope[min(index, envelope.high)]

proc applyEnvelope(samples: var seq[float32]; channels: int;
                   envelope: seq[float32]; fallbackDb: float64) =
  if channels <= 0:
    return
  let frames = samples.len div channels
  for i in 0 ..< frames:
    let g = gainAtIndex(envelope, i, fallbackDb)
    for ch in 0 ..< channels:
      samples[i * channels + ch] *= g

proc runMaster*(ctx: var Ctx; args: seq[string]): Report =
  let scan = scanArgs(args)
  if not scan.ok:
    return scan.rep

  let badKey = unknownMeta(scan.meta)
  if badKey.len > 0:
    return usageError("--meta: неизвестный ключ «" & badKey & "»",
      "ключи: title, artist, genre, comment, date, software")

  let projectInput = isProjectPath(scan.path)
  if scan.stems and not projectInput:
    return usageError("--stems требует проект, а не готовый файл",
      "стемы рендерятся по дорожкам: euterpia master project.eproj --stems")

  let parts = splitFile(scan.path)
  let stem = if parts.name.len > 0: parts.name else: "master"
  var deliveryDir = scan.dir
  if deliveryDir.len == 0:
    deliveryDir = if scan.outPath.len > 0: parentDir(scan.outPath)
                  elif parts.dir.len > 0: parts.dir
                  else: "."
  if deliveryDir.len == 0:
    deliveryDir = "."
  if not dirExists(deliveryDir):
    try:
      createDir(deliveryDir)
    except CatchableError:
      return envError("не удалось создать каталог сдачи: " & deliveryDir,
        "проверьте права и путь")

  var outPath = scan.outPath
  if outPath.len == 0:
    outPath = deliveryDir / (stem & ".master.wav")

  # --- источник -----------------------------------------------------------
  var proj = ProjectFormat()
  var tracks: seq[TrackInfo] = @[]
  var meta = WavMetadata()
  if projectInput:
    if not fileExists(scan.path):
      return envError("проект не найден: " & scan.path,
        "путь к проекту задаётся позиционно или ключом --file")
    let loaded = loadAt(scan.path)
    if not loaded.ok:
      return loaded.rep
    proj = loaded.proj
    # Метаданные и дорожки — через Query API (#336/#63): CLI не заглядывает
    # во внутренности формата, а спрашивает описание документа.
    let doc = openDocument(scan.path, proj)
    meta = metaFrom(queryMetadata(doc), scan.meta)
    tracks = queryTracks(doc)
  else:
    meta = metaFromPairs(scan.meta)

  let opts = block:
    var o = defaultMasterOptions(scan.target, scan.ceiling)
    o.keepEnvelope = scan.stems
    o

  # `--dry-run`: показать план, ничего не рендеря и не записывая.
  if ctx.dryRun:
    var body = %*{
      "input": scan.path,
      "out": outPath,
      "format": "wav",
      "bitsPerSample": scan.bits,
      "dither": scan.dither,
      "targetLufs": scan.target,
      "ceilingDb": scan.ceiling,
      "stems": scan.stems,
      "dryRun": true,
    }
    if projectInput:
      let plan = renderProject(ctx, scan.path, outPath, scan)
      if not plan.ok:
        return plan
      body["render"] = plan.body
    else:
      let audio = readAudio(scan.path)
      if not audio.ok:
        return envError(audio.error, "вход — WAV/FLAC/MP3/OGG/AIFF")
      let m = measureLoudness(audio.samples, audio.channels,
                              float64(audio.sampleRate))
      body["inputLufs"] = %m.integratedLufs
      body["truePeakDb"] = %m.truePeakDb
    return okReport(body = body,
      lines = @["план сдачи: " & scan.path, "мастер: " & outPath &
                " (--dry-run)"])

  # --- мастер-микс в 32-битном промежуточном файле ------------------------
  var master: AudioData
  if projectInput:
    let tempPath = deliveryDir / (".eut-master-" &
                                  $getCurrentProcessId() & ".wav")
    let rendered = renderProject(ctx, scan.path, tempPath, scan)
    if not rendered.ok:
      return rendered
    master = readAudio(tempPath)
    try: removeFile(tempPath)
    except CatchableError: discard
    if not master.ok:
      return panicError("мастер не прочитал собственный рендер: " &
                        master.error,
        "это баг: приложите вывод `euterpia --version` и команду")
  else:
    master = readAudio(scan.path)
    if not master.ok:
      return envError(master.error, "вход — WAV/FLAC/MP3/OGG/AIFF")

  if master.sampleRate <= 0 or master.channels <= 0 or
     master.samples.len == 0:
    return envError("вход пуст: " & scan.path,
      "проверьте файл: euterpia analyze " & scan.path)

  # --- нормализация и лимитер ---------------------------------------------
  let report = normalizeMaster(master.samples, master.channels,
                               float64(master.sampleRate), opts)

  let written = writeWav(outPath, master.samples, master.channels,
                         master.sampleRate, scan.bits, scan.dither, meta)
  if not written.ok:
    return envError(written.error, "проверьте каталог и права: " & outPath)


  # --- стемы --------------------------------------------------------------
  var stemRecords = newJArray()
  var stemSum: seq[float32] = @[]
  if scan.stems:
    stemSum = newSeq[float32](master.samples.len)
    for index, track in tracks:
      if not hasContent(track):
        continue
      let stemName = $track.id & "-" & safeStemName(track, index)
      let temp = deliveryDir / (".eut-stem-" & $getCurrentProcessId() &
                                "-" & $track.id & ".wav")
      let rendered = renderProject(ctx, scan.path, temp, scan, track.id)
      if not rendered.ok:
        try: removeFile(temp)
        except CatchableError: discard
        return rendered
      var data = readAudio(temp)
      try: removeFile(temp)
      except CatchableError: discard
      if not data.ok:
        return panicError("стем #" & $track.id & " не читается: " & data.error,
          "это баг рендера стема (#209)")
      if data.samples.len != master.samples.len or
         data.channels != master.channels or
         data.sampleRate != master.sampleRate:
        return panicError("стем #" & $track.id & " не совпал с мастером по " &
                          "формату", "это баг рендера стема (#209)")

      applyEnvelope(data.samples, data.channels, report.gainEnvelope,
                    report.appliedGainDb)
      for i in 0 ..< data.samples.len:
        stemSum[i] += data.samples[i]

      var stemMeta = meta
      if stemMeta.title.len == 0:
        stemMeta.title = track.name
      else:
        stemMeta.title = stemMeta.title & " — " & track.name
      stemMeta.comment = "stem: " & track.name
      let stemPath = deliveryDir / (stem & "." & stemName & ".wav")
      let stemWritten = writeWav(stemPath, data.samples, data.channels,
                                 data.sampleRate, scan.bits, scan.dither,
                                 stemMeta)
      if not stemWritten.ok:
        return envError(stemWritten.error, "стем: " & stemPath)
      let m = measureLoudness(data.samples, data.channels,
                              float64(data.sampleRate))
      stemRecords.add %*{
        "trackId": track.id,
        "name": track.name,
        "file": stemPath,
        "bytes": getFileSize(stemPath),
        "sha1": sha1Of(stemPath),
        "lufs": m.integratedLufs,
        "truePeakDb": m.truePeakDb,
      }

  # --- сумма стемов против мастера ----------------------------------------
  var sumErrorDb = 0.0
  if stemSum.len > 0:
    var masterPeak = 0.0
    var diffPeak = 0.0
    for i in 0 ..< stemSum.len:
      let mp = abs(float64(master.samples[i]))
      if mp > masterPeak: masterPeak = mp
      let d = abs(float64(stemSum[i] - master.samples[i]))
      if d > diffPeak: diffPeak = d
    if masterPeak > 0.0 and diffPeak > 0.0:
      sumErrorDb = 20.0 * log10(diffPeak / masterPeak)
    elif diffPeak > 0.0:
      sumErrorDb = PeakFloorDb


  # --- манифест -----------------------------------------------------------
  var manifest = %*{
    "schema": 1,
    "format": "euterpia-delivery",
    "input": scan.path,
    "master": {
      "file": outPath,
      "bytes": getFileSize(outPath),
      "sha1": sha1Of(outPath),
      "bitsPerSample": scan.bits,
      "sampleRate": master.sampleRate,
      "channels": master.channels,
      "frames": report.output.frames,
      "lufs": report.output.integratedLufs,
      "truePeakDb": report.output.truePeakDb,
      "lra": report.output.loudnessRangeLu,
    },
    "stems": stemRecords,
    "target": {"lufs": scan.target, "ceilingDb": scan.ceiling},
    "dither": scan.dither,
  }
  if stemSum.len > 0:
    manifest["stemsSumErrorDb"] = %sumErrorDb
  let manifestPath = deliveryDir / (stem & ".manifest.json")
  try:
    writeFile(manifestPath, $manifest)
  except CatchableError as e:
    return envError("не удалось записать манифест: " & e.msg, manifestPath)

  # --- отчёт --------------------------------------------------------------
  var body = %*{
    "input": scan.path,
    "out": outPath,
    "format": "wav",
    "bitsPerSample": scan.bits,
    "sampleRate": master.sampleRate,
    "channels": master.channels,
    "dither": scan.dither,
    "targetLufs": scan.target,
    "ceilingDb": scan.ceiling,
    "inputLufs": report.input.integratedLufs,
    "inputTruePeakDb": report.input.truePeakDb,
    "outputLufs": report.output.integratedLufs,
    "truePeakDb": report.output.truePeakDb,
    "samplePeakDb": report.output.samplePeakDb,
    "shortTermMaxLufs": report.output.shortTermMaxLufs,
    "lra": report.output.loudnessRangeLu,
    "gainDb": report.gainDb,
    "appliedGainDb": report.appliedGainDb,
    "ceilingCorrectionDb": report.ceilingCorrectionDb,
    "limitedFrames": report.limitedFrames,
    "frames": report.output.frames,
    "sha1": sha1Of(outPath),
    "bytes": getFileSize(outPath),
    "manifest": manifestPath,
    "stems": stemRecords,
    "metadata": %*{
      "title": meta.title, "artist": meta.artist, "genre": meta.genre,
      "comment": meta.comment, "date": meta.date,
    },
  }
  if stemSum.len > 0:
    body["stemsSumErrorDb"] = %sumErrorDb

  var lines = @[
    "мастер: " & outPath,
    "громкость: " & formatFloat(report.input.integratedLufs, ffDecimal, 1) &
      " → " & formatFloat(report.output.integratedLufs, ffDecimal, 1) &
      " LUFS (цель " & formatFloat(scan.target, ffDecimal, 1) & ")",
    "true peak: " & formatFloat(report.output.truePeakDb, ffDecimal, 2) &
      " dBTP (потолок " & formatFloat(scan.ceiling, ffDecimal, 2) & ")",
    "усиление: " & formatFloat(report.appliedGainDb, ffDecimal, 2) & " дБ" &
      (if report.limitedFrames > 0:
         ", лимитер: " & $report.limitedFrames & " кадров" else: ""),
    "формат: WAV " & $scan.bits & " бит, " & $master.sampleRate &
      " Гц, стерео" & (if scan.dither: ", TPDF dither" else: ""),
  ]
  if scan.stems:
    lines.add "стемов: " & $stemRecords.len & ", манифест: " & manifestPath
    lines.add "сумма стемов к мастеру: " &
      formatFloat(sumErrorDb, ffDecimal, 1) & " дБ"
  okReport(body = body, lines = lines)

