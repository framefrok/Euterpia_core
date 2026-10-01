# tests/unit/test_waveform_cache.nim
#
# commons/waveform_cache.nim — кэш пиков волновой формы (issue #57).
#
# Что проверяется:
#   - синхронный путь: saveWaveformToCache -> getWaveform ->
#     getWaveformForDisplay / getPeakAtPosition (min/max/rms, границы точек);
#   - refCount защищает используемую запись от вытеснения (LRU);
#   - getCacheSize / clearCache;
#   - асинхронный путь: worker thread реально генерирует пики из файла
#     (polling по state до wsReady);
#   - отсутствующий файл -> getWaveform возвращает nil.
#
# Тест осознанно минимальный по времени: генерация идёт в отдельном потоке,
# поэтому готовность ждём с таймаутом, а не sleep-ом на «достаточно долго».

import std/[unittest, os, math, times]
import waveform_cache
import audio_file_io
import wav_codec

proc writeWav(path: string; frames, channels: int; isFloat: bool;
              gen: proc(i: int): float32) =
  var inf = AudioFileInfo(
    sampleRate: 48000'i32, channels: int16(channels),
    bitsPerSample: (if isFloat: 32'i16 else: 16'i16),
    isFloat: isFloat, format: afWav)
  var enc = openEncoder(path, inf)
  var buf = newSeq[float32](frames * channels)
  for i in 0 ..< frames:
    for c in 0 ..< channels:
      buf[i * channels + c] = gen(i)
  enc.writeFrames(cast[ptr UncheckedArray[float32]](addr buf[0]), int32(frames))
  enc.close()

proc waitReady(cache: WaveformCache; entry: WaveformCacheEntry;
               timeoutMs = 5000): bool =
  ## Ждём готовности через СИНХРОНИЗИРОВАННЫЙ аксессор: прямой доступ к
  ## `entry.state` из другого потока — гонка данных (issue #84, TSan).
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    if cache.waveformReady(entry): return true
    sleep(1)
  false

proc flatData(numPoints: int32; readyPath: int64 = 0): WaveformData =
  WaveformData(
    minValues: newSeq[float32](int(numPoints)),
    maxValues: newSeq[float32](int(numPoints)),
    rmsValues: newSeq[float32](int(numPoints)),
    numPoints: numPoints, sampleRate: 48000, channels: 1,
    totalFrames: readyPath)

proc freshDir(name: string): string =
  result = getTempDir() / ("euterpia_wf_" & name)
  if dirExists(result): removeDir(result)
  createDir(result)

suite "waveform_cache: синхронный путь":
  test "getWaveformForDisplay отдаёт min/max сохранённых точек":
    let dir = freshDir("display")
    let path = dir / "a.wav"
    writeWav(path, 64, 1, false, proc(i: int): float32 = 0.0f)

    let cache = initWaveformCache(dir, 16)
    var data = flatData(2)
    data.minValues = @[-1.0f, 0.0f]
    data.maxValues = @[1.0f, 0.5f]
    data.rmsValues = @[0.7f, 0.2f]
    cache.saveWaveformToCache(path, data)

    let disp = cache.getWaveformForDisplay(path, 2)
    check disp.len == 2
    check disp[0].minY == -1.0f
    check disp[0].maxY == 1.0f
    check disp[1].minY == 0.0f
    check disp[1].maxY == 0.5f

    cache.destroy()
    removeDir(dir)

  test "getPeakAtPosition читает пик нужной точки и отвергает выход за границы":
    let dir = freshDir("peak")
    let path = dir / "b.wav"
    writeWav(path, 64, 1, false, proc(i: int): float32 = 0.0f)

    let cache = initWaveformCache(dir, 16)
    var data = flatData(4096)
    data.minValues[1024] = -0.8f
    data.maxValues[2048] = 0.6f
    cache.saveWaveformToCache(path, data)

    check cache.getPeakAtPosition(path, 1024.0 / 4096.0) == 0.8f
    check cache.getPeakAtPosition(path, 2048.0 / 4096.0) == 0.6f
    check cache.getPeakAtPosition(path, 2.0) == 0.0f       # вне диапазона
    check cache.getPeakAtPosition(path, -0.5) == 0.0f

    cache.destroy()
    removeDir(dir)

  test "отсутствующий файл -> nil и пустой дисплей":
    let dir = freshDir("missing")
    let cache = initWaveformCache(dir, 8)
    check cache.getWaveform(dir / "nope.wav") == nil
    check cache.getWaveformForDisplay(dir / "nope.wav", 512).len == 0
    check cache.getPeakAtPosition(dir / "nope.wav", 0.5) == 0.0f
    cache.destroy()
    removeDir(dir)

suite "waveform_cache: вытеснение":
  test "LRU не вытесняет запись с refCount > 0":
    let dir = freshDir("lru")
    let p1 = dir / "p1.wav"
    let p2 = dir / "p2.wav"
    let p3 = dir / "p3.wav"
    for p in [p1, p2, p3]:
      writeWav(p, 64, 1, false, proc(i: int): float32 = 0.0f)

    let cache = initWaveformCache(dir, 2)
    var data = flatData(8)
    cache.saveWaveformToCache(p1, data)
    cache.saveWaveformToCache(p2, data)
    check cache.getCacheSize() == 2

    # Держим p1 — он не должен быть вытеснен.
    let held = cache.getWaveform(p1, 8)
    check held != nil
    check cache.waveformReady(held)

    cache.saveWaveformToCache(p3, data)      # вытесняет p2 (refCount == 0)
    check cache.getCacheSize() == 2

    # p1 выжил: get отдаёт ту же готовую запись, а не pending.
    let held2 = cache.getWaveform(p1, 8)
    check cache.waveformReady(held2)

    cache.releaseWaveform(held2)
    cache.releaseWaveform(held)
    cache.destroy()
    removeDir(dir)

  test "clearCache опустошает кэш":
    let dir = freshDir("clear")
    let path = dir / "c.wav"
    writeWav(path, 64, 1, false, proc(i: int): float32 = 0.0f)

    let cache = initWaveformCache(dir, 8)
    cache.saveWaveformToCache(path, flatData(4))
    check cache.getCacheSize() == 1
    cache.clearCache()
    check cache.getCacheSize() == 0
    cache.destroy()
    removeDir(dir)

suite "waveform_cache: асинхронная генерация":
  test "worker thread считает min/max/rms по блокам файла":
    let dir = freshDir("async")
    let path = dir / "ramp.wav"
    # Рампа -1 .. +1 на 1024 сэмпла: у каждого блока предсказуемый знак.
    writeWav(path, 1024, 1, true, proc(i: int): float32 =
      -1.0f + 2.0f * float32(i) / 1023.0f)

    let cache = initWaveformCache(dir, 8)
    let entry = cache.getWaveform(path, 8)
    check entry != nil
    check waitReady(cache, entry)

    # Только КОПИЯ под локом: прямой доступ к entry.data из другого потока —
    # гонка данных (нашёл TSan, issue #84).
    var wf: WaveformData
    check cache.waveformSnapshot(entry, wf)
    check wf.numPoints == 8
    check wf.channels == 1
    check wf.sampleRate == 48000
    check wf.totalFrames == 1024

    # Первый блок целиком отрицательный, последний — целиком положительный.
    check wf.minValues[0] < -0.9f
    check wf.maxValues[0] < -0.7f
    check wf.maxValues[7] > 0.9f
    check wf.minValues[7] > 0.7f
    # RMS заполнен и ненулевой (внутри ±1).
    check wf.rmsValues[0] > 0.7f
    check wf.rmsValues[7] > 0.7f

    cache.releaseWaveform(entry)
    cache.destroy()
    removeDir(dir)

