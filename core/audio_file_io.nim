# core/audio_file_io.nim
#
# Фасад для работы с аудиофайлами. Использует Variant Objects для безопасного
# и быстрого полиморфизма без использования экспериментальных concept'ов.

import std/[os, strutils]
import codec_api
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
  ##
  ## Запись идёт через двухсегментный `getWritePtr(framesRequested)` (#357):
  ## старый однопараметровый `getWritePtr()` не разбивал запись на границе
  ## кольца и не смотрел на свободное место, поэтому readFrames писал до
  ## `blockSize` фреймов за конец аллокации — «спящий» heap overflow (кламп в
  ## commitWrite срабатывал уже ПОСЛЕ записи). Теперь readFrames получает
  ## ровно те сегменты, что вернуло кольцо, а когда места нет — поток уступает
  ## процессор Audio Thread.
  try:
    var decoder = openDecoder(path)
    let info = decoder.getInfo()

    let channels = int(info.channels)
    let bytesPerFrame = max(1, channels * int(info.bitsPerSample div 8))

    const blockSize = 4096
    var rawBuf = newSeq[uint8](blockSize * bytesPerFrame)

    var framesRemaining = info.numFrames
    while framesRemaining > 0:
      # До двух непрерывных сегментов внутри кольца; n1 + n2 никогда не
      # выходит за аллокацию, а суммарно не превышает свободное место.
      let (p1, p2, n1, n2) = rtBuffer.getWritePtr(int32(blockSize))
      let capacity = n1 + n2
      if capacity <= 0:
        # Кольцо полно: ждём, пока Audio Thread освободит место.
        sleep(1)
        continue

      var committed = 0'i32
      let got1 = decoder.readFrames(
        cast[ptr UncheckedArray[uint8]](addr rawBuf[0]), p1, n1)
      committed += got1
      # Второй сегмент читаем только если первый заполнен целиком (иначе
      # это конец файла посреди сегмента — читать «через границу» нельзя).
      if got1 == n1 and n2 > 0:
        committed += decoder.readFrames(
          cast[ptr UncheckedArray[uint8]](addr rawBuf[0]), p2, n2)

      if committed <= 0:
        break  # конец файла
      rtBuffer.commitWrite(committed)
      framesRemaining -= int64(committed)
      if committed < capacity:
        break  # конец файла: прочитано меньше, чем было свободного места

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

  # Чтение БЛОКАМИ, а не файл целиком (#355): раньше один вызов readFrames
  # клал весь файл в raw-буфер фиксированных 1 МиБ, и файл длиннее ~6 секунд
  # (стерео, 16 бит, 44.1 кГц) переполнял кучу — ASan падал, обычной сборкой
  # это порча памяти рядом с seq. Размер блока — в КАДРАХ, поэтому и
  # `int32(frames)` в вызове не переполняется на многочасовых файлах.
  const blockSize = 4096
  let bytesPerFrame = max(1, int(info.channels) * int(info.bitsPerSample div 8))
  var rawBuf = newSeq[uint8](blockSize * bytesPerFrame)

  var framesDone: int64 = 0
  while framesDone < info.numFrames:
    let want = int32(min(int64(blockSize), info.numFrames - framesDone))
    let offset = int(framesDone * int64(info.channels))
    let framesRead = decoder.readFrames(
      cast[ptr UncheckedArray[uint8]](addr rawBuf[0]),
      cast[ptr UncheckedArray[float32]](addr result.samples[offset]),
      want)
    if framesRead <= 0:
      break
    framesDone += int64(framesRead)
    if framesRead < want:
      break

  decoder.close()

  if framesDone < info.numFrames:
    result.samples.setLen(int(framesDone * int64(info.channels)))
    result.info.numFrames = framesDone

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