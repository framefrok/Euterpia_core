# core/audio_file_io.nim
#
# Фасад для работы с аудиофайлами. Использует Variant Objects для безопасного
# и быстрого полиморфизма без использования экспериментальных concept'ов.

import std/[os, strutils]
import wav_codec
import audio_buffer

# I/O операции и аллокации памяти могут генерировать исключения.
# {.push raises: [].} здесь НЕ используется намеренно.

type
  # Variant Object: явный, безопасный и быстрый полиморфизм
  AudioDecoder* = object
    case format*: AudioFileFormat
    of afWav: wavReader*: WavReader
    of afFlac, afOgg, afMp3, afAiff: discard # Заглушки для будущих форматов

  AudioEncoder* = object
    case format*: AudioFileFormat
    of afWav: wavWriter*: WavWriter
    of afFlac, afOgg, afMp3, afAiff: discard

proc openDecoder*(path: string): AudioDecoder =
  let ext = path.splitFile().ext.toLowerAscii()
  case ext
  of ".wav", ".wave":
    result.format = afWav
    result.wavReader = openWavReader(path)
  else:
    raise newException(IOError, "Unsupported format: " & ext)

proc readFrames*(decoder: var AudioDecoder, rawBuf: ptr UncheckedArray[uint8], outBuf: ptr UncheckedArray[float32], frames: int32): int32 =
  case decoder.format
  of afWav:
    return readFrames(decoder.wavReader, rawBuf, outBuf, frames)
  else:
    return 0

proc close*(decoder: var AudioDecoder) =
  case decoder.format
  of afWav:
    close(decoder.wavReader)
  else:
    discard

proc getInfo*(decoder: AudioDecoder): AudioFileInfo =
  case decoder.format
  of afWav:
    return decoder.wavReader.info
  else:
    return AudioFileInfo()

proc openEncoder*(path: string, info: AudioFileInfo): AudioEncoder =
  let ext = path.splitFile().ext.toLowerAscii()
  case ext
  of ".wav", ".wave":
    result.format = afWav
    result.wavWriter = openWavWriter(path, info)
  else:
    raise newException(IOError, "Unsupported format: " & ext)

proc writeFrames*(encoder: var AudioEncoder, buffer: ptr UncheckedArray[float32], frames: int32) =
  case encoder.format
  of afWav:
    writeFrames(encoder.wavWriter, buffer, frames)
  else:
    discard

proc close*(encoder: var AudioEncoder) =
  case encoder.format
  of afWav:
    close(encoder.wavWriter)
  else:
    discard

proc streamFileToBuffer*(path: string, rtBuffer: var StreamingAudioBuffer) {.thread.} =
  ## Background Thread процедура.
  ## Обернута в try/except, чтобы ошибка I/O не обрушила Audio Thread хоста.
  try:
    var decoder = openDecoder(path)
    let info = decoder.getInfo()
    
    let blockSize = 4096
    let bytesPerFrame = int(info.channels) * int(info.bitsPerSample div 8)
    var rawBuf = newSeq[uint8](blockSize * bytesPerFrame)
    
    var totalFramesRead: int64 = 0
    
    while totalFramesRead < info.numFrames:
      let framesRead = decoder.readFrames(
        cast[ptr UncheckedArray[uint8]](addr rawBuf[0]),
        rtBuffer.getWritePtr(),
        int32(blockSize)
      )
      
      if framesRead == 0:
        break
      
      rtBuffer.advanceWritePtr(framesRead)
      totalFramesRead += int64(framesRead)
      
    decoder.close()
  except:
    # В фоновом потоке мы не можем пробрасывать исключения в Audio Thread.
    # Ошибки чтения просто прервут стриминг (Audio Thread заполнит остаток тишиной).
    discard

proc loadAudioFile*(path: string): tuple[samples: seq[float32], info: AudioFileInfo] =
  var decoder = openDecoder(path)
  let info = decoder.getInfo()
  result.info = info

  let totalSamples = int(info.numFrames * int64(info.channels))
  if totalSamples <= 0:
    # Пустой/оборванный файл (issue #76): 0 кадров — это валидный результат.
    # Без этой ветки `addr result.samples[0]` берётся от ПУСТОГО seq и даёт
    # IndexDefect в debug-сборке.
    decoder.close()
    result.samples = @[]
    return

  result.samples = newSeq[float32](totalSamples)

  var rawBuf = newSeq[uint8](1024 * 1024)

  let framesRead = decoder.readFrames(
    cast[ptr UncheckedArray[uint8]](addr rawBuf[0]),
    cast[ptr UncheckedArray[float32]](addr result.samples[0]),
    int32(info.numFrames)
  )

  decoder.close()

  if framesRead < int32(info.numFrames):
    result.samples.setLen(int(framesRead * int64(info.channels)))
    result.info.numFrames = int64(framesRead)

proc exportAudio*(path: string, info: AudioFileInfo, samples: openArray[float32]) =
  var encoder = openEncoder(path, info)
  
  let blockSize = 4096
  var offset = 0
  
  while offset < samples.len:
    let framesToWrite = min(blockSize, (samples.len - offset) div int(info.channels))
    let bufferPtr = cast[ptr UncheckedArray[float32]](unsafeAddr samples[offset])
    
    encoder.writeFrames(bufferPtr, int32(framesToWrite))
    offset += framesToWrite * int(info.channels)
  
  encoder.close()