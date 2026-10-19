# core/flac_codec.nim
#
# FLAC-энкодер (issue #411, продолжение #209).
#
# Зачем свой энкодер, если ядро умеет FLAC читать (#10):
#   * «сдача во FLAC lossless» без энкодера — обещание, а не функция;
#   * вендорить C-кодек нельзя: ядро не тянет внешних зависимостей (§8);
#   * формат FLAC позволяет ПРОСТОЙ корректный энкодер: VERBATIM-субфреймы
#     (сырые сэмплы) плюс обязательные CRC. Файл получается больше, чем у
#     libFLAC (нет предсказания), но он LOSSLESS и читается любым
#     декодером, включая `flac -t` и dr_flac, которым ядро читает FLAC.
#
# Что пишется:
#   * `fLaC` + STREAMINFO (block size 4096, 16/24/32 бита, SR проекта);
#   * кадры фиксированного размера с VERBATIM-субфреймами;
#   * CRC-8 заголовка и CRC-16 кадра — без них декодер обязан отвергнуть
#     файл, поэтому «примерно правильный» поток не годится;
#   * STREAMINFO.total_samples дописывается при закрытии (seek назад).
#
# Realtime-влияние: только control-path (экспорт), audio callback не
# затрагивается. Dither — тот же детерминированный TPDF, что у WAV (#209),
# и только для целочисленных форматов.

import std/[math]

import codec_api

const
  FlacBlockSize* = 4096
  FlacMaxChannels* = 2
  FlacStreamInfoBytes = 34

type
  FlacWriter* = object
    ## Состояние энкодера. Control-path: живёт на стеке вызывающего,
    ## аллокации допустимы (это не RT).
    file: File
    info*: AudioFileInfo
    channels: int
    bits: int
    framesWritten*: int64
    frameIndex: uint32
    blockFill: int32
    blocks: array[FlacMaxChannels, seq[int32]]
    frameBuf: seq[byte]
    ditherState: uint32
    opened: bool

proc crc8(data: openArray[byte]): uint8 =
  ## CRC-8 FLAC: полином 0x07, init 0.
  result = 0'u8
  for b in data:
    result = result xor b
    for _ in 0 ..< 8:
      if (result and 0x80'u8) != 0'u8:
        result = (result shl 1) xor 0x07'u8
      else:
        result = result shl 1

proc crc16(data: openArray[byte]): uint16 =
  ## CRC-16 FLAC: полином 0x8005, init 0.
  var crc = 0'u16
  for b in data:
    crc = crc xor (uint16(b) shl 8)
    for _ in 0 ..< 8:
      if (crc and 0x8000'u16) != 0'u16:
        crc = (crc shl 1) xor 0x8005'u16
      else:
        crc = crc shl 1
  crc

proc appendUtf8(dst: var seq[byte]; value: uint32) =
  ## Номер кадра FLAC кодируется UTF-8 (как в спецификации).
  if value < 0x80'u32:
    dst.add byte(value)
  elif value < 0x800'u32:
    dst.add byte(0xC0'u32 or (value shr 6))
    dst.add byte(0x80'u32 or (value and 0x3F'u32))
  elif value < 0x10000'u32:
    dst.add byte(0xE0'u32 or (value shr 12))
    dst.add byte(0x80'u32 or ((value shr 6) and 0x3F'u32))
    dst.add byte(0x80'u32 or (value and 0x3F'u32))
  else:
    dst.add byte(0xF0'u32 or (value shr 18))
    dst.add byte(0x80'u32 or ((value shr 12) and 0x3F'u32))
    dst.add byte(0x80'u32 or ((value shr 6) and 0x3F'u32))
    dst.add byte(0x80'u32 or (value and 0x3F'u32))

proc writeStreamInfo(w: var FlacWriter; totalSamples: int64) =
  ## 34 байта STREAMINFO. Пишется дважды: при открытии (total=0) и при
  ## закрытии (точное число кадров).
  var si: array[FlacStreamInfoBytes, byte]
  si[0] = byte((FlacBlockSize shr 8) and 0xFF)
  si[1] = byte(FlacBlockSize and 0xFF)
  si[2] = byte((FlacBlockSize shr 8) and 0xFF)
  si[3] = byte(FlacBlockSize and 0xFF)
  # min/max frame size = 0 (неизвестно; декодеру это не нужно).
  for i in 4 .. 9:
    si[i] = 0
  let sr = uint64(w.info.sampleRate) and 0xFFFFF'u64
  let ch = uint64(w.channels - 1) and 0x7'u64
  let bps = uint64(w.bits - 1) and 0x1F'u64
  let total = uint64(totalSamples) and 0xFFFFFFFFF'u64
  let packed = (sr shl 44) or (ch shl 41) or (bps shl 36) or total
  for i in 0 ..< 8:
    si[10 + i] = byte((packed shr (56 - 8 * i)) and 0xFF'u64)
  # MD5 = 0: «не вычислялся». Это допустимо по спецификации.
  for i in 18 ..< FlacStreamInfoBytes:
    si[i] = 0
  setFilePos(w.file, 8)
  discard writeBuffer(w.file, addr si[0], FlacStreamInfoBytes)

proc openFlacWriter*(path: string; info: AudioFileInfo): FlacWriter =
  ## Открыть FLAC-поток. Ошибки — `IOError` (как у WAV-писателя).
  if info.channels <= 0 or info.channels > int16(FlacMaxChannels):
    raise newException(IOError, "FLAC: поддерживается 1 или 2 канала")
  if info.bitsPerSample notin [16'i16, 24'i16, 32'i16]:
    raise newException(IOError, "FLAC: глубина 16, 24 или 32 бита")
  if info.sampleRate <= 0:
    raise newException(IOError, "FLAC: частота дискретизации должна быть > 0")

  result.info = info
  result.channels = int(info.channels)
  result.bits = int(info.bitsPerSample)
  result.ditherState = 0x9E3779B9'u32
  result.frameBuf = newSeq[byte](FlacBlockSize * FlacMaxChannels * 4 + 64)
  for ch in 0 ..< result.channels:
    result.blocks[ch] = newSeq[int32](FlacBlockSize)

  result.file = open(path, fmWrite)
  if result.file.isNil:
    raise newException(IOError, "не удалось открыть FLAC-файл: " & path)
  var marker: array[4, byte] = [byte('f'), byte('L'), byte('a'), byte('C')]
  discard writeBuffer(result.file, addr marker[0], 4)
  var header: array[4, byte] = [0x80'u8, 0x00'u8, 0x00'u8, 0x22'u8]
    # last-metadata-block | type 0 | length 34
  discard writeBuffer(result.file, addr header[0], 4)
  result.writeStreamInfo(0)
  result.opened = true

proc nextDitherNoise(w: var FlacWriter): float32 =
  ## Детерминированный TPDF (±1 LSB): повторный экспорт даёт те же байты.
  var x = w.ditherState
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  w.ditherState = x
  let a = float32(x and 0xFFFF'u32)
  let b = float32((x shr 16) and 0xFFFF'u32)
  let scale =
    case w.bits
    of 16: 32767.0'f32
    of 24: 8388607.0'f32
    else: 2147483647.0'f32
  (a - b) / 65536.0f / scale

proc appendSample(dst: var seq[byte]; sample: int32; bits: int) =
  ## VERBATIM-сэмпл: big-endian, два дополнения, ровно `bits` бит
  ## (16/24/32 кратны байту — побитовой упаковки не нужно).
  if bits == 16:
    let v = uint16(sample and 0xFFFF)
    dst.add byte(v shr 8)
    dst.add byte(v and 0xFF)
  elif bits == 24:
    let v = uint32(sample) and 0xFFFFFF'u32
    dst.add byte((v shr 16) and 0xFF)
    dst.add byte((v shr 8) and 0xFF)
    dst.add byte(v and 0xFF)
  else:
    let v = uint32(sample)
    dst.add byte((v shr 24) and 0xFF)
    dst.add byte((v shr 16) and 0xFF)
    dst.add byte((v shr 8) and 0xFF)
    dst.add byte(v and 0xFF)

proc flushFrame(w: var FlacWriter) =
  ## Записать один кадр из накопленного блока.
  if w.blockFill <= 0 or not w.opened:
    return
  let count = int(w.blockFill)
  var frame: seq[byte] = @[]
  frame.add 0xFF'u8
  frame.add 0xF8'u8        # sync + reserved 0 + fixed blocksize

  let blockCode: uint8 =
    if count == FlacBlockSize: 12'u8   # 0b1100 = 4096
    else: 7'u8                        # 16-битный размер в конце заголовка
  frame.add byte((blockCode shl 4) or 0'u8)  # sample rate: из STREAMINFO
  frame.add byte((w.channels - 1) shl 4)
    # channel assignment + sample size (0 = из STREAMINFO)
  appendUtf8(frame, w.frameIndex)
  if blockCode == 7'u8:
    let size = uint16(count - 1)
    frame.add byte(size shr 8)
    frame.add byte(size and 0xFF)
  let headerCrc = crc8(frame)
  frame.add headerCrc

  for ch in 0 ..< w.channels:
    frame.add 0x02'u8      # VERBATIM, wasted-bits = 0
    for i in 0 ..< count:
      appendSample(frame, w.blocks[ch][i], w.bits)

  let frameCrc = crc16(frame)
  frame.add byte(frameCrc shr 8)
  frame.add byte(frameCrc and 0xFF)
  discard writeBuffer(w.file, addr frame[0], frame.len)
  inc w.frameIndex
  w.blockFill = 0

proc writeFrames*(w: var FlacWriter; buffer: ptr UncheckedArray[float32];
                  frames: int32) =
  ## Записать interleaved float32. Квантование — то же, что у WAV:
  ## NaN → 0, клиппинг в [-1, 1], dither только для 16/24/32 бит.
  if not w.opened or buffer.isNil or frames <= 0:
    return
  let channels = w.channels
  let useDither = w.info.dither
  var s = 0
  let total = int(frames) * channels
  while s < total:
    let ch = s mod channels
    var sample = buffer[s]
    if sample != sample:
      sample = 0.0f
    if useDither:
      sample += nextDitherNoise(w)
    if sample > 1.0f:
      sample = 1.0f
    elif sample < -1.0f:
      sample = -1.0f
    let scale =
      case w.bits
      of 16: 32767.0'f32
      of 24: 8388607.0'f32
      else: 2147483647.0'f32
    w.blocks[ch][w.blockFill] = int32(round(sample * scale))
    inc s
    if ch == channels - 1:
      inc w.blockFill
      if w.blockFill >= int32(FlacBlockSize):
        w.flushFrame()
  w.framesWritten += int64(frames)

proc close*(w: var FlacWriter) =
  if not w.opened:
    return
  w.flushFrame()
  # Точное число кадров: без него декодер не знает длительность.
  w.writeStreamInfo(w.framesWritten)
  flushFile(w.file)
  close(w.file)
  w.opened = false

proc flacEncoderAvailable*(): bool {.inline.} =
  ## Энкодер встроен: внешняя библиотека не нужна.
  true

