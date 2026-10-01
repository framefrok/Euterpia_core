# EUTERPIA — Архитектурный манифест

**Версия 2.0**

Единый источник архитектурных правил. Всё, что не описано здесь, решается по духу
документа: маленькое ядро, ясные границы, заменяемые компоненты.

Главное в версии 2.0: **ядро модернизируемое и заменяемое**. Открытые библиотеки
на C и Nim разрешены — но только за стабильными контрактами и только после
проверки качества, скорости и работоспособности (§11).

---

## 1. Назначение

EUTERPIA — ядро цифровой звуковой рабочей станции (DAW) и среда исполнения
аудио-графов в реальном времени.

Три идеи проекта:

1. **Ядро маленькое.** Малый объём легче защищать и переписывать.
2. **Границы важнее реализации.** Ценность — стабильные контракты, а не конкретный
   UI, плагинный формат или отдельный DSP-алгоритм.
3. **Всё заменяемо.** Ядро, backend, плагины, GUI — каждый компонент заменяем без
   переписывания остальных.

> Не большое, а хорошо разделённое.

---

## 2. Главный принцип

Система — набор независимых компонентов, а не монолит.

Каждая часть должна уметь:

- быть переписана;
- быть заменена;
- быть отключена;
- тестироваться отдельно;
- работать без GUI;
- работать без CLI;
- работать без конкретного набора нод.

Если компонент нельзя заменить или протестировать отдельно — это архитектурная
ошибка, а не «технический долг».

---

## 3. Слои

```text
Commons    нейтральные утилиты; никого не знают
Core       ядро (Nim stdlib + свой код) + контракты core/api
adapters/  реализации контрактов поверх внешних библиотек
Nodes      реализации возможностей поверх Core
CLI        управление (control)
Editor     визуализация (control)
```

```text
                 CLI        Editor
                   \         /
                    \       /
                     Nodes
                       |
                     Core
                       |
                    Commons
```

`adapters/` стоит сбоку и знает только контракты:

```text
Core ── core/api/<X>_api ──► adapters/<lib> ──► внешняя библиотека
```

---

## 4. Dependency Law

Зависимости направлены строго вниз.

```text
Commons  → никого не знает
Core     → Commons не обязателен
adapters → core/api + Commons
Nodes    → Core (+ Commons)
CLI      → Core + Nodes + Commons
Editor   → Core + Nodes + Commons
```

Запрещено:

```text
Core     → Nodes / CLI / Editor / adapters
Nodes    → CLI / Editor
CLI      → Editor
Editor   → CLI
Commons  → Core / Nodes / CLI / Editor
adapters → внутренности ядра (только core/api)
adapters → adapters
```

Правило проверяется автоматически (§29).

---

## 5. Core: назначение

Core — фундамент. Он меняется только при доказанной необходимости.

Если задачу можно решить в Node, CLI, Editor или adapters — Core не меняется.

Core не знает, кто им управляет:

```text
не знает:  Editor, CLI, Qt, SDL, OpenGL, GUI, конкретный плагин, конкретный backend
работает:  из CLI, Editor, теста, headless-сервера, другого приложения
```

---

## 6. Core: что входит

Ядро (`core/`, без сторонних библиотек):

```text
runtime (audio engine)
graph + graph compiler
realtime scheduler
transport
события (events)
параметры (parameters)
память (memory pool)
шины (realtime bus)
audio buffers
```

Контракты внешних миров — отдельно, в `core/api/` (§8).

DSP-алгоритмы по умолчанию **не** в ядре: это Nodes.

---
## 7. Core: что запрещено

```text
echo / printf для обычной работы
GUI
filesystem access в render path
JSON parsing в realtime
аллокации в render path
seq mutation в render path
строки в realtime API
исключения в realtime
locks / mutex в realtime
spawn во время render
загрузка DLL / файлов во время render
```

И запрещено:

```text
Core → конкретная внешняя библиотека
Core → adapters
зависимость Core от Editor / CLI / Nodes
```

Единственный обмен с внешним миром — через контракт `core/api/` (§8).

---

## 8. Контракты core/api

Контракт — тонкое описание внешней возможности. Только типы, таблица методов и
nil-safe обёртки. Никакой реализации.

Форма контракта:

```text
объект-таблица методов   (поля-proc, опциональные)
имя контракта            (cstring)
указатель impl           (принадлежит адаптеру; ядро его не читает)
nil-safe обёртки         (ядро вызывает только их)
POD-типы                 (без seq/string/ref в realtime-полях)
{.push raises: [].}      (ошибки — кодом/значением)
```

Контракты (открытый список):

```text
core/api/audio_backend_api   аудио-ввод/вывод
core/api/midi_api            MIDI
core/api/plugin_api          хостинг плагинов
core/api/codec_api           кодеки аудиофайлов
core/api/src_api             ресемплинг
core/api/stretch_api         time-stretch / pitch-shift
core/api/fft_api             FFT
```

Свойства:

- контракт стабилен и версионируется отдельно от реализации;
- контракт опционален: ядро собирается и без него (§11);
- ошибки — кодом/значением, а не исключением.

Контракт-образец: `core/api/audio_backend_api.nim`.

---

## 9. Адаптеры

Адаптер реализует ровно один контракт `core/api/`.

```text
1. одному контракту может соответствовать несколько адаптеров;
2. адаптер не расширяет контракт «сбоку»;
3. адаптер не импортирует внутренности ядра и другие адаптеры;
4. адаптер опционален: без библиотеки ядро всё равно собирается;
5. адаптер регистрируется на control-path (§31);
6. ошибки — кодом/значением.
```

Размещение (одна библиотека — один каталог):

```text
adapters/portaudio     adapters/miniaudio   adapters/jack
adapters/rtmidi        adapters/libremidi
adapters/clap          adapters/lilv        adapters/vst3   adapters/eut
adapters/dr_libs       adapters/libsndfile
adapters/libsamplerate adapters/speexdsp
adapters/rubberband    adapters/soundtouch
adapters/pocketfft     adapters/kissfft
```

Замена библиотеки — без изменения ядра и без изменения типов, которыми пользуется
ядро.

---

## 10. Внешние библиотеки (C и Nim)

Открытые библиотеки на C и Nim **разрешены и приветствуются**. Мы не изобретаем
заново то, что уже хорошо сделано.

Правила:

```text
1. библиотека живёт только в adapters/<lib>/, один каталог на библиотеку;
2. в ядре Core её имени быть не должно (нет dynlib / importc / #include);
3. ядро работает с ней только через контракт core/api/;
4. версия библиотеки фиксируется (pinned);
5. лицензия совместима — либо изоляция явно оговорена.
```

Библиотеку допустимо брать, если она:

```text
- решает сложную системную задачу;
- стабильна и имеет известный ABI;
- изолируется одним адаптером;
- удаляется без переписывания половины Core.
```

---

## 11. Проверка внешних библиотек (обязательно)

Оговорка, без которой ничего не добавляется.

Новая библиотека или изменение допускаются **только после проверки**:

```text
КАЧЕСТВО         корректность результата, тесты, отсутствие регрессий
СКОРОСТЬ         бенчмарк до/после: CPU, память, latency
РАБОТОСПОСОБНОСТЬ собирается, запускается, не падает, не течёт
```

Порядок:

```text
1. замер baseline;
2. прототип за контрактом (в adapters/, опционально);
3. тесты (unit + contract) и бенчмарки;
4. сравнение с baseline: не хуже по скорости и по качеству;
5. решение: принять / отклонить.
```

> Нет проверки — нет изменения.

Анти-правило:

```text
❌ «потянем библиотеку, потом разберёмся»
❌ линковка внешней библиотеки в дефолтную сборку ядра
❌ падение на старте, если библиотека не найдена
```

---
## 12. Realtime — неприкосновенная зона

Audio thread — особый мир. В realtime запрещено:

```text
malloc / allocShared / newSeq / seq.add
Table / HashSet / JSON / FileStream
echo / locks / sleep / spawn
GC-sensitive операции
загрузка DLL / файлов
операция с неизвестной стоимостью
```

Realtime обязан быть:

```text
allocation-free
lock-free
exception-free
deterministic
```

Правило:

> Если стоимость операции неизвестна — она не выполняется в realtime path.

---

## 13. Control и Realtime

Два разных мира:

```text
CONTROL:   Editor, CLI, Project, File I/O, загрузка плагинов,
           редактирование графа, компиляция, undo/redo, waveform

REALTIME:  audio callback, DSP, transport clock, events,
           parameters, pipeline, meters, audio output
```

Они не смешиваются. Связь — только lock-free:

```text
Control ──lock-free commands──► Realtime
Control ◄──lock-free events────  Realtime
```

Всё дорогое (аллокации, файлы, плагины, компиляция) — только в control world.

---

## 14. Потоки и владение

```text
1. один ресурс — один владелец;
2. жизненный цикл ресурса явен (init → use → destroy);
3. поток-владелец фиксирован;
4. нет скрытого глобального мутабельного состояния;
5. «thread-safe» не равно «realtime-safe».
```

Потоки проекта:

```text
control / main  — редактирование, компиляция, загрузка, диалоги
audio           — render callback; максимальный приоритет
workers         — фоновые задачи (I/O, waveform, offline render)
```

Обмен между потоками — через lock-free очереди и предвыделенную память.

---

## 15. Ошибки и логирование

Ошибки в ядре — кодом или значением, а не исключением (особенно в realtime).

```text
realtime  → никогда не бросает исключений
audio API → возвращает код ошибки / enum
control   → может использовать исключения на границе с ОС и файлами
```

Логирование:

```text
echo/printf в Core запрещён;
используется Logger (абстракция);
адаптеры логируют через тот же Logger;
логирование никогда не выполняется в realtime.
```

---

## 16. Память

```text
реaltime      → только предвыделенные буферы и пулы; ноль аллокаций
control       → допустимы обычные аллокации и Nim-seq
```

Механизмы ядра:

```text
memory pool       — фиксированные блоки, O(1) acquire/release
handles           — вместо сырых указателей там, где нужен lifetime
preallocation     — размеры известны заранее
stable addresses  — блоки не перемещаются
```

`seq` нельзя использовать как постоянное хранилище указателей: перевыделение
инвалидирует адреса.

---

## 17. Граф и компиляция

Граф создаётся и правится на control-path. Ядро получает immutable snapshot.

```text
Graph → Validation → Compilation → CompiledPipeline → Atomic Swap → Audio Thread
```

Realtime знает только `CompiledPipeline`. Он не знает про `Table`, `seq[Node]`,
`EditorConnection`.

Если граф меняется — пересобирается pipeline и атомарно подменяется; render не
выполняет анализ графа.

---
## 18. CompiledPipeline

После компиляции pipeline самодостаточен:

```text
execution order
buffer assignments
event routing
control routing
dependencies
latency compensation
node state
worker schedule
```

Во время render ничего из этого не вычисляется. Pipeline — священный объект: он
не мутирует в realtime, только читается.

---

## 19. Параметры и события

Параметры:

```text
сглаживание (smoothing) в сэмплах, а не «по блокам»;
значение не зависит от blockSize;
изменения приходят командами из control world.
```

События (notes, MIDI, transport) — POD-структуры в lock-free очередях:

```text
нулевая аллокация в realtime;
сортировка по времени в блоке;
фиксированный максимум на блок.
```

---

## 20. Nodes

Nodes — реализации возможностей поверх Core. Не часть Core.

```text
nodes/sdk/          контракты нод (стабильнее самих нод)
nodes/builtin/      генераторы, фильтры, динамика, эффекты, микширование
nodes/extensions/   eut/, clap/ (и другие plugin-форматы)
```

Node не знает про Editor. Node не хранит Editor state. DSP state отделён от
дескриптора ноды.

---

## 21. Node SDK

`nodes/sdk/` содержит:

```text
Node API
Descriptor API
Parameter API
Event API
DSP helpers
```

Node API версионируется и стабильнее реализаций нод. Внутри нод допустимы
большие изменения; контракт нод — нет.

---

## 22. Аудио backend и ресемплинг

Backend — внешний мир за контрактом `core/api/audio_backend_api`:

```text
открытие устройства, start/stop, device enum,
xrun-диагностика, latency
```

Если частота устройства не совпадает с частотой проекта:

```text
SRC включается за контрактом src_api (адаптер);
latency SRC учитывается в компенсации задержек (PDC);
SRC работает на предвыделенных буферах.
```

Замена backend (PortAudio → miniaudio → JACK → PipeWire) не требует правок ядра.

---

## 23. CLI и Editor

CLI и Editor — равноправные клиенты Core. Первым классом идёт headless-режим:
всё, что делает Editor, должно иметь CLI-путь.

CLI:

- не содержит бизнес-логику Core;
- пригоден для автоматизации и AI (machine-readable output).

Editor:

- тонкий; не второй Core;
- работает только через публичный API Core;
- не копирует логику CLI и наоборот.

GUI-библиотеки (Dear ImGui, Blend2D, NanoVG, Raylib) живут в `editor/`, а не в
Core и не в `adapters/`.

---

## 24. Commons

Commons — самый скучный слой: нейтральные утилиты.

```text
math helpers, result/error types, strings, paths,
маленькие контейнеры, id-генераторы, логирование
```

Commons никого не знает. Если модуль можно назвать конкретно — это не Commons.

---
## 25. Проект и состояние

Два вида данных:

```text
Project data   — сохраняется: граф, ноды, параметры, секвенции, настройки
Runtime data   — только в рантайме: pipeline, буферы, метрики, временные кэши
```

Правила:

```text
Project не зависит от Editor;
Project не хранит runtime state;
runtime state не сериализуется;
формат проекта версионируется (§27).
```

---

## 26. Undo/Redo

Undo/Redo — часть control layer, а не ядра.

```text
реализуется командами (command model);
не снимает снимки runtime;
живёт на control-path;
не трогает audio thread напрямую.
```

---

## 27. Версионирование

Не смешиваются:

```text
Project format version
Core API version
Core runtime version
Node API version
Plugin ABI version
Adapter contract version
Adapter implementation version
CLI version
```

Например:

```text
Project format: 3
Node API: 2
Core runtime: 5
Adapter contract: 1
Adapter impl: 4
```

Старый проект не должен ломаться без причины: нужен migration layer
(`v1 → v2 → v3`).

---

## 28. Quality gates: тесты

```text
unit        — модули
contract    — fake-адаптеры, без внешних библиотек
integration — сборка графа и render
realtime    — lock-free, отсутствие аллокаций, xruns
```

Правила:

```text
тесты контракта не требуют внешних библиотек;
изменения Core сопровождаются тестами;
архитектурные правила проверяются в CI (§29);
регресс тестов — блокер.
```

---

## 29. Quality gates: архитектура и CI

Автопроверки в CI:

```text
Core импортирует Editor / CLI / Nodes / adapters  → FAIL
adapters импортируют внутренности Core            → FAIL
adapters импортируют adapters                      → FAIL
Commons импортирует Core / Nodes / CLI / Editor    → FAIL
имя внешней библиотеки встречается в ядре Core     → FAIL
```

Пример проверки изоляции:

```bash
grep -rniE "portaudio|miniaudio|rtmidi|libremidi|lilv|vst3|sndfile|rubberband|soundtouch|samplerate|speexdsp|pocketfft|kiss" core/ \
  | grep -v "core/api/" && exit 1 || true
```

Сборка в CI:

```text
ядро без адаптеров        → обязано быть зелёным
ядро с fake-адаптерами    → обязано быть зелёным
адаптеры (если есть lib)  → nim check + live-тесты
```

---

## 30. Quality gates: скорость и работоспособность

```text
1. бенчмарк до/после обязателен для hot-path;
2. регресс по CPU / memory / latency — блокер;
3. -ffast-math запрещён (детерминизм важнее скорости);
4. sanitizers (ASan / UBSan / TSan) для realtime-кода;
5. profiling before optimization;
6. offline render использует тот же DSP, что realtime, и детерминирован.
```

Ни одна оптимизация или библиотека не принимается без измерений.

---

## 31. Реестр адаптеров

Реестр — control-path объект с явным владельцем (не глобальный синглтон).

```text
register(contract, name, factory)
list(contract)   → [name …]
select(contract, name)
current(contract)→ name
```

Правила:

```text
регистрация — вне realtime;
выбор: явное имя → приоритет платформы → первый доступный;
смена адаптера: stop → close → open (без XRun);
из audio-потока реестр не читается.
```

Клиенты (CLI/Editor) оперируют **именем** адаптера, а не его типом.

---
## 32. Изменяемость

Каждый subsystem проектируется так, будто завтра его перепишут.

```text
WaveformCache v1 → v2       без изменения Editor API
PortAudioBackend → PipeWireBackend
GraphCompiler v1 → v2
```

Новые возможности появляются в Nodes / CLI / Editor / adapters, а не через
разрушение фундаментальных структур ядра.

---

## 33. Когда можно менять Core

```text
1. проблему нельзя решить выше Core;
2. текущий API архитектурно ограничивает будущее;
3. изменение улучшает фундамент, а не конкретную фичу;
4. есть тесты;
5. влияние на ABI/API задокументировано;
6. рассмотрена compatibility layer.
```

Любое изменение Core имеет высокую цену принятия и проходит ревью отдельно.

---

## 34. Что запрещено категорически

```text
❌ GUI-зависимость в Core
❌ Editor / CLI / Nodes зависимость в Core
❌ сторонняя библиотека в ядре Core
❌ импорт adapters из ядра Core
❌ import одного адаптера другим
❌ обязательная зависимость ядра от внешней библиотеки
❌ File I/O / allocation / locks / exceptions в realtime
❌ graph analysis во время render
❌ seq pointer без lifetime guarantee
❌ глобальное состояние без крайней необходимости
❌ циклические зависимости
❌ giant utils / giant manager
❌ копирование логики между CLI и Editor
❌ сериализация runtime state
❌ Node-specific знание в Core
```

---

## 35. Что поощряется

```text
✓ маленькие модули и API
✓ явное владение и жизненный цикл
✓ стабильные контракты
✓ immutable snapshots
✓ handles вместо сырых указателей
✓ детерминированная обработка
✓ предвыделение памяти
✓ lock-free обмен
✓ contract-тесты
✓ бенчмарки и профилирование
✓ background workers
✓ adapters и dependency inversion
✓ headless-работа
✓ machine-readable вывод CLI
```

---

## 36. Чек-лист перед любым изменением

```text
1. К какому слою относится?
2. Кто владеет состоянием?
3. В каком потоке работает?
4. Можно ли это протестировать отдельно?
5. Можно ли это заменить?
6. Увеличивает ли это связанность?
7. Есть ли контракт (для внешнего мира)?
8. Есть ли тесты и бенчмарк?
9. Не нарушен ли realtime?
```

Если связанность растёт — сначала ищем архитектурное решение, а не тащим
зависимость.

---
## 37. C и Nim: правила интеграции

Ядро пишется на Nim. C-компоненты подключаются только через адаптеры.

```text
биндинги к C — через futhark / c2nim или ручные {.importc.};
определения C-типов — только в адаптере;
ABI-точные структуры — {.bycopy.};
callback'и — {.cdecl, raises: [].};
никакого C-кода в ядре;
никаких C++ типов в публичном ABI (для C++ — тонкий C-фасад).
```

Смешение C и Nim допускается и поощряется там, где Nim неудобен (SIMD, low-level),
но граница всегда проходит по контракту.

---

## 38. Плагинные форматы

Хостинг плагинов — внешний мир за контрактом `core/api/plugin_api`.

```text
adapters/clap    CLAP (C-first, основной)
adapters/lilv    LV2 (C, через Lilv)
adapters/vst3    VST3 (C++ → тонкий C-bridge)
adapters/eut     собственный формат EUT
```

Правила:

```text
граф не знает о формате плагина;
конвертация событий — внутри адаптера;
состояние плагина сохраняется в проект;
форматы опциональны (§11);
проблемная лицензия — только опциональный адаптер.
```

---

## 39. Transport и Sequencer

Transport:

```text
play / stop / pause / seek / tempo / loop;
sample-accurate;
состояние доступно realtime через POD-структуру.
```

Sequencer:

```text
работает на control-path;
готовит события на блок заранее;
не выполняет I/O в realtime.
```

---

## 40. Метрики и наблюдаемость

Ядро отдаёт метрики на control-path (lock-free):

```text
peak / RMS по каналам
CPU load
xruns
sample rate / buffer size
transport state
active voices
graph version
```

Метрики не влияют на render и не аллоцируются в realtime. CLI и Editor читают их
через публичный API.

---

## 41. Offline render

```text
использует тот же CompiledPipeline и тот же DSP, что realtime;
детерминирован (одинаковый вход → одинаковый выход);
не ограничен realtime-запретами, но результат совпадает с realtime;
live и offline не должны расходиться.
```

---

## 42. Документация как архитектура

Каждый крупный модуль описывает себя кратко:

```text
Purpose
Owns
Depends on
Thread
Realtime-safe?
Public API
Lifecycle
```

Пример:

```text
audio_engine
  Purpose:      realtime execution
  Owns:         sample clock, active pipeline
  Depends on:   Core graph/runtime
  Thread:       audio
  Realtime:     yes
```

Архитектурные правила из §29 проверяются в CI, а не только описаны в README.

---

## 43. Итоговая архитектура

```text
                     USER
                 /          \
              CLI            Editor
                 \          /
                  Control API
                       |
              Core (ядро + core/api)
                       |
                    Node API
                 /            \
          Builtin Nodes     External Nodes
          (DSP/Synth/FX)    (EUT / CLAP / LV2 / VST3)
                       |
              core/api контракты
                       |
                    adapters/
                       |
          audio/midi devices, files, DSP libs
```

Commons — сбоку и нейтрален.

---

## 44. Итог

EUTERPIA должна быть не большой, а хорошо разделённой.

Маленькое ядро. Ясные контракты. Заменяемые адаптеры.

Открытые библиотеки на C и Nim — да, но за контрактом `core/api/` и после
проверки качества, скорости и работоспособности.

---
