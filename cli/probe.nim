# cli/probe.nim
#
# Пробы ВНЕШНИХ библиотек для CLI (issues #105, #258).
#
# Зачем отдельный модуль: и `doctor` (#105), и `config` (#258) должны уметь
# честно ответить на вопрос «есть ли на этой машине portaudio/rtmidi», при
# этом CLI НЕ имеет права импортировать `{.dynlib.}`-адаптеры: их символы
# резолвятся на инициализации модуля, то есть отсутствие библиотеки роняет
# процесс ДО `main()` (проверено на adapters/rtmidi, #267). `dlopen` делает
# ровно то же самое, но поддаётся обработке.
#
# Список имён библиотек живёт здесь, а не в адаптерах, потому что адаптеры в
# CLI не линкуются (#88): это знание нужно ровно для пробы.

import std/dynlib

const
  PortAudioLibs* =
    when defined(windows): ["portaudio_x64.dll"]
    elif defined(macosx): ["libportaudio.dylib"]
    else: ["libportaudio.so", "libportaudio.so.2"]

  RtMidiLibs* =
    when defined(windows): ["rtmidi.dll"]
    elif defined(macosx): ["librtmidi.dylib"]
    else: ["librtmidi.so", "librtmidi.so.7", "librtmidi.so.6", "librtmidi.so.5"]

proc dynlibProbe*(names: openArray[string]): tuple[found: bool; name: string] =
  ## Пробует загрузить библиотеку по имени и сразу выгружает её.
  ##
  ## `dlopen` — ровно то, что делает загрузчик перед `main()` для
  ## dynlib-адаптеров, поэтому проба честно отвечает на вопрос «смог бы
  ## CLI использовать этот бэкенд». Библиотека не инициализируется и не
  ## открывает устройств: загрузили — выгрузили.
  for name in names:
    try:
      let handle = loadLib(name)
      if not handle.isNil:
        unloadLib(handle)
        return (true, name)
    except LibraryError:
      discard
  (false, "")
