#waveform_cache.nim
import std/[tables, os, locks, math, deques, times]
import audio_file_io

const
  DefaultMaxEntries = 256

type
  WaveformState* = enum
    wsPending,
    wsGenerating,
    wsReady,
    wsFailed

  WaveformData* = object
    minValues*: seq[float32]
    maxValues*: seq[float32]
    rmsValues*: seq[float32]
    numPoints*: int32
    sampleRate*: int32
    channels*: int32
    totalFrames*: int64

  # ref object гарантирует стабильность указателя в памяти (не инвалидируется Table)
  WaveformCacheEntry* = ref object
    path*: string
    fileSize*: int64
    mtime*: int64
    numPoints*: int32
    data*: WaveformData
    refCount*: int32
    state*: WaveformState
    lastAccessed*: int64

  # ref object для безопасной передачи в background thread
  WaveformCache* = ref object
    entries: Table[string, WaveformCacheEntry]
    maxEntries: int32
    cacheDir: string
    accessCounter: int64
    
    # Thread-safety primitives
    lock: Lock
    cond: Cond
    queue: Deque[WaveformCacheEntry]
    workerThread: Thread[WaveformCache]
    running: bool

# --- Внутренние хелперы ---

proc makeKey(path: string, fileSize, mtime: int64, numPoints: int32): string =
  # Многофакторный ключ: защищает от ситуаций, когда файл заменили, но имя осталось
  path & "|" & $fileSize & "|" & $mtime & "|" & $numPoints

proc evictLru(cache: WaveformCache) =
  ## Удаляет самую старую запись, которая НЕ используется в данный момент (refCount == 0)
  if cache.entries.len >= int(cache.maxEntries):
    var lruKey = ""
    var lruTime = int64.high
    for k, v in cache.entries:
      if v.refCount == 0 and v.lastAccessed < lruTime:
        lruTime = v.lastAccessed
        lruKey = k
    if lruKey != "":
      cache.entries.del(lruKey)

proc generateWaveformData(filepath: string, numPoints: int32): WaveformData =
  try:
    # Используем loadAudioFile, так как в фасаде audio_file_io нет seekAudioFile
    let (samples, info) = loadAudioFile(filepath)
    let totalFrames = info.numFrames
    let channels = int32(info.channels)
    
    result = WaveformData(
      minValues: newSeq[float32](int(numPoints)),
      maxValues: newSeq[float32](int(numPoints)),
      rmsValues: newSeq[float32](int(numPoints)),
      numPoints: numPoints,
      sampleRate: int32(info.sampleRate),
      channels: channels,
      totalFrames: totalFrames
    )
    
    if totalFrames == 0 or samples.len == 0:
      return
      
    let framesPerPoint = totalFrames div int64(numPoints)
    
    if framesPerPoint <= 0:
      # Файл короче, чем запрошенное количество точек
      for p in 0 ..< int(totalFrames):
        var minVal = 1.0f
        var maxVal = -1.0f
        var rmsSum = 0.0f
        for c in 0 ..< channels:
          let sample = samples[p * channels + c]
          if sample < minVal: minVal = sample
          if sample > maxVal: maxVal = sample
          rmsSum += sample * sample
        result.minValues[p] = minVal
        result.maxValues[p] = maxVal
        result.rmsValues[p] = sqrt(rmsSum / float32(channels))
      return
      
    for p in 0 ..< numPoints:
      let startFrame = int64(p) * framesPerPoint
      let framesToRead = min(framesPerPoint, totalFrames - startFrame)
      
      var minVal = 1.0f
      var maxVal = -1.0f
      var rmsSum = 0.0f
      
      let startSampleIdx = int(startFrame * int64(channels))
      let endSampleIdx = startSampleIdx + int(framesToRead * int64(channels))
      
      for i in startSampleIdx ..< endSampleIdx:
        let sample = samples[i]
        if sample < minVal: minVal = sample
        if sample > maxVal: maxVal = sample
        rmsSum += sample * sample
      
      result.minValues[p] = minVal
      result.maxValues[p] = maxVal
      result.rmsValues[p] = sqrt(rmsSum / float32(framesToRead * channels))
      
  except CatchableError:
    # Возвращаем пустую структуру при ошибках I/O
    discard

# --- Background Worker ---

proc workerLoop(cache: WaveformCache) {.thread.} =
  while true:
    var entry: WaveformCacheEntry = nil
    
    acquire(cache.lock)
    while cache.queue.len == 0 and cache.running:
      wait(cache.cond, cache.lock)
    
    if not cache.running and cache.queue.len == 0:
      release(cache.lock)
      break
      
    if cache.queue.len > 0:
      entry = cache.queue.popFirst()
      entry.state = wsGenerating
    
    release(cache.lock)
    
    if entry != nil:
      # Тяжелая генерация происходит ЗДЕСЬ, не блокируя UI
      var data: WaveformData
      var success = true
      try:
        data = generateWaveformData(entry.path, entry.numPoints)
      except CatchableError:
        success = false
        
      acquire(cache.lock)
      if success:
        entry.data = data
        entry.state = wsReady
      else:
        entry.state = wsFailed
      release(cache.lock)

# --- Публичный API ---

proc initWaveformCache*(cacheDir: string = "waveform_cache", maxEntries: int32 = DefaultMaxEntries): WaveformCache =
  result = WaveformCache(
    entries: initTable[string, WaveformCacheEntry](),
    maxEntries: maxEntries,
    cacheDir: cacheDir,
    accessCounter: 0,
    running: true
  )
  initLock(result.lock)
  initCond(result.cond)
  
  try:
    if not dirExists(cacheDir):
      createDir(cacheDir)
  except CatchableError:
    discard # Если нет прав на создание папки, кэш просто будет работать только в RAM
    
  createThread(result.workerThread, workerLoop, result)

proc destroy*(cache: WaveformCache) =
  acquire(cache.lock)
  cache.running = false
  signal(cache.cond) # Будим поток, чтобы он завершился
  release(cache.lock)
  joinThread(cache.workerThread)
  deinitLock(cache.lock)
  deinitCond(cache.cond)

proc getWaveform*(cache: WaveformCache, filepath: string, numPoints: int32 = 1024): WaveformCacheEntry =
  var info: FileInfo
  try:
    info = getFileInfo(filepath)
  except CatchableError:
    return nil # Файл не найден
    
  let mtime = toUnix(info.lastWriteTime)
  let key = makeKey(filepath, int64(info.size), mtime, numPoints)
  
  acquire(cache.lock)
  if key in cache.entries:
    result = cache.entries[key]
    inc result.refCount
    result.lastAccessed = cache.accessCounter
    inc cache.accessCounter
    release(cache.lock)
    return

  # Создаем pending-запись и ставим в очередь на генерацию
  let entry = WaveformCacheEntry(
    path: filepath,
    fileSize: int64(info.size),
    mtime: mtime,
    numPoints: numPoints,
    refCount: 1,
    state: wsPending,
    lastAccessed: cache.accessCounter
  )
  inc cache.accessCounter
  
  evictLru(cache)
  cache.entries[key] = entry
  cache.queue.addLast(entry)
  signal(cache.cond) # Будим worker thread
  
  release(cache.lock)
  return entry

proc releaseWaveform*(cache: WaveformCache, entry: WaveformCacheEntry) =
  if entry == nil: return
  acquire(cache.lock)
  if entry.refCount > 0:
    dec entry.refCount
  release(cache.lock)

proc saveWaveformToCache*(cache: WaveformCache, filepath: string, data: WaveformData) =
  var info: FileInfo
  try:
    info = getFileInfo(filepath)
  except CatchableError:
    return

  let mtime = toUnix(info.lastWriteTime)
  let key = makeKey(filepath, int64(info.size), mtime, data.numPoints)
  
  acquire(cache.lock)
  let entry = WaveformCacheEntry(
    path: filepath,
    fileSize: int64(info.size),
    mtime: mtime,
    numPoints: data.numPoints,
    data: data,
    refCount: 0,
    state: wsReady,
    lastAccessed: cache.accessCounter
  )
  inc cache.accessCounter
  
  evictLru(cache)
  cache.entries[key] = entry
  release(cache.lock)

proc clearCache*(cache: WaveformCache) =
  acquire(cache.lock)
  cache.entries.clear()
  cache.queue.clear()
  release(cache.lock)

proc getCacheSize*(cache: WaveformCache): int =
  acquire(cache.lock)
  result = cache.entries.len
  release(cache.lock)

# --- UI-Facing API ---

proc getWaveformForDisplay*(cache: WaveformCache, filepath: string, displayWidth: int32): seq[tuple[minY, maxY: float32]] =
  let entry = cache.getWaveform(filepath, displayWidth)
  if entry == nil:
    return @[]
  
  # defer гарантирует, что refCount не уйдет в утечку при любом выходе из функции
  defer: cache.releaseWaveform(entry)
  
  # UI может отрисовать лоадер, если состояние не Ready
  if entry.state != wsReady:
    return @[]
  
  result = newSeq[tuple[minY, maxY: float32]](int(entry.data.numPoints))
  for i in 0 ..< entry.data.numPoints:
    result[i] = (minY: entry.data.minValues[i], maxY: entry.data.maxValues[i])

proc getPeakAtPosition*(cache: WaveformCache, filepath: string, position: float64): float32 =
  let entry = cache.getWaveform(filepath, 4096)
  if entry == nil:
    return 0.0f
    
  defer: cache.releaseWaveform(entry)
  
  if entry.state != wsReady:
    return 0.0f
  
  let pointIdx = int(position * float64(entry.data.numPoints))
  if pointIdx < 0 or pointIdx >= entry.data.numPoints:
    return 0.0f
  
  return max(abs(entry.data.minValues[pointIdx]), abs(entry.data.maxValues[pointIdx]))