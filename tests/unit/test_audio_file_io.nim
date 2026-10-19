# tests/unit/test_audio_file_io.nim
#
# core/audio_file_io.nim — фасад чтения/записи аудиофайлов (issue #57).
#
# Модуль перенесён в Core из commons/ в issue #5: он использует wav_codec и
# audio_buffer, а Commons не знает о Core (MANIFEST §26/§27). Проверяется
# поведение фасада:
#   - round-trip WAV для 16/24/32-bit (int и float), стерео, порядок каналов;
#   - диспетчер форматов: неподдерживаемое расширение -> IOError;
#   - отсутствующий файл -> IOError;
#   - getInfo отдаёт корректные метаданные.

import std/[unittest, os, math, strutils]
import audio_file_io
import audio_buffer
import wav_codec

proc writeWav(path: string; info: AudioFileInfo; samples: seq[float32]) =
  var enc = openEncoder(path, info)
  var buf = samples
  let frames = int32(samples.len div int(info.channels))
  enc.writeFrames(cast[ptr UncheckedArray[float32]](addr buf[0]), frames)
  enc.close()

proc sineSeq(frames, channels: int; freq: float32): seq[float32] =
  result = newSeq[float32](frames * channels)
  for f in 0 ..< frames:
    for c in 0 ..< channels:
      result[f * channels + c] = sin(2.0f * PI * float32(f) * freq / 48000.0f) * 0.5f

proc info(bits: int16; channels: int16; isFloat: bool): AudioFileInfo =
  AudioFileInfo(
    sampleRate: 48000'i32, channels: channels,
    bitsPerSample: bits, isFloat: isFloat, format: afWav)

suite "audio_file_io: round-trip":
  test "16-bit PCM сохраняет форму сигнала":
    let path = getTempDir() / "euterpia_afio_16.wav"
    let src = sineSeq(512, 1, 1000.0f)
    writeWav(path, info(16, 1, false), src)
    defer: removeFile(path)

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.sampleRate == 48000
    check gotInfo.channels == 1
    check gotInfo.numFrames == 512
    check got.len == 512

    var maxErr = 0.0f
    for i in 0 ..< src.len:
      maxErr = max(maxErr, abs(got[i] - src[i]))
    # Квантование 16 бит: шаг ~ 1/32768.
    check maxErr < 1e-3f

  test "32-bit float точен":
    let path = getTempDir() / "euterpia_afio_32f.wav"
    let src = sineSeq(256, 1, 440.0f)
    writeWav(path, info(32, 1, true), src)
    defer: removeFile(path)

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.isFloat
    check gotInfo.numFrames == 256
    for i in 0 ..< src.len:
      check abs(got[i] - src[i]) < 1e-6f

  test "стерео 24-bit: каналы не перепутаны":
    let path = getTempDir() / "euterpia_afio_24.wav"
    # Левый = +0.25, правый = -0.25 константой.
    var src = newSeq[float32](128 * 2)
    for f in 0 ..< 128:
      src[f * 2] = 0.25f
      src[f * 2 + 1] = -0.25f
    writeWav(path, info(24, 2, false), src)
    defer: removeFile(path)

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.channels == 2
    check gotInfo.numFrames == 128
    for f in 0 ..< 128:
      check abs(got[f * 2] - 0.25f) < 1e-5f
      check abs(got[f * 2 + 1] + 0.25f) < 1e-5f


# =============================================================================
# #209: 32-битный PCM, INFO-чанк, TPDF-dither
# =============================================================================

suite "audio_file_io: сдача (#209)":
  test "32-bit PCM round-trip точен до шага квантования":
    let path = getTempDir() / "euterpia_afio_32i.wav"
    var src = newSeq[float32](128)
    for i in 0 ..< 128:
      src[i] = float32(sin(float64(i) * 0.1))
    writeWav(path, info(32, 1, false), src)
    defer: removeFile(path)
    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.bitsPerSample == 32
    check gotInfo.numFrames == 128
    for i in 0 ..< 128:
      check abs(got[i] - src[i]) < 1e-8f

  test "INFO-чанк пишется и не мешает чтению":
    let path = getTempDir() / "euterpia_afio_info.wav"
    var wi = info(16, 2, false)
    wi.metadata = WavMetadata(title: "T", artist: "A", genre: "G",
                              comment: "C", software: "EUTERPIA")
    let src = sineSeq(64, 2, 440.0f)
    writeWav(path, wi, src)
    defer: removeFile(path)

    let raw = readFile(path)
    check raw.find("LIST") >= 0
    check raw.find("INFO") >= 0
    check raw.find("INAM") >= 0
    check raw.find("IART") >= 0
    check raw.find("\0T\0") >= 0
    check raw.find("\0A\0") >= 0

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.numFrames == 64
    check got.len == 128

  test "dither: TPDF разбивает ступеньку, но не слышен":
    let plain = getTempDir() / "euterpia_afio_nodither.wav"
    let dith = getTempDir() / "euterpia_afio_dither.wav"
    let dith2 = getTempDir() / "euterpia_afio_dither2.wav"
    defer:
      for p in [plain, dith, dith2]:
        if fileExists(p): removeFile(p)

    # 1/3 шага 16-бит: без dither всё округлится в 0.
    let value = 0.3f / 32768.0f
    var src = newSeq[float32](1024)
    for i in 0 ..< 1024: src[i] = value

    var wi = info(16, 1, false)
    writeWav(plain, wi, src)
    wi.dither = true
    writeWav(dith, wi, src)
    writeWav(dith2, wi, src)

    let (a, _) = loadAudioFile(plain)
    let (b, _) = loadAudioFile(dith)
    var changed = 0
    var maxAbs = 0.0f
    for i in 0 ..< 1024:
      maxAbs = max(maxAbs, abs(b[i]))
      if abs(b[i] - a[i]) > 0.0f:
        inc changed
    check changed > 0
    # ±1 шаг квантования: шум не должен «вылезать» за пределы сигнала.
    check maxAbs < 2.5f / 32768.0f
    # Детерминизм: один и тот же вход и настройки — те же байты (#102).
    check readFile(dith) == readFile(dith2)

suite "audio_file_io: диспетчер форматов и ошибки":
  test "openDecoder отвергает неподдерживаемое расширение":
    expect IOError:
      discard openDecoder("track.mp3")
    expect IOError:
      discard openDecoder("track.flac")
    expect IOError:
      discard openDecoder("track.ogg")
    expect IOError:
      discard openDecoder("track.aiff")

  test "openEncoder: FLAC поддержан (#411), неизвестное — отказ":
    let path = getTempDir() / "euterpia_afio_enc.flac"
    var enc = openEncoder(path, info(16, 2, false))
    check enc.format == afFlac
    var samples = sineSeq(256, 2, 440.0f)
    enc.writeFrames(cast[ptr UncheckedArray[float32]](addr samples[0]), 128)
    enc.close()
    check fileExists(path)
    check getFileSize(path) > 0
    removeFile(path)

    # Unknown extension and lossy formats (CLI-only preview) — honest refusal.
    expect IOError:
      discard openEncoder("mix.xyz", info(16, 2, false))
    expect IOError:
      discard openEncoder("mix.ogg", info(16, 2, false))

  test "расширение распознаётся без учёта регистра":
    let path = getTempDir() / "euterpia_afio_upper.WAV"
    writeWav(path, info(16, 1, false), sineSeq(64, 1, 500.0f))
    defer: removeFile(path)
    var dec = openDecoder(path)
    check dec.getInfo().numFrames == 64
    dec.close()

  test "loadAudioFile на отсутствующем файле бросает IOError":
    expect IOError:
      discard loadAudioFile(getTempDir() / "euterpia_afio_missing.wav")

  test "getInfo отдаёт метаданные и duration":
    let path = getTempDir() / "euterpia_afio_info.wav"
    writeWav(path, info(32, 2, true), sineSeq(4800, 2, 200.0f))
    defer: removeFile(path)

    var dec = openDecoder(path)
    let gi = dec.getInfo()
    check gi.sampleRate == 48000
    check gi.channels == 2
    check gi.bitsPerSample == 32
    check gi.isFloat
    check gi.format == afWav
    check gi.numFrames == 4800
    check abs(gi.duration - 0.1) < 1e-9     # 4800 сэмплов при 48 кГц
    dec.close()

suite "audio_file_io: оборванная запись (#76)":
  test "незакрытый WAV читается как пустой, а не как «4 ГБ»":
    let path = getTempDir() / "euterpia_afio_unclosed.wav"
    var enc = openEncoder(path, info(16, 1, false))
    # Пишем БОЛЬШЕ буфера потока: тогда заголовок с плейсхолдерами реально
    # попадает на диск (у FileStream буферизованная запись, и без close()
    # маленький файл остаётся пустым).
    var buf = newSeq[float32](10_000)
    enc.writeFrames(cast[ptr UncheckedArray[float32]](addr buf[0]), 10_000)
    # НЕ вызываем enc.close() до проверок: эмулируем падение процесса между
    # open и close (здесь и читаются плейсхолдеры нулевых размеров).
    #
    # Но cleanup обязан закрыть писателя ПЕРЕД удалением: на Windows
    # RemoveFile падает с «file is being used by another process», пока
    # хендл открыт (unlink открытого файла на POSIX разрешён, поэтому на
    # Linux/macOS тест проходил и дефект не был виден — CI на Windows до
    # починки workflow вообще не запускался, см. #249/#251).
    defer:
      enc.close()
      removeFile(path)

    # Заголовок: RIFF-размер на смещении 4, `data` ищется по маркеру —
    # перед ним лежит зарезервированный JUNK под будущий ds64 (RF64).
    let raw = readFile(path)
    check raw.len > 44
    check raw[0 .. 3] == "RIFF"
    let dataPos = raw.find("data")
    check dataPos > 0
    check raw[dataPos .. dataPos + 3] == "data"

    var riffSize: uint32
    var dataSize: uint32
    copyMem(addr riffSize, unsafeAddr raw[4], 4)
    copyMem(addr dataSize, unsafeAddr raw[dataPos + 4], 4)
    # Плейсхолдеры нулевые: до close() настоящих размеров в файле нет.
    # Раньше здесь стояло 0xFFFFFFFF, и файл «claim’ил» ~4 ГБ.
    check riffSize == 0'u32
    check dataSize == 0'u32

    # И такой файл реально читается как пустой (не падает, не аллоцирует
    # гигабайты). До этого правки `addr samples[0]` на пустом seq давал
    # IndexDefect в debug-сборке.
    let (samples, gotInfo) = loadAudioFile(path)
    check gotInfo.numFrames == 0
    check samples.len == 0

  test "закрытый файл: размеры корректны (регрессия обычного пути)":
    let path = getTempDir() / "euterpia_afio_closed.wav"
    let src = sineSeq(128, 1, 500.0f)
    writeWav(path, info(16, 1, false), src)
    defer: removeFile(path)

    let raw = readFile(path)
    var riffSize: uint32
    var dataSize: uint32
    copyMem(addr riffSize, unsafeAddr raw[4], 4)
    let dataPos = raw.find("data")
    check dataPos > 0
    copyMem(addr dataSize, unsafeAddr raw[dataPos + 4], 4)
    check riffSize == uint32(raw.len - 8)
    check dataSize == 128'u32 * 2'u32      # 16 бит × 128 кадров

    let (samples, gotInfo) = loadAudioFile(path)
    check gotInfo.numFrames == 128
    check samples.len == 128

suite "audio_file_io: файлы длиннее сырого буфера (#355)":
  test "round-trip файла > 1 МиБ сырых данных читается целиком":
    ## Регрессия heap-переполнения: раньше loadAudioFile клал весь файл в
    ## raw-буфер фиксированных 1 МиБ одним вызовом readFrames. Стерео,
    ## 16 бит, 48 кГц, 6 секунд = 288 000 кадров = 1 152 000 байт сырых —
    ## больше старого буфера. ASan на старом коде падал здесь.
    let path = getTempDir() / "euterpia_afio_long.wav"
    let frames = 48000 * 6
    var src = newSeq[float32](frames * 2)
    for f in 0 ..< frames:
      # Линейный рамп вместо синуса: побайтовая сверка после round-trip
      # ловит и потерю блоков, и сдвиг порядка каналов.
      let v = float32(f mod 1000) / 1000.0f - 0.5f
      src[f * 2] = v
      src[f * 2 + 1] = -v
    writeWav(path, info(16, 2, false), src)
    defer: removeFile(path)

    check getFileSize(path) > 1_048_576'i64   # условие старого переполнения

    let (got, gotInfo) = loadAudioFile(path)
    check gotInfo.numFrames == int64(frames)
    check got.len == src.len
    # Ошибка квантования 16 бит — не больше шага; главное — длина и порядок.
    var maxErr = 0.0f
    for i in 0 ..< src.len:
      maxErr = max(maxErr, abs(got[i] - src[i]))
    check maxErr < 1e-3f

suite "audio_file_io: NaN/Inf в сигнале (#358)":
  ## Регрессия: наивные max/min пропускают NaN (сравнения с NaN дают false)
  ## в конвертацию float→int — в файл попадало недетерминированное значение.
  ## Recorder такие сигналы обнулял, wav_codec — нет: писатели ядра
  ## расходились. Guard обязан дать один и тот же результат в обоих путях.

  proc checkGuarded(bits: int16; isFloat: bool; tol: float32) =
    let path = getTempDir() / "euterpia_afio_nan.wav"
    var src = newSeq[float32](8)
    src[0] = NaN                 # → 0.0
    src[1] = NegInf              # → -1.0
    src[2] = Inf                 # → +1.0
    src[3] = 0.5f                # → без изменений
    src[4] = -2.0f * NaN         # NaN, но не литерал: тоже → 0.0
    src[5] = 1e30f               # за пределом → +1.0
    src[6] = -1e30f              # за пределом → -1.0
    src[7] = 0.0f
    writeWav(path, info(bits, 1, isFloat), src)
    defer: removeFile(path)

    let (got, _) = loadAudioFile(path)
    check got.len == 8
    for i, v in got:
      check v == v              # ни одного NaN в прочитанных данных
    check got[0] == 0.0f
    check abs(got[1] - (-1.0f)) < tol
    check abs(got[2] - 1.0f) < tol
    check abs(got[3] - 0.5f) < tol
    check got[4] == 0.0f
    check abs(got[5] - 1.0f) < tol
    check abs(got[6] - (-1.0f)) < tol
    check got[7] == 0.0f

  test "32-bit float: NaN → 0, Inf → ±1, остальное не тронуто":
    checkGuarded(32, true, 1e-6f)

  test "16-bit PCM: тот же guard, что и в audio_recorder":
    checkGuarded(16, false, 1e-3f)

suite "audio_file_io: враждебный заголовок (#354)":
  ## Битый WAV обязан дать IOError (CLI ловит CatchableError и возвращает
  ## код 2), а НЕ Defect — тот не наследует CatchableError и ронял процесс.

  proc writeRawWav(path: string; channels, sampleRate, bits: uint16;
                   audioFormat: uint16 = 1) =
    ## Минимальный валидный RIFF/WAVE побайтово: раскладка fmt —
    ## 20 audioFormat, 22 channels, 24 sampleRate, 28 byteRate,
    ## 32 blockAlign, 34 bitsPerSample, 36 "data", 40 dataSize.
    var b = newString(52)
    b[0 .. 3] = "RIFF"
    b[8 .. 11] = "WAVE"
    b[12 .. 15] = "fmt "
    b[36 .. 39] = "data"
    proc putU32(off: int; v: uint32) =
      b[off] = char(v and 0xff)
      b[off + 1] = char((v shr 8) and 0xff)
      b[off + 2] = char((v shr 16) and 0xff)
      b[off + 3] = char((v shr 24) and 0xff)
    proc putU16(off: int; v: uint16) =
      b[off] = char(v and 0xff)
      b[off + 1] = char((v shr 8) and 0xff)
    let blockAlign = channels * (bits div 8)
    putU32(4, 44'u32)             # RIFF size
    putU32(16, 16'u32)            # fmt size
    putU16(20, audioFormat)
    putU16(22, channels)
    putU32(24, uint32(sampleRate))
    putU32(28, uint32(sampleRate) * uint32(blockAlign))
    putU16(32, blockAlign)
    putU16(34, bits)
    putU32(40, 4'u32)             # data size
    writeFile(path, b)

  test "channels=0 — IOError, а не division by zero":
    let path = getTempDir() / "euterpia_afio_ch0.wav"
    writeRawWav(path, channels = 0, sampleRate = 44100, bits = 16)
    defer: removeFile(path)
    expect IOError:
      discard loadAudioFile(path)

  test "sampleRate=0 — IOError, а не duration=inf":
    let path = getTempDir() / "euterpia_afio_sr0.wav"
    writeRawWav(path, channels = 2, sampleRate = 0, bits = 16)
    defer: removeFile(path)
    expect IOError:
      discard loadAudioFile(path)

  test "8-бит PCM — честный отказ, а не тишина без ошибки":
    let path = getTempDir() / "euterpia_afio_8bit.wav"
    writeRawWav(path, channels = 2, sampleRate = 44100, bits = 8)
    defer: removeFile(path)
    expect IOError:
      discard loadAudioFile(path)

  test "мусорная глубина (bits=4) — IOError":
    let path = getTempDir() / "euterpia_afio_4bit.wav"
    writeRawWav(path, channels = 1, sampleRate = 44100, bits = 4)
    defer: removeFile(path)
    expect IOError:
      discard loadAudioFile(path)


suite "audio_file_io: streamFileToBuffer на границе кольца (#357)":
  ## Регрессия «спящего» heap overflow: однопараметровый getWritePtr() не
  ## разбивал запись на границе кольца и не смотрел на свободное место, и
  ## readFrames писал до blockSize (4096) фреймов за конец аллокации.
  ## Кольцо здесь намеренно МЕНЬШЕ блока, поэтому запись пересекает границу
  ## на каждом шаге; под ASan старая версия падала на записи.

  type
    StreamJob = object
      path: array[256, char]
      rtBuf: ptr StreamingAudioBuffer

  proc streamJobRun(job: pointer) {.thread.} =
    let j = cast[ptr StreamJob](job)
    streamFileToBuffer($cast[cstring](unsafeAddr j.path[0]), j.rtBuf[])

  test "файл длиннее кольца заливается целиком, без записи мимо границ":
    let path = getTempDir() / "euterpia_afio_stream_wrap.wav"
    let frames = 5000
    # Моно 32-bit float: сравнение после round-trip точное, без квантования.
    var src = newSeq[float32](frames)
    for i in 0 ..< frames:
      src[i] = float32(i mod 97) / 97.0f - 0.5f
    writeWav(path, info(32, 1, true), src)
    defer: removeFile(path)

    # Кольцо 64 кадра << blockSize: запись принудительно режется границей
    # кольца многократно (startIdx переходит через capacity).
    var rtBuf = StreamingAudioBuffer.init(64'i64, 1'i32)
    defer: rtBuf.destroy()

    doAssert path.len < 256
    let job = cast[ptr StreamJob](allocShared0(sizeof(StreamJob)))
    doAssert job != nil
    defer: deallocShared(job)
    job.rtBuf = addr rtBuf
    for i, ch in path:
      job.path[i] = ch
    job.path[path.len] = '\0'

    var th: Thread[pointer]
    createThread(th, streamJobRun, cast[pointer](job))

    var got = newSeq[float32](frames)
    var received = 0
    var idleSpins = 0
    var chunk: array[256, float32]
    while received < frames and idleSpins < 5000:
      let n = rtBuf.read(cast[ptr UncheckedArray[float32]](addr chunk[0]), 256)
      if n > 0:
        for k in 0 ..< int(n):
          got[received + k] = chunk[k]
        received += int(n)
        idleSpins = 0
      else:
        sleep(1)          # кольцо пусто: ждём продюсера
        inc idleSpins

    joinThread(th)

    check received == frames        # ничего не потеряно по дороге
    var maxErr = 0.0f
    for i in 0 ..< frames:
      maxErr = max(maxErr, abs(got[i] - src[i]))
    check maxErr < 1e-6f            # порядок и значения не перепутаны


# =============================================================================
# RF64 (аудит, P0): чтение файла > 4 ГБ и зарезервированный ds64
# =============================================================================

suite "audio_file_io: RF64":
  proc writeTinyRf64(path: string) =
    ## Минимальный RF64: ds64 с настоящими размерами, data с 0xFFFFFFFF.
    ## Писатель переходит в RF64 только на реальном переполнении RIFF
    ## (4 ГиБ в тесте не записать), поэтому читатель проверяется на
    ## синтетическом файле, собранном строго по спецификации.
    const frames = 4
    const dataBytes = frames * 2
    var b = newString(80 + dataBytes)
    proc putU16(off: int; v: uint16) =
      b[off] = char(v and 0xff)
      b[off + 1] = char((v shr 8) and 0xff)
    proc putU32(off: int; v: uint32) =
      b[off] = char(v and 0xff)
      b[off + 1] = char((v shr 8) and 0xff)
      b[off + 2] = char((v shr 16) and 0xff)
      b[off + 3] = char((v shr 24) and 0xff)
    proc putU64(off: int; v: uint64) =
      for i in 0 ..< 8:
        b[off + i] = char((v shr (i * 8)) and 0xFF)
    b[0 .. 3] = "RF64"
    putU32(4, 0xFFFFFFFF'u32)
    b[8 .. 11] = "WAVE"
    b[12 .. 15] = "ds64"
    putU32(16, 28'u32)
    putU64(20, uint64(80 + dataBytes - 8))   # RIFF size
    putU64(28, uint64(dataBytes))            # data size
    putU64(36, uint64(frames))               # sample count
    putU32(44, 0'u32)                        # table length
    b[48 .. 51] = "fmt "
    putU32(52, 16'u32)
    putU16(56, 1'u16)                        # PCM
    putU16(58, 1'u16)                        # mono
    putU32(60, 48000'u32)
    putU32(64, 96000'u32)
    putU16(68, 2'u16)
    putU16(70, 16'u16)
    b[72 .. 75] = "data"
    putU32(76, 0xFFFFFFFF'u32)
    putU16(80, 0'u16)
    putU16(82, 16384'u16)                    # +0.5
    putU16(84, 0'u16)
    putU16(86, 0'u16)
    writeFile(path, b)

  test "ds64 задаёт настоящий размер data, а не 0xFFFFFFFF":
    let path = getTempDir() / "euterpia_afio_rf64.wav"
    writeTinyRf64(path)
    defer: removeFile(path)

    let (samples, got) = loadAudioFile(path)
    check got.format == afWav
    check got.numFrames == 4
    check got.channels == 1
    check got.sampleRate == 48000
    check samples.len == 4
    check samples[0] == 0.0f
    check abs(samples[1] - 0.5f) < 1e-6f
    check samples[2] == 0.0f
    check samples[3] == 0.0f

  test "обычный файл остаётся RIFF, JUNK не мешает читателю":
    let path = getTempDir() / "euterpia_afio_junk.wav"
    writeWav(path, info(16, 1, false), sineSeq(64, 1, 440.0f))
    defer: removeFile(path)

    let raw = readFile(path)
    check raw[0 .. 3] == "RIFF"
    check raw.find("JUNK") > 0
    # Размер RIFF в шапке — реальный, а не плейсхолдер.
    var riffSize: uint32
    copyMem(addr riffSize, unsafeAddr raw[4], 4)
    check int64(riffSize) == int64(raw.len) - 8

    let (samples, got) = loadAudioFile(path)
    check got.numFrames == 64
    check samples.len == 64


# =============================================================================
# seek для декодированных форматов (аудит, P2)
# =============================================================================

suite "audio_file_io: seek (аудит P2)":
  test "seekAudioFile позиционирует FLAC/MP3/OGG/AIFF, а не игнорируется":
    for name in ["tone.flac", "tone.mp3", "tone.ogg", "tone.aiff"]:
      let path = "tests/fixtures" / name
      let (all, info) = loadAudioFile(path)
      let ch = int(info.channels)
      check ch > 0
      check all.len > 300 * ch

      var dec = openDecoder(path)
      var raw = newSeq[uint8](4096)
      var head = newSeq[float32](64 * ch)
      check dec.readFrames(cast[ptr UncheckedArray[uint8]](addr raw[0]),
                           cast[ptr UncheckedArray[float32]](addr head[0]),
                           64) == 64

      let target = 200
      dec.seekAudioFile(int64(target))
      var got = newSeq[float32](32 * ch)
      check dec.readFrames(cast[ptr UncheckedArray[uint8]](addr raw[0]),
                           cast[ptr UncheckedArray[float32]](addr got[0]),
                           32) == 32
      for i in 0 ..< 32 * ch:
        check abs(got[i] - all[target * ch + i]) < 1e-6f
      dec.close()

  test "seekAudioFile клампится к концу файла":
    let path = "tests/fixtures" / "tone.flac"
    let (all, info) = loadAudioFile(path)
    let ch = int(info.channels)
    var dec = openDecoder(path)
    dec.seekAudioFile(int64(high(int64)))
    var raw = newSeq[uint8](64)
    var got = newSeq[float32](16 * ch)
    check dec.readFrames(cast[ptr UncheckedArray[uint8]](addr raw[0]),
                         cast[ptr UncheckedArray[float32]](addr got[0]),
                         16) == 0
    dec.close()

