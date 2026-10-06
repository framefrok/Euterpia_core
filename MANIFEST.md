# EUTERPIA

## Архитектурный манифест и правила разработки

**Версия архитектуры: 1.0**

---

# 1. Главный принцип EUTERPIA

> **EUTERPIA должна оставаться системой независимых компонентов, а не единым приложением с десятками связанных модулей.**

Любая часть проекта должна иметь возможность быть:

* переписана;
* заменена;
* отключена;
* перенесена;
* протестирована отдельно;
* использована без GUI;
* использована без CLI;
* использована без конкретного набора Nodes.

Главная ценность проекта — **не конкретный UI, не конкретный plugin API и даже не конкретная реализация DSP**.

Главная ценность — стабильные контракты между частями системы.

---

# 2. Четыре основополагающих направления

EUTERPIA состоит из четырёх основных направлений:

```text
EUTERPIA
│
├── Core
├── CLI
├── Commons
└── Editor
```

Но существует ещё один особый слой:

```text
Nodes
```

Nodes не являются частью Core и не должны превращаться в его содержимое.

Они являются **реализациями возможностей EUTERPIA**, построенными поверх Core.

Поэтому итоговая архитектура:

```text
                   ┌─────────────┐
                   │    Editor   │
                   └──────┬──────┘
                          │
                   ┌──────▼──────┐
                   │     CLI     │
                   └──────┬──────┘
                          │
             ┌────────────▼────────────┐
             │          Nodes          │
             └────────────┬────────────┘
                          │
                    ┌─────▼─────┐
                    │   Core    │
                    └─────┬─────┘
                          │
                    ┌─────▼─────┐
                    │  stdlib   │
                    └───────────┘

Commons
   ↑
используется верхними слоями,
но не знает о них.
```

При этом зависимости должны быть строго однонаправленными.

---

# 3. Core

## Core — фундамент EUTERPIA

Core — самая важная часть проекта.

Core должен изменяться **только при доказанной необходимости**.

Это не означает, что Core нельзя улучшать.

Это означает:

> **Любое изменение Core должно иметь очень высокую цену принятия.**

Если проблему можно решить в Node, CLI, Editor или Commons — Core менять запрещается.

---

## Core отвечает только за фундамент

Core должен содержать:

```text
audio runtime
graph
graph compiler
realtime scheduler
transport
events
parameters
memory management
plugin ABI
node ABI
audio buffers
clock
realtime communication
```

Core НЕ должен содержать:

```text
GUI
консоль UI
меню
проектный редактор
визуальные элементы
названия кнопок
панели
горячие клавиши Editor
формат layout Editor
специфический UI state
```

---

# 4. Священное правило Core

> **Core не должен знать, кто им управляет.**

Core не знает:

```text
Editor
CLI
Qt
SDL
OpenGL
Vulkan
Wayland
Windows GUI
```

Core должен одинаково работать:

```text
из CLI
из Editor
из теста
из другого приложения
из headless-сервера
из AI-generated workflow
```

---

# 5. Core должен быть максимально маленьким

В Core должно попадать только то, без чего невозможно существование audio engine.

Например:

```text
core/
├── signal_types
├── node_api
├── event_system
├── parameter_system
├── graph
├── graph_compiler
├── pipeline
├── scheduler
├── transport
├── realtime_bus
├── memory
├── audio_engine
├── plugin_api
└── runtime
```

DSP algorithms не должны автоматически считаться Core.

---

# 6. Что запрещено в Core

Запрещается:

```text
echo
printf для обычной работы
GUI
filesystem access в render path
JSON parsing в realtime
dynamic allocation в render path
seq mutation в render path
строки в realtime API
exception handling в realtime
threadpool spawn во время render
lock/mutex в realtime
загрузка DLL во время render
загрузка файлов во время render
```

Также запрещается:

```text
Node → Editor
Core → Editor
Core → CLI
Core → Project UI
Core → конкретный plugin
```

---

# 7. Core и сторонние зависимости

Главное правило:

> **Core должен максимально зависеть от стандартной библиотеки Nim и собственного кода.**

Предпочтение:

```text
Nim stdlib
+
EUTERPIA Core
```

а не:

```text
Nim
+
10 framework
+
7 helper libraries
+
GUI
+
audio abstraction
+
plugin abstraction
+
serialization framework
+
...
```

Сторонняя библиотека допускается в Core только если одновременно выполняется одно из условий:

1. её невозможно разумно заменить небольшим собственным слоем;
2. она решает сложную системную задачу;
3. она стабильна;
4. её ABI хорошо известен;
5. зависимость можно изолировать отдельным модулем;
6. удаление библиотеки не требует переписывать половину Core.

---

# 8. Внешние библиотеки изолируются

Нельзя писать:

```text
Core
 ├── PortAudio
 ├── RtMidi
 ├── CLAP
 └── какая-нибудь GUI library
```

Напрямую во всех модулях.

Должно быть:

```text
Core
 │
 ├── audio_backend_api
 │
 ├── midi_api
 │
 └── plugin_api
 │
        ↓
adapters/
 ├── portaudio
 ├── rtmidi
 └── clap
```

Таким образом PortAudio можно заменить на:

```text
JACK
ALSA
WASAPI
CoreAudio
PipeWire
SDL
собственный backend
```

не переписывая AudioEngine.

---

# 9. Realtime — неприкосновенная зона

Audio thread — особый мир.

В realtime processing запрещено:

```text
malloc
allocShared
newSeq
seq.add
Table
HashSet
JSON
FileStream
echo
locks
sleep
spawn
GC-sensitive operations
DLL loading
```

и вообще всё, что может дать непредсказуемую задержку.

Правило:

> **Если операция потенциально имеет неизвестную стоимость — она не выполняется в realtime path.**

---

# 10. Разделение control time и audio time

EUTERPIA должна иметь два совершенно разных мира:

```text
CONTROL WORLD
────────────────────────────
Editor
CLI
Project
File I/O
Plugin loading
Graph editing
Compilation
Undo/Redo
Waveform generation
Asset management


REALTIME WORLD
────────────────────────────
Audio callback
DSP
Transport clock
Events
Parameters
Pipeline
Meters
Audio output
```

Они не должны смешиваться.

Связь:

```text
Control
   │
   │ lock-free commands
   ▼
Realtime
   │
   │ lock-free events/metrics
   ▼
Control
```

---

# 11. Graph не должен существовать в realtime

Editor изменяет:

```text
Graph
```

Core получает immutable snapshot.

Затем:

```text
Graph
 ↓
Validation
 ↓
Compilation
 ↓
CompiledPipeline
```

Audio thread работает только:

```text
CompiledPipeline
```

Он не знает о:

```text
Table
seq[EditorNode]
EditorConnection
```

---

# 12. CompiledPipeline — священный объект

После compilation pipeline должен содержать всё необходимое для работы:

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

Во время render ничего из этого не вычисляется.

Идеальная схема:

```text
Editor Graph
     ↓
Compiler
     ↓
CompiledPipeline
     ↓
Atomic Swap
     ↓
Audio Thread
```

---

# 13. Nodes

## Nodes — отдельный слой

Nodes **не должны находиться внутри Core**.

Это принципиально важно.

Core должен знать только:

```text
что такое Node;
как Node запускается;
какие у Node есть ports;
как Node сообщает latency;
как Node получает parameters;
как Node получает events.
```

Но Core не должен знать:

```text
что такое CompressorNode
что такое ReverbNode
что такое SynthNode
что такое EQNode
```

---

# 14. Где должны храниться Nodes

Рекомендуемая структура:

```text
EUTERPIA/
│
├── core/
│
├── nodes/
│   │
│   ├── builtin/
│   │   ├── generators/
│   │   ├── effects/
│   │   ├── dynamics/
│   │   ├── filters/
│   │   ├── utilities/
│   │   ├── routing/
│   │   └── instruments/
│   │
│   ├── extensions/
│   │   ├── eut/
│   │   └── clap/
│   │
│   └── sdk/
│
├── cli/
├── commons/
├── editor/
│
├── tests/
└── docs/
```

Это наиболее важное архитектурное решение.

---

# 15. Почему Nodes не являются Commons

Commons нельзя превращать в:

```text
"всё, что не знаем куда положить"
```

Нельзя:

```text
Commons/
 ├── Synth
 ├── Reverb
 ├── EQ
 ├── FileManager
 ├── EditorStuff
 └── ...
```

Это создаст второй Core, только ещё хуже.

Commons должен содержать **общие нейтральные инструменты**, а Nodes — реальные возможности audio engine.

---

# 16. Builtin Nodes

Builtin nodes являются официальными Node implementations EUTERPIA.

Например:

```text
nodes/builtin/
├── oscillator
├── sampler
├── gain
├── pan
├── mixer
├── filter
├── eq
├── compressor
├── limiter
├── reverb
├── delay
├── analyzer
├── midi
└── utility
```

Они:

```text
зависят от Core
могут зависеть от Commons
не зависят от Editor
не зависят от CLI
```

---

# 17. Node никогда не должен знать об Editor

Node не должен содержать:

```text
draw()
drawNode()
uiColor
editorPosition
windowSize
imguiState
editorNamePosition
```

У Node могут быть описания параметров:

```text
name
defaultValue
min
max
unit
flags
```

Но визуальное представление принадлежит Editor.

---

# 18. Один Node — два представления

Например:

```text
Compressor
```

Core-level descriptor:

```text
threshold
ratio
attack
release
makeup
```

Editor-level presentation:

```text
knob
slider
meter
graph
label
color
layout
```

И это должны быть два разных мира.

---

# 19. CLI

CLI — не "вспомогательная утилита".

Это полноценный интерфейс управления EUTERPIA.

Цель:

> Любой проект должен быть возможно создать, изменить, собрать и отрендерить без Editor.

Например концептуально:

```text
euterpia init
euterpia node add oscillator
euterpia node add filter
euterpia connect oscillator:out filter:in
euterpia param set filter cutoff 1200
euterpia transport tempo 140
euterpia render project.eproj
```

Расширение файла проекта — `.eproj`. Историческое `.eut` принимается наравне:
расширение — **подпись файла, а не часть формата** (тип файла определяется по
содержимому, §58), поэтому переименование проекта (`demo.eut` → `demo.eproj`)
не требует миграции. Слово «EUT» в других значениях (внутренний ABI ядер,
формат плагинов, §104) к расширению файла проекта отношения не имеет.

---

# 20. CLI не должен содержать бизнес-логику Core

Запрещено:

```text
CLI сам компилирует Graph
CLI сам управляет DSP
CLI сам создаёт buffers
CLI сам знает внутренние структуры pipeline
```

Правильно:

```text
CLI
 ↓
Core API
```

CLI — только интерфейс.

---

# 21. CLI должен быть пригоден для AI

Это отдельный принцип EUTERPIA.

CLI должен быть:

```text
deterministic
scriptable
machine-readable
human-readable
composable
```

Желательно иметь два режима:

```text
human
json
```

Например:

```text
euterpia node list
```

и:

```text
euterpia --json node list
```

Это позволит AI легко:

```text
создавать проекты
исследовать структуру
изменять параметры
читать ошибки
строить workflows
```

Поверхность команд описывается **один раз**. Спецификация `libs/cli_spec`
(issue #330) даёт данные: имя, синопсис, ключи с типами значений и
умолчаниями, пример вызова, поля ответа `--json`. Из них собираются
человеческая справка (`--help`), машинная схема (`help --json`), кандидаты
автодополнения (`__complete`) и раздел справочника `docs/cli.md`
(`nimble cliDocs`). Копий описания — в шаблонах оболочки, документации или
списке ключей команды — быть не должно: расхождение обязан ловить CI, а не
читатель.

---

# 22. Editor

Editor — это визуальная оболочка.

Он не является ядром.

Editor отвечает за:

```text
node canvas
drag & drop
connections
parameter editing
timeline
mixer UI
meters
waveforms
project browser
keyboard shortcuts
visual state
```

Но всё действие выполняется через Core API.

---

# 23. Editor нельзя превращать в "второй Core"

Плохо:

```text
Editor хранит собственную DSP graph
Editor имеет собственный Transport
Editor считает latency
Editor самостоятельно компилирует pipeline
Editor вручную управляет audio buffers
```

Правильно:

```text
Editor
   ↓
Core API
   ↓
Core
```

Editor должен говорить:

```text
create node
connect nodes
set parameter
load project
save project
play
stop
```

и не знать внутреннюю реализацию.

---

# 24. ComfyUI-подход

От ComfyUI имеет смысл брать не код, а философию интерфейса:

```text
Node
Port
Connection
Workflow
Visual graph
Properties
Search
Modularity
```

Но EUTERPIA не должна копировать ComfyUI архитектурно.

DAW имеет свои требования:

```text
sample accuracy
latency
realtime processing
tempo
transport
audio buffers
MIDI
automation
plugin processing
```

Поэтому:

> **ComfyUI вдохновляет Editor, но Core EUTERPIA развивается независимо.**

---

# 25. Commons

Commons должен быть самым скучным модулем проекта.

И это хорошо.

Commons содержит только:

```text
math helpers
result/error types
strings helpers
path helpers
small containers
ID generators
logging abstractions
serialization helpers
utility algorithms
```

Но только если они действительно общие.

---

# 26. Главное правило Commons

> Если модуль можно назвать конкретно — он, вероятно, не должен лежать в Commons.

Например:

```text
wav_utils
```

не Commons.

Это:

```text
audio_file_io
```

`midi_parser` не Commons.

Это MIDI layer.

`NodeEditorMath` не Commons.

Это Editor.

Commons нельзя превращать в свалку utilities.

---

# 27. Dependency Law

Официальный закон:

```text
Commons
   ↑
   │
Core
   ↑
   │
Nodes
   ↑
 ┌─┴─────────┐
CLI        Editor
```

Но с ещё более строгим правилом:

```text
Commons → никого не знает

Core → Commons НЕ обязателен

Nodes → Core (+ Commons)

CLI → Core + Nodes + Commons

Editor → Core + Nodes + Commons
```

И особенно:

```text
Core ─X→ Nodes
Core ─X→ CLI
Core ─X→ Editor

Nodes ─X→ CLI
Nodes ─X→ Editor

CLI ─X→ Editor
Editor ─X→ CLI

Commons ─X→ Core
Commons ─X→ Nodes
Commons ─X→ Editor
Commons ─X→ CLI
```

Это правило проверяется автоматически: `tools/check_architecture.py`
(issue #50). Guard читает ТОЛЬКО строки `import`/`include`/`from` — подстрока
в докстроке или комментарии зависимостью не считается, иначе легитимное по §8
перечисление бэкендов в `core/audio_backend_api.nim` выглядело бы протечкой.
Запрет формулируется по СЛОЮ: множество запретных имён вычисляется из состава
папок, а не из перечня библиотек, — поэтому новый адаптер не проскочит мимо
проверки. В CI скрипт запускает джоб `architecture`; локально —
`nimble archGuard` или `python3 tools/check_architecture.py`.

Следствие для состава: модуль, который работает с аудио-доменом и поэтому
знает о Core (`audio_file_io`, `waveform_cache`), в Commons лежать не может —
по §26 у него есть конкретное имя. Эти два модуля живут в `core/` (issue #5),
а в Commons остаются только нейтральные `midi_io` и `undo_redo`.

---

# 28. Почему Core желательно не связывать с Commons

Это намеренно.

Хотя Core может использовать некоторые utility-функции Commons, желательно, чтобы самое фундаментальное ядро могло существовать отдельно:

```text
Core
   ↓
Nim stdlib
```

Тогда теоретически можно создать:

```text
EUTERPIA Core
```

как отдельную библиотеку.

Это даст максимальную свободу будущих переписываний.

---

# 29. API прежде реализации

Каждый крупный модуль сначала должен иметь контракт.

Например:

```text
transport.nim
```

не должен начинаться с огромной реализации.

Сначала определяется:

```text
Transport
    play()
    stop()
    pause()
    seek()
    setTempo()
    setLoop()
    position()
```

Затем implementation.

Такой подход позволяет заменить реализацию, сохранив API.

---

# 30. Stable API / Private implementation

Наружу:

```text
Transport*
AudioEngine*
NodeDescriptor*
CompiledPipeline*
```

Внутри:

```text
TransportState
InternalGraph
PipelineBuilder
WorkerState
DelayState
```

Внутренние структуры не экспортируются без необходимости.

---

# 31. Минимизация `*`

В Nim экспорт:

```nim
foo*
```

должен быть осознанным.

Правило:

> Не экспортируй символ, если другой модуль не должен его использовать.

Это значительно уменьшит связанность.

---

# 32. Не передавать большие структуры просто так

Плохо:

```text
Editor → огромный Project → Core → Node → Editor
```

Хорошо:

```text
Editor
 ↓
Core Command
 ↓
Core
```

или:

```text
ProjectSnapshot
```

---

# 33. Ownership должен быть очевидным

Для каждого pointer должно быть понятно:

```text
кто создал?
кто владеет?
кто уничтожает?
когда указатель становится недействительным?
может ли он пересекать thread boundary?
```

Запрещается код типа:

```text
seq.add(...)
pointer = addr seq[^1]
```

без гарантии стабильного lifetime.

---

# 34. `seq` нельзя использовать как постоянное хранилище указателей

Особенно:

```text
addr seq[i]
```

не должен переживать операции, способные изменить capacity.

Для долгоживущего state использовать:

```text
stable allocation
object
shared allocation
fixed storage
arena with stable addresses
handle/index
```

---

# 35. ID лучше pointer

Для editor/control системы предпочтительнее:

```text
NodeId
TrackId
ClipId
ParameterId
```

чем передача указателей между подсистемами.

Пример:

```text
NodeId → Core registry → NodeState
```

Так компоненты не зависят от адресов памяти.

---

# 36. Handles > raw pointers

Raw pointers допускаются там, где это действительно необходимо:

```text
audio buffer
DSP state
C ABI
device callback
```

Для остального:

```text
NodeHandle
BufferHandle
PluginHandle
TrackHandle
ClipHandle
```

Это упрощает lifetime management.

Handle — **значение**, а не ссылка на объект: документ + слот + поколение + вид
сущности. Поколение отличает старый адрес от адреса переиспользованного слота
(ABA), документ — чужой адрес от своего. Адрес вложенной сущности — handle
владельца плюс путь шагов: `node:3.1/component:1/param:0`. Реализация и её
контракт — `core/handles.nim` (issue #143), CLI печатает и принимает такие
адреса (`docs/cli.md`).

---

# 37. Один модуль — одна ответственность

Нельзя:

```text
audio_engine.nim
```

который одновременно:

```text
обрабатывает DSP
работает с PortAudio
читает MIDI
управляет проектом
сохраняет JSON
рисует UI
```

Правильно:

```text
AudioEngine
AudioBackend
Midi
Project
Editor
```

---

# 38. Не создавать "God modules"

Особенно опасные будущие файлы:

```text
euterpia.nim
manager.nim
system.nim
utils.nim
common.nim
core.nim
```

которые постепенно начинают импортировать всё.

Если модуль импортирует половину проекта — архитектура уже начинает разрушаться.

---

# 39. Циклические зависимости запрещены

Нельзя:

```text
A → B
B → C
C → A
```

Если возникает цикл:

> проблема решается архитектурой, а не `include`, `forward` или дополнительными pointer hacks.

---

# 40. Interfaces вместо взаимного знания

Если два слоя действительно должны взаимодействовать, создаётся маленький контракт.

Например:

```text
audio_backend_api
```

вместо:

```text
audio_engine → PortAudio
PortAudio → audio_engine internals
```

---

# 41. Каждый внешний мир получает Adapter

Структура:

```text
Core API
   ↑
Adapter
   ↑
External library
```

Например:

```text
CLAP Adapter
PortAudio Adapter
RtMidi Adapter
```

Заменить библиотеку должно быть возможно без изменения Core.

---

# 42. Сторонняя библиотека не должна проникать внутрь проекта

Если используется:

```text
PortAudio
```

не должно быть 30 модулей, которые импортируют его напрямую.

Только:

```text
audio_backend_portaudio
```

знает PortAudio.

То же самое для:

```text
RtMidi
CLAP
GUI
```

---

# 43. Logging

Core не должен постоянно писать:

```text
echo
```

Особенно realtime.

Нужен абстрактный logger:

```text
Logger
 ├── CLI logger
 ├── Editor logger
 └── Silent logger
```

Audio thread должен иметь только realtime-safe diagnostic mechanisms.

---

# 44. Ошибки

Нельзя использовать exceptions как обычный runtime-control-flow в realtime.

Realtime API:

```text
bool
Result
status code
enum
```

Control API может использовать exceptions там, где это удобно.

Например:

```text
project loading
plugin loading
file IO
CLI parsing
```

---

# 45. Realtime assertions

В Debug build допускается больше проверок.

В Release:

```text
Audio thread
```

должен быть предсказуемым.

Механизм обязателен и реализован — `DEBUG_ASSERT_REALTIME_SAFE` в
`core/rt_guard.nim` (issue #11):

```text
rtScope / rtEnter / rtLeave                     — пометить audio-путь
rtAssertNoAlloc / rtAssertNoLock / rtAssertNoIo — точка риска
```

В debug-сборке нарушение падает с категорией (`rvAlloc`, `rvLock`, `rvIo`,
`rvDepth`) и номером строки, в release проверки компилируются в пустоту
(overhead = 0). Глубина вложенности ограничена `MaxRtDepth`.

---

# 46. DSP code должен быть скучным

DSP node должен выглядеть приблизительно так:

```text
read parameters
read input
process samples
write output
update state
```

Не надо:

```text
Table
string
objects creation
logging
file access
graph traversal
```

внутри `process()`.

---

# 47. DSP state отделяется от Node descriptor

Например:

```text
GainDescriptor
GainState
processGain()
```

Descriptor:

```text
metadata
parameters
ports
```

State:

```text
current gain
smoother
DSP variables
```

---

# 48. Node не должен хранить Editor state

Запрещено:

```text
node.editorX
node.editorY
node.selected
node.collapsed
node.color
```

Это состояние Editor.

Node runtime:

```text
DSP state
parameter state
latency
ports
```

---

# 49. Project data и Runtime data

Разделять:

```text
Project Model
```

и:

```text
Runtime Model
```

Проект хранит:

```text
nodes
connections
parameters
clips
automation
tracks
settings
```

Runtime хранит:

```text
compiled pipeline
buffers
DSP state
plugin instances
workers
audio handles
```

Runtime pointers нельзя сериализовать.

---

# 50. Project должен быть независим от Editor

Проект можно создать:

```text
CLI
```

и открыть:

```text
Editor
```

и наоборот.

Файл проекта не должен содержать:

```text
Editor window position
panel sizes
selected node
zoom
temporary UI state
```

Это может существовать в отдельном UI state file.

---

# 51. Editor State

Например:

```text
project.eproj
project.editor.json
```

Или:

```text
project.eproj
.editor/
```

Так проектный файл остаётся чистым.

---

# 52. Node State в проекте

Project должен хранить **данные Node**, но не реализацию Node.

Например:

```json
{
    "type": "builtin.compressor",
    "parameters": {
        "threshold": -12,
        "ratio": 4
    }
}
```

А runtime получает:

```text
builtin.compressor
        ↓
NodeRegistry
        ↓
NodeFactory
        ↓
NodeState
```

---

# 53. Node Registry

Нужен отдельный механизм:

```text
NodeRegistry
```

Он связывает:

```text
Node Type ID
        ↓
Descriptor
        ↓
Factory
        ↓
Processor
```

Пример:

```text
builtin.gain
builtin.filter
builtin.oscillator
eut.example.synth
clap.vendor.plugin
```

Core знает API Registry.

Конкретные Nodes регистрируются извне.

---

# 54. Core не должен знать список Nodes

Это фундаментальное правило.

Не надо делать:

```nim
import dsp_nodes
import core_nodes
import synth_nodes
import mixer_nodes
```

в Core.

Вместо этого:

```text
Core
 ↓
NodeRegistry
 ↑
Builtin Nodes
```

---

# 55. Где лежат project-specific Nodes

Если в будущем пользователь создаёт собственные Nodes, структура может быть:

```text
project/
├── project.eproj
├── assets/
├── presets/
└── nodes/
```

Например — модуль ноды (разделяемая библиотека, не проект):

```text
project/nodes/my_synth.so
```

или:

```text
project/nodes/my_synth.dll
```

Расширение `.eut` у модуля ноды не используется: «EUT» — имя формата плагинов и
внутреннего ABI (§104), а не расширение файла; расширение `.eproj` закреплено за
проектом (§19). Так «открыть проект» и «загрузить ноду» не выглядят одинаково.

Но сам project не должен встраивать чужую реализацию в Core.

---

# 56. SDK

Именно поэтому нужен:

```text
nodes/sdk/
```

SDK содержит:

```text
Node API
Descriptor API
Parameter API
Event API
DSP helpers
Plugin helpers
```

С его помощью можно писать Node независимо от Editor.

---

# 57. Node SDK должен быть стабильнее самих Nodes

Внутри:

```text
Node implementation
```

можно делать большие изменения.

Но:

```text
Node API
```

должен версионироваться.

Например:

```text
EUT_NODE_API_1
EUT_NODE_API_2
```

---

# 58. Версионирование

Обязательное правило:

```text
Project format version
Core API version
Node API version
Plugin ABI version
CLI version
```

не смешиваются.

Например:

```text
Project format: 3
Node API: 2
Core runtime: 5
```

---

# 59. Backward compatibility

Core может развиваться.

Но проект:

```text
project_v1.eproj
```

не должен внезапно перестать загружаться без понятной причины.

Расширение в этом не участвует: тип файла определяется по содержимому (§58),
поэтому проект, переименованный из `project_v1.eut` в `project_v1.eproj`,
загружается без миграции — `.eut` остаётся принятым историческим расширением.

Нужен:

```text
migration layer
```

например:

```text
v1 → v2
v2 → v3
```

---

# 60. CLI и Editor — равноправные клиенты Core

Не должно быть:

```text
Editor — настоящий продукт
CLI — урезанная игрушка
```

Наоборот:

```text
Core
 ↑
 ├── CLI
 └── Editor
```

Они используют один и тот же API.

---

# 61. Headless-first

EUTERPIA должна уметь работать без GUI.

Это даёт:

```text
CI/CD
AI workflows
servers
render farms
automation
scripts
batch processing
testing
```

Editor должен быть опциональным frontend.

---

# 62. AI-friendly architecture

CLI должен позволять:

```text
создать проект
найти node
подключить node
прочитать параметры
изменить параметры
запустить
рендерить
сохранить
```

без GUI.

Это делает EUTERPIA пригодной для:

```text
AI agents
shell scripts
generators
automation
```

---

# 63. AI не должен получать внутренние структуры Core

AI работает через стабильный API:

```text
CLI commands
Project format
Node descriptors
```

а не через:

```text
изменение внутренних pointer
редактирование runtime memory
правку бинарных state
```

Чтение — тот же контракт, что и запись: клиент задаёт ВОПРОСЫ через Query API
(`core/control/query.nim`), а не обходит документ полями. `node list/show`,
`param list/get`, `project show` получают неизменяемые DTO со устойчивым
порядком, а не ссылки на модель; тот же ответ видит Editor, поэтому «один
вопрос — один ответ» проверяемо (#141, #336). Обратный ход (обход коллекций
документа клиентом) запрещён проверкой `tools/check_architecture.py`; в ней
поимённо перечислены только валидаторы целостности и пути записи — их предмет
и есть сам файл.

---

# 64. Editor должен быть тонким

Чем меньше логики в Editor, тем лучше.

Editor должен в основном делать:

```text
Input
 ↓
Command
 ↓
Core
 ↓
State update
 ↓
Render
```

а не:

```text
Input
 ↓
Editor пытается самостоятельно изменить всё
```

---

# 65. Командная модель

Очень желательно сделать единый command API:

```text
CreateNode
DeleteNode
Connect
Disconnect
SetParameter
AddTrack
RemoveTrack
AddClip
DeleteClip
AddNote
DeleteNote
SetTransport
```

CLI и Editor вызывают одни и те же команды.

Это автоматически унифицирует:

```text
Undo
Redo
CLI
Editor
Automation
AI
```

Результат команды — не `bool`, а **кадр ошибки** (`ErrorCode` + сообщение +
подсказка): «ноды нет» и «порт занят» — разные отказы с разными подсказками, а
агент различает их по коду, не разбирая текст. Реализация — `core/control/`
(Control Core рядом с Realtime Core, §66), хозяин документа отдаёт описания
типов и часы, поэтому ядро не знает ни типов нод, ни системного времени.

---

# 66. Undo/Redo — часть control layer

Undo/Redo не относится к DSP.

Поэтому:

```text
Core realtime
```

не должен зависеть от Undo.

Можно иметь:

```text
Control Core
```

и:

```text
Realtime Core
```

внутри архитектуры, если система вырастет.

---

# 67. Подготовка к переписыванию

Каждый модуль должен иметь возможность быть заменённым.

Например:

```text
GraphCompiler v1
        ↓
GraphCompiler v2
```

при этом:

```text
Node API
AudioEngine API
Editor API
CLI API
```

остаются прежними.

---

# 68. Contract Tests

Для каждого крупного API должны быть contract tests.

Например:

```text
Transport contract
Node contract
Plugin contract
Pipeline contract
Project format contract
CLI contract
```

Тогда новую реализацию можно проверить:

```text
old implementation
new implementation
```

против одних и тех же тестов.

---

# 69. Модуль считается хорошим, если его можно удалить

Очень полезный критерий:

> **Если модуль невозможно удалить без переписывания большого количества соседних модулей — он слишком связан.**

---

# 70. Модуль считается плохим, если без него рушится всё

Исключение:

```text
Core
```

Но даже Core должен быть максимально изолирован.

---

# 71. Публичные API должны быть маленькими

Лучше:

```text
10 понятных функций
```

чем:

```text
80 процедур,
из которых пользователю нужны 7.
```

Каждая exported procedure должна отвечать на вопрос:

> Кто её вызывает и зачем?

Если ответа нет — export не нужен.

---

# 72. Никаких скрытых глобальных состояний

Запрещается:

```text
globalMidiManager
globalAudioEngine
globalCurrentProject
globalEditorState
globalNodeRegistry
```

без очень веской причины.

Dependency должна быть явной:

```text
Engine
Registry
Transport
Project
```

передаются через объекты/handles.

---

# 73. Один владелец — один ресурс

Например:

```text
PluginInstance
```

имеет одного владельца.

```text
AudioBackend
```

имеет одного владельца.

```text
Pipeline
```

имеет понятный lifecycle.

Нельзя создавать систему, в которой неизвестно:

```text
кто уничтожит resource?
```

---

# 74. Lifecycle должен быть явным

Большие объекты должны иметь:

```text
init
start
process
stop
destroy
```

или эквивалентную lifecycle-модель.

Особенно:

```text
audio
plugins
workers
MIDI
devices
```

---

# 75. Thread ownership

Для каждого объекта должно быть понятно:

```text
Control Thread
Audio Thread
Worker Thread
MIDI Thread
```

Кто может читать?

Кто может писать?

Можно ли одновременно?

Если документации нет — архитектура считается незавершённой.

---

# 76. Thread-safe не означает realtime-safe

Это разные вещи.

Можно иметь:

```text
thread-safe
```

но всё ещё нельзя:

```text
audio callback
```

Например mutex technically thread-safe, но для realtime он запрещён.

---

# 77. Determinism

EUTERPIA должна стремиться к детерминированному DSP.

Одинаковые:

```text
input
project
sample rate
tempo
parameters
```

должны давать одинаковый:

```text
output
```

где это разумно.

Это особенно важно для:

```text
offline rendering
tests
AI generated projects
```

---

# 78. Offline render должен использовать тот же DSP

Нельзя иметь:

```text
Realtime DSP
```

и полностью отдельный:

```text
Offline DSP
```

Они должны использовать один pipeline.

Различаться может только:

```text
clock source
output sink
```

---

# 79. Performance optimisation only after profiling

Запрещается оптимизировать "на глаз".

Сначала:

```text
profile
measure
identify bottleneck
change
measure again
```

Особенно в DSP.

---

# 80. Красивый код важнее хитрого кода

Предпочтение:

```text
понятный O(N)
```

вместо:

```text
магического lock-free шаблона на 300 строк
```

если это не доказанный bottleneck.

---

# 81. Код должен быть скучно читаемым

Хороший EUTERPIA-код должен позволять разработчику открыть файл через год и понять:

```text
что происходит
кто вызывает
кто владеет памятью
где thread boundary
где realtime boundary
```

без археологии.

---

# 82. Запрещается "магия"

Нежелательны:

```text
магические ID
магические числа
неочевидные глобальные состояния
скрытые side effects
неявное владение
неявные conversions
```

Например:

```text
10000
```

не должен молча означать:

```text
PDC generated node ID
```

Должен существовать понятный механизм.

---

# 83. Константы должны объяснять себя

Плохо:

```nim
const Max = 256
```

Хорошо:

```nim
const MaxBlockFrames = 256
```

Или:

```nim
const DefaultPpq = 960
```

---

# 84. Один концепт — одно имя

Нельзя называть одно и то же:

```text
samplePos
samplePosition
currentSample
position
```

в разных модулях без причины.

Нужно выбрать стандарт.

---

# 85. Терминология EUTERPIA

Предлагается зафиксировать:

```text
Frame   = один sample frame
Sample  = один sample одного канала
Block   = block frames
Node    = processing unit
Port    = input/output endpoint
Event   = timestamped event
Parameter = controllable numeric property
Graph   = editable topology
Pipeline = compiled executable graph
Transport = musical clock
Project = persistent user data
Runtime = execution state
```

---

# 86. File structure

Рекомендуемая структура проекта:

```text
EUTERPIA/
│
├── core/
│   ├── base/
│   ├── graph/
│   ├── runtime/
│   ├── transport/
│   ├── realtime/
│   ├── memory/
│   ├── plugin/
│   └── io/
│
├── nodes/
│   ├── sdk/
│   ├── builtin/
│   │   ├── generators/
│   │   ├── instruments/
│   │   ├── filters/
│   │   ├── dynamics/
│   │   ├── effects/
│   │   ├── mixing/
│   │   └── utility/
│   │
│   └── extensions/
│       ├── eut/
│       └── clap/
│
├── cli/
│   ├── commands/
│   ├── formatting/
│   └── main.nim
│
├── commons/
│   ├── collections/
│   ├── math/
│   ├── errors/
│   ├── logging/
│   └── utilities/
│
├── editor/
│   ├── canvas/
│   ├── nodes/
│   ├── timeline/
│   ├── mixer/
│   ├── inspector/
│   ├── project/
│   └── main.nim
│
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── realtime/
│   ├── dsp/
│   ├── cli/
│   └── plugins/
│
├── docs/
│
└── tools/
```

---

# 87. Внутри Core

Для роста проекта Core лучше сразу разделять логически.

```text
core/
├── types/
│   ├── audio_types
│   ├── event_types
│   ├── parameter_types
│   └── node_types
│
├── graph/
│   ├── graph
│   ├── graph_validate
│   ├── graph_compile
│   ├── latency
│   └── pipeline
│
├── realtime/
│   ├── audio_engine
│   ├── realtime_bus
│   ├── scheduler
│   └── epoch
│
├── transport/
│   └── transport
│
├── memory/
│   ├── pool
│   ├── arena
│   └── handles
│
└── plugin/
    ├── plugin_api
    └── plugin_registry
```

---

# 88. Core должен быть "boring"

Это сознательный принцип.

Core не должен постоянно меняться из-за новых фич.

Новые возможности должны появляться преимущественно здесь:

```text
Nodes
CLI
Editor
Adapters
```

а не через изменение фундаментальных структур.

---

# 89. Когда разрешено менять Core

Изменение Core разрешается, если:

```text
1. невозможно решить проблему выше Core;
2. текущий API архитектурно ограничивает будущее;
3. изменение улучшает фундамент, а не конкретную фичу;
4. есть тесты;
5. влияние на ABI/API документировано;
6. рассмотрена возможность compatibility layer.
```

---

# 90. Что запрещается категорически

```text
❌ GUI зависимость в Core
❌ Editor dependency в Core
❌ CLI dependency в Core
❌ Nodes dependency в Core
❌ File I/O в realtime
❌ allocation в realtime
❌ locks в realtime
❌ exceptions в realtime
❌ graph analysis во время render
❌ seq pointer без lifetime guarantee
❌ глобальное состояние без крайней необходимости
❌ циклические зависимости
❌ giant "utils" modules
❌ giant manager classes
❌ копирование одинаковой логики в CLI и Editor
❌ сериализация runtime state
❌ plugin-specific код в Core
❌ GUI-specific данные в Node
❌ Node-specific knowledge в Core
❌ случайное добавление dependency ради одной функции
```

---

# 91. Что поощряется

```text
✓ маленькие модули
✓ маленькие API
✓ явное владение
✓ стабильные interfaces
✓ immutable snapshots
✓ handles
✓ deterministic processing
✓ preallocation
✓ lock-free communication
✓ contract tests
✓ background workers
✓ adapters
✓ dependency inversion
✓ headless operation
✓ CLI automation
✓ machine-readable output
✓ profiling
✓ документация архитектуры
```

---

# 92. Правило "трёх слоёв"

При добавлении новой функциональности сначала определить:

```text
Это фундамент?
```

Если да:

```text
Core
```

Если это реализация Node:

```text
Nodes
```

Если это интерфейс управления:

```text
CLI
```

Если это визуализация:

```text
Editor
```

Если это действительно нейтральная вспомогательная функция:

```text
Commons
```

Если ответ:

```text
"ну это вроде подходит в Commons"
```

то почти наверняка это **не Commons**.

---

# 93. Правило зависимости

Перед добавлением import разработчик должен спросить:

> Может ли этот модуль существовать без нового import?

Если да — dependency не добавляется.

Если нет:

> Является ли эта зависимость частью архитектурного контракта?

Если нет:

> Нужен ли adapter?

Это должно стать привычкой проекта.

---

# 94. Правило переписывания

Каждый новый subsystem нужно проектировать так, будто завтра его придется полностью переписать.

Например:

```text
WaveformCache v1
```

должен позволять заменить его на:

```text
WaveformCache v2
```

без изменения Editor API.

То же:

```text
PortAudioBackend
```

→

```text
PipeWireBackend
```

и:

```text
GraphCompiler v1
```

→

```text
GraphCompiler v2
```

---

# 95. Правило "не распространяй implementation details"

Если Editor использует:

```text
PipelineStep
MemoryPool
DelayCompensationData
```

напрямую — это плохой знак.

Editor должен использовать:

```text
Core public API
```

а не внутренности.

То же относится к CLI.

---

# 96. Публичная архитектура

Внешнему пользователю EUTERPIA желательно видеть:

```text
Project
Graph
Node
Parameter
Transport
AudioEngine
Renderer
```

а не:

```text
PipelineStep
NetLifetime
BufferEndSteps
RetireItem
PoolBlock
```

---

# 97. Private implementation должна оставаться private

Если внутренняя структура перестаёт быть необходима другим модулям — она должна быть скрыта.

Это делает Core устойчивым к переписыванию.

---

# 98. Документация — часть архитектуры

Каждый крупный модуль должен иметь короткое описание:

```text
Purpose
Owns
Depends on
Thread
Realtime-safe?
Public API
Lifecycle
```

Например:

```text
audio_engine
Purpose:
Realtime execution.

Owns:
sample clock, active pipeline.

Depends on:
Core graph/runtime.

Thread:
Audio.

Realtime:
YES.
```

---

# 99. Архитектурная документация должна быть тестируемой

Например можно автоматически проверять:

```text
Core imports Editor → FAIL
Core imports CLI → FAIL
Core imports Nodes → FAIL
Node imports Editor → FAIL
Commons imports Core → FAIL
```

Архитектурные правила должны быть не только в README.

Они должны проверяться CI.

---

# 100. Финальная философия EUTERPIA

EUTERPIA не должна становиться большим приложением.

Она должна оставаться:

```text
маленьким Core
+
стабильные API
+
независимые Nodes
+
CLI
+
Editor
+
тонкие adapters
```

Главная цель:

```text
           EUTERPIA
              │
       ┌──────┴──────┐
       │             │
      Core          Nodes
       │             │
       └──────┬──────┘
              │
      ┌───────┴────────┐
      │                │
     CLI             Editor
```

При этом **Core никогда не превращается в зависимость от верхних слоёв**.

---

# 101. Главный закон

> **Core определяет правила.
> Nodes реализуют возможности.
> CLI предоставляет управление.
> Editor предоставляет визуализацию.
> Commons предоставляет только нейтральные инструменты.**

И ещё один:

> **Ни один слой не должен знать о внутреннем устройстве слоя выше него.**

И самый важный:

> **Если новое решение делает систему менее заменяемой — это плохое архитектурное решение, даже если сейчас оно быстрее или удобнее.**

---

# 102. Целевая архитектура EUTERPIA

В конечном итоге архитектура должна выглядеть так:

```text
                         USER
                    ┌─────┴─────┐
                    │           │
                  CLI         Editor
                    │           │
                    └─────┬─────┘
                          │
                     Control API
                          │
                 ┌────────▼────────┐
                 │      Core       │
                 │                 │
                 │ Graph            │
                 │ Compiler         │
                 │ Transport        │
                 │ Parameters       │
                 │ Events           │
                 │ Runtime          │
                 │ Scheduler        │
                 │ Memory           │
                 │ Plugin API       │
                 └────────┬────────┘
                          │
                     Node API
                          │
              ┌───────────┴───────────┐
              │                       │
         Builtin Nodes          External Nodes
              │                       │
              ├── DSP                 ├── EUT
              ├── Synth               └── CLAP
              ├── FX
              └── Utility
                          │
                    Audio Backend
                          │
                ┌─────────┴─────────┐
                │                   │
             Audio I/O           Devices
```

А `Commons` находится сбоку как **нейтральный фундаментальный набор инструментов**, который не знает ни про Core, ни про Nodes, ни про Editor:

```text
                 Commons
               ↙   ↓   ↘
             Core Nodes CLI/Editor
```

Причём использование Commons Core-ом должно быть минимальным.

---

# 103. Итоговое правило разработки

Перед тем как добавить код в EUTERPIA, нужно ответить на пять вопросов:

```text
1. К какому слою относится эта функциональность?

2. Кто владеет её состоянием?

3. В каком thread она работает?

4. Может ли этот модуль быть переписан независимо?

5. Увеличивает ли новая зависимость связанность проекта?
```

Если ответ на последний вопрос:

```text
Да
```

нужно сначала искать архитектурное решение.

---

# 104. Форматы плагинов: только открытые. VST не поддерживается

Подключаемые форматы: **CLAP**, собственный **EUT** и (в плане) **LV2**.
Всё это форматы с открытой лицензией и чистым C ABI.

Термин «EUT» в проекте означает **две разные вещи**, и их нельзя смешивать:
* **внутренний ABI ядер** — C-контракт DSP-ядер, вкомпилированных в движок
  (`nodes/builtin/csrc/eut_dsp.h`, `eut_abi.c`, `eut_osc.c`, …). Он обязателен:
  на нём стоят все встроенные ноды;
* **формат плагинов EUT** — загружаемый из `dynlib` модуль за `plugin_api`
  (`adapters/eut/eut_plugin*.nim`, ABI v1). Сейчас он **спроектирован, но не
  подключён** к реестру и не имеет сквозного теста.
Подробный разбор (что это, зачем, можно ли отказаться, дорожная карта и как
хостить CLAP без обёрток) — в **[docs/eut.md](docs/eut.md)**. Решение «оставить
или снять формат» вынесено в отдельный RFC-issue.

**VST / VST3 не поддерживается и не будет поддерживаться.** Причины:

1. **Лицензия проприетарная.** VST3 SDK — собственность Steinberg:
   соглашение принимается вручную, распространение бинарей с SDK
   ограничено, совместимость с открытыми лицензиями отсутствует.
2. **Нет стабильного C ABI.** VST3 — интерфейсы C++ из XML-генератора,
   RTTI, исключения, привязка к конкретному компилятору и версии STL.
   Хостинг потребовал бы изолированного C++-bridge в отдельном процессе —
   чужая архитектура вместо нашей таблицы методов.
3. **Плохо оптимизирован для realtime.** Спецификация не запрещает
   аллокации в куче и локи внутри `process()`, а §9/§10 запрещают такие
   вызовы в audio-потоке. Совместимость пришлось бы делать через
   out-of-process-прослойку с IPC на каждый аудиоблок.
4. **Стоимость выше пользы.** Основной формат — CLAP, второй — EUT;
   VST добавил бы юридическую и инженерную нагрузку на сборку, тесты и
   релизы, не дав ничего, чего нет в открытых форматах.

Правило: новый адаптер формата добавляется только если у формата
открытая лицензия, C ABI и явный realtime-контракт. Раз `plugin_api` не
знает форматов, отказ от VST — это просто отсутствие адаптера в
`adapters/`, без правок Core.

# 105. Версии, ветви и Issue: порядок важнее скорости

Рост превратил крупные линии (`v0.3`, `v0.4`, …) в неуправляемые: в одной
версии рядом стоят архитектурные изменения и косметика, а объём неизмерим.
Правило ниже разбивает линию на **подверсии** с предсказуемым смыслом.
Полные правила, шаблоны и порядок миграции — в `docs/versions.md` и `.github/`.

1. **Линия** — это тема (`v0.3` CLI, `v0.4` фундамент, …). **Подверсия** — шаг
   внутри линии: `v0.3.1`, `v0.3.2`, ….
2. **Смысл шага зафиксирован** и не «перескакивает»:
   * `.1` — организация и документация: README, MANIFEST, `euterpia_version`,
     шаблоны, релизная механика (CHANGELOG, артефакты, установка);
   * `.2` — критическое и архитектурное: P0/P1-ошибки, крупные архитектурные
     изменения, снятие блокеров;
   * `.3` — функциональность P1;
   * `.4` — функциональность P2;
   * `.5` — функциональность P3 и полировка;
   * `.6`… — только если линия переросла, и снова по смыслу, а не «до круглого».
3. **Не смешивать** в одной подверсии глубокую архитектуру и оформление
   (кнопки, косметика интерфейса). Сначала фундамент и логика, затем форма.
4. **Объём** подверсии — тот, что реально закрывается целиком. Дробить на
   десятки микро-релизов нельзя; разросшийся шаг делят по теме, а не по счётчику.
5. **Ветви повторяют подверсии**: `feat/v0.3.3-transport`, `fix/v0.3.2-...`,
   `docs/v0.3.1-...`. `main` — только то, что прошло CI и ревью.
6. **Issue привязывается к подверсии** (milestone) по тому же смыслу: метка
   `docs`/`chore`/`ci` → `.1`; `architecture` или P0/P1-`bug` → `.2`; иначе по
   приоритету `p1 → .3`, `p2 → .4`, `p3 → .5`.
7. **Дублировать Issue запрещено.** Развитие направления оформляется ссылкой на
   существующую Issue с конкретикой: файл, номера строк, выписка кода, что не
   устраивает; что добавить/удалить и почему. Следующая подверсия продолжает
   направление ссылкой, а не копией.

---


---

# EUTERPIA должна быть не большой, а хорошо разделённой.

Не:

```text
"у нас 100 модулей"
```

а:

```text
"у нас 100 модулей, и каждый знает только необходимое ему количество других модулей."
```

Это и есть главный критерий качества EUTERPIA.
