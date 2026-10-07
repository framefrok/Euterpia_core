# commons/codecs/decoders.nim
#
# Декодирование сжатых аудиоформатов (issue #10): FLAC, MP3, OGG Vorbis.
#
# Где живёт и почему (решение по открытому вопросу issue #10): Commons —
# самый нижний слой, он не знает ни Core, ни Nodes, ни клиентов. Кодек — это
# «превратить файл в сэмплы», без модели проекта и без аудиоустройства, поэтому
# его место здесь (§15: Commons — не свалка, а самостоятельные утилиты без
# зависимостей вверх). Core (`core/audio_file_io`) импортирует Commons — это
# разрешено направлением слоёв (`core → commons`), а обратное запрещено.
#
# Реализация — вендоренные single-header библиотеки (public domain / MIT):
#   dr_flac.h (mackron/dr_libs), dr_mp3.h (mackron/dr_libs), stb_vorbis.c
#   (nothings/stb). Ноль внешних зависимостей, ноль системных пакетов.
# Мост — плоский C-ABI `csrc/codec_shim.h` (layout библиотек прячется в C).
#
# Encode сюда НЕ входит: у названных библиотек нет энкодеров, а WAV/AIFF
# пишутся ядром (`core/wav_codec`, `commons/codecs/aiff`). `encode` для
# FLAC/MP3/OGG честно отвечает «не поддерживается», а не тихо портит файл.

import std/os

{.passC: "-I" & (currentSourcePath.parentDir / "csrc") & "/".}
{.compile: ("csrc/codec_shim.c", "eut_codec_shim.o").}

const
  EutCodecFlac = 1.cint
  EutCodecMp3 = 2.cint
  EutCodecVorbis = 3.cint

proc eut_codec_ready(kind: cint): cint {.importc, cdecl.}
proc eut_codec_probe(path: cstring, kind: cint, channels: ptr cint,
                     sampleRate: ptr cint, frames: ptr clonglong): cint
  {.importc, cdecl.}
proc eut_codec_decode(path: cstring, kind: cint, outBuf: ptr float32,
                      maxFrames: clonglong): clonglong {.importc, cdecl.}

type
  CodecKind* = enum
    ## Форматы, которые умеет этот модуль (WAV и AIFF живут отдельно).
    ckFlac = 1
    ckMp3 = 2
    ckVorbis = 3

  CodecInfo* = object
    ## Метаданные декодируемого файла.
    channels*: int
    sampleRate*: int
    frames*: int64

proc codecKindOrd(kind: CodecKind): cint {.inline.} =
  cint(ord(kind))

proc ready*(kind: CodecKind): bool =
  ## Готов ли кодек (все вендоренные библиотеки вкомпилены → всегда да).
  eut_codec_ready(codecKindOrd(kind)) != 0

proc probeCodec*(path: string; kind: CodecKind; info: var CodecInfo): bool =
  ## Метаданные файла. `false` — файл не открылся (битый, усечённый, чужой).
  var ch, sr: cint
  var fr: clonglong
  let rc = eut_codec_probe(path.cstring, codecKindOrd(kind),
                           addr ch, addr sr, addr fr)
  if rc != 0:
    return false
  info = CodecInfo(channels: int(ch), sampleRate: int(sr), frames: int64(fr))
  info.channels > 0 and info.sampleRate > 0 and info.frames > 0

proc decodeCodec*(path: string; kind: CodecKind): seq[float32] =
  ## Декодирует весь файл в interleaved float32. Ошибка — пустой seq
  ## (битый/усечённый файл не должен ни падать, ни возвращать мусор).
  var info: CodecInfo
  if not probeCodec(path, kind, info):
    return @[]
  let total = int(info.frames) * info.channels
  if total <= 0:
    return @[]
  result = newSeq[float32](total)
  let got = eut_codec_decode(path.cstring, codecKindOrd(kind),
                             cast[ptr float32](addr result[0]),
                             clonglong(info.frames))
  if got <= 0:
    return @[]
  if int64(got) < info.frames:
    result.setLen(int(int64(got)) * info.channels)
