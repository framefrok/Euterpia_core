# commons/codecs/aiff.nim
#
# AIFF/AIFC (issue #10). Чистый Nim: формат простой (chunk-структура как у
# RIFF, но big-endian), и держать ради него C-зависимость незачем.
#
# Что поддерживается:
#   * AIFF — PCM 16/24/32 бита, big-endian;
#   * AIFC с `NONE` (big-endian PCM), `sowt` (little-endian PCM) и
#     `fl32`/`fl64` (float) — так сохраняют sndfile/Logic.
# Encode пишет обычный AIFF PCM 16/24.
#
# Ошибки — значением (bool/пустой seq), а не исключением: битый файл это
# нормальный исход клиента, а не паника.

import std/[os, math]

type
  AiffInfo* = object
    channels*: int
    sampleRate*: int
    bitsPerSample*: int
    isFloat*: bool
    frames*: int64

# ---------------------------------------------------------------------------
# big-endian чтение
# ---------------------------------------------------------------------------

proc rdU16(b: string; o: int): uint16 {.inline.} =
  (uint16(b[o].ord) shl 8) or uint16(b[o + 1].ord)

proc rdU32(b: string; o: int): uint32 {.inline.} =
  (uint32(b[o].ord) shl 24) or (uint32(b[o + 1].ord) shl 16) or
    (uint32(b[o + 2].ord) shl 8) or uint32(b[o + 3].ord)

proc rdFourCC(b: string; o: int): string {.inline.} =
  b[o .. o + 3]

proc readExtended80(b: string; o: int): float64 =
  ## 80-битный IEEE 754 extended (big-endian): 1 знак, 15 экспонента,
  ## 64 мантисса (старший бит = целая единица). Именно так в AIFF хранится SR.
  let sign = (b[o].ord shr 7) and 1
  let exp = (uint16(b[o].ord and 0x7F) shl 8) or uint16(b[o + 1].ord)
  var mant = 0'u64
  for i in 0 ..< 8:
    mant = (mant shl 8) or uint64(b[o + 2 + i].ord)
  if exp == 0 and mant == 0:
    return 0.0
  let e = int(exp) - 16383 - 63
  var v = float64(mant) * pow(2.0, float64(e))
  if sign == 1:
    v = -v
  v

proc writeExtended80(rate: float64): array[10, uint8] =
  ## 80-битный extended — 10 байт: 2 байта (знак+экспонента) + 8 мантиссы.
  var r = rate
  if r <= 0:
    r = 44100.0
  var k = 0
  while r >= 18446744073709551616.0:  # 2^64
    r /= 2.0
    inc k
  while r < 9223372036854775808.0:    # 2^63
    r *= 2.0
    dec k
  let mant = uint64(r)
  let expField = 16383 + 63 + k
  result[0] = uint8((expField shr 8) and 0x7F)
  result[1] = uint8(expField and 0xFF)
  for i in 0 ..< 8:
    result[2 + i] = uint8((mant shr (56 - 8 * i)) and 0xFF)

# ---------------------------------------------------------------------------
# Чтение
# ---------------------------------------------------------------------------

proc probeAiff*(path: string; info: var AiffInfo): bool =
  ## Метаданные AIFF/AIFC. `false` — файл не наш/битый.
  if not fileExists(path):
    return false
  var data: string
  try:
    data = readFile(path)
  except CatchableError:
    return false
  if data.len < 12 or rdFourCC(data, 0) != "FORM":
    return false
  let formType = rdFourCC(data, 8)
  if formType != "AIFF" and formType != "AIFC":
    return false

  var commFound = false
  var pos = 12
  while pos + 8 <= data.len:
    let id = rdFourCC(data, pos)
    let size = int(rdU32(data, pos + 4))
    let body = pos + 8
    if id == "COMM":
      if body + 18 > data.len:
        return false
      let channels = int(rdU16(data, body))
      let numFrames = int64(rdU32(data, body + 2))
      let bits = int(rdU16(data, body + 6))
      let sr = readExtended80(data, body + 8)
      if channels <= 0 or bits <= 0 or sr <= 0.0:
        return false
      info.channels = channels
      info.bitsPerSample = bits
      info.sampleRate = int(sr + 0.5)
      info.frames = numFrames
      info.isFloat = false
      if formType == "AIFC" and size >= 22 and body + 22 <= data.len:
        let comp = rdFourCC(data, body + 18)
        case comp
        of "NONE", "sowt": discard
        of "fl32", "FL32": info.isFloat = true; info.bitsPerSample = 32
        of "fl64", "FL64": info.isFloat = true; info.bitsPerSample = 64
        else: return false
      commFound = true
    pos = body + size
    if size mod 2 != 0:
      inc pos

  commFound


proc readAiffAll*(path: string; info: var AiffInfo): seq[float32] =
  ## Весь файл в interleaved float32. Пустой seq — ошибка.
  if not probeAiff(path, info):
    return @[]
  var data: string
  try:
    data = readFile(path)
  except CatchableError:
    return @[]

  let formType = rdFourCC(data, 8)
  var littleEndian = false
  var pos = 12
  var ssndBody = -1
  var ssndSize = 0
  while pos + 8 <= data.len:
    let id = rdFourCC(data, pos)
    let size = int(rdU32(data, pos + 4))
    let body = pos + 8
    if id == "COMM" and formType == "AIFC" and body + 22 <= data.len:
      if rdFourCC(data, body + 18) == "sowt":
        littleEndian = true
    elif id == "SSND":
      ssndBody = body
      ssndSize = size
    pos = body + size
    if size mod 2 != 0:
      inc pos

  if ssndBody < 0 or ssndBody + 8 > data.len:
    return @[]

  let channels = info.channels
  let bits = info.bitsPerSample
  let isFloat = info.isFloat
  let offset = int(rdU32(data, ssndBody))
  let start = ssndBody + 8 + offset
  let bytesPerSample = bits div 8
  if bytesPerSample <= 0 or start > data.len:
    return @[]
  var available = ssndSize - 8 - offset
  if available <= 0 or start + available > data.len:
    available = data.len - start
  var frames = int64(available div (bytesPerSample * channels))
  if info.frames > 0 and frames > info.frames:
    frames = info.frames
  if frames <= 0:
    return @[]

  result = newSeq[float32](int(frames) * channels)
  var o = start
  for f in 0 ..< int(frames):
    for c in 0 ..< channels:
      var v = 0.0f
      if isFloat and bits == 32:
        var u: uint32
        if littleEndian:
          u = uint32(data[o].ord) or (uint32(data[o + 1].ord) shl 8) or
              (uint32(data[o + 2].ord) shl 16) or (uint32(data[o + 3].ord) shl 24)
        else:
          u = rdU32(data, o)
        v = cast[ptr float32](addr u)[]
      elif bits == 16:
        var iv: int32
        if littleEndian:
          iv = int32(cast[int16](uint16(data[o].ord) or
                                 (uint16(data[o + 1].ord) shl 8)))
        else:
          iv = int32(cast[int16](rdU16(data, o)))
        v = float32(iv) / 32768.0f
      elif bits == 24:
        var iv: int32
        if littleEndian:
          iv = int32(data[o].ord) or (int32(data[o + 1].ord) shl 8) or
               (int32(data[o + 2].ord) shl 16)
        else:
          iv = (int32(data[o].ord) shl 16) or (int32(data[o + 1].ord) shl 8) or
               int32(data[o + 2].ord)
        if (iv and 0x800000) != 0:
          iv = iv or (not 0xFFFFFF)
        v = float32(iv) / 8388608.0f
      elif bits == 32:
        var iv: int32
        if littleEndian:
          iv = int32(data[o].ord) or (int32(data[o + 1].ord) shl 8) or
               (int32(data[o + 2].ord) shl 16) or (int32(data[o + 3].ord) shl 24)
        else:
          iv = int32(rdU32(data, o))
        v = float32(iv) / 2147483648.0f
      else:
        return @[]
      result[f * channels + c] = v
      o += bytesPerSample


# ---------------------------------------------------------------------------
# Запись (PCM 16/24, big-endian)
# ---------------------------------------------------------------------------

proc putU16BE(dst: var string; v: uint16) =
  dst.add char((v shr 8) and 0xFF'u16)
  dst.add char(v and 0xFF'u16)

proc putU32BE(dst: var string; v: uint32) =
  dst.add char((v shr 24) and 0xFF'u32)
  dst.add char((v shr 16) and 0xFF'u32)
  dst.add char((v shr 8) and 0xFF'u32)
  dst.add char(v and 0xFF'u32)

proc writeAiff*(path: string; channels, sampleRate, bitsPerSample: int;
                samples: openArray[float32]): bool =
  ## Записать AIFF PCM 16/24 бита (big-endian). `false` — ошибка записи.
  if channels <= 0 or sampleRate <= 0:
    return false
  let bits = if bitsPerSample == 24: 24 else: 16
  let bytesPerSample = bits div 8
  let frames = samples.len div channels
  if frames <= 0:
    return false

  var body: string
  body.add "COMM"
  putU32BE(body, 18'u32)
  putU16BE(body, uint16(channels))
  putU32BE(body, uint32(frames))
  putU16BE(body, uint16(bits))
  for b in writeExtended80(float64(sampleRate)):
    body.add char(b)

  let dataBytes = frames * channels * bytesPerSample
  body.add "SSND"
  putU32BE(body, uint32(8 + dataBytes))
  putU32BE(body, 0'u32)  # offset
  putU32BE(body, 0'u32)  # blockSize

  var pcm = newString(dataBytes)
  var w = 0
  for s in samples:
    var y = s
    if y != y:
      y = 0.0f
    if y > 1.0f:
      y = 1.0f
    elif y < -1.0f:
      y = -1.0f
    if bits == 16:
      let iv = cast[uint16](int16(y * 32767.0f))
      pcm[w] = char((iv shr 8) and 0xFF'u16)
      pcm[w + 1] = char(iv and 0xFF'u16)
      w += 2
    else:
      let iv = cast[uint32](int32(y * 8388607.0f))
      pcm[w] = char((iv shr 16) and 0xFF'u32)
      pcm[w + 1] = char((iv shr 8) and 0xFF'u32)
      pcm[w + 2] = char(iv and 0xFF'u32)
      w += 3

  var formData = "FORM"
  putU32BE(formData, uint32(4 + body.len + pcm.len))
  formData.add "AIFF"
  formData.add body
  formData.add pcm

  try:
    writeFile(path, formData)
    true
  except CatchableError:
    false

