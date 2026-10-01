# EUTERPIA — ядро DAW

Ядро модульного DAW: realtime audio engine, компилятор графа, планировщик
DSP-воркеров, transport, node SDK, встроенные DSP-ноды и хост плагинов CLAP.

Архитектурные правила (границы слоёв, запреты realtime-пути, принципы
заменяемости) описаны в **[MANIFEST.md](MANIFEST.md)** — это основной
документ проекта, а не приложение к коду. Любое изменение ядра сверяется
с §89 («Когда разрешено менять Core») и §103 («Итоговое правило разработки»).

## Структура

```text
core/        — фундамент: runtime, граф, планировщик, память, IPC
commons/     — нейтральные инструменты, не знающие о Core
nodes/       — Node SDK, встроенные ноды, хосты плагинов
adapters/    — адаптеры внешних библиотек (PortAudio, RtMidi)
tests/       — unit-набор DSP/контрактов и интеграционный тест ядра
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
adapters/rtmidi/    — реализация midi_api (librtmidi, dynlib)
adapters/clap/      — CLAP 1.2: ABI, хостинг за plugin_api
adapters/eut/       — собственный ABI EUT-плагинов за plugin_api
adapters/reference/ — эталонный адаптер plugin_api (в памяти, для тестов)
```

Внешние плагины: **только CLAP** (`.clap`). Формат VST не поддерживается
и не планируется (MANIFEST §8, §42).

### `commons/` — нейтральные инструменты

`audio_file_io`, `midi_io` (нейтральный кодек Standard MIDI File),
`undo_redo`, `waveform_cache`. Commons не должен знать о Core — остаточные
отклонения (`audio_file_io` → `wav_codec`/`audio_buffer`) отслеживаются
в issue #5. `midi_io` после развязки (issue #28) Core не знает:
устройства MIDI живут в `adapters/rtmidi` за контрактом `core/midi_api`.

## Сборка и тесты

Требования: **Nim >= 2.0.0** (проверено на 2.2.12).
Внешние библиотеки — опциональные, загружаются в рантайме через `dynlib`:

```text
libportaudio   (аудио-устройства)
librtmidi      (MIDI-устройства)
```

```bash
nimble test           # unit + integration
nimble unit           # только unit-тесты DSP и контрактов
nimble integration    # интеграционный тест ядра
nimble buildRelease   # release-сборка с LTO
```

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

- #4 — метрика `xruns` не доходит до control plane;
- #5 — Commons частично зависит от Core (`audio_file_io` → `wav_codec`);
- #6, #7 — в CLAP-адаптере не реализованы host extensions (params/state/
  gui/thread-check) и трансляция out-events: базовый контракт `plugin_api`
  заполнен, расширения — отдельная задача;
- #8 — нет ресемплинга при несовпадении SR устройства и проекта;
- #9 — `DspScheduler` не умеет менять граф без teardown пула воркеров;
- #10 — FLAC/OGG/MP3/AIFF — заглушки;
- #11 — нет `DEBUG_ASSERT_REALTIME_SAFE`;
- #13 — TSan-прогон есть в CI и блокирует merge; UBSan/ASan ещё нет.

Закрыто в этой линии работ: #2 (`audio_backend_api`), #3 (входной
аудиотракт), #28 (`midi_api`), #29 (`plugin_api`: CLAP/EUT за единым
контрактом), #37 (единый `ring_buffer`), #12/#14 (CI, Logger вместо
`echo`).

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
считаются по сырому входу до нод, входные xrun'ы адаптер сообщает через
`engine.noteInputStatus()`.

## Лицензия

MIT — см. [LICENSE](LICENSE).
