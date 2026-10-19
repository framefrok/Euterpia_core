# adapters/libremidi/README.md

# libremidi как MIDI-бэкенд (issue #38)

`midi_backend_libremidi.nim` реализует `core/midi_api` поверх **libremidi**
(MIT, C++): MIDI 1.0 и MIDI 2.0/UMP, бэкенды ALSA, JACK, CoreMIDI, WinMM,
Windows MIDI Services.

## Границы

* Nim-адаптер знает только C-фасад (`libremidi_shim.h`) и грузит его
  через `dynlib` (`adapters/lazy_dynlib.nim`). Никакие C++-типы наружу не
  выходят: ABI фасада — POD-структуры и `cdecl`-функции.
* Маппинг UMP → `MidiMessage`/`RealtimeEvent` живёт в Core
  (`core/ump.nim`), а не здесь (§41/§42). `grep -rn libremidi core/` пуст.
* Нет библиотеки — `midiInit` возвращает `meUnavailable`; процесс не падает
  до `main()` (issue #267). Имя библиотеки переопределяется
  `EUTERPIA_LIBREMIDI_LIB`.

## Сборка фасада

```bash
# 1. Библиотека (вендорится с фиксированной версией)
git clone --depth 1 --branch v4.5.0 https://github.com/celtera/libremidi
cmake -S libremidi -B build/libremidi -DLIBREMIDI_NO_WINUWP=ON
cmake --build build/libremidi

# 2. Фасад: статический объект + разделяемая библиотека
g++ -std=c++17 -shared -fPIC -O2 -DEUTERPIA_WITH_LIBREMEDI \
    -Ilibremidi/include adapters/libremidi/libremidi_shim.cpp \
    -o build/libeuterpia_libremidi.so
```

Заглушка для CI (без C++ и без библиотеки) собирается тем же файлом без
`-DEUTERPIA_WITH_LIBREMEDI`: функции возвращают «недоступно».

## RtMidi

Решение по открытому вопросу issue #38: RtMidi-адаптер **сохраняется** как
альтернатива. Причины: (1) он не требует C++-тулчейна и работает на
машинах без libremidi; (2) `midi list`/`midi monitor` остаются доступными
даже когда фасад не собран; (3) выбор бэкенда — данные
(`MidiBackendApi`), поэтому оба адаптера сосуществуют без ветвлений в Core
(§69: модуль можно удалить позже, когда libremidi станет обязательным).
