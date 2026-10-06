# Встраивание ядра EUTERPIA

Ядро EUTERPIA — библиотека, а не приложение. «Встроить ядро» значит взять
свой процесс, свой audio-callback и свой язык, а у EUTERPIA попросить только
звук: граф, рендер блоков, метрики. Ни CLI, ни Editor для этого не нужны —
так требует §61 (headless-first) и §90 («❌ GUI зависимость в Core»).

Документ отвечает на три вопроса:

1. что вызывает хост и в каком порядке (контракт);
2. чем хост владеет, а чем — движок (владение);
3. как это собрать и проверить (Nim-хост, C-ABI-библиотека, CI).

Исходная задача — [#213](https://github.com/framefrok/Euterpia_core/issues/213),
порядок шага — `docs/plans/v0.3.2.md` §6.

## 1. Три уровня встраивания

| Уровень | Кто так делает | Что использует |
|---|---|---|
| Nim-хост в том же процессе | тесты, `libs/compose`, собственный DAW на Nim | публичные модули Core/Nodes (`audio_engine`, `pipeline_builder`, …) |
| C-ABI-библиотека | движок/плагин на C, C++, Rust, Python | `*.exportc, cdecl, dynlib` фасад (`examples/embed_lib.nim`) |
| CLI / Editor | человек и скрипты | те же публичные API через Control Core (§19-§21) |

Первые два уровня — предмет #213, примеры лежат в `examples/`:

- `examples/embed_render.nim` — Nim-хост: граф → блоки → офлайн-рендер;
- `examples/embed_lib.nim` — C-ABI-фасад: сборка `static`/`dynamic`;
- `examples/host_ctypes.py` — чужой рантайм: Python грузит библиотеку
  через `ctypes` и играет 200 блоков.

## 2. Контракт: что делает ядро, а что — хост

Ядро **не** открывает устройство и **не** владеет аудио-потоком. Устройство
и callback — сторона хоста (адаптер `adapters/*` это подтверждает: он делает
ровно то же, что делает чужой хост):

| Обязанность | Кто отвечает | Чем |
|---|---|---|
| аудио-callback и его поток | хост | зовёт `renderBlock(engine, outBuf)` |
| формат буфера | хост | interleaved stereo, `blockSize * 2` × float32 |
| создание/уничтожение движка | хост | `createAudioEngine` / `destroyAudioEngine` |
| публикация графа в RT | хост, **единственный путь** | `postGraphUpdate` (§10, §12) |
| команды контроля (play/stop/tempo/param) | хост | `postPlay`/`postStop`/`postSetTempo`/`postSetParam` |
| чтение метрик и позиции | хост, из control-потока | `pollMetrics`, `currentFrame`, `xrunCount` |
| состояния нод | **хост** | создал → сам `destroyNodeState` |
| компиляция графа | ядро | `buildPipeline` (Node SDK) |
| владение пайплайном | ядро, начиная с `postGraphUpdate` | освобождает `destroyAudioEngine` |

Три инварианта, которые ломаются чаще всего:

1. **Пайплайн переходит движку.** После успешного `postGraphUpdate` указатель
   принадлежит движку; повторное `destroyPipeline` даёт двойное освобождение
   (ловится ASan). `renderToWav` забирает пайплайн так же.
2. **Состояния нод — собственность хоста.** `instantiateNode` создаёт
   состояние, `destroyNodeState` освобождает; движок их не трогает.
3. **В audio-пути нет ничего, кроме `renderBlock`.** Ни аллокаций, ни локов,
   ни исключений (§9): команды уходят в очередь, метрики — в SPSC (§10).

## 3. Порядок вызовов (минимальный хост)

```nim
import signal_types, graph_compiler, compiled_pipeline
import audio_engine, offline_render
import sdk/node_registry, sdk/pipeline_builder
import builtin/builtin_registry

# 1. граф: реестр типов -> состояния -> компиляция
var reg = initNodeRegistry()
doAssert registerBuiltinNodes(reg) == BuiltinCount
var osc, gain, mix: EditorNode
doAssert reg.instantiateNode("euterpia.osc", 1, osc)
doAssert reg.instantiateNode("euterpia.gain", 2, gain)
doAssert reg.instantiateNode("euterpia.mix", 3, mix)

var graph: NodeGraph
graph.nodes[1] = osc
graph.nodes[2] = gain
graph.nodes[3] = mix            # 3 — нода, чей выход идёт в драйвер
graph.connections.add EditorConnection(
  srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio)
graph.connections.add EditorConnection(
  srcNodeId: 2, srcPortIdx: 0, dstNodeId: 3, dstPortIdx: 0, sigType: sigAudio)

var cr: CompileResult
var binding: ptr PipelineBinding
doAssert buildPipeline(reg, graph, 3, cr, binding)

# 2. движок: команды из control-потока, блоки из audio-потока
let engine = createAudioEngine(48000.0f, 128)
doAssert engine.postGraphUpdate(cr.pipeline)   # владение ушло движку
doAssert engine.postPlay()
var buf: array[256, float32]                   # 128 кадров × 2 канала
var p = cast[ptr UncheckedArray[float32]](addr buf[0])
for _ in 0 ..< 400:
  engine.renderBlock(p)                        # ← это и есть callback

# 3. остановка: движок освобождает пайплайн, состояния — хост
doAssert engine.postStop()
destroyAudioEngine(engine)
destroyNodeState(reg.findNodeType("euterpia.osc"), osc.userData)
destroyNodeState(reg.findNodeType("euterpia.gain"), gain.userData)
destroyNodeState(reg.findNodeType("euterpia.mix"), mix.userData)
```

Живой пример с проверками — `examples/embed_render.nim`; офлайн-ветка
(«тот же пайплайн, но без устройства») — `renderToWav`, он же страхует от
ошибок во владении: пайплайн снова уходит движку.

Хост с записью/входом вызывает 4-аргументный `renderBlock(engine, driverIn,
inputChannels, driverOut)` — тот же RT-контракт, только вход не «тишина».

## 4. Сборка как библиотеки

Флаги — часть контракта встраивания, поэтому они фиксированы и продублированы
в `euterpia.nimble` (цели `embedExample`/`embedLib`):

```bash
# dynamic: build/libeuterpia_embed.so (.dylib / .dll)
nim c --app:lib -d:release --hints:off \
      --nimcache:build/nc_embedlib \
      --out:build/libeuterpia_embed.so examples/embed_lib.nim

# static: build/libeuterpia_embed.a + заголовок `--header`
# (Nim кладёт .h в nimcache, имя — по имени выходного файла)
nim c --app:staticLib -d:release --hints:off \
      --nimcache:build/nc_embedstatic --header \
      --out:build/libeuterpia_embed.a examples/embed_lib.nim
cp build/nc_embedstatic/euterpia_embed.h build/euterpia_embed.h
```

Что важно знать про сборку:

- **Модульные пути и память.** `core/`, `nodes/`, `commons/` подключены через
  `config.nims` репозитория; если файл хоста лежит вне репозитория, добавьте
  `--path:<repo>/core`, `--path:<repo>/nodes` и те же `--mm:orc`/`--threads:on`.
  Смешивать разные memory manager'ы на одной границе нельзя.
- **`{.exportc, cdecl, dynlib.}`** на каждом символе: только они попадают в
  таблицу экспорта (на Linux — `-rdynamic`/видимость по `--app:lib`).
  Символы без `exportc` наружу не выдаются — внутренности ядра не становятся
  частью ABI по недосмотру.
- **Nim-рантайм.** Отдельного `NimMain` для `--app:lib` вызывать не нужно —
  это проверяет джоб `embed`: `ctypes.CDLL` загружает библиотеку и сразу
  зовёт `eutHostCreate`. На Windows/macOS упаковка символов своя, поэтому
  загрузка проверяется в Linux-джобе (как у `clap`).
- **Заголовок.** `--header` генерирует `.h` с прототипами экспортированных
  процедур (в Linux-прогоне это `eutHostCreate`, `eutHostRenderBlock`, …):
  удобно отдать хосту на C/C++. Файл кладётся в **nimcache** (имя — по имени
  выходного файла) и тянет `nimbase.h`; источник правды всё равно `exportc`
  в `examples/embed_lib.nim`, а не сгенерированный файл.

## 5. C-ABI-фасад

Минимальный фасад (полностью — `examples/embed_lib.nim`). Наружу выходят
только POD: числа, указатели и непрозрачный handle; ни `seq`, ни исключений,
ни строк с владением.

| Функция | Смысл | Возврат |
|---|---|---|
| `eutHostVersion()` | версия ядра, тот же источник, что `euterpia --version` | `const char*` |
| `eutHostCreate(sr, blockSize)` | движок + граф osc → gain → mix | handle или `NULL` |
| `eutHostPlay(h)` / `eutHostStop(h)` | команда транспорта | `1` — принята |
| `eutHostRenderBlock(h, out)` | один блок в буфер хоста | пик блока |
| `eutHostCurrentFrame(h)` | позиция транспорта | кадры |
| `eutHostXruns(h)` | сколько блоков потеряно | счётчик |
| `eutHostDestroy(h)` | освобождение всего | — |

Правила фасада (их же требуют §9, §10 и «❌ исключения в realtime» из §90):

- **исключение не пересекает границу.** Nim-исключение сквозь C — UB, поэтому
  на отказ отвечает код возврата/`NULL`;
- **`NULL` — допустимый аргумент.** Любая функция с `h == NULL` возвращает
  нейтральное значение, а не падает: хост может звать `stop`/`destroy` из
  обработчика ошибок;
- **`renderBlock` не выделяет память.** Пишет в буфер вызывающего; всё, что
  нужно блоку, уже в RT-куче движка;
- **handle непрозрачен.** Хост не знает, что внутри: это позволяет менять
  структуру хоста, не ломая ABI.

## 6. Хост на Python (ctypes)

Тот же путь, которым пойдёт игровой движок на C/C++/Rust:

```python
lib = ctypes.CDLL("./build/libeuterpia_embed.so")
lib.eutHostCreate.restype = ctypes.c_void_p
lib.eutHostCreate.argtypes = [ctypes.c_int, ctypes.c_int]
lib.eutHostRenderBlock.restype = ctypes.c_float
lib.eutHostRenderBlock.argtypes = [ctypes.c_void_p,
                                   ctypes.POINTER(ctypes.c_float)]

host = lib.eutHostCreate(48000, 128)
buf = (ctypes.c_float * (128 * 2))()
for _ in range(200):
    lib.eutHostRenderBlock(host, buf)      # здесь стоял бы audio callback
lib.eutHostDestroy(host)
```

`argtypes`/`restype` обязательны: без них ctypes считает `int` и портит
указатели. Полный скрипт с проверками (пик > 0, транспорт двигается) —
`examples/host_ctypes.py`.

## 7. Проверка

| Что | Команда | Джоб CI |
|---|---|---|
| Nim-хост из коробки | `nimble embedExample` | `embed` |
| C-ABI + чужой рантайм | `nimble embedLib` | `embed` |
| ядро не зависит от GUI | `nimble archGuard` | `architecture` |

`embedExample` не просто собирает пример: он рендерит WAV, открывает его
обратно и проверяет частоту, каналы и число кадров — «файл создан» не
считается доказательством. `embedLib` грузит библиотеку из Python, поэтому
протечка GUI, зависимость от argv CLI или потерянный символ видны сразу.

## Границы шага (#213)

- **Есть:** lifecycle движка, публикация графа, команды транспорта, метрики,
  офлайн-рендер, сборка `static`/`dynamic`, C-ABI, пример и CI.
- **Нет (осознанно):** GUI и Editor-API (§90), I/O проекта внутри ядра,
  интерфейс плагинов (это `plugin_api`, #29), а также расширенный Control
  Core (#139/#141) — он вызывается из Nim-хоста напрямую, отдельного
  C-ABI-фасада для команд документа в этот шаг не входит.

