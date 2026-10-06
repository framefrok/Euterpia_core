# ============================================================
# EUTERPIA — описание пакета и задачи сборки ядра.
#
# Ядро DAW: Core (фундамент) + Node SDK (контракты нод) + builtin DSP-ноды.
# CLI и Editor строятся поверх, когда появятся.
#
# Внешние плагины: CLAP (.clap) и собственный EUT; LV2 — в плане (issue #39).
# Формат VST (VST2/VST3) не поддерживается и не будет поддерживаться
# (MANIFEST §104).
# ============================================================

# Версия пакета берётся из Nim-модуля `euterpia_version.nim`, а не пишется
# строкой: тот же модуль печатает `euterpia --version`, поэтому версия
# пакета и версия CLI не могут разойтись (issue #88; релиз — #113).
import euterpia_version

version       = EuterpiaVersion
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
  buildDir*   = "build"
  unitBin*    = "build/euterpia_unit_tests"
  intBin*     = "build/euterpia_integration_tests"
  cliBin*     =
    when defined(windows): "build/euterpia.exe"
    else: "build/euterpia"
  cliTestBin* = "build/cli_test"

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

# Направление зависимостей слоёв (MANIFEST §27, issue #50).
#
# Проверка статическая и не требует Nim: скрипт разбирает только строки
# import/include/from и падает на core ─X→ adapters/nodes, nodes ─X→ adapters
# и commons ─X→ core/nodes. Тот же скрипт запускает джоб CI `architecture`,
# поэтому зелёная локальная проверка означает зелёный джоб.
task archGuard, "Направление зависимостей слоёв: core/nodes/commons не тянут вниз (§27, #50)":
  exec "python3 tools/check_architecture.py"


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
# CLI (issue #88). Отдельная цель, а не часть `nimble test`, по двум
# причинам:
#   * CLI линкует адаптер miniaudio — это статическая C-библиотека
#     (единственный адаптер без внешней зависимости), её сборка заметно
#     тяжелее unit-набора;
#   * контракт CLI проверяется ЗАПУСКОМ процесса (коды возврата,
#     разделение stdout/stderr), то есть это smoke-тест, а не unit-тест.
# ---------------------------------------------------------------------------
task cli, "Сборка CLI: build/euterpia (issue #88)":
  mkDir buildDir
  buildLog "cli"
  exec "nim c --hints:off --out:" & cliBin & " cli.nim"

task cliSmoke, "CLI smoke: точка входа, doctor, completion, проект, граф и настройки (#88, #89, #90, #105, #258, #259)":
  mkDir buildDir
  buildLog "cli build"
  exec "nim c --hints:off --out:" & cliBin & " cli.nim"
  buildLog "cli smoke test"
  exec "nim c -r --hints:off --out:" & cliTestBin & " tests/cli_test.nim"

task cliDocs, "Пересобрать раздел справочника docs/cli.md из описания команд (#330)":
  ## Раздел между маркерами `cli-spec:begin`/`cli-spec:end` принадлежит
  ## спецификации (`libs/cli_spec`), а не руке: правится описание команды,
  ## раздел пересобирается этой задачей, а CI (`nimble cliSmoke`) сверяет
  ## раздел в репозитории со свежим выводом байт-в-байт.
  mkDir buildDir
  buildLog "cli build"
  exec "nim c --hints:off --out:" & cliBin & " cli.nim"
  buildLog "cli docs"
  exec cliBin & " __reference --write docs/cli.md"

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
  # -d:useMalloc (#364): Nim-аллокаторы (в т.ч. allocShared) уходят в libc,
  # поэтому санитайзер видит ту же кучу, что и C-код ядра. Без флага
  # allocShared-арены (кольцо, memory_pool, аудио-арены пайплайна) живут в
  # собственной mmap-куче Nim мимо инструментирования — переполнения в них
  # не видны. Для UBSan это не про OOB, но единый аллокатор убирает
  # расхождение поведения debug-сборок.
  exec "nim c -r --hints:off --nimcache:build/nc_ubsan -d:useMalloc " &
    "--passC:-fsanitize=undefined --passC:-fno-sanitize-recover=all " &
    "--passL:-fsanitize=undefined --out:build/unit_ubsan tests/unit/all_tests.nim"

task asan, "Unit-набор под AddressSanitizer (#13)":
  mkDir buildDir
  buildLog "unit tests under ASan"
  # detect_leaks=0: ядро намеренно держит shared-арены (memory_pool,
  # audio-арены пайплайна) на весь срок жизни процесса.
  #
  # -d:useMalloc (#364): БЕЗ него Nim держит allocShared/allocShared0 в
  # собственной mmap-куче, и ASan их НЕ инструментирует — переполнения в
  # `core/audio_buffer.nim` (StreamingAudioBuffer), `core/memory_pool.nim`
  # и аудио-аренах пайплайна не ловились. Флаг направляет все Nim-аллокации
  # через libc malloc, поэтому то же переполнение падает:
  # `AddressSanitizer: heap-buffer-overflow in allocShared0Impl__system_...`.
  # Проверка эффективности флага — `nimble asanProbe` и шаг CI в джобе asan.
  exec "ASAN_OPTIONS=detect_leaks=0 nim c -r --hints:off --nimcache:build/nc_asan -d:useMalloc " &
    "--passC:-fsanitize=address --passC:-fno-omit-frame-pointer " &
    "--passL:-fsanitize=address --out:build/unit_asan tests/unit/all_tests.nim"

# ---------------------------------------------------------------------------
# Зонд ASan/allocShared (#364): доказывает, что флаг -d:useMalloc в `asan`
# действительно ловит переполнения shared-арен. Без useMalloc зонд молчит
# (буфер лежит в mmap-куче Nim мимо санитайзера), с ним — падает с
# heap-buffer-overflow. Задача ждёт НЕНУЛЕВОЙ код возврата: зелёный зонд
# означает, что ASan перестал видеть shared-выделения, и джоба asan даёт
# ложную уверенность.
# ---------------------------------------------------------------------------
task asanProbe, "ASan-зонд переполнения allocShared0 ловится с -d:useMalloc (#364)":
  mkDir buildDir
  buildLog "asan allocShared overshoot probe"
  exec "ASAN_OPTIONS=detect_leaks=0 nim c --hints:off --nimcache:build/nc_asan_probe -d:useMalloc " &
    "--passC:-fsanitize=address --passC:-fno-omit-frame-pointer " &
    "--passL:-fsanitize=address --out:build/asan_probe tests/asan_probe_allocshared.nim"
  buildLog "прогон зонда (ожидается падение ASan)"
  # gorgeEx в NimScript возвращает (вывод, код) вместо `exec`, который
  # падает на ненулевом коде: зонд ОБЯЗАН упасть, это и есть критерий.
  when defined(windows):
    # ASan-джоб CI — только Linux; на Windows зонд просто собирается.
    echo "skip: зонд-ассерт выполняется в Linux-джобе asan (#364)"
  else:
    let (probeOut, probeCode) = gorgeEx(
      "bash -c 'ASAN_OPTIONS=detect_leaks=0 build/asan_probe 2>&1'")
    echo probeOut
    if probeCode == 0:
      raise newException(ValueError,
        "ASan не поймал переполнение allocShared0: -d:useMalloc не действует (#364)")
    echo "ok: ASan поймал переполнение allocShared0 (код " & $probeCode & ")"

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

# ---------------------------------------------------------------------------
# Встраивание ядра (#213). Ядро без GUI проверяется не словами, а двумя
# разными хостами:
#   * `embedExample` — Nim-хост (examples/embed_render.nim): граф из нод,
#     блоки в «своём» audio-callback, офлайн-рендер в WAV;
#   * `embedLib` — C-ABI-фасад (examples/embed_lib.nim) собирается в
#     РАЗДЕЛЯЕМУЮ библиотеку и грузится из Python через ctypes. Это и есть
#     проверка границы: если фасад потянет GUI, рантайм или лишние символы
#     Nim, загрузка из чужого процесса перестанет работать.
#
# Отдельные цели, а не часть `nimble test`: `--app:lib` и внешний
# интерпретатор в unit-набор не входят (та же причина, что у `clapMock`).
# Джоб CI — `embed`, только Linux (ABI разделяемых библиотек).
# ---------------------------------------------------------------------------
task embedExample, "Пример встраивания: Nim-хост собирается и прогоняется (#213)":
  mkDir buildDir
  buildLog "embed example (nim host)"
  exec "nim c -r --hints:off --out:build/embed_example examples/embed_render.nim"

task embedLib, "C-ABI ядра: shared-библиотека + загрузка из Python ctypes (#213)":
  mkDir buildDir
  buildLog "embed lib (c abi, shared library)"
  let embedLibPath =
    when defined(windows): "build/euterpia_embed.dll"
    elif defined(macosx): "build/libeuterpia_embed.dylib"
    else: "build/libeuterpia_embed.so"
  exec "nim c --app:lib -d:release --hints:off " &
    "--nimcache:build/nc_embedlib --out:" & embedLibPath &
    " examples/embed_lib.nim"
  when defined(windows):
    # Загрузка ctypes — шаг Linux-джоба `embed`: на Windows упаковка
    # символьной таблицы своя (`__declspec(dllexport)` против `-rdynamic`).
    echo "skip: загрузка ctypes выполняется в Linux-джобе embed (#213)"
  else:
    buildLog "host ctypes (python)"
    exec "python3 examples/host_ctypes.py " & embedLibPath

# ---------------------------------------------------------------------------
# «Композиция как код» (#285): пьеса собирается библиотекой libs/compose,
# рендерится и проверяется командами CLI. Демонстрирует, что прикладной
# слой (libs) строится поверх публичных API Core/Nodes, а не лезет внутрь.
# ---------------------------------------------------------------------------
task compose, "Собрать пьесу библиотекой libs/compose и проверить (#285, #295)":
  mkDir buildDir
  buildLog "cli build"
  exec "nim c --hints:off --out:" & cliBin & " cli.nim"
  buildLog "compose: dark-fantasy (libs/compose)"
  exec "./compositions/dark-fantasy/build.sh " & cliBin

