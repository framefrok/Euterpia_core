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
# Проприетарная: репозиторий публичный, но все права сохраняются за автором
# как минимум до ветки v0.10 (возможно v0.15). Поле обязательно для nimble —
# без него `nimble test`/`dump` падают с «does not contain a license field».
# История: #252, 1e59ed4 удалил `license = "MIT"` вместе с удалением LICENSE.
license       = "Proprietary"
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
  exec "nim check --hints:off adapters/rtmidi/midi_backend_rtmidi.nim"
  # Хостинг плагинов за core/plugin_api (issue #29). Форматы (CLAP, EUT)
  # проверяются `nim check`: реальных плагинов и сетевого доступа в CI нет,
  # а контракт покрыт unit-тестом на эталонном адаптере.
  exec "nim check --hints:off adapters/clap/clap_host.nim"
  exec "nim check --hints:off adapters/clap/clap_host_extensions.nim"
  exec "nim check --hints:off adapters/clap/clap_plugin_extensions.nim"
  exec "nim check --hints:off adapters/clap/clap_plugin_backend.nim"
  exec "nim check --hints:off adapters/eut/eut_plugin.nim"
  exec "nim check --hints:off adapters/eut/eut_plugin_backend.nim"
  exec "nim check --hints:off adapters/reference/fake_plugin_backend.nim"
  # miniaudio (#31): TU шима здесь НЕ компилируется (`nim check` не трогает
  # {.compile.}), поэтому проверка быстрая; сборка+прогон — задача
  # `miniaudioSmoke`.
  exec "nim check --hints:off adapters/miniaudio/audio_backend_miniaudio.nim"

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

# ---------------------------------------------------------------------------
# miniaudio (#31). Здесь РЕАЛЬНО собирается и линкуется TU miniaudio
# (adapters/miniaudio/miniaudio_impl.c) — это единственная проверка, что
# C-шим компилируется. Устройства может не быть: тогда тест печатает SKIP
# и завершается успешно, но обязательно проверяет, что отсутствие
# устройства даёт код ошибки, а не падение.
# ---------------------------------------------------------------------------
task miniaudioSmoke, "Сборка TU miniaudio и smoke-прогон адаптера (#31)":
  mkDir buildDir
  buildLog "miniaudio smoke"
  exec "nim c -r --hints:off --out:build/miniaudio_smoke tests/miniaudio_smoke.nim"

# ---------------------------------------------------------------------------
# Санитайзеры (issue #13). Прогоняют тот же unit-набор, что и CI-джобы
# ubsan/asan, — цель для локального воспроизведения падений.
#
# ВАЖНО: у каждого санитайзера СВОЙ --nimcache. При общем кэше объектные
# файлы перемешиваются, и линковка падает на символах «чужого» санитайзера
# (__asan_report_store4 в UBSan-прогоне и наоборот). По этой же причине
# прогоны нельзя запускать параллельно в одном каталоге сборки.
# ---------------------------------------------------------------------------
task ubsan, "Unit-набор под UndefinedBehaviorSanitizer (#13)":
  mkDir buildDir
  buildLog "unit tests under UBSan"
  exec "nim c -r --hints:off --nimcache:build/nc_ubsan " &
    "--passC:-fsanitize=undefined --passC:-fno-sanitize-recover=all " &
    "--passL:-fsanitize=undefined --out:build/unit_ubsan tests/unit/all_tests.nim"

task asan, "Unit-набор под AddressSanitizer (#13)":
  mkDir buildDir
  buildLog "unit tests under ASan"
  # detect_leaks=0: ядро намеренно держит shared-арены (memory_pool,
  # audio-арены пайплайна) на весь срок жизни процесса.
  exec "ASAN_OPTIONS=detect_leaks=0 nim c -r --hints:off --nimcache:build/nc_asan " &
    "--passC:-fsanitize=address --passC:-fno-omit-frame-pointer " &
    "--passL:-fsanitize=address --out:build/unit_asan tests/unit/all_tests.nim"

# ---------------------------------------------------------------------------
# Сквозной CLAP-тест (issue #53). Mock-плагин (tests/mock/) собирается в
# РАЗДЕЛЯЕМУЮ библиотеку — в дереве нет ни одного внешнего `.clap`.
#
# Отдельная цель нужна потому, что `nimble test` не должен зависеть от
# сборки разделяемых библиотек: если `--app:lib` где-то не поддержан,
# падает именно этот джоб, а не весь unit-набор.
# ---------------------------------------------------------------------------
task clapMock, "Сборка mock CLAP-плагина и сквозной тест хостинга (#53)":
  mkDir buildDir
  buildLog "mock CLAP plugin (shared library)"
  let mockLib =
    when defined(windows): "build/mockclap.dll"
    elif defined(macosx): "build/libmockclap.dylib"
    else: "build/libmockclap.so"
  exec "nim c --app:lib --hints:off --out:" & mockLib &
    " tests/mock/mock_clap_plugin.nim"
  buildLog "clap host end-to-end test"
  exec "nim c -r --hints:off --out:build/clap_mock_test tests/clap_mock_test.nim"

