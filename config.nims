# config.nims — общие параметры сборки EUTERPIA.
#
# Применяется ко всем точкам входа: unit/integration/realtime тестам,
# утилитам, будущим CLI и Editor.
#
# Здесь только то, что обязано быть одинаковым ВЕЗДЕ.
# Политика флагов (зачем каждый флаг) описана в MANIFEST.md, раздел 7.

# ----------------------------------------------------------------------------
# Модульные пути
#
# Зависимости строго однонаправленные (MANIFEST §27, §93):
#   Core <- Nodes <- CLI/Editor
#   Commons не знает ни про Core, ни про Nodes, ни про Editor.
#
# Ни один модуль Core не должен делать import из nodes/commons.
# ----------------------------------------------------------------------------
switch("path", "core")
switch("path", "commons")
switch("path", "nodes")
switch("path", "libs")
switch("path", "adapters")
switch("path", "adapters/portaudio")
switch("path", "adapters/rtmidi")
switch("path", "adapters/clap")
switch("path", "adapters/eut")
switch("path", "adapters/reference")
switch("path", "adapters/miniaudio")
switch("path", "tests")

# Корень пакета (issue #88).
#
# В корне лежит `euterpia_version.nim` — единый источник версии, который
# импортируют И nimble-скрипт пакета, И CLI (`cli/*`). Вложенные модули
# корень пакета сами не видят (Nim ищет импорт относительно каталога
# импортирующего файла), поэтому путь задаётся явно.
switch("path", ".")

# ----------------------------------------------------------------------------
# Потоки
#
# audio_recorder (writer thread) требует настоящих потоков. В Nim >= 2.0
# threads уже включён по умолчанию, но полагаться на дефолт в проекте
# с realtime-кодом нельзя.
#
# ВАЖНО: проверять потоки нужно через compileOption("threads"),
# а НЕ через defined(threads). В Nim 2.2 при --threads:on условный
# символ threads НЕ определён (проверено: defined(threads)=false,
# compileOption("threads")=true), поэтому `when defined(threads)`
# молча выключает весь threaded-код — без ошибок компиляции.
# Thread, createThread и joinThread при этом доступны всегда.
# ----------------------------------------------------------------------------
switch("threads", "on")

# ----------------------------------------------------------------------------
# Менеджер памяти
#
# orc/arc: в Audio Engine и графе живут объекты без GC-циклов,
# а realtime-путь не должен зависеть от GC вообще.
# ----------------------------------------------------------------------------
switch("mm", "orc")

# ----------------------------------------------------------------------------
# Флаги C
#
# ВАЖНО: -ffast-math НЕ используется никогда.
#   Он разрешает компилятору считать, что NaN/Inf невозможны, а значит
#   режет защитные проверки в DSP, по-разному обрабатывает знаки нулей
#   и делает результат зависимым от порядка векторизации.
#   Для ядра DAW детерминизм важнее скорости.
#
# -fno-strict-aliasing НЕ используется (issue #400). Аудиоарены — это
# `ptr UncheckedArray[float32]`, и доступ к ним идёт по объектам одного типа;
# межтиповые передачи выполняются через `copyMem`/явные buffer views, а не
# через type-punning. Отключение strict-aliasing маскировало бы UB, а не
# исправляло его; сборка без флага проходит unit/integration/CLI и ASan.
# ----------------------------------------------------------------------------
switch("passC", "-fno-math-errno")

# miniaudio (adapters/miniaudio, issue #31): путь к вендоренному заголовку.
# Нужен, когда TU шима компилируется не из своего каталога.
switch("passC", "-Iadapters/miniaudio")

when defined(release) or defined(danger):
  switch("passC", "-O3")
  switch("passC", "-DNDEBUG")
else:
  # В debug-сборке C компилируется быстрее, а проверки инвариантов всё равно
  # идут через doAssert на стороне Nim.
  switch("passC", "-O1")

# ----------------------------------------------------------------------------
# Realtime-guard (issue #11, MANIFEST §45)
#
# `rtGuardEnabled` включает core/rt_guard: thread-local пометку audio-потока
# и проверки запрещённых операций. В release НЕ включается: `rtAssert*`
# и `inRealtimeContext` компилируются в константу, overhead = 0.
#
# ВНИМАНИЕ: release-сборка НЕ включает guard намеренно. Проверки должны
# быть бесплатными в горячем пути, а не «дешёвыми».
# ----------------------------------------------------------------------------
when not defined(release) and not defined(danger):
  switch("define", "rtGuardEnabled")


