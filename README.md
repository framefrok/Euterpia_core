# EUTERPIA — ядро DAW

Ядро модульного DAW: realtime audio engine, компилятор графа, планировщик
DSP-воркеров, transport, node SDK, встроенные DSP-ноды и хост плагинов CLAP.

Архитектурные правила (границы слоёв, запреты realtime-пути, принципы
заменяемости) описаны в **[MANIFEST.md](MANIFEST.md)** — это основной
документ проекта, а не приложение к коду. Любое изменение ядра сверяется
с §89 («Когда разрешено менять Core») и §103 («Итоговое правило разработки»).

## Статус

Кратко — что уже работает, а что ещё нет (детали в issues).

| Область | Состояние |
|---|---|
| Ядро: runtime, граф, планировщик, память, IPC | ✅ `nimble test` (unit + integration) |
| Realtime-дисциплина | ✅ TSan-джоб (блокирует merge), UBSan и ASan-джобы в CI (#13) |
| Аудио-бэкенды | ✅ PortAudio (`dynlib`) **и** miniaudio 0.11.25 (вендорен, #31) |
| MIDI | ✅ `midi_api` + RtMidi-адаптер, SMF-кодек в Commons |
| Входной тракт и запись | ✅ вход → ноды/рекордер, RT-кольцо → worker → WAV |
| Хостинг плагинов | ✅ `plugin_api` + CLAP 1.2 (host- и plugin-side, сквозной mock-тест, состояние в проекте) + EUT (#6, #53) |
| DSP-ноды | ✅ 9 встроенных (io/input, gain, pan, biquad, svf, delay, compressor, oscillator, noise) + C-ядра с SIMD-дисплеями |
| Кодеки | 🟡 WAV 16/24/32-бит, Standard MIDI File; FLAC/OGG/MP3/AIFF — заглушки (#10) |
| Тесты | ✅ 247 unit-проверок + интеграционный набор; Core/Commons покрыты (#57) |
| CLI / Editor | ❌ точки входа (`cli.nim`, `editor.nim`, `main.nim`) пусты |

## Возможности

Что ядро умеет сегодня:

- **Рендер блока** через граф: монолитный `renderProc` или пошаговые
  `PipelineStep`, мастер-буфер привязывается к драйверному.
- **Компиляция графа**: отказ на циклах, компенсация задержек (PDC),
  арена буферов — одна крупная аллокация на блок, а не сотни мелких.
- **Планировщик**: уровневые задачи по воркерам, готовый `DspTask`-граф
  (постоянный пул воркеров — #9).
- **Память и обмен**: фиксированные пулы с generation-handle против
  ABA/double-free, единое SPSC/MPSC-кольцо, `ipc_bus` для команд и метрик.
- **Транспорт и таймлайн**: play/stop/pause/seek, loop, темп, размер,
  BBT ↔ сэмплы (4/4, 6/8, 3/4, 7/8), секвенсор клипов/автоматизации.
- **Запись**: пре-ролл, сэмпл-точный старт, счётчик потерянных кадров,
  запись в WAV из RT-пути без аллокаций.
- **MIDI**: контракт бэкенда, конвертация MIDI → `RealtimeEvent`,
  нейтральный SMF-кодек без зависимости от Core.
- **Плагины**: `plugin_api` (единый контракт), CLAP 1.2
  (load/enumerate/params/state/latency/audio-ports + host-расширения
  `params|state|gui|thread-check|latency`, `request_callback`), EUT ABI.
- **Два взаимозаменяемых аудио-бэкенда** и `nim check`-проверка всех
  адаптеров в CI.
- **Отсутствие исключений в реальном времени**: адаптеры и ноды возвращают
  коды, `{.raises: [].}` на публичных ABI.

## Структура

```text
core/        — фундамент: runtime, граф, планировщик, память, IPC
commons/     — нейтральные инструменты, не знающие о Core
nodes/       — Node SDK и встроенные DSP-ноды
adapters/    — PortAudio, miniaudio, RtMidi, CLAP, EUT (и эталонный)
tests/       — unit-набор DSP/контрактов, интеграционный тест и mock-плагин CLAP
config.nims  — общие флаги сборки для всех точек входа
MANIFEST.md  — архитектурный манифест
```

### `core/` — фундамент

| Модуль | Ответственность |
|---|---|
| `audio_engine` | рендер блока, apply команд, retirement пайплайнов |
| `graph_compiler` | сборка `CompiledPipeline`, PDC, отказ на циклах |
| `compiled_pipeline` | неизменяемый объект графа: шаги, арены, версия |
| `dsp_scheduler` | уровневый планировщик задач по воркерам |
| `ipc_bus` | MPSC/SPSC очереди поверх `ring_buffer`, `EngineCommand`, `EngineMetric` |
| `ring_buffer` | единое lock-free кольцо SPSC/MPSC (issue #37) |
| `memory_pool` | фиксированные пулы, generation-handle против ABA/double-free |
| `transport`, `sequencer` | таймлайн, клипы, автоматизация |
| `project` | сериализация проекта (не runtime) |
| `audio_recorder` | запись: RT-кольцо → worker thread → WAV |
| `audio_buffer`, `signal_types`, `node_interface` | контракты буферов, событий, нод |
| `param_registry`, `audio_params` | реестр параметров |
| `wav_codec` | WAV read/write |
| `audio_backend_api` | контракт аудио-бэкенда (PortAudio — в `adapters/`) |
| `midi_api`, `midi_events` | контракт MIDI-бэкенда и MIDI → `RealtimeEvent` (issue #28) |
| `plugin_api` | контракт хостинга плагинов: CLAP/EUT/… — в `adapters/` (issue #29) |

### `nodes/` — реализации возможностей

```text
nodes/sdk/            — node_api, node_registry, pipeline_builder, audio_buffers, dsp_units
nodes/builtin/        — io (input), gain, pan, biquad, svf, delay, compressor, oscillator, noise
nodes/builtin/csrc/   — C-ядра DSP, собираются в ABI-совместимые дескрипторы
nodes/metronome.nim, nodes/mixer_console.nim — прикладные узлы
```

Хостинг плагинов живёт НЕ здесь: форматы (CLAP, EUT, в будущем LV2/VST3)
подключаются за контрактом `core/plugin_api` из `adapters/` (issue #29).

### `adapters/` — реализации контрактов Core

```text
adapters/portaudio/ — реализация audio_backend_api (libportaudio, dynlib)
adapters/miniaudio/ — реализация audio_backend_api (miniaudio, вендорен в дерево)
adapters/rtmidi/    — реализация midi_api (librtmidi, dynlib)
adapters/clap/      — CLAP 1.2: ABI, хостинг за plugin_api, host extensions
adapters/eut/       — собственный ABI EUT-плагинов за plugin_api
adapters/reference/ — эталонный адаптер plugin_api (в памяти, для тестов)
```

Два аудио-бэкенда взаимозаменяемы: PortAudio подключается как внешняя
`.so` через `dynlib`, miniaudio (single-header C, 0.11.25) линкуется в
бинарник и не тянет ни одной внешней библиотеки. Core видит только
`AudioBackendApi` и не знает, какой из них выбран (issue #31).

Внешние плагины: **только CLAP** (`.clap`). Формат VST не поддерживается
и не планируется (MANIFEST §8, §42).

### `commons/` — нейтральные инструменты

`audio_file_io`, `midi_io` (нейтральный кодек Standard MIDI File),
`undo_redo`, `waveform_cache`. Commons не должен знать о Core — остаточные
отклонения (`audio_file_io` → `wav_codec`/`audio_buffer`) отслеживаются
в issue #5. `midi_io` после развязки (issue #28) Core не знает:
устройства MIDI живут в `adapters/rtmidi` за контрактом `core/midi_api`.

## План

`[x]` — сделано и лежит в `main`; `[ ]` — открытая задача (номер — issue с
деталями). Внутри блоков порядок приоритетный.

### Закрыто в линии v0.3

- [x] #2 `audio_backend_api` + PortAudio-адаптер
- [x] #3 входной аудиотракт: драйвер → planar-арена → ноды/рекордер
- [x] #28 `midi_api` + `adapters/rtmidi`; Commons развязан от Core
- [x] #29 `plugin_api` — единый контракт хостинга (CLAP/EUT за таблицей методов)
- [x] #31 miniaudio вторым аудио-бэкендом (вендоренный 0.11.25 + C-шим)
- [x] #37 единое SPSC/MPSC-кольцо вместо трёх реализаций
- [x] #6 CLAP host-расширения (`params|state|gui|thread-check|latency`, `request_*`)
- [x] #49 `param*`/`state*`/`latencyFrames` CLAP через `clap_plugin_extensions`
- [x] #58 BBT-конверсия учитывает знаменатель размера (PR #59)
- [x] #61 `audio_recorder`: устаревшая `rcArm` не откатывает `disarm` (PR #62)
- [x] #64 компрессор: кривая gain покрывает весь блок, убран OOB (PR #65)
- [x] #43 инвалидация кэша C-ядер при правке `eut_dsp.h` (хеш заголовка в имени объекта)
- [x] #12 CI-матрица, LICENSE, шаблоны; #14 `Logger` вместо `echo` в Core
- [x] #57 unit-тесты на непокрытые модули (`sequencer`, `project`,
      `param_registry`, `memory_pool`, `logger`, `undo_redo`,
      `waveform_cache`, `audio_file_io`, `transport`)
- [x] #13 UBSan/ASan-цели: `nimble ubsan` / `nimble asan` + одноимённые CI-джобы
- [x] #6 CLAP: host- и plugin-side расширения + сквозной mock-плагин и
      состояние плагина в проекте (`nimble clapMock`, #53)
- [x] TSan-джоб в CI и архитектурные guards (`core` не знает про форматы)
- [x] #7 трансляция событий `EventQueue` ↔ CLAP: out-events, MIDI для
      CC/pitch bend/aftertouch/program change, клампы портов и каналов
- [x] #4 метрика `xruns`: счётчик драйвера → `EngineMetric` (дельта за блок,
      монотонный тотал, битмаск флагов и отдельный счётчик входных xrun'ов)

### Ближайшие шаги

- [ ] #32 backend manager: выбор и hot-swap PortAudio ↔ miniaudio
- [ ] #39 LV2 (Lilv) и #40 VST3 (изолированный C-bridge) за `plugin_api`

### Экосистема и бэкенды

- [ ] #38 libremidi как MIDI-бэкенд (MIDI 1.0 + 2.0/UMP)
- [ ] #8 ресемплинг при несовпадении SR; #10 FLAC/OGG/MP3/AIFF
- [ ] #36 `fft_api`; #35 `stretch_api` (time-stretch / pitch-shift)

### Производительность и надёжность

- [ ] #9 постоянный пул воркеров и двойной буфер расписания
- [ ] #11 `DEBUG_ASSERT_REALTIME_SAFE` — guard на аллокации/локи в audio-потоке
- [ ] #16 gcsafe-аудит audio-пути
- [ ] #5 убрать остаточную зависимость Commons → Core
- [ ] #42 кэш Nim в macOS-джобе
- [ ] #50 расширить architecture-guards на направление зависимостей;
      #52 miniaudio-сборка на Windows/macOS

### Интерфейс

- [ ] #30 каркас Editor на Dear ImGui; #33 векторный рендерер таймлайна
      (Blend2D / NanoVG); #34 Raylib как альтернативный каркас окна

## Потенциал

- **Контракты вместо зависимостей.** `audio_backend_api`, `midi_api`,
  `plugin_api` — таблицы методов, за которыми заменяема любая библиотека.
  Отсюда естественно растут WASAPI/CoreAudio/ALSA/JACK (miniaudio даёт их
  одним заголовком), LV2/VST3 (#39/#40) и внешние плагины без правок Core.
- **Детерминизм как свойство сборки.** `-ffast-math` запрещён, NaN/Inf
  проверяются явно, у C-ядер рядом с SIMD-дисплеями есть скалярный фолбэк —
  это база для воспроизводимого offline-рендера, сравнения сборок и
  headless-рендер-фермы в CI.
- **Realtime-дисциплина подтверждается CI, а не обещаниями:** TSan
  блокирует merge, UBSan/ASan собираются и проходят. Это фундамент низкой
  latency (мониторинг, live) без «магических» отладок в будущем.
- **Примитивы готовы к масштабированию:** арены, пулы с generation-handle и
  единое кольцо — на них ложатся постоянный многопоточный планировщик (#9)
  и изоляция плагина в отдельный процесс (#40) без смены модели памяти.
- **Вендоренный miniaudio — короткий путь к кодекам и SRC:** декодеры
  WAV/FLAC/MP3 и ресемплер уже в дереве, поэтому #10/#8 не требуют новых
  внешних зависимостей (важно для сборки «без сети» и для поставки).
- **Node SDK разделяет descriptor и state** — SDK можно открывать для
  сторонних DSP-нод, не трогая граф и планировщик.
- **Пустые `cli.nim`/`editor.nim` при готовых контрактах** — CLI и редактор
  строятся поверх, ядро при этом не меняется (MANIFEST §89).

## Сборка и тесты

Требования: **Nim >= 2.0.0** (проверено на 2.2.12).
Внешние библиотеки — опциональные, загружаются в рантайме через `dynlib`:

```text
libportaudio   (аудио-устройства, альтернатива miniaudio)
librtmidi      (MIDI-устройства)
```

miniaudio-бэкенд **не требует** внешних библиотек: `miniaudio.h`
(0.11.25) вендорен в `adapters/miniaudio/` и компилируется вместе с
адаптером.

```bash
nimble test            # unit + integration
nimble unit            # только unit-тесты DSP и контрактов
nimble integration     # интеграционный тест ядра
nimble buildRelease    # release-сборка с LTO
nimble miniaudioSmoke  # сборка TU miniaudio + smoke-прогон адаптера (#31)
nimble ubsan           # unit-набор под UndefinedBehaviorSanitizer (#13)
nimble asan            # unit-набор под AddressSanitizer (#13)
nimble clapMock        # сборка mock CLAP-плагина + сквозной тест хостинга (#53)
```

`nimble miniaudioSmoke` — единственная проверка, которая реально собирает
и линкует C-шим miniaudio. Если устройства нет, печатается `SKIP`, но
обязательно проверяется, что отсутствие устройства даёт код ошибки, а не
падение; при наличии устройства проверяются enumeration, open/start/stop
и рост `xrunCount` при искусственной перегрузке.

Бинарники тестов кладутся в `build/` (каталог в `.gitignore`).

## Флаги сборки

Задаются централизованно в `config.nims`, чтобы они были одинаковыми для
unit-, integration- и realtime-тестов:

```text
--mm:orc --threads:on
-fno-strict-aliasing -fno-math-errno
-O3 + -DNDEBUG        (release/danger)
```

`-ffast-math` **не используется никогда**: он разрешает компилятору считать
NaN/Inf невозможными, что срезает защитные проверки в DSP и делает результат
зависимым от порядка векторизации. Для ядра DAW детерминизм важнее скорости.

## Realtime-контракт

Audio-поток не выполняет: аллокаций, блокирующих примитивов, файлового I/O,
логирования, разбора строк/JSON и загрузки динамических библиотек.
Обмен между control- и audio-плоскостями — только через lock-free очереди
`ipc_bus` и предвыделенные пулы `memory_pool` (MANIFEST §9, §10, §43, §44).

## Известные ограничения

Отслеживаются в issues репозитория:

- #5 — Commons частично зависит от Core (`audio_file_io` → `wav_codec`);
- CLAP (#6, #7, #49): host extensions (params/state/gui/thread-check/latency)
  и `request_callback`/`request_restart` реализованы в
  `adapters/clap/clap_host_extensions.nim` и покрыты
  `tests/unit/test_clap_host_extensions.nim`; сквозной путь
  load → instantiate → process → params → state проверяется `nimble
  clapMock` (`tests/mock/mock_clap_plugin.nim` + `tests/clap_mock_test.nim`,
  джоб `clap` в CI), состояние плагина хранится в `core/project.nim`.
  Трансляция событий (#7) — `EventQueue` ↔ CLAP в обе стороны, включая
  MIDI-сообщения для CC/pitch bend/aftertouch/program change; тесты
  `tests/unit/test_clap_events.nim` + сквозные. Прогон официального
  `clap-validator` — ручной: он требует реальных `.clap` и сети и в CI
  невозможен;
- доступ к параметрам/состоянию/latency/аудио-портам ПЛАГИНА
  (plugin-side расширения) реализован в
  `adapters/clap/clap_plugin_extensions.nim` (#49) и покрыт
  `tests/unit/test_clap_plugin_extensions.nim`; дублирующий
  `clap_plugin_host.nim` удалён — в нём было две ошибки ABI
  (`clap_istream`/`clap_ostream` были склеены в одну структуру, поля
  `clap_audio_port_info` переставлены);
- #8 — нет ресемплинга при несовпадении SR устройства и проекта;
- #9 — `DspScheduler` не умеет менять граф без teardown пула воркеров;
- #10 — FLAC/OGG/MP3/AIFF — заглушки;
- #11 — нет `DEBUG_ASSERT_REALTIME_SAFE`;
- у miniaudio 0.11.25 нет публичного статуса драйвера/xrun-счётчика:
  `xrunCount` считается C-шимом как вызов рендера, не уложившийся в
  длительность блока, плюс `interruption_began`, а адаптер превращает
  дельту этого счётчика в `cfg.reportStatus` (issue #31, #4);
- два аудио-бэкенда (PortAudio, miniaudio) пока выбираются вручную:
  manager с hot-swap — issue #32.

Закрыто в этой линии работ: #2 (`audio_backend_api`), #3 (входной
аудиотракт), #28 (`midi_api`), #29 (`plugin_api`: CLAP/EUT за единым
контрактом), #31 (miniaudio-бэкенд), #37 (единый `ring_buffer`),
#12/#14 (CI, Logger вместо `echo`), #57 (тесты непокрытых модулей
Core/Commons), #13 (UBSan/ASan-цели и CI-джобы), #6/#49/#53 (CLAP:
host- и plugin-side расширения, mock-плагин и состояние в проекте),
#7 (трансляция событий EventQueue ↔ CLAP и MIDI-out плагина),
#4 (метрика xruns: счётчик драйвера → EngineMetric).

## Входной тракт

`AudioEngine.renderBlock(engine, driverIn, inputChannels, driverOut)`
раскладывает interleaved-вход драйвера в planar-арену и публикует её в
граф через `NodeProcessContext.input`:

```text
driverIn (interleaved) ──▶ input arena (planar) ──▶ ctx.input
                                                    ├─▶ nodes/builtin/io/input.nim
                                                    └─▶ recorder (TrackInputRouting)
```

Входной поток не отдаёт ноду-источник: `inputChannels == 0` (устройство
без входов или offline-рендер) означает «тишина». Метрики `inputPeakL/R`
считаются по сырому входу до нод.

## Xrun'ы

Xrun'ы драйвера доходят до control-plane (issue #4). Адаптер вызывает
`cfg.reportStatus` из audio callback (обычно это `engine.noteStatus`), а
движок публикует в `EngineMetric`:

- `xruns` — сколько xrun'ов было ЗА ЭТОТ блок (дельта, а не тотал);
- `driverStatusFlags` — накопленный битмаск «какие именно» (бит N ==
  ординал `AudioStreamFlag`: input/output × underflow/overflow) — так
  UI/CLI отличает input-overflow от output-underflow, не зная нативных
  констант драйвера;
- `inputXruns` — отдельный счётчик входных xrun'ов (`noteInputStatus`).

Control-path дополнительно видит `engine.xrunCount()` — монотонный тотал.

Флаги PortAudio (`paInputUnderflow`=0x1 …) уже совпадают с этой битмаской
один в один, а miniaudio-шим отдаёт ординал, который адаптер переводит в
бит. Весь путь — только атомики: в audio-потоке нет локов, аллокаций и
логирования.

## Лицензия

MIT — см. [LICENSE](LICENSE).
