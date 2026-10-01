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

# Флаги потоков и memory manager задаются в config.nims, чтобы они
# были одинаковыми при любой точке входа (unit, integration, CLI).

task test, "Полный прогон тестов ядра: unit + integration":
  mkDir buildDir
  buildLog "unit tests"
  exec "nim c -r --hints:off --out:" & unitBin & " tests/unit/all_tests.nim"
  buildLog "integration tests"
  exec "nim c -r --hints:off --out:" & intBin & " tests/integration_test.nim"
  buildLog "готово"
  echo "Все тесты EUTERPIA прошли."

task unit, "Только unit-тесты DSP и контрактов":
  mkDir buildDir
  exec "nim c -r --hints:off --out:" & unitBin & " tests/unit/all_tests.nim"

task integration, "Интеграционный тест ядра":
  mkDir buildDir
  exec "nim c -r --hints:off --out:" & intBin & " tests/integration_test.nim"

task buildRelease, "Сборка интеграционного теста в release с LTO":
  mkDir buildDir
  exec "nim c --hints:off -d:release --passL:-flto --out:" & intBin & " tests/integration_test.nim"

