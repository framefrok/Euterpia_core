# tests/unit/test_codec_api.nim
#
# Общий контракт форматов аудиофайлов (issue #356).
#
# Проверяется главное свойство выноса типов из `wav_codec`: контракт доступен
# БЕЗ импорта конкретного кодека. Этот файл импортирует ТОЛЬКО `codec_api` —
# если `AudioFileInfo`/`AudioFileFormat` снова «переедут» в кодек, тест
# перестанет компилироваться.

import std/unittest

import codec_api

suite "codec_api: контракт не тянет реализацию кодека (#356)":
  test "AudioFileInfo собирается и читается без wav_codec":
    let inf = AudioFileInfo(
      sampleRate: 48000'i32,
      channels: 2'i16,
      bitsPerSample: 16'i16,
      numFrames: 100'i64,
      isFloat: false,
      format: afWav,
      duration: 0.1)
    check inf.sampleRate == 48000
    check inf.channels == 2
    check inf.bitsPerSample == 16
    check inf.numFrames == 100
    check not inf.isFloat
    check inf.format == afWav

  test "значения по умолчанию — валидный «пустой» контракт":
    let empty = AudioFileInfo()
    check empty.sampleRate == 0
    check empty.channels == 0
    check empty.numFrames == 0
    check empty.format == afWav   # первый вариант перечисления

  test "перечисление форматов знает и текущий, и будущие":
    # afWav реализован; остальные — заглушки под будущие кодеки (#10).
    let all = {afWav, afFlac, afOgg, afMp3, afAiff}
    check afWav in all
    check ord(afWav) == 0
    check all.len == 5
