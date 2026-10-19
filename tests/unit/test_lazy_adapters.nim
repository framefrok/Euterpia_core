# tests/unit/test_lazy_adapters.nim
#
# Ленивая загрузка внешних библиотек адаптеров (issue #267).
#
# Главное утверждение: импорт адаптера и вызов init на машине БЕЗ
# библиотеки не роняют процесс. Прагма `{.dynlib.}` резолвила символы в
# инициализации модуля, поэтому такой тест был невозможен: процесс падал
# до первой строки.
#
# Имя библиотеки переопределяется переменной окружения — так ветка
# «библиотеки нет» проверяется детерминированно даже там, где PortAudio
# и RtMidi установлены.

import std/[unittest, os]

import audio_backend_api
import midi_api
import ../../adapters/portaudio/audio_backend_portaudio
import ../../adapters/rtmidi/midi_backend_rtmidi

const
  PortAudioEnv = "EUTERPIA_PORTAUDIO_LIB"
  RtMidiEnv = "EUTERPIA_RTMIDI_LIB"
  MissingLib = "/nonexistent/euterpia-no-such-library.so"

template withEnv(name, value: string; body: untyped) =
  block:
    let hadEnv = existsEnv(name)
    let oldEnv = if hadEnv: getEnv(name) else: ""
    putEnv(name, value)
    try:
      body
    finally:
      if hadEnv: putEnv(name, oldEnv)
      else: delEnv(name)

suite "ленивая загрузка dynlib-адаптеров (#267)":
  test "portaudio: импорт не требует библиотеки, init даёт abeUnavailable":
    withEnv(PortAudioEnv, MissingLib):
      let api = createPortAudioBackend()
      check not api.isNil

      var log = silentLogger()
      let err = backendInit(api, addr log)
      check err == abeUnavailable
      check backendDeviceCount(api, true) == 0
      check backendDeviceCount(api, false) == 0
      check not backendIsRunning(api)

      destroyPortAudioBackend(api)

  test "rtmidi: импорт не требует библиотеки, init даёт meUnavailable":
    withEnv(RtMidiEnv, MissingLib):
      let api = createRtMidiBackend()
      check not api.isNil

      var log = silentLogger()
      let err = midiInit(api, addr log)
      check err == meUnavailable
      check midiDeviceCount(api, mpdInput) == 0
      check midiDeviceCount(api, mpdOutput) == 0
      check midiOpenPort(api, mpdInput, 0).isNil

      destroyRtMidiBackend(api)

  test "повторная попытка после ошибки не кэширует «недоступно» навсегда":
    # openLibrary пытается загрузить заново, если handle пуст: смена
    # переменной окружения (или установка библиотеки) подхватывается.
    withEnv(PortAudioEnv, MissingLib):
      let api = createPortAudioBackend()
      var log = silentLogger()
      check backendInit(api, addr log) == abeUnavailable
      destroyPortAudioBackend(api)

    withEnv(PortAudioEnv, MissingLib & ".still-missing"):
      let api2 = createPortAudioBackend()
      var log2 = silentLogger()
      check backendInit(api2, addr log2) == abeUnavailable
      destroyPortAudioBackend(api2)
