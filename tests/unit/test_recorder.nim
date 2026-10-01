# tests/unit/test_recorder.nim
#
# Рекордер: синхронность arm/disarm на control plane (фикс rsArmed/rsIdle),
# сэмпл-точный старт, отсутствие сброшенных фреймов при простое.
#
# Тесты «запись: ...» проверяют РЕАЛЬНУЮ работу writer thread: команды
# старта/стопа дренирует отдельный поток, и только он открывает/закрывает
# WAV и публикует регион. Если в audio_recorder.nim вернётся проверка
# `when defined(threads)` (она всегда ложна при --threads:on), поток не
# создастся, регион не появится и тест упадёт. Это осознанный предохранитель.

import std/[unittest, os]
import audio_recorder

proc newRecDir(name: string): string =
  ## Каталог для WAV-файлов теста — во временной папке, а не в репозитории.
  ## Хвосты предыдущего (упавшего) прогона удаляются сразу.
  result = getTempDir() / ("euterpia_rec_" & name)
  if dirExists(result):
    removeDir(result)

proc dropRecDir(dir: string) =
  ## Рекурсивное удаление каталога теста вместе с записанными WAV.
  if dirExists(dir):
    removeDir(dir)

suite "audio_recorder":
  test "arm/disarm видны сразу на control plane":
    # Фикс: состояния хранились в обычном int и читались через defer —
    # UI успевал показать «не вооружён» для уже вооружённого трека.
    # Теперь это Atomic, и читатель видит запись немедленно.
    let recDir = newRecDir("arm")
    var rec = initAudioRecorder(
      sampleRate = 48000, blockSize = 128, outputDir = recDir,
      inputChannels = 2, ringFrames = 4096
    )
    check rec.addTrackRecorder(
      trackId = 1, inputChannel = 0, channels = 2, preRollFrames = 0
    )

    check not rec.hasArmedTracks()
    rec.armTrack(1)
    check rec.hasArmedTracks()          # сразу, без ожидания
    rec.disarmTrack(1)
    check not rec.hasArmedTracks()      # и тут же снимается

    rec.cleanupRecordings()
    destroyAudioRecorder(rec)
    dropRecDir(recDir)

  test "запись: старт, данные, стоп -> регион ненулевой длины":
    let recDir = newRecDir("region")
    var rec = initAudioRecorder(
      sampleRate = 48000, blockSize = 128, outputDir = recDir,
      inputChannels = 2, ringFrames = 4096
    )
    check rec.addTrackRecorder(
      trackId = 1, inputChannel = 0, channels = 2, preRollFrames = 0
    )

    rec.armTrack(1)
    rec.startRecording(currentSample = 0)
    # Команды старт/стоп дренирует worker thread (открывает и закрывает
    # WAV-файл): даём ему время отработать до опроса.
    sleep(150)

    var input: array[256, float32]   # 128 frames * 2ch
    for i in 0 ..< input.len:
      input[i] = 0.25f

    # 8 блоков: команда старта применяется на первом же recordBlock
    # (currentSample + blockSize > startAt = 0).
    for b in 0 ..< 8:
      rec.recordBlock(
        cast[ptr UncheckedArray[float32]](addr input[0]),
        currentSample = int64(b * 128)
      )

    check rec.isRecording()

    # Worker открывает WAV только увидев rsRecording, поэтому даём
    # ему цикл между «старт записан» и «стоп запрошен»: иначе close
    # обгонит open и регион не создастся вовсе.
    sleep(150)

    rec.stopRecording()
    # Ещё один блок + пауза: worker закрывает файл и пушит регион.
    rec.recordBlock(
      cast[ptr UncheckedArray[float32]](addr input[0]),
      currentSample = 8 * 128
    )
    sleep(150)

    check not rec.isRecording()
    check rec.getTrackDroppedFrames(1) == 0'i64

    let regions = rec.getRecordedRegions()
    check regions.len >= 1
    if regions.len >= 1:
      check regions[0].trackId == 1
      check regions[0].lengthSamples > 0'i64
      check regions[0].sampleRate == 48000
      check regions[0].channels == 2

    rec.cleanupRecordings()
    destroyAudioRecorder(rec)
    dropRecDir(recDir)

  test "дубликат trackId отклоняется":
    let recDir = newRecDir("dup")
    var rec = initAudioRecorder(outputDir = recDir)
    check rec.addTrackRecorder(trackId = 7, inputChannel = 0, channels = 2)
    check not rec.addTrackRecorder(trackId = 7, inputChannel = 1, channels = 2)
    rec.cleanupRecordings()
    destroyAudioRecorder(rec)
    dropRecDir(recDir)

  test "не-вооружённый трек не пишется":
    let recDir = newRecDir("disarmed")
    var rec = initAudioRecorder(
      sampleRate = 48000, blockSize = 128, outputDir = recDir,
      inputChannels = 2, ringFrames = 4096
    )
    check rec.addTrackRecorder(trackId = 1, inputChannel = 0, channels = 2)

    # Без arm старт невозможен: состояние остаётся rsIdle.
    rec.startRecording(currentSample = 0)
    var input: array[256, float32]
    for i in 0 ..< input.len:
      input[i] = 0.5f
    rec.recordBlock(
      cast[ptr UncheckedArray[float32]](addr input[0]),
      currentSample = 0
    )
    check not rec.isRecording()

    rec.cleanupRecordings()
    destroyAudioRecorder(rec)
    dropRecDir(recDir)