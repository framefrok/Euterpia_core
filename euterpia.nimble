# ============================================================
# EUTERPIA — описание пакета и задачи сборки ядра.
#
# Ядро DAW: Core (фундамент) + Node SDK (контракты нод) + builtin DSP-ноды.
# CLI и Editor строятся поверх, когда появятся.
#
# Внешние плагины: только CLAP (.clap). Формат VST не поддерживается
# и не планируется (MANIFEST §8, §42).
# ============================================================

version       = "0.2.0"
author        = "EUTERPIA"
description   = "EUTERPIA DAW core: audio runtime, graph compiler, realtime scheduler, node SDK, builtin DSP"
license       = "MIT"
srcDir        = "core"

requires "nim >= 2.0.0"

const
  buildDir* = "build"
  unitBin*  = "build/euterpia_unit_tests"
  intBin*   = "build/euterpia_integration_tests"

proc buildLog(title: string) =
  echo ""
  echo "-- " & title

# Тип-проверка адаптеров.
#
# Внешние библиотеки (libportaudio, librtmidi) в CI могут отсутствовать,
# а импорт адаптера тянет eager-загрузку dynlib на старте процесса.
# Поэтому адаптер проверяется `nim check`: семантический разбор без
# линковки и без загрузки библиотеки.
proc checkAdapters() =
  buildLog "adapters type-check"
  exec "nim check --hints:off adapters/portaudio/audio_backend_portaudio.nim"

# Флаги потоков и memory manager задаются в config.nims, чтобы они
# были одинаковыми при любой точке входа (unit, integration, CLI).

task test, "Полный прогон тестов ядра: unit + integration":
  mkDir buildDir
  checkAdapters()
  buildLog "unit tests"
  exec "nim c -r --hints:off --out:" & unitBin & " tests/unit/all_tests.nim"
  buildLog "integration tests"
  exec "nim c -r --hints:off --out:" & intBin & " tests/integration_test.nim"
  buildLog "готово"
  echo "Все тесты EUTERPIA прошли."

task check, "Только тип-проверка адаптеров":
  checkAdapters()
  echo "Адаптеры типизируются корректно."


task unit, "Только unit-тесты DSP и контрактов":
  mkDir buildDir
  exec "nim c -r --hints:off --out:" & unitBin & " tests/unit/all_tests.nim"

task integration, "Интеграционный тест ядра":
  mkDir buildDir
  exec "nim c -r --hints:off --out:" & intBin & " tests/integration_test.nim"

task buildRelease, "Сборка интеграционного теста в release с LTO":
  mkDir buildDir
  exec "nim c --hints:off -d:release --passL:-flto --out:" & intBin & " tests/integration_test.nim"

