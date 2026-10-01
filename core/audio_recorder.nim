# audio_recorder.nim
#
# Архитектура:
#   Audio callback -> lock-free ring buffer -> Recording worker thread -> WAV writer
#
# Важно:
# - Для фоновой записи на диск компилировать с --threads:on.
# - recordBlock() не делает аллокаций, lock'ов, I/O и не бросает исключений.
# - Все файловые операции выполняет worker thread.
# - Управление состоянием записи идёт через команды, а не через прямые файловые
#   операции из UI/transport thread.
# - Pre-roll хранится в отдельном кольце и копируется в основное кольцо только
#   в момент фактического старта записи.

import std/[os, times, atomics, locks]
import rt_guard

const
  MaxRecordTracks* = 32
  MaxPendingCommands = 256
  MaxCompletedRegions = 256
  MaxPathChars = 1024

type
  RecordingState* = enum
    rsIdle
    rsArmed
    rsRecording
    rsPaused

  TrackInputRouting* = object
    ## Маршрутизация входа для одного трек-рекордера.
    ##
    ## На текущей версии поддерживаются моно и стерео дорожки:
    ## - channels == 1: пишется только src0
    ## - channels == 2: пишутся src0 и src1
    channels*: int32
    src0*: int32
    src1*: int32

  RecordedRegion* = object
    id*: int32
    trackId*: int32
    startSample*: int64
    lengthSamples*: int64      # количество фреймов, не отдельных float-сэмплов
    filename*: string
    sampleRate*: int32
    channels*: int32

  AudioRing = object
    ## Основной ring buffer от audio thread к writer thread.
    ##
    ## Producer: audio thread.
    ## Consumer: recording worker thread.
    data: ptr UncheckedArray[float32]
    capacity: int              # в сэмплах float32, не в фреймах
    writePos: Atomic[uint64]
    readPos: Atomic[uint64]

  PreRollRing = object
    ## Небольшой буфер пре-ролла.
    ##
    ## Используется только audio thread'ом, пока трек находится в состоянии
    ## armed. При старте записи копируется в основной ring buffer.
    data: ptr UncheckedArray[float32]
    capacity: int              # в сэмплах float32
    writePos: int
    filled: int

  TrackSlot = object
    trackId: int32
    routing: TrackInputRouting

    state: Atomic[int32]

    # Последнее НАМЕРЕНИЕ control plane по армированию этого трека (#61).
    #
    # Нужен потому, что состояние меняется синхронно (UI обязан видеть
    # результат сразу), а команды worker'у идут асинхронно. Без этого флага
    # устаревшая rcArm, обработанная после disarmTrack, возвращала rsArmed
    # и «воскрешала» уже снятое армирование.
    armRequested: Atomic[int32]

    # Запуск записи может быть отложен до нужного transport sample.
    startRequested: Atomic[int32]
    pendingStartSample: Atomic[int64]
    actualStartSample: Atomic[int64]
    startSampleValid: Atomic[int32]

    # Диагностика сброшенных фреймов из-за нехватки места в кольце (overrun)
    droppedFrames: Atomic[int64]

    ring: AudioRing
    preRoll: PreRollRing

    # Временный буфер блока для маршрутизации входных каналов.
    # Аллоцируется заранее, в RT не используется newSeq.
    blockBuffer: ptr UncheckedArray[float32]
    blockBufferSamples: int

    # Служебное состояние, принадлежащее только audio thread.
    lastAudioState: RecordingState

  RecorderCommandKind = enum
    rcNone
    rcArm
    rcDisarm
    rcStart
    rcStop
    rcPause
    rcResume
    rcCleanupAll

  RecorderCommand = object
    kind: RecorderCommandKind
    trackId: int32
    sample: int64

  CommandQueue = object
    lock: Lock
    data: array[MaxPendingCommands, RecorderCommand]
    head: int
    tail: int
    count: int

  StoredRegion = object
    id: int32
    trackId: int32
    startSample: int64
    lengthSamples: int64
    sampleRate: int32
    channels: int32
    filename: array[MaxPathChars, char]

  RegionQueue = object
    lock: Lock
    data: array[MaxCompletedRegions, StoredRegion]
    head: int
    tail: int
    count: int

  WavWriter = object
    ## Компактный WAV writer для worker thread.
    f: File
    sampleRate: int32
    channels: int32
    bitsPerSample: int32
    bytesWritten: int64
    isOpen: bool

  WorkerLocal = object
    fileOpen: array[MaxRecordTracks, bool]
    closePending: array[MaxRecordTracks, bool]
    startPending: array[MaxRecordTracks, bool]
    startWait: array[MaxRecordTracks, int]

    samplesWritten: array[MaxRecordTracks, int64]
    startSamples: array[MaxRecordTracks, int64]
    currentFiles: array[MaxRecordTracks, string]

    writers: array[MaxRecordTracks, WavWriter]

    takeCounter: int32
    regionId: int32

  AudioRecorderCore = object
    sampleRate: int32
    blockSize: int32
    inputChannels: int32
    ringFrames: int32

    outputDir: array[MaxPathChars, char]

    running: Atomic[int32]
    trackCount: Atomic[int32]

    tracks: array[MaxRecordTracks, TrackSlot]
    commands: CommandQueue
    regions: RegionQueue

when compileOption("threads"):
  type
    AudioRecorder* = object
      core: ptr AudioRecorderCore
      worker: Thread[ptr AudioRecorderCore]
else:
  type
    AudioRecorder* = object
      core: ptr AudioRecorderCore

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc stateToInt(s: RecordingState): int32 {.inline, raises: [], gcsafe.} =
  int32(ord(s))

proc intToState(x: int32): RecordingState {.inline, raises: [], gcsafe.} =
  case x
  of 1: rsArmed
  of 2: rsRecording
  of 3: rsPaused
  else: rsIdle

proc loadState(a: var Atomic[int32]): RecordingState {.inline, raises: [], gcsafe.} =
  intToState(a.load(moAcquire))

proc storeState(a: var Atomic[int32]; s: RecordingState) {.inline, raises: [], gcsafe.} =
  a.store(stateToInt(s), moRelease)

proc clampInt32(x, a, b: int32): int32 {.inline, raises: [], gcsafe.} =
  if x < a: a
  elif x > b: b
  else: x

proc copyToFixed(dst: var openArray[char]; s: string) =
  let n = min(s.len, dst.len - 1)
  if n > 0:
    copyMem(addr dst[0], unsafeAddr s[0], n)
  if dst.len > 0:
    dst[n] = '\0'

proc fixedToString(src: openArray[char]): string =
  var n = 0
  while n < src.len and src[n] != '\0':
    inc n
  if n > 0:
    result = newString(n)
    copyMem(addr result[0], unsafeAddr src[0], n)

proc twoDigits(x: int): string =
  if x < 10:
    result = "0"
  else:
    result = ""
  result.add($x)

proc makeTimestamp(): string =
  let dt = now()
  result = $dt.year
  result.add(twoDigits(int(dt.month)))
  result.add(twoDigits(dt.monthday))
  result.add("-")
  result.add(twoDigits(dt.hour))
  result.add(twoDigits(dt.minute))
  result.add(twoDigits(dt.second))

proc makeTakeFilename(outDir: string; trackId, take: int32; timestamp: string): string =
  var name = "track_"
  name.add($trackId)
  name.add("_take_")
  name.add($take)
  name.add("_")
  name.add(timestamp)
  name.add(".wav")
  result = outDir / name

# ---------------------------------------------------------------------------
# Minimal WAV writer
# ---------------------------------------------------------------------------

proc putU16(buf: var openArray[byte]; pos: int; v: uint16) =
  buf[pos + 0] = byte(v and 0xff'u16)
  buf[pos + 1] = byte((v shr 8) and 0xff'u16)

proc putU32(buf: var openArray[byte]; pos: int; v: uint32) =
  buf[pos + 0] = byte(v and 0xff'u32)
  buf[pos + 1] = byte((v shr 8) and 0xff'u32)
  buf[pos + 2] = byte((v shr 16) and 0xff'u32)
  buf[pos + 3] = byte((v shr 24) and 0xff'u32)

proc openWavWriter(
    w: var WavWriter;
    filename: string;
    sampleRate: int32;
    channels: int32;
    bitsPerSample: int32
): bool =
  ## Открывает WAV файл и пишет пустой заголовок, который будет обновлён
  ## при закрытии.
  w.isOpen = false
  w.bytesWritten = 0
  w.sampleRate = sampleRate
  w.channels = channels
  w.bitsPerSample = if bitsPerSample == 16: 16 else: 24

  var fileOpened = false
  try:
    fileOpened = open(w.f, filename, fmWrite)
  except CatchableError:
    fileOpened = false

  if not fileOpened:
    return false

  w.isOpen = true

  var h: array[44, byte]

  # RIFF header
  h[0] = byte('R')
  h[1] = byte('I')
  h[2] = byte('F')
  h[3] = byte('F')
  putU32(h, 4, 0'u32) # final RIFF size later

  h[8] = byte('W')
  h[9] = byte('A')
  h[10] = byte('V')
  h[11] = byte('E')

  # fmt chunk
  h[12] = byte('f')
  h[13] = byte('m')
  h[14] = byte('t')
  h[15] = byte(' ')
  putU32(h, 16, 16'u32)

  putU16(h, 20, 1'u16)                 # PCM
  putU16(h, 22, uint16(w.channels))

  putU32(h, 24, uint32(w.sampleRate))

  let blockAlign = int32(w.channels * (w.bitsPerSample div 8))
  let byteRate = int64(w.sampleRate) * int64(blockAlign)

  putU32(h, 28, uint32(byteRate))
  putU16(h, 32, uint16(blockAlign))
  putU16(h, 34, uint16(w.bitsPerSample))

  # data chunk
  h[36] = byte('d')
  h[37] = byte('a')
  h[38] = byte('t')
  h[39] = byte('a')
  putU32(h, 40, 0'u32) # final data size later

  try:
    discard w.f.writeBuffer(addr h[0], h.len)
    return true
  except CatchableError:
    try:
      w.f.close()
    except CatchableError:
      discard
    w.isOpen = false
    return false

proc closeWavWriter(w: var WavWriter) =
  if not w.isOpen:
    return

  # Обновить размеры в заголовке.
  try:
    flushFile(w.f)

    let dataSize = w.bytesWritten
    let riffSize = 36 + dataSize

    var b: array[4, byte]

    w.f.setFilePos(4)
    putU32(b, 0, uint32(riffSize))
    discard w.f.writeBuffer(addr b[0], b.len)

    w.f.setFilePos(40)
    putU32(b, 0, uint32(dataSize))
    discard w.f.writeBuffer(addr b[0], b.len)
  except CatchableError:
    discard

  try:
    w.f.close()
  except CatchableError:
    discard

  w.isOpen = false
  w.bytesWritten = 0

proc writeWavFrames(
    w: var WavWriter;
    src: ptr UncheckedArray[float32];
    frames: int;
    channels: int
): int =
  ## Пишет interleaved float32 фреймы как PCM 16/24 bit.
  ##
  ## Возвращает количество успешно записанных фреймов.
  if not w.isOpen or frames <= 0 or src.isNil or channels <= 0 or channels > 2:
    return 0

  let bytesPerSample = w.bitsPerSample div 8
  let frameBytes = channels * bytesPerSample

  const ChunkFrames = 512
  var buf: array[ChunkFrames * 2 * 3, byte]

  var remaining = frames
  var srcOffset = 0
  var framesWritten = 0

  while remaining > 0:
    let n = min(ChunkFrames, remaining)
    let bytesNeeded = n * frameBytes

    if bytesNeeded > buf.len:
      break

    var p = 0

    if w.bitsPerSample == 16:
      for f in 0 ..< n:
        let base = srcOffset + f * channels
        for c in 0 ..< channels:
          var y = src[base + c]

          # NaN guard
          if y != y:
            y = 0.0

          if y > 1.0:
            y = 1.0
          elif y < -1.0:
            y = -1.0

          let v = int32(y * 32767.0)
          let u = cast[uint32](v)

          buf[p + 0] = byte(u and 0xff'u32)
          buf[p + 1] = byte((u shr 8) and 0xff'u32)
          inc p, 2

    else:
      # 24-bit
      for f in 0 ..< n:
        let base = srcOffset + f * channels
        for c in 0 ..< channels:
          var y = src[base + c]

          # NaN guard
          if y != y:
            y = 0.0

          if y > 1.0:
            y = 1.0
          elif y < -1.0:
            y = -1.0

          let v = int32(y * 8388607.0)
          let u = cast[uint32](v)

          buf[p + 0] = byte(u and 0xff'u32)
          buf[p + 1] = byte((u shr 8) and 0xff'u32)
          buf[p + 2] = byte((u shr 16) and 0xff'u32)
          inc p, 3

    let writtenBytes =
      try:
        w.f.writeBuffer(addr buf[0], bytesNeeded)
      except CatchableError:
        0

    if writtenBytes <= 0:
      break

    w.bytesWritten += int64(writtenBytes)

    if writtenBytes != bytesNeeded:
      break

    framesWritten += n
    srcOffset += n * channels
    remaining -= n

  result = framesWritten

# ---------------------------------------------------------------------------
# Ring buffers
# ---------------------------------------------------------------------------

proc initAudioRing(r: var AudioRing; frames, channels: int) =
  let ch = max(1, channels)
  let f = max(1, frames)
  r.capacity = f * ch
  r.data = cast[ptr UncheckedArray[float32]](
    allocShared0(r.capacity * sizeof(float32))
  )
  r.writePos.store(0'u64, moRelaxed)
  r.readPos.store(0'u64, moRelaxed)

proc destroyAudioRing(r: var AudioRing) =
  if not r.data.isNil:
    deallocShared(cast[pointer](r.data))
    r.data = nil
  r.capacity = 0
  r.writePos.store(0'u64, moRelaxed)
  r.readPos.store(0'u64, moRelaxed)

proc clearRing(rb: var AudioRing) {.raises: [], gcsafe.} =
  rb.writePos.store(0'u64, moRelaxed)
  rb.readPos.store(0'u64, moRelaxed)

proc availableSamples(rb: var AudioRing): int {.raises: [], gcsafe.} =
  let w = rb.writePos.load(moAcquire)
  let r = rb.readPos.load(moRelaxed)
  int(w - r)

proc freeSamples(rb: var AudioRing): int {.inline, raises: [], gcsafe.} =
  ## Возвращает гарантированное свободное место в кольце для producer (audio thread).
  if rb.capacity <= 0:
    return 0
  let w = rb.writePos.load(moRelaxed)
  let r = rb.readPos.load(moAcquire)
  let used = int(w - r)
  let free = rb.capacity - used
  if free < 0: 0 else: free

proc writeRing(
    rb: var AudioRing;
    src: ptr UncheckedArray[float32];
    count: int
): int {.raises: [], gcsafe.} =
  ## Пишет до count сэмплов. Если места не хватает, хвост отбрасывается.
  if rb.capacity <= 0 or rb.data.isNil or count <= 0 or src.isNil:
    return 0

  let cap = rb.capacity
  let w = rb.writePos.load(moRelaxed)
  let r = rb.readPos.load(moAcquire)
  let used = int(w - r)
  let free = cap - used

  if free <= 0:
    return 0

  let n = min(count, free)
  let idx = int(w mod uint64(cap))
  let first = min(cap - idx, n)

  copyMem(
    cast[pointer](addr rb.data[idx]),
    cast[pointer](unsafeAddr src[0]),
    first * sizeof(float32)
  )

  if n > first:
    copyMem(
      cast[pointer](addr rb.data[0]),
      cast[pointer](unsafeAddr src[first]),
      (n - first) * sizeof(float32)
    )

  rb.writePos.store(w + uint64(n), moRelease)
  result = n

proc initPreRollRing(pr: var PreRollRing; frames, channels: int) =
  let ch = max(1, channels)
  let f = max(0, frames)
  pr.capacity = f * ch
  pr.writePos = 0
  pr.filled = 0
  if pr.capacity > 0:
    pr.data = cast[ptr UncheckedArray[float32]](
      allocShared0(pr.capacity * sizeof(float32))
    )
  else:
    pr.data = nil

proc destroyPreRollRing(pr: var PreRollRing) =
  if not pr.data.isNil:
    deallocShared(cast[pointer](pr.data))
    pr.data = nil
  pr.capacity = 0
  pr.writePos = 0
  pr.filled = 0

proc clearPreRoll(pr: var PreRollRing) {.raises: [], gcsafe.} =
  pr.writePos = 0
  pr.filled = 0

proc pushPreRoll(
    pr: var PreRollRing;
    src: ptr UncheckedArray[float32];
    count: int
) {.raises: [], gcsafe.} =
  ## Перезаписывает старые сэмплы, если пре-ролл переполнен.
  if pr.capacity <= 0 or pr.data.isNil or count <= 0 or src.isNil:
    return

  if count >= pr.capacity:
    # Оставляем только последние capacity сэмплов.
    let off = count - pr.capacity
    copyMem(
      cast[pointer](addr pr.data[0]),
      cast[pointer](unsafeAddr src[off]),
      pr.capacity * sizeof(float32)
    )
    pr.writePos = 0
    pr.filled = pr.capacity
    return

  let first = min(pr.capacity - pr.writePos, count)
  copyMem(
    cast[pointer](addr pr.data[pr.writePos]),
    cast[pointer](unsafeAddr src[0]),
    first * sizeof(float32)
  )

  if count > first:
    copyMem(
      cast[pointer](addr pr.data[0]),
      cast[pointer](unsafeAddr src[first]),
      (count - first) * sizeof(float32)
    )

  pr.writePos = (pr.writePos + count) mod pr.capacity
  pr.filled = min(pr.filled + count, pr.capacity)

proc flushPreRoll*(
    pr: var PreRollRing;
    rb: var AudioRing;
    channels: int;
    droppedSamples: var int
): int {.raises: [], gcsafe.} =
  ## Копирует накопленный pre-roll в основной ring buffer в правильном порядке.
  ##
  ## Если в основном кольце недостаточно места для всего накопленного pre-roll:
  ## - Отбрасываются САМЫЕ СТАРЫЕ сэмплы (с фиксацией в droppedSamples).
  ## - Сохраняются и копируются САМЫЕ СВЕЖИЕ сэмплы, непосредственно предшествующие
  ##   точке старта. Это сохраняет непрерывность фазы и таймлайна (без дыр во времени).
  ## - В audio thread категорически запрещено блокироваться/ждать worker thread.
  droppedSamples = 0
  let total = pr.filled
  if total <= 0 or pr.capacity <= 0 or pr.data.isNil:
    clearPreRoll(pr)
    return 0

  let ch = max(1, channels)
  var free = freeSamples(rb)

  # Свободное место выравниваем кратно каналам (по целым фреймам).
  free = free - (free mod ch)

  # Сколько сэмплов мы гарантированно можем записать
  var count = min(total, free)
  count = count - (count mod ch)

  if count <= 0:
    # В основном кольце нет места даже для одного фрейма: сбрасываем весь pre-roll
    droppedSamples = total
    clearPreRoll(pr)
    return 0

  droppedSamples = total - count

  # Нам нужны последние `count` сэмплов перед pr.writePos.
  # Логический старт нужного фрагмента в кольцевом буфере:
  let start = (pr.writePos - count + pr.capacity) mod pr.capacity

  var written = 0

  if start + count <= pr.capacity:
    written = writeRing(
      rb,
      cast[ptr UncheckedArray[float32]](addr pr.data[start]),
      count
    )
  else:
    let first = pr.capacity - start
    let w1 = writeRing(
      rb,
      cast[ptr UncheckedArray[float32]](addr pr.data[start]),
      first
    )
    written += w1
    if w1 == first and count > first:
      let second = count - first
      let w2 = writeRing(
        rb,
        cast[ptr UncheckedArray[float32]](addr pr.data[0]),
        second
      )
      written += w2

  # Если по непредвиденной причине записалось меньше, учитываем в дропах
  if written < count:
    droppedSamples += (count - written)

  clearPreRoll(pr)
  result = written

proc flushPreRoll*(
    pr: var PreRollRing;
    rb: var AudioRing;
    channels: int = 1
): int {.inline, raises: [], gcsafe.} =
  var dummyDropped = 0
  result = flushPreRoll(pr, rb, channels, dummyDropped)

# ---------------------------------------------------------------------------
# Audio-thread routing
# ---------------------------------------------------------------------------

proc fillBlockBufferAt*(
    slot: ptr TrackSlot;
    inputBuffer: ptr UncheckedArray[float32];
    stride: int;
    startFrame: int;
    endFrame: int
): int {.raises: [], gcsafe.} =
  ## Маршрутизирует входные каналы для диапазона фреймов [startFrame, endFrame)
  ## в заранее выделенный blockBuffer (начиная с нулевого смещения blockBuffer).
  ##
  ## Возвращает количество записанных сэмплов, а не фреймов.
  let count = endFrame - startFrame
  if count <= 0 or startFrame < 0 or slot.blockBuffer.isNil:
    return 0

  let ch = int(slot.routing.channels)

  if ch == 1:
    let src0 = int(slot.routing.src0)
    var i = startFrame
    var o = 0
    while i < endFrame:
      slot.blockBuffer[o] = inputBuffer[i * stride + src0]
      inc i
      inc o
    return count

  # ch == 2
  let src0 = int(slot.routing.src0)
  let src1 = int(slot.routing.src1)
  var i = startFrame
  var o = 0
  while i < endFrame:
    let base = i * stride
    slot.blockBuffer[o] = inputBuffer[base + src0]
    slot.blockBuffer[o + 1] = inputBuffer[base + src1]
    inc i
    inc o, 2
  return count * 2

proc fillBlockBuffer*(
    slot: ptr TrackSlot;
    inputBuffer: ptr UncheckedArray[float32];
    stride: int;
    blockSize: int
): int {.inline, raises: [], gcsafe.} =
  ## Маршрутизирует входные каналы в заранее выделенный blockBuffer.
  ##
  ## Возвращает количество записанных сэмплов, а не фреймов.
  fillBlockBufferAt(slot, inputBuffer, stride, 0, blockSize)

# ---------------------------------------------------------------------------
# Command queue
# ---------------------------------------------------------------------------

proc pushCommand(q: var CommandQueue; cmd: RecorderCommand) =
  #
  # Это не RT-путь. Здесь допустим короткий retry.
  #
  var attempts = 0
  while true:
    acquire(q.lock)
    if q.count < MaxPendingCommands:
      q.data[q.tail] = cmd
      q.tail = (q.tail + 1) mod MaxPendingCommands
      inc q.count
      release(q.lock)
      return
    release(q.lock)

    inc attempts
    if attempts > 100:
      # Очередь переполнена. Жертвуем самой старой командой, чтобы сохранить
      # более новую. На практике до этого доходить не должно.
      acquire(q.lock)
      if q.count > 0:
        q.head = (q.head + 1) mod MaxPendingCommands
        dec q.count
      if q.count < MaxPendingCommands:
        q.data[q.tail] = cmd
        q.tail = (q.tail + 1) mod MaxPendingCommands
        inc q.count
        release(q.lock)
        return
      release(q.lock)

    sleep(1)

proc popCommand(q: var CommandQueue; cmd: var RecorderCommand): bool =
  acquire(q.lock)
  if q.count > 0:
    cmd = q.data[q.head]
    q.head = (q.head + 1) mod MaxPendingCommands
    dec q.count
    release(q.lock)
    return true
  release(q.lock)
  return false

# ---------------------------------------------------------------------------
# Region queue
# ---------------------------------------------------------------------------

proc pushRegion(q: var RegionQueue; r: StoredRegion) =
  acquire(q.lock)
  if q.count == MaxCompletedRegions:
    # Если очередь переполнена, выбрасываем самый старый регион.
    q.head = (q.head + 1) mod MaxCompletedRegions
    dec q.count

  q.data[q.tail] = r
  q.tail = (q.tail + 1) mod MaxCompletedRegions
  inc q.count
  release(q.lock)

proc clearRegions(q: var RegionQueue) =
  acquire(q.lock)
  q.head = 0
  q.tail = 0
  q.count = 0
  release(q.lock)

proc popAllRegions(q: var RegionQueue; outSeq: var seq[RecordedRegion]) =
  acquire(q.lock)
  let n = q.count
  if n > 0:
    newSeq(outSeq, n)
    for i in 0 ..< n:
      let idx = (q.head + i) mod MaxCompletedRegions
      let r = q.data[idx]
      outSeq[i] = RecordedRegion(
        id: r.id,
        trackId: r.trackId,
        startSample: r.startSample,
        lengthSamples: r.lengthSamples,
        filename: fixedToString(r.filename),
        sampleRate: r.sampleRate,
        channels: r.channels
      )
  q.head = 0
  q.tail = 0
  q.count = 0
  release(q.lock)

# ---------------------------------------------------------------------------
# Worker helpers
# ---------------------------------------------------------------------------

proc findSlot(core: ptr AudioRecorderCore; trackId: int32): int =
  let n = int(core.trackCount.load(moAcquire))
  for i in 0 ..< n:
    if core.tracks[i].trackId == trackId:
      return i
  return -1

proc drainTrack(
    slot: ptr TrackSlot;
    w: var WavWriter;
    writtenFrames: var int64
): int =
  ## Пишет готовые фреймы из ring buffer в WAV writer.
  ##
  ## Возвращает количество записанных фреймов за один вызов.
  let ch = int(slot.routing.channels)
  if ch <= 0 or slot.ring.capacity <= 0 or not w.isOpen:
    return 0

  var framesWritten = 0

  while true:
    let wp = slot.ring.writePos.load(moAcquire)
    let rp = slot.ring.readPos.load(moRelaxed)
    let avail = int(wp - rp)

    if avail < ch:
      break

    let usableSamples = avail - (avail mod ch)
    let startIdx = int(rp mod uint64(slot.ring.capacity))
    let contiguousSamples = min(slot.ring.capacity - startIdx, usableSamples)
    let contiguousFrames = contiguousSamples div ch

    if contiguousFrames <= 0:
      break

    var framesWrittenChunk = 0
    try:
      framesWrittenChunk = writeWavFrames(
        w,
        cast[ptr UncheckedArray[float32]](addr slot.ring.data[startIdx]),
        contiguousFrames,
        ch
      )
    except CatchableError:
      framesWrittenChunk = 0

    if framesWrittenChunk <= 0:
      break

    slot.ring.readPos.store(rp + uint64(framesWrittenChunk * ch), moRelease)
    writtenFrames += int64(framesWrittenChunk)
    framesWritten += framesWrittenChunk

    if framesWrittenChunk < contiguousFrames:
      break

    if contiguousSamples == usableSamples:
      break

  result = framesWritten

proc pushRegionForTrack(
    core: ptr AudioRecorderCore;
    wl: var WorkerLocal;
    idx: int
) =
  if wl.samplesWritten[idx] <= 0:
    return

  let slot = addr core.tracks[idx]

  var r: StoredRegion
  r.id = wl.regionId
  inc wl.regionId
  r.trackId = slot.trackId
  r.startSample = wl.startSamples[idx]
  r.lengthSamples = wl.samplesWritten[idx]
  r.sampleRate = core.sampleRate
  r.channels = slot.routing.channels
  copyToFixed(r.filename, wl.currentFiles[idx])

  core.regions.pushRegion(r)

# ---------------------------------------------------------------------------
# Command processing in worker
# ---------------------------------------------------------------------------

proc processCommand(
    core: ptr AudioRecorderCore;
    cmd: RecorderCommand;
    wl: var WorkerLocal;
    outputDir: string
) =
  case cmd.kind
  of rcNone:
    discard

  of rcArm:
    let idx = findSlot(core, cmd.trackId)
    if idx >= 0:
      let slot = addr core.tracks[idx]
      let st = loadState(slot[].state)

      # Worker готовит инфраструктуру записи (кольцо, пре-ролл, счётчики).
      #
      # Состояние rsArmed к этому моменту уже мог выставить control plane
      # (armTrack ставит его синхронно, чтобы UI видел результат сразу),
      # поэтому rsArmed здесь — допустимое входное состояние, а не признак
      # двойного армирования.
      #
      # Если трек пишет или ещё закрывает старый файл — не армируем:
      # closePending означает, что канал освободится только после flush.
      #
      # `armRequested` отсекает устаревшую команду: если control plane уже
      # снял армирование (disarmTrack), эта rcArm не должна возвращать
      # rsArmed (#61).
      if slot[].armRequested.load(moAcquire) == 1 and
         (st == rsIdle or st == rsArmed) and
         not wl.fileOpen[idx] and not wl.closePending[idx]:
        clearRing(slot[].ring)
        clearPreRoll(slot[].preRoll)
        slot[].droppedFrames.store(0'i64, moRelease)
        slot[].startRequested.store(0, moRelease)
        slot[].startSampleValid.store(0, moRelease)
        storeState(slot[].state, rsArmed)

  of rcDisarm:
    let idx = findSlot(core, cmd.trackId)
    if idx >= 0:
      let slot = addr core.tracks[idx]
      let st = loadState(slot[].state)

      slot[].startRequested.store(0, moRelease)

      if st == rsArmed:
        storeState(slot[].state, rsIdle)
      elif st == rsRecording or st == rsPaused:
        storeState(slot[].state, rsIdle)
        wl.closePending[idx] = true

  of rcStart:
    var armedIdx: array[MaxRecordTracks, int]
    var armedCount = 0

    let n = int(core.trackCount.load(moAcquire))
    for i in 0 ..< n:
      let slot = addr core.tracks[i]
      # `armRequested` — защита «в глубину»: даже если состояние почему-то
      # осталось rsArmed, запись не стартует по инерции после disarmTrack (#61).
      if loadState(slot[].state) == rsArmed and
         slot[].armRequested.load(moAcquire) == 1 and
         not wl.startPending[i]:
        armedIdx[armedCount] = i
        inc armedCount

    if armedCount > 0:
      inc wl.takeCounter
      let timestamp = makeTimestamp()

      for j in 0 ..< armedCount:
        let i = armedIdx[j]
        let slot = addr core.tracks[i]

        slot[].pendingStartSample.store(cmd.sample, moRelease)
        slot[].startSampleValid.store(0, moRelease)

        wl.startPending[i] = true
        wl.startWait[i] = 0
        wl.closePending[i] = false
        wl.samplesWritten[i] = 0
        wl.startSamples[i] = cmd.sample
        wl.currentFiles[i] = makeTakeFilename(
          outputDir,
          slot.trackId,
          wl.takeCounter,
          timestamp
        )

        # Audio thread сам переведёт трек из armed в recording, когда увидит
        # нужный транспортный сэмпл. Это даёт более точный старт и позволяет
        # корректно забрать pre-roll.
        slot[].startRequested.store(1, moRelease)

  of rcStop:
    let n = int(core.trackCount.load(moAcquire))
    for i in 0 ..< n:
      let slot = addr core.tracks[i]
      let st = loadState(slot[].state)

      slot[].startRequested.store(0, moRelease)

      if st == rsRecording or st == rsPaused:
        storeState(slot[].state, rsIdle)
        wl.closePending[i] = true
      elif wl.startPending[i]:
        # Старт был запрошен, но фактическая запись ещё не началась.
        wl.closePending[i] = true

  of rcPause:
    let n = int(core.trackCount.load(moAcquire))
    for i in 0 ..< n:
      let slot = addr core.tracks[i]
      if loadState(slot[].state) == rsRecording:
        storeState(slot[].state, rsPaused)

  of rcResume:
    let n = int(core.trackCount.load(moAcquire))
    for i in 0 ..< n:
      let slot = addr core.tracks[i]
      let st = loadState(slot[].state)
      if st == rsPaused and (wl.fileOpen[i] or wl.startPending[i]):
        storeState(slot[].state, rsRecording)

  of rcCleanupAll:
    let n = int(core.trackCount.load(moAcquire))
    for i in 0 ..< n:
      let slot = addr core.tracks[i]
      slot[].startRequested.store(0, moRelease)
      storeState(slot[].state, rsIdle)

      if wl.fileOpen[i] or wl.startPending[i]:
        wl.closePending[i] = true

# ---------------------------------------------------------------------------
# Worker main
# ---------------------------------------------------------------------------

proc workerMain(core: ptr AudioRecorderCore) {.used.} =
  var wl: WorkerLocal
  let outputDir = fixedToString(core.outputDir)

  try:
    while true:
      # 1. Обработка команд.
      var cmd: RecorderCommand
      while core.commands.popCommand(cmd):
        processCommand(core, cmd, wl, outputDir)

      # 2. Обслуживание треков.
      let n = int(core.trackCount.load(moAcquire))
      for i in 0 ..< n:
        let slot = addr core.tracks[i]
        let st = loadState(slot[].state)

        # Открытие файла после фактического старта записи.
        if wl.startPending[i] and
           not wl.fileOpen[i] and
           not wl.closePending[i] and
           st == rsRecording:

          let valid = slot[].startSampleValid.load(moAcquire) != 0

          if valid or wl.startWait[i] > 1000:
            if valid:
              wl.startSamples[i] = slot[].actualStartSample.load(moAcquire)
            else:
              wl.startSamples[i] = slot[].pendingStartSample.load(moAcquire)

            var opened = false
            try:
              opened = openWavWriter(
                wl.writers[i],
                wl.currentFiles[i],
                core.sampleRate,
                slot.routing.channels,
                24
              )
            except CatchableError:
              opened = false

            if opened:
              wl.fileOpen[i] = true
              wl.startPending[i] = false
              wl.startWait[i] = 0
            else:
              # Если файл не открылся, останавливаем трек и очищаем кольцо.
              wl.startPending[i] = false
              wl.closePending[i] = true
              storeState(slot[].state, rsIdle)
          else:
            inc wl.startWait[i]

        # Запись данных из ring buffer.
        if wl.fileOpen[i]:
          if st == rsRecording or st == rsPaused or wl.closePending[i]:
            discard drainTrack(slot, wl.writers[i], wl.samplesWritten[i])

          if wl.closePending[i] and availableSamples(slot[].ring) < int(slot.routing.channels):
            closeWavWriter(wl.writers[i])
            wl.fileOpen[i] = false

            pushRegionForTrack(core, wl, i)

            wl.closePending[i] = false
            wl.startPending[i] = false
            wl.samplesWritten[i] = 0
            clearRing(slot[].ring)

        elif wl.closePending[i]:
          # Файл так и не был открыт, например, старт отменили до записи.
          wl.closePending[i] = false
          wl.startPending[i] = false
          clearRing(slot[].ring)

        # Защита от осиротевших состояний.
        if (st == rsRecording or st == rsPaused) and
           not wl.fileOpen[i] and
           not wl.startPending[i] and
           not wl.closePending[i]:
          storeState(slot[].state, rsIdle)

      if core.running.load(moAcquire) == 0:
        break

      sleep(1)

    # Финальная аварийная разборка при выходе из потока.
    let n2 = int(core.trackCount.load(moAcquire))
    for i in 0 ..< n2:
      let slot = addr core.tracks[i]

      if wl.fileOpen[i]:
        discard drainTrack(slot, wl.writers[i], wl.samplesWritten[i])
        closeWavWriter(wl.writers[i])
        wl.fileOpen[i] = false
        pushRegionForTrack(core, wl, i)

      storeState(slot[].state, rsIdle)
      slot[].startRequested.store(0, moRelease)

  except CatchableError:
    # Worker thread не должен ронять процесс.
    discard

when compileOption("threads"):
  proc recorderWorker(arg: ptr AudioRecorderCore) {.thread.} =
    workerMain(arg)

# ---------------------------------------------------------------------------
# Slot lifecycle
# ---------------------------------------------------------------------------

proc destroyTrackSlot(slot: var TrackSlot) =
  destroyAudioRing(slot.ring)
  destroyPreRollRing(slot.preRoll)
  if not slot.blockBuffer.isNil:
    deallocShared(cast[pointer](slot.blockBuffer))
    slot.blockBuffer = nil
  slot.blockBufferSamples = 0

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc initAudioRecorder*(
    sampleRate: int32 = 48000,
    blockSize: int32 = 128,
    outputDir: string = "recordings",
    inputChannels: int32 = 2,
    ringFrames: int32 = 65536
): AudioRecorder =
  ## Создаёт рекордер.
  ##
  ## При compileOption("threads") (в этом проекте он всегда включён
  ## через config.nims) запускается writer thread.
  ## Без потоков код остаётся компилируемым, но фоновая запись
  ## на диск работать не будет.
  ##
  ## ringFrames — запас фреймов в основном кольце на трек.
  ## Для pre-roll память добавляется отдельно в каждом треке.

  let core = cast[ptr AudioRecorderCore](
    allocShared0(sizeof(AudioRecorderCore))
  )

  core.sampleRate = if sampleRate > 0: sampleRate else: 48000
  core.blockSize = if blockSize > 0: blockSize else: 128
  core.inputChannels = if inputChannels > 0: inputChannels else: 2
  core.ringFrames = if ringFrames > 0: ringFrames else: 65536

  copyToFixed(core.outputDir, outputDir)

  initLock(core.commands.lock)
  initLock(core.regions.lock)

  core.running.store(1, moRelease)
  core.trackCount.store(0, moRelease)

  try:
    if not dirExists(outputDir):
      createDir(outputDir)
  except CatchableError:
    # Ошибка каталога позже приведёт к ошибке открытия файлов.
    discard

  result.core = core

  when compileOption("threads"):
    createThread(result.worker, recorderWorker, core)

proc destroyAudioRecorder*(rec: var AudioRecorder) =
  ## Останавливает поток, закрывает ресурсы и освобождает память.
  if rec.core.isNil:
    return

  # Попросить остановить всё и закрыть файлы.
  var cmd = RecorderCommand(kind: rcCleanupAll)
  rec.core.commands.pushCommand(cmd)

  when compileOption("threads"):
    # Дать worker'у короткий шанс закрыть файлы до принудительного выхода.
    for i in 0 ..< 50:
      sleep(1)

    rec.core.running.store(0, moRelease)
    joinThread(rec.worker)
  else:
    # Дренаж команд и принудительная финализация в текущем потоке.
    rec.core.running.store(0, moRelease)
    workerMain(rec.core)   # однократный вызов — закроет файлы, вытолкнет регионы

  let n = int(rec.core.trackCount.load(moAcquire))
  for i in 0 ..< n:
    destroyTrackSlot(rec.core.tracks[i])

  deinitLock(rec.core.commands.lock)
  deinitLock(rec.core.regions.lock)

  deallocShared(cast[pointer](rec.core))
  rec.core = nil

proc addTrackRecorder*(
    rec: var AudioRecorder;
    trackId: int32;
    routing: TrackInputRouting;
    preRollFrames: int32 = 0
): bool =
  ## Добавляет трек с явным input routing.
  ##
  ## channels = 1 — моно, пишется только src0.
  ## channels = 2 — стерео, пишутся src0/src1.

  if rec.core.isNil:
    return false

  let count = int(rec.core.trackCount.load(moAcquire))
  if count >= MaxRecordTracks:
    return false

  # Проверка дубликата.
  for i in 0 ..< count:
    if rec.core.tracks[i].trackId == trackId:
      return false

  let idx = count
  let slot = addr rec.core.tracks[idx]

  var r = routing
  r.channels = if r.channels <= 1: 1 else: 2

  let maxSrc = max(0'i32, rec.core.inputChannels - 1)
  r.src0 = clampInt32(r.src0, 0, maxSrc)
  r.src1 = clampInt32(r.src1, 0, maxSrc)

  let blockSize = int(rec.core.blockSize)
  let channels = int(r.channels)
  let preRoll = max(0, int(preRollFrames))

  # Основное кольцо должно вмещать и pre-roll, и запас на старт файла.
  let safetyFrames = max(int(rec.core.ringFrames), blockSize * 8)
  let neededFrames = max(safetyFrames, preRoll + blockSize * 4)

  slot.trackId = trackId
  slot.routing = r

  initAudioRing(slot[].ring, neededFrames, channels)
  initPreRollRing(slot[].preRoll, preRoll, channels)

  slot.blockBufferSamples = max(1, blockSize * channels)
  slot.blockBuffer = cast[ptr UncheckedArray[float32]](
    allocShared0(slot.blockBufferSamples * sizeof(float32))
  )

  slot.lastAudioState = rsIdle

  storeState(slot[].state, rsIdle)
  slot[].armRequested.store(0, moRelease)
  slot[].droppedFrames.store(0'i64, moRelease)
  slot[].startRequested.store(0, moRelease)
  slot[].pendingStartSample.store(0'i64, moRelease)
  slot[].actualStartSample.store(0'i64, moRelease)
  slot[].startSampleValid.store(0, moRelease)

  # Публикуем новый трек только после полной инициализации.
  discard rec.core.trackCount.fetchAdd(1'i32, moRelease)
  return true

proc addTrackRecorder*(
    rec: var AudioRecorder;
    trackId: int32;
    inputChannel: int32;
    channels: int32 = 2;
    preRollFrames: int32 = 0
): bool =
  ## Совместимый вариант.
  ##
  ## Для стерео используется пара каналов:
  ##   inputChannel, inputChannel + 1
  ##
  ## Для моно используйте channels = 1.

  var routing = TrackInputRouting(
    channels: channels,
    src0: inputChannel,
    src1: inputChannel + 1
  )

  if channels <= 1:
    routing.channels = 1
    routing.src1 = inputChannel

  addTrackRecorder(rec, trackId, routing, preRollFrames)

proc armTrack*(rec: var AudioRecorder; trackId: int32) =
  ## Arm: помечает трек как готовый к записи.
  ##
  ## Состояние выставляется СРАЗУ на control plane, потому что UI/CLI
  ## должны видеть hasArmedTracks() == true немедленно после вызова,
  ## а не после того как worker thread разберёт очередь команд.
  ##
  ## Запись состояния идёт через Atomic[int32] и безопасна для RT-чтения.
  ## Команда rcArm при этом остаётся: worker на её основе очищает
  ## кольцо/пре-ролл и сбрасывает счётчики, то есть готовит инфраструктуру
  ## записи. Порядок команд в очереди сохраняет семантику
  ## arm -> start -> disarm.
  if rec.core.isNil:
    return

  let idx = findSlot(rec.core, trackId)
  if idx >= 0:
    let slot = addr rec.core.tracks[idx]
    # Намерение фиксируется ДО синхронной смены состояния: worker, разбирая
    # очередь, ориентируется на него, а не на порядок прихода команд (#61).
    slot[].armRequested.store(1, moRelease)

    let st = loadState(slot[].state)
    if st == rsIdle or st == rsArmed:
      storeState(slot[].state, rsArmed)

  rec.core.commands.pushCommand(
    RecorderCommand(kind: rcArm, trackId: trackId)
  )


proc disarmTrack*(rec: var AudioRecorder; trackId: int32) =
  ## Disarm: снимает армирование.
  ##
  ## Если трек ещё не писал, состояние снимается сразу на control plane.
  ## Если трек уже пишет, переход в rsIdle делает worker: он обязан
  ## корректно дописать буфер и закрыть WAV-файл (иначе теряется take).
  if rec.core.isNil:
    return

  let idx = findSlot(rec.core, trackId)
  if idx >= 0:
    let slot = addr rec.core.tracks[idx]
    slot[].armRequested.store(0, moRelease)

    let st = loadState(slot[].state)

    if st == rsArmed:
      slot[].startRequested.store(0, moRelease)
      storeState(slot[].state, rsIdle)

  rec.core.commands.pushCommand(
    RecorderCommand(kind: rcDisarm, trackId: trackId)
  )

proc startRecording*(rec: var AudioRecorder; currentSample: int64) =
  ## Запрашивает старт для всех вооружённых треков.
  ##
  ## Фактический переход из armed в recording выполняет audio thread,
  ## когда увидит подходящий транспортный сэмпл.
  if rec.core.isNil:
    return
  rec.core.commands.pushCommand(
    RecorderCommand(kind: rcStart, trackId: -1, sample: currentSample)
  )

proc stopRecording*(rec: var AudioRecorder) =
  if rec.core.isNil:
    return
  rec.core.commands.pushCommand(
    RecorderCommand(kind: rcStop, trackId: -1)
  )

proc pauseRecording*(rec: var AudioRecorder) =
  if rec.core.isNil:
    return
  rec.core.commands.pushCommand(
    RecorderCommand(kind: rcPause, trackId: -1)
  )

proc resumeRecording*(rec: var AudioRecorder) =
  if rec.core.isNil:
    return
  rec.core.commands.pushCommand(
    RecorderCommand(kind: rcResume, trackId: -1)
  )

proc cleanupRecordings*(rec: var AudioRecorder) =
  ## Останавливает все активные записи и очищает очередь готовых регионов.
  ##
  ## Если нужно сначала собрать регионы, вызовите getRecordedRegions()
  ## до cleanupRecordings().
  if rec.core.isNil:
    return

  rec.core.commands.pushCommand(
    RecorderCommand(kind: rcCleanupAll, trackId: -1)
  )
  rec.core.regions.clearRegions()

proc getRecordedRegions*(rec: var AudioRecorder): seq[RecordedRegion] =
  ## Забирает накопленные завершённые регионы.
  ##
  ## После вызова внутренняя очередь очищается.
  result = @[]
  if rec.core.isNil:
    return
  rec.core.regions.popAllRegions(result)

proc getTrackDroppedFrames*(rec: var AudioRecorder; trackId: int32): int64 =
  ## Возвращает суммарное количество сброшенных фреймов (xrun / buffer overrun)
  ## для указанного трека с момента его армирования или создания.
  if rec.core.isNil:
    return 0'i64
  let idx = findSlot(rec.core, trackId)
  if idx >= 0:
    return rec.core.tracks[idx].droppedFrames.load(moAcquire)
  return 0'i64

proc isRecording*(rec: var AudioRecorder): bool =
  if rec.core.isNil:
    return false

  let n = int(rec.core.trackCount.load(moAcquire))
  for i in 0 ..< n:
    if loadState(rec.core.tracks[i].state) == rsRecording:
      return true
  return false

proc hasArmedTracks*(rec: var AudioRecorder): bool =
  if rec.core.isNil:
    return false

  let n = int(rec.core.trackCount.load(moAcquire))
  for i in 0 ..< n:
    if loadState(rec.core.tracks[i].state) == rsArmed:
      return true
  return false

# ---------------------------------------------------------------------------
# Realtime entry point
# ---------------------------------------------------------------------------

proc recordBlock*(
    rec: var AudioRecorder;
    inputBuffer: ptr UncheckedArray[float32];
    currentSample: int64
) {.raises: [], gcsafe.} =
  ## RT-путь.
  ##
  ## Здесь запрещено:
  ## - аллоцировать память;
  ## - делать file I/O;
  ## - использовать lock'и;
  ## - бросать исключения.
  ##
  ## Здесь разрешено:
  ## - читать атомарные флаги;
  ## - копировать сэмплы в заранее выделенные кольца;
  ## - переводить состояния трека по заранее запрошенным командам.

  # Realtime-guard (issue #11): recordBlock — RT-путь записи. Копирование
  # в кольцо обязано остаться без аллокаций; guard ловит регрессию,
  # которая иначе проявилась бы только как щелчок на записи.
  rtScope():
    if rec.core.isNil or inputBuffer.isNil:
      return

    let core = rec.core
    let blockSize = int(core.blockSize)
    if blockSize <= 0:
      return

    let stride = max(1, int(core.inputChannels))
    let count = int(core.trackCount.load(moAcquire))

    for i in 0 ..< count:
      let slot = addr core.tracks[i]

      if slot.blockBuffer.isNil:
        continue

      var st = loadState(slot[].state)
      let ch = max(1, int(slot.routing.channels))

      # Если запрошен старт и текущий блок пересекает или превышает целевую точку,
      # выполняем сэмпл-точный старт.
      if st == rsArmed and slot[].startRequested.load(moAcquire) != 0:
        let startAt = slot[].pendingStartSample.load(moRelaxed)
        if currentSample + int64(blockSize) > startAt:
          slot[].startRequested.store(0, moRelease)

          # Сколько сэмплов блока реально «до старта».
          var beforeStart = int64(blockSize)
          if startAt > currentSample:
            beforeStart = startAt - currentSample
          else:
            beforeStart = 0

          let beforeSamples = int(beforeStart) * ch
          let afterSamples  = (blockSize - int(beforeStart)) * ch

          if beforeSamples > 0:
            let n = fillBlockBuffer(slot, inputBuffer, stride, int(beforeStart))
            if n > 0:
              pushPreRoll(
                slot[].preRoll,
                cast[ptr UncheckedArray[float32]](addr slot.blockBuffer[0]),
                n
              )

          var droppedPreRoll = 0
          let flushedSamples = flushPreRoll(slot[].preRoll, slot[].ring, ch, droppedPreRoll)

          if droppedPreRoll > 0:
            discard slot[].droppedFrames.fetchAdd(int64(droppedPreRoll div ch), moRelaxed)

          let flushedFrames = int64(flushedSamples) div int64(ch)

          var actualStart = startAt - flushedFrames
          if actualStart < 0:
            actualStart = 0

          slot[].actualStartSample.store(actualStart, moRelease)
          slot[].startSampleValid.store(1, moRelease)

          storeState(slot[].state, rsRecording)
          st = rsRecording
          slot[].lastAudioState = rsRecording

          if afterSamples > 0:
            # Заполняем blockBuffer для второй половины блока
            let n = fillBlockBufferAt(
              slot,
              inputBuffer,
              stride,
              int(beforeStart),
              blockSize
            )
            if n > 0:
              let written = writeRing(
                slot[].ring,
                cast[ptr UncheckedArray[float32]](addr slot.blockBuffer[0]),
                n
              )
              if written < n:
                discard slot[].droppedFrames.fetchAdd(int64((n - written) div ch), moRelaxed)

          continue   # этот блок уже полностью обработан

      # Реакция на смену состояния.
      if st != slot[].lastAudioState:
        if st == rsArmed:
          clearPreRoll(slot[].preRoll)
        slot[].lastAudioState = st

      # Собственно приём аудио.
      if st == rsArmed:
        let samples = fillBlockBuffer(slot, inputBuffer, stride, blockSize)
        if samples > 0:
          pushPreRoll(
            slot[].preRoll,
            cast[ptr UncheckedArray[float32]](addr slot.blockBuffer[0]),
            samples
          )

      elif st == rsRecording:
        let samples = fillBlockBuffer(slot, inputBuffer, stride, blockSize)
        if samples > 0:
          let written = writeRing(
            slot[].ring,
            cast[ptr UncheckedArray[float32]](addr slot.blockBuffer[0]),
            samples
          )
          if written < samples:
            discard slot[].droppedFrames.fetchAdd(int64((samples - written) div ch), moRelaxed)

    # rsIdle и rsPaused не принимают новые сэмплы.