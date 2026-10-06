# core/wav_codec.nim
#
# Реализация чтения/записи WAV файлов.
# I/O операции могут генерировать IOError/OSError, поэтому raises: [] не используется.

import std/[streams, os, math]

const
  MAX_RIFF_SIZE = 4_294_967_295'i64  # 4GB - 1

type
  AudioFileFormat* = enum 
    afWav
    afFlac
    afOgg
    afMp3
    afAiff
  
  AudioFileInfo* = object
    sampleRate*: int32
    channels*: int16
    bitsPerSample*: int16
    numFrames*: int64
    isFloat*: bool
    format*: AudioFileFormat
    duration*: float64

  WavReader* = object
    stream: FileStream
    info*: AudioFileInfo
    dataOffset: int64
    dataSize: int64
    currentFrame: int64

  WavWriter* = object
    stream: FileStream
    info*: AudioFileInfo
    dataOffset: int64
    bytesWritten: int64
    isRf64: bool

proc readFmtChunk(stream: FileStream, info: var AudioFileInfo, chunkSize: uint32): bool =
  let startPos = stream.getPosition()
  let audioFormat = stream.readUint16()
  info.channels = int16(stream.readUint16())
  info.sampleRate = int32(stream.readUint32())
  discard stream.readUint32()  # byteRate
  discard stream.readUint16()  # blockAlign
  info.bitsPerSample = int16(stream.readUint16())
  
  if audioFormat == 1:
    info.isFloat = false
  elif audioFormat == 3:
    info.isFloat = true
  elif audioFormat == 0xFFFE'u16:
    let cbSize = stream.readUint16()
    if cbSize >= 22:
      discard stream.readUint16()
      discard stream.readUint32()
      let subFormatCode = stream.readUint16()
      if subFormatCode == 1: info.isFloat = false
      elif subFormatCode == 3: info.isFloat = true
      else: return false
    else: return false
  else:
    return false
  
  let bytesRead = stream.getPosition() - startPos
  let skip = int64(chunkSize) - bytesRead
  if skip > 0:
    stream.setPosition(stream.getPosition() + skip)
  
  return true

proc openWavReader*(path: string): WavReader =
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  
  result.stream = newFileStream(path, fmRead)
  if result.stream == nil:
    raise newException(IOError, "Cannot open file: " & path)
  
  let riff = result.stream.readStr(4)
  let riffSize = result.stream.readUint32()
  discard riffSize # Избегаем warning
  let wave = result.stream.readStr(4)
  
  if wave != "WAVE":
    result.stream.close()
    raise newException(IOError, "Not a WAV file")
  
  let isRf64 = (riff == "RF64")
  if riff != "RIFF" and not isRf64:
    result.stream.close()
    raise newException(IOError, "Invalid RIFF header")
  
  var dataSize64 = -1'i64
  result.dataOffset = 0
  
  while not result.stream.atEnd():
    let chunkId = result.stream.readStr(4)
    let chunkSize = result.stream.readUint32()
    let startPos = result.stream.getPosition()
    
    if chunkId == "ds64" and isRf64:
      discard result.stream.readUint64()
      dataSize64 = cast[int64](result.stream.readUint64())
      discard result.stream.readUint64()
      let tableLength = result.stream.readUint32()
      result.stream.setPosition(startPos + 24 + int64(tableLength))
      
    elif chunkId == "fmt ":
      if not readFmtChunk(result.stream, result.info, chunkSize):
        result.stream.close()
        raise newException(IOError, "Unsupported PCM format")
      # Валидация заголовка СРАЗУ после fmt (#354, #103): нулевые каналы
      # давали `Defect: division by zero` при вычислении numFrames — Defect
      # не ловится `except CatchableError` в CLI, и битый файл ронял процесс
      # вместо кода возврата 2. Неподдерживаемая глубина (8 бит, 64 float)
      # читалась бы «тишиной»: в readFrames веток для неё нет.
      if result.info.channels <= 0 or result.info.channels > 512:
        result.stream.close()
        raise newException(IOError,
          "Invalid channel count: " & $result.info.channels)
      if result.info.sampleRate <= 0 or result.info.sampleRate > 768000:
        result.stream.close()
        raise newException(IOError,
          "Invalid sample rate: " & $result.info.sampleRate)
      if result.info.bitsPerSample notin [16'i16, 24'i16, 32'i16]:
        result.stream.close()
        raise newException(IOError,
          "Unsupported bit depth: " & $result.info.bitsPerSample &
          " (supported: 16, 24, 32)")
        
    elif chunkId == "data":
      result.dataOffset = startPos
      if isRf64 and dataSize64 != -1:
        result.dataSize = dataSize64
      else:
        result.dataSize = int64(chunkSize)
      break
    
    let bytesRead = result.stream.getPosition() - startPos
    let skip = int64(chunkSize) - bytesRead
    if skip > 0:
      result.stream.setPosition(result.stream.getPosition() + skip)
    
    if chunkSize mod 2 != 0:
      result.stream.setPosition(result.stream.getPosition() + 1)
  
  if result.dataOffset == 0:
    result.stream.close()
    raise newException(IOError, "No data chunk found")

  # Последний рубеж перед делением (#354): если data шёл ДО fmt (порядок
  # чанков не нормирован), заголовок ещё не прочитан — и numFrames был бы
  # делением на ноль.
  if result.info.channels <= 0 or result.info.bitsPerSample < 8:
    result.stream.close()
    raise newException(IOError, "WAV header missing or invalid (no fmt chunk)")

  let bytesPerFrame = int64(result.info.channels) * int64(result.info.bitsPerSample div 8)
  result.info.numFrames = result.dataSize div bytesPerFrame
  result.info.duration = float64(result.info.numFrames) / float64(result.info.sampleRate)
  result.info.format = afWav
  result.currentFrame = 0

proc readFrames*(reader: var WavReader, 
                 rawBuffer: ptr UncheckedArray[uint8],
                 outBuffer: ptr UncheckedArray[float32], 
                 frames: int32): int32 =
  let framesToRead = min(int64(frames), reader.info.numFrames - reader.currentFrame)
  if framesToRead <= 0:
    return 0
  
  let channels = int32(reader.info.channels)
  let bytesPerSample = reader.info.bitsPerSample div 8
  let bytesToRead = int(framesToRead) * channels * bytesPerSample
  
  reader.stream.setPosition(reader.dataOffset + reader.currentFrame * int64(channels * bytesPerSample))
  let bytesRead = reader.stream.readData(rawBuffer, bytesToRead)
  let framesRead = int32(bytesRead div (channels * bytesPerSample))
  
  for f in 0 ..< framesRead:
    for c in 0 ..< channels:
      let sampleIdx = f * channels + c
      var sampleVal: float32 = 0.0f
      
      if reader.info.bitsPerSample == 16:
        let byteIdx = sampleIdx * 2
        let intVal = int16(rawBuffer[byteIdx]) or (int16(rawBuffer[byteIdx + 1]) shl 8)
        sampleVal = float32(intVal) / 32768.0f
        
      elif reader.info.bitsPerSample == 24:
        let byteIdx = sampleIdx * 3
        var intVal = int32(rawBuffer[byteIdx]) or 
                     (int32(rawBuffer[byteIdx + 1]) shl 8) or 
                     (int32(rawBuffer[byteIdx + 2]) shl 16)
        if (rawBuffer[byteIdx + 2] and 0x80'u8) != 0:
          intVal = intVal or 0xFF000000'i32
        sampleVal = float32(intVal) / 8388608.0f
        
      elif reader.info.bitsPerSample == 32:
        let byteIdx = sampleIdx * 4
        if reader.info.isFloat:
          sampleVal = cast[ptr float32](addr rawBuffer[byteIdx])[]
        else:
          var intVal = int32(rawBuffer[byteIdx]) or 
                       (int32(rawBuffer[byteIdx + 1]) shl 8) or 
                       (int32(rawBuffer[byteIdx + 2]) shl 16) or
                       (int32(rawBuffer[byteIdx + 3]) shl 24)
          sampleVal = float32(intVal) / 2147483648.0f
      
      outBuffer[f * channels + c] = sampleVal
  
  reader.currentFrame += int64(framesRead)
  return framesRead

proc seek*(reader: var WavReader, framePosition: int64) =
  reader.currentFrame = max(0, min(framePosition, reader.info.numFrames))

proc close*(reader: var WavReader) =
  if reader.stream != nil:
    reader.stream.close()
    reader.stream = nil

proc openWavWriter*(path: string, info: AudioFileInfo): WavWriter =
  result.stream = newFileStream(path, fmWrite)
  if result.stream == nil:
    raise newException(IOError, "Cannot create file: " & path)
  
  result.info = info
  result.info.format = afWav
  result.bytesWritten = 0
  
  let expectedSize = int64(info.numFrames) * int64(info.channels) * int64(info.bitsPerSample div 8)
  result.isRf64 = (expectedSize > MAX_RIFF_SIZE)
  
  if result.isRf64:
    result.stream.write("RF64")
    # В RF64 0xFFFFFFFF — часть спецификации: реальные размеры лежат в ds64.
    result.stream.write(0xFFFFFFFF'u32)
    result.stream.write("WAVE")
    result.stream.write("ds64")
    result.stream.write(uint32(28))
    result.stream.write(0'u64)
    result.stream.write(0'u64)
    result.stream.write(0'u64)
    result.stream.write(uint32(0))
  else:
    result.stream.write("RIFF")
    # 0, а не 0xFFFFFFFF: настоящий размер пишется в close(). Если процесс
    # упадёт между open и close, на диске останется файл, который читается
    # как ПУСТОЙ, а не как «4 ГБ данных» (issue #76).
    result.stream.write(0'u32)
    result.stream.write("WAVE")
  
  result.stream.write("fmt ")
  result.stream.write(uint32(16))
  
  let audioFormat = if info.isFloat: uint16(3) else: uint16(1)
  result.stream.write(audioFormat)
  result.stream.write(uint16(info.channels))
  result.stream.write(uint32(info.sampleRate))
  
  let byteRate = uint32(info.sampleRate * int32(info.channels) * (int32(info.bitsPerSample) div 8))
  let blockAlign = uint16(info.channels * int16(info.bitsPerSample div 8))
  
  result.stream.write(byteRate)
  result.stream.write(blockAlign)
  result.stream.write(uint16(info.bitsPerSample))
  
  result.stream.write("data")
  if result.isRf64:
    result.stream.write(0xFFFFFFFF'u32)
  else:
    # Плейсхолдер 0 до close(): оборванный файл читается как пустой (#76).
    result.stream.write(0'u32)
  
  result.dataOffset = result.stream.getPosition()

proc writeFrames*(writer: var WavWriter, buffer: ptr UncheckedArray[float32], frames: int32) =
  let channels = int32(writer.info.channels)
  let bytesPerSample = writer.info.bitsPerSample div 8
  let totalSamples = frames * channels
  
  # Аллокация допустима, так как это Control/Background thread (экспорт), а не RT path
  var tempBuffer = newSeq[uint8](totalSamples * bytesPerSample)
  
  for s in 0 ..< totalSamples:
    let sample = max(-1.0f, min(1.0f, buffer[s]))
    
    if writer.info.bitsPerSample == 16:
      let intVal = int16(sample * 32767.0f)
      let byteIdx = s * 2
      tempBuffer[byteIdx] = uint8(intVal and 0xFF)
      tempBuffer[byteIdx + 1] = uint8((intVal shr 8) and 0xFF)
      
    elif writer.info.bitsPerSample == 24:
      let intVal = int32(sample * 8388607.0f)
      let byteIdx = s * 3
      tempBuffer[byteIdx] = uint8(intVal and 0xFF)
      tempBuffer[byteIdx + 1] = uint8((intVal shr 8) and 0xFF)
      tempBuffer[byteIdx + 2] = uint8((intVal shr 16) and 0xFF)
      
    elif writer.info.bitsPerSample == 32:
      if writer.info.isFloat:
        let byteIdx = s * 4
        let floatVal = sample
        tempBuffer[byteIdx] = cast[ptr array[4, uint8]](unsafeAddr floatVal)[0]
        tempBuffer[byteIdx + 1] = cast[ptr array[4, uint8]](unsafeAddr floatVal)[1]
        tempBuffer[byteIdx + 2] = cast[ptr array[4, uint8]](unsafeAddr floatVal)[2]
        tempBuffer[byteIdx + 3] = cast[ptr array[4, uint8]](unsafeAddr floatVal)[3]
      else:
        let intVal = int32(sample * 2147483647.0f)
        let byteIdx = s * 4
        tempBuffer[byteIdx] = uint8(intVal and 0xFF)
        tempBuffer[byteIdx + 1] = uint8((intVal shr 8) and 0xFF)
        tempBuffer[byteIdx + 2] = uint8((intVal shr 16) and 0xFF)
        tempBuffer[byteIdx + 3] = uint8((intVal shr 24) and 0xFF)
  
  writer.stream.writeData(addr tempBuffer[0], tempBuffer.len)
  writer.bytesWritten += int64(tempBuffer.len)
  writer.info.numFrames += int64(frames)

proc close*(writer: var WavWriter) =
  if writer.stream == nil:
    return
  
  if writer.isRf64:
    let totalSize = writer.dataOffset + writer.bytesWritten - 8
    writer.stream.setPosition(20)
    writer.stream.write(uint64(totalSize))
    writer.stream.setPosition(28)
    writer.stream.write(uint64(writer.bytesWritten))
    writer.stream.setPosition(36)
    writer.stream.write(uint64(writer.info.numFrames))
  else:
    writer.stream.setPosition(4)
    let fileSize = uint32(writer.dataOffset + writer.bytesWritten - 8)
    writer.stream.write(fileSize)
    writer.stream.setPosition(writer.dataOffset - 4)
    let dataSize = uint32(writer.bytesWritten)
    writer.stream.write(dataSize)
  
  writer.stream.close()
  writer.stream = nil