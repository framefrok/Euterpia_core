# cli/preview_encoder.nim
#
# Lossy-превью сдачи через внешний кодировщик (issue #411).
#
# Почему внешний инструмент, а не свой кодек:
#   * ядро не тянет внешних зависимостей (§8), а MP3/OGG-энкодеры —
#     это патенты/лицензии и сотни килобайт кода;
#   * превью — не «сдаточный» формат: манифест помечает его `role: preview`
#     и `lossless: false`, поэтому честнее вызвать проверенный инструмент,
#     чем обещать «свой» кодек;
#   * нет инструмента — код 2 с подсказкой, как установить. Это лучше, чем
#     молча записать битый файл.
#
# Границы (§20): CLI не кодирует аудио сам и не трогает audio-поток; он
# только выбирает инструмент и разбирает результат. Готовый WAV пишет
# существующий путь `master`.
#
# Инструменты (первый найденный в PATH):
#   * OGG Vorbis: `ffmpeg -c:a libvorbis` или `oggenc`;
#   * MP3:        `ffmpeg -c:a libmp3lame` или `lame`.

import std/[os, osproc, strutils]


type
  PreviewResult* = object
    ok*: bool
    tool*: string
      ## Чем кодировали (пусто — не нашли).
    codec*: string
      ## `vorbis` | `mp3`.
    bitrate*: int
      ## кбит/с.
    error*: string

proc quoteArg(value: string): string =
  ## Безопасная передача пути в shell: кавычки-апострофы + экранирование.
  quoteShell(value)

proc runTool(command: string): tuple[ok: bool; output: string] =
  try:
    let (output, code) = execCmdEx(command, options = {poStdErrToStdOut})
    (code == 0, output)
  except CatchableError as e:
    (false, e.msg)

proc ffmpegCodec(format: string): string =
  case format
  of "ogg", "oga": "libvorbis"
  of "mp3": "libmp3lame"
  else: ""

proc encodePreview*(
  wavPath, outPath: string;
  format: string;
  bitrateKbps: int
): PreviewResult =
  ## Перекодировать готовый WAV в lossy-превью.
  ##
  ## `format` — `ogg`|`mp3` (без точки). Проверка «файл читается» остаётся
  ## за вызывающим: здесь только кодирование и честный отчёт.
  result.bitrate = bitrateKbps
  result.codec = if format == "mp3": "mp3" else: "vorbis"
  let ffmpeg = findExe("ffmpeg")
  let native =
    case format
    of "mp3": findExe("lame")
    of "ogg", "oga": findExe("oggenc")
    else: ""

  # ffmpeg умеет оба формата и один синтаксис битрейта — он первый.
  if ffmpeg.len > 0:
    let codec = ffmpegCodec(format)
    let cmd = quoteArg(ffmpeg) & " -hide_banner -nostdin -y -i " &
              quoteArg(wavPath) & " -c:a " & codec & " -b:a " &
              $bitrateKbps & "k " & quoteArg(outPath)
    let run = runTool(cmd)
    if run.ok and fileExists(outPath):
      result.ok = true
      result.tool = "ffmpeg"
      return
    result.error = "ffmpeg вернул ошибку: " & run.output.strip()
    return

  if native.len > 0:
    let cmd =
      if format == "mp3":
        quoteArg(native) & " -b " & $bitrateKbps & " " &
          quoteArg(wavPath) & " " & quoteArg(outPath)
      else:
        quoteArg(native) & " -b " & $bitrateKbps & " -o " &
          quoteArg(outPath) & " " & quoteArg(wavPath)
    let run = runTool(cmd)
    if run.ok and fileExists(outPath):
      result.ok = true
      result.tool = if format == "mp3": "lame" else: "oggenc"
      return
    result.error = result.tool & " вернул ошибку: " & run.output.strip()
    return

  result.error = "кодировщик " & format & " не найден"
