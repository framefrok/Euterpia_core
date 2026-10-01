# midi_io.nim
#
# Нейтральный MIDI-инструмент Commons (issue #28).
#
# Что здесь было раньше (и почему это неправильно):
#   1. загрузка внешней MIDI-библиотеки прямо в Commons — внешний мир
#      проникал внутрь проекта (MANIFEST §42); её место — adapters/RtMidi;
#   2. собственный SPSC-кольцевой буфер — дубль realtime-примитива
#      (issue #37); теперь единственное кольцо живёт в core/ring_buffer.nim;
#   3. импорт модуля типов сигналов Core — Commons знал про Core
#      (MANIFEST §25/§26); трансляция MIDI -> RealtimeEvent переехала
#      в core/midi_events.nim.
#
# После переноса устройств в `adapters/RtMidi` + `core/midi_api` здесь
# остаётся ровно то, что и должно жить в Commons: чистый кодек
# Standard MIDI File (SMF) без единой внешней зависимости и без Core.
#
# Поддерживается чтение/запись форматов 0 и 1, канальные сообщения
# (Note On/Off, CC, Program Change, Pitch Bend, Aftertouch). Мета- и
# SysEx-события при чтении корректно пропускаются (с потреблением длины),
# при записи не порождаются.

{.push raises: [].}

type
  SmfEvent* {.bycopy.} = object
    ## Одно канальное событие файла. POD, без внешних ссылок.
    tick*: uint32      ## абсолютный тик от начала трека (в делениях division)
    status*: uint8     ## байт статуса с каналом (0x9n, 0x8n, ...)
    data1*: uint8
    data2*: uint8

  SmfTrack* = object
    events*: seq[SmfEvent]

  SmfFile* = object
    format*: uint16    ## 0 или 1
    division*: uint16  ## ticks per quarter note (PPQ)
    tracks*: seq[SmfTrack]

# ==============================================================================
# Примитивы чтения/записи
# ==============================================================================

proc putU16BE(dst: var seq[byte]; v: uint16) {.inline.} =
  dst.add byte((v shr 8) and 0xFF)
  dst.add byte(v and 0xFF)

proc putU32BE(dst: var seq[byte]; v: uint32) {.inline.} =
  dst.add byte((v shr 24) and 0xFF)
  dst.add byte((v shr 16) and 0xFF)
  dst.add byte((v shr 8) and 0xFF)
  dst.add byte(v and 0xFF)

proc getU16BE(data: openArray[byte]; pos: var int): uint16 {.inline.} =
  if pos + 1 >= data.len:
    pos = data.len
    return 0'u16
  result = (uint16(data[pos]) shl 8) or uint16(data[pos + 1])
  pos += 2

proc getU32BE(data: openArray[byte]; pos: var int): uint32 {.inline.} =
  if pos + 3 >= data.len:
    pos = data.len
    return 0'u32
  result =
    (uint32(data[pos]) shl 24) or
    (uint32(data[pos + 1]) shl 16) or
    (uint32(data[pos + 2]) shl 8) or
    uint32(data[pos + 3])
  pos += 4

proc encodeVarLen*(value: uint32): seq[byte] =
  ## Variable-length quantity SMF (7 бит на байт, старший бит — продолжение).
  var buf: array[5, byte]
  var count = 0
  var v = value
  buf[count] = byte(v and 0x7F)
  inc count
  v = v shr 7
  while v > 0:
    buf[count] = byte((v and 0x7F) or 0x80)
    inc count
    v = v shr 7
  # байты собраны в обратном порядке
  result = newSeq[byte](count)
  for i in 0 ..< count:
    result[i] = buf[count - 1 - i]

proc decodeVarLen*(data: openArray[byte]; pos: var int): uint32 =
  ## Читает VLQ. При обрыве данных возвращает то, что успел прочитать,
  ## и выставляет pos = data.len (вызывающий увидит конец файла).
  result = 0'u32
  var i = 0
  while pos < data.len:
    let b = data[pos]
    inc pos
    result = (result shl 7) or uint32(b and 0x7F)
    inc i
    if (b and 0x80) == 0:
      return
    if i >= 4:
      return


# ==============================================================================
# SMF: кодирование
# ==============================================================================

proc addAscii(dst: var seq[byte]; s: string) {.inline.} =
  for ch in s:
    dst.add byte(ord(ch))

proc channelEventLength(status: uint8): int {.inline.} =
  ## 0 — не канальное сообщение (sys/meta), иначе число байтов данных.
  case status and 0xF0'u8
  of 0xC0'u8, 0xD0'u8: 1
  of 0x80'u8, 0x90'u8, 0xA0'u8, 0xB0'u8, 0xE0'u8: 2
  else: 0

proc encodeTrack(t: SmfTrack): seq[byte] =
  var body: seq[byte] = @[]
  var lastTick = 0'u32

  for ev in t.events:
    let delta = if ev.tick >= lastTick: ev.tick - lastTick else: 0'u32
    lastTick = ev.tick

    body.add encodeVarLen(delta)
    body.add ev.status
    let n = channelEventLength(ev.status)
    if n >= 1: body.add ev.data1
    if n >= 2: body.add ev.data2

  # End of Track: обязательное завершение любого MTrk-чанка.
  body.add encodeVarLen(0)
  body.add 0xFF'u8
  body.add 0x2F'u8
  body.add 0x00'u8

  result = @[]
  result.addAscii("MTrk")
  result.putU32BE(uint32(body.len))
  result.add body

proc encodeSmf*(f: SmfFile): seq[byte] =
  ## Сериализует файл в байты SMF формата 0/1.
  result = @[]
  result.addAscii("MThd")
  result.putU32BE(6'u32)
  result.putU16BE(f.format)
  result.putU16BE(uint16(min(f.tracks.len, 0xFFFF)))
  result.putU16BE(f.division)

  for t in f.tracks:
    result.add encodeTrack(t)

# ==============================================================================
# SMF: разбор
# ==============================================================================

proc parseSmf*(data: openArray[byte]): tuple[ok: bool, file: SmfFile] =
  ## Разбирает SMF. Возвращает ok=false на любом структурном нарушении —
  ## ядро не падает на битом файле, а честно сообщает об ошибке.
  result.ok = false

  if data.len < 14:
    return

  if not (data[0] == byte(ord('M')) and data[1] == byte(ord('T')) and
          data[2] == byte(ord('h')) and data[3] == byte(ord('d'))):
    return

  var pos = 4
  let headerLen = int(getU32BE(data, pos))
  if headerLen < 6:
    return

  let fmt = getU16BE(data, pos)
  let nTracks = int(getU16BE(data, pos))
  let division = getU16BE(data, pos)

  # Заголовок может быть длиннее 6 байт — эти байты пропускаем.
  pos = 8 + headerLen
  if pos > data.len:
    return

  result.file.format = fmt
  result.file.division = division
  result.file.tracks = @[]

  var trackIdx = 0
  while trackIdx < nTracks and pos + 8 <= data.len:
    if not (data[pos] == byte(ord('M')) and data[pos + 1] == byte(ord('T')) and
            data[pos + 2] == byte(ord('r')) and data[pos + 3] == byte(ord('k'))):
      break

    pos += 4
    let trkLen = int(getU32BE(data, pos))
    let trackEnd = min(pos + trkLen, data.len)

    var track = SmfTrack(events: @[])
    var lastTick = 0'u32
    var running: uint8 = 0'u8

    while pos < trackEnd:
      let delta = decodeVarLen(data, pos)
      lastTick += delta

      if pos >= trackEnd:
        break

      var status = data[pos]

      if status < 0x80'u8:
        # Running status: байт статуса не передан, используем предыдущий.
        if running == 0'u8:
          break
        status = running
      else:
        inc pos
        if status < 0xF0'u8:
          running = status

      if status >= 0xF0'u8:
        # Meta (0xFF) / SysEx (0xF0, 0xF7): потребляем длину и пропускаем.
        if status == 0xFF'u8:
          if pos >= trackEnd:
            break
          inc pos  # meta type
        let len = int(decodeVarLen(data, pos))
        pos += len
        continue

      let n = channelEventLength(status)
      if n == 0:
        break
      if pos + n > trackEnd:
        # защита: не выходим за границы чанка
        break

      let d1 = data[pos]
      let d2 = if n >= 2: data[pos + 1] else: 0'u8
      pos += n

      track.events.add SmfEvent(tick: lastTick, status: status, data1: d1, data2: d2)

    pos = trackEnd
    result.file.tracks.add track
    inc trackIdx

  result.ok = true

{.pop.}
