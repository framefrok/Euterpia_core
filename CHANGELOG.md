# Changelog

Все значимые изменения EUTERPIA. Формат — по мотивам
[Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — по
правилам проекта (`docs/versions.md`, MANIFEST §105).

Правило релиза (#113): **у каждого пункта есть ссылка на issue или PR**.
Версия пакета — единственная константа `euterpia_version.nim`, поэтому
`euterpia --version`, поле `version` пакета и имя тега совпадают.

## [0.3.11] — Поставка и полировка (v0.3.11)

### Added
- **`euterpia open` and file associations** (issue #348): a project can be
  opened read-only from the terminal; a bare project path as the first
  argument is treated as `open <path>`. Packages ship `euterpia-open`, which
  changes to the project directory and then runs `euterpia open`, so a click
  on `.eproj`/`.eut` behaves like opening the project in a terminal. Linux
  `.desktop`/MIME and the Windows registry association invoke the helper
  ([#348](https://github.com/framefrok/Euterpia_core/issues/348)).
- **man(1) pages generated from the command specification** (issue #349):
  `euterpia.1` lists every visible command and each command gets
  `euterpia-<command>.1`; `__man --write/--check` materialises and verifies
  the pages, `nimble cliMan` regenerates them, and CI fails when the
  committed `man/` directory is stale or a registry command has no page.
  Completion now also covers **PowerShell** in addition to bash/zsh/fish.
  Manual and completion scripts are installed by `install.sh` and the Windows
  installer ([#349](https://github.com/framefrok/Euterpia_core/issues/349)).
- **Command compatibility policy** (issue #350): `CommandSpec` can declare
  legacy `aliases` (`aliasesDeprecatedSince`) and a deprecated command
  (`deprecatedSince` + `replacedBy`). Aliases execute the canonical command,
  print a warning to **stderr**, appear in `help --json`, and are marked in
  man pages. The first real alias is `inspect` → `analyze`; batch lines and
  `--script` resolve aliases through the same table. The rules — what is
  additive, what requires a schema/format bump, deprecation windows — are in
  `docs/cli-policy.md`
  ([#350](https://github.com/framefrok/Euterpia_core/issues/350)).
- **Executable quick start** (issue #351): `docs/quickstart.md` contains the
  only command block; `tools/quickstart.sh` extracts and executes it
  (template → set list → parameter preset → graph check → render → analyze →
  strict validate), measures the time and fails above five minutes. CI runs
  the same script, and the clean-machine container runs it from the shipped
  documentation with packaged presets
  ([#351](https://github.com/framefrok/Euterpia_core/issues/351)).
- **Delivery payload** (issue #348): archives now include man pages,
  completion scripts, presets under `share/euterpia/presets`, the
  `euterpia-open` helper and `quickstart.md`/`cli-policy.md`; the clean-machine
  job checks `open`, `__man --check`, completion files, presets, the quick
  start and that `play` without an audio device exits with code 2.
- **`open`** is listed as a CLI-only command in the client parity table: in
  the editor a project is already open in a window.

### Changed
- CLI version is `0.3.11`; the release tag `v0.3.11` matches
  `euterpia_version.nim`.

## [0.3.10] — Итеративная работа в терминале (v0.3.10)

### Добавлено
- **`watch` — авто-ререндер при изменении файлов** (issue #344): команда
  держит процесс, ловит правку проекта, `*.notes`/`*.eus` рядом и явных
  `--watch` файлов и перерендеривает в тот же WAV. Дебаунс (`--debounce`) и
  `--min-interval` не дают шторму рендеров; решение принимает `libs/watch`,
  поэтому «две быстрые правки → один рендер» проверяется без сна. Вывод
  пишется атомарно (`<out>.tmp-<pid>.wav` + переименование), Ctrl-C
  завершает цикл без временных файлов, проект не изменяется.
  `--once` — однократный рендер для CI ([#344](https://github.com/framefrok/Euterpia_core/issues/344)).
- **Поток метрик `--metrics`** (issue #345): `render`, `record` и `play`
  печатают NDJSON-снимки (пики/RMS по каналам, латентность блока, xrun'ы,
  состояние транспорта, голоса, входные пики). В `--json` метрики идут в
  stdout отдельными строками, в human — короткой строкой в stderr, поэтому
  stdout остаётся отчётом. Интервал задаёт `--metrics-interval`, режим
  «после события» — `--metrics-event peak|xrun`. Офлайн-рендер отдаёт метрики
  через новый колбэк `OfflineRenderOptions.onChunk`, а `t` считается по
  времени аудио — поток детерминирован
  ([#345](https://github.com/framefrok/Euterpia_core/issues/345)).
- **Интерактивный `analyze`** (issue #346): вердикт (`clean`/`attention`/`fail`)
  печатается первым и совпадает в human, `--json` и HTML; гистограмма
  амплитуд и спектр в логарифмических полосах рисуются в терминале (ASCII без
  TTY, цвет — при TTY), `--html` пишет самодостаточный отчёт со встроенной
  спектрограммой (canvas + base64, без внешних файлов). `--no-terminal`
  отключает графику, `--fail-on` по-прежнему переносит вердикт в код 1
  ([#346](https://github.com/framefrok/Euterpia_core/issues/346)).
- **`doctor --deep`** (issue #347): по запросу проверяет проект — загрузку,
  метаданные, граф с компиляцией, lint и файлы аудиоресурсов на диске; каждая
  проверка имеет id и `elapsedMs` в отчёте и `--json`, у находок есть совет.
  Быстрый `doctor` (без `--deep`) не изменился по времени и содержанию;
  проблема проекта даёт код 1, недоступное окружение — 2. Deep находит то,
  чего не видит `validate`: например, удалённый файл ресурса
  ([#347](https://github.com/framefrok/Euterpia_core/issues/347)).
- **`elapsedMs` в модели проверок** (`cli/checks`): поле есть всегда (0 у
  быстрых команд), поэтому схема `--json` не зависит от режима.

## [0.3.9] — Шаблоны и сет-листы (v0.3.9)

### Добавлено
- **`libs/presets` — заготовки как данные** (issues #341–#343): три формата с
  версией и узнаванием по содержимому — шаблон проекта (`euterpia.preset` v1:
  ноды с параметрами, связи по именам, дорожки и необязательная партитура),
  сет-лист (`euterpia.setlist` v1: состав пьесы поверх шаблона) и пресет
  параметров (`euterpia.param-preset` v1: тип/роль → значения). Проверка идёт
  по реестру нод **до** применения: неизвестный тип — код `not_found`,
  параметр вне диапазона — `invalid_argument`, шаблон без однозначного
  мастер-выхода отвергается, а не рендерится тишиной
  ([#341](https://github.com/framefrok/Euterpia_core/issues/341)).
- **`init --preset`, `preset list/show/apply`** (issue #341): стартовый проект
  по шаблону собирается тем же путём, что `script build` (#416) — второго
  способа сборки нет. `init --preset band` даёт проект, проходящий `graph
  check` без правок; применение к существующему проекту — одна транзакция:
  отказ не оставляет следов, `euterpia undo` отменяет её целиком. id новых
  нод сдвигаются за последний занятый, дорожки добавляются после существующих.
- **`setlist list/show/apply`** (issue #342): пьеса собирается сет-листом с
  нуля (шаблон + партии одним сценарием) или обновляется транзакцией: партия
  существующей дорожки получает `clip.set`, а не второй клип. Сведение —
  параметры голоса (`level`, `pan`), проверенные по типу; состав пьесы
  печатается и в human, и в `--json`.
- **`preset param list/show/apply`** (issue #343): пресет применяется к нодам
  по типу и (необязательно) роли; несовместимый тип отвергается целиком, а
  отчёт перечисляет изменённое, совпавшее (не тронуто) и не попавшее под роль.
- **Заготовки в репозитории**: `presets/templates/band.preset.json`,
  `presets/setlists/punk-demo.setlist.json`, `presets/params/` (`cello-warm`,
  `piano-bright`, `bass-sub`). Они версионируются вместе с типами нод, а
  `EUTERPIA_PRESETS` добавляет внешний каталог поиска.
- **Исправление `libs/script`**: подстановка переменных падала assertion'ом на
  любом массиве внутри команды (`pairs` у `JsonNode` определён только для
  объектов), поэтому `clip.set` с нотами нельзя было записать сценарием.
  Теперь массивы обходятся `items` с явным индексом, регрессия покрыта тестом.

## [0.3.8] — Сравнение и проверки (v0.3.8)

### Добавлено
- **`libs/diff` — сравнение проектов и рендеров** (issue #337): структурное
  сравнение документов по каноническому JSON формата. Сущности опознаются по
  `id`, поэтому перестановка ключей и порядка нод различием не считается, а
  изменение одной величины даёт ровно одно различие с адресом
  (`node:1.parameters.freq`, `track:1/clip:7/note:0:60:0.velocity`,
  `connection:1.a0->2.a0`, `lane:2:11/point:0.value`, `pluginState:2.state`).
  Рендеры сравниваются числом: пик, RMS, DC, спектральный центроид и доли трёх
  полос, плюс поштучное расхождение сэмплов, максимальная дельта и кадр
  первого расхождения. Отчёт — человеческий текст и `--json` с форматом
  `euterpia.diff` v1
  ([#337](https://github.com/framefrok/Euterpia_core/issues/337)).
- **`project diff` и `render diff`** (issue #338): команды сравнения с
  осмысленным кодом возврата. По умолчанию 0 в обоих случаях (вопрос, а не
  вердикт), `--exit-code` — различия дают код 1 (гейт для CI), нечитаемый
  файл — код 2 с причиной в `error`, а не «различий нет»
  ([#338](https://github.com/framefrok/Euterpia_core/issues/338)).
- **`project validate --strict`** (issue #339): строгий lint — висячие ссылки
  (клип → ресурс, линия → нода и параметр), дубли идентификаторов (клипы,
  ресурсы, линии, связи), значения вне диапазона (уровень, панорама, нота за
  границей клипа), неиспользуемое (нода без связей, дорожка без клипов, ресурс
  без ссылок) и незарегистрированные типы. Новый уровень `note` («на заметку»)
  в отчётах: `fail`/`warn`/`note` различаются и в сводке, и в `--json`;
  код возврата меняет только `fail`. Циклы графа не дублируются — их находит
  компилятор в `graph check`
  ([#339](https://github.com/framefrok/Euterpia_core/issues/339)).
- **`ci check` — единый вход для проверки проекта в CI** (issue #340):
  validate → graph check → render → analyze по порядку, остановка на первом
  провале, код возврата упавшего шага (1 — данные, 2 — среда, 3 — баг). Вывод
  шагов сохраняется в отчёте и при провале (`steps[].lines` в `--json`,
  `failedStep` называет виновника). `--strict` включает lint и порог
  инспектора `warn`; `--fast` оставляет только validate и graph; `--seconds`
  ограничивает фрагмент рендера (по умолчанию 1 с), `--out` задаёт файл
  ([#340](https://github.com/framefrok/Euterpia_core/issues/340)).
- **Query API: ресурсы и ссылка клипа** (issue #339): `queryResources` и
  `ClipInfo.resourceId` — валидатору и клиентам не нужно открывать формат
  руками, чтобы найти висячую ссылку клипа на отсутствующий аудиоресурс.
- **`script build` — пересборка проекта из сценария** (issue #416): сборка
  «с нуля» — содержимое заменяется, метаданные берутся из `--base`/текущего
  файла/умолчаний `init`. Существующий проект перезаписывается только с
  `--force`, прежняя версия остаётся в `.bak`, история архивируется в
  `.history.bak` (документ заменён — прежний стек отмены к нему не относится).
  Сборка детерминирована: две сборки из одного сценария и одной базы дают
  побайтово тот же файл. `plan --build` показывает сборку, не трогая диск
  ([#416](https://github.com/framefrok/Euterpia_core/issues/416)).
- **Предохранитель потерь при сборке**: если в проекте есть `resources`,
  `pluginStates` или `automationLanes` (сценарий их пока не выражает),
  `build` отказывает со списком; `--allow-loss` — осознанное согласие, и
  потерянное перечисляется в отчёте (`lost` в `--json`)
  ([#416](https://github.com/framefrok/Euterpia_core/issues/416)).
- **Подсказка в отказе `script run`**: «уже есть» теперь ведёт к
  `script build … --force`, а не оставляет удалять проект руками
  ([#416](https://github.com/framefrok/Euterpia_core/issues/416)).

### Исправлено
- **`init --force` оставлял чужую историю** (issue #331, #416): перезапись
  проекта архивирует `<проект>.history` в `<проект>.history.bak`, поэтому
  `undo` после перезаписи не применяет обратные команды от старого документа.

## [0.3.7] — Сценарии (v0.3.7)

### Добавлено
- **`libs/script` — сценарий как файл** (issue #333): формат
  `euterpia.script` v1 хранит команды control-слоя, описание, базовый
  документ и переменные. `parseScript`/`encodeScript` дают каноническую
  запись, версия формата проверяется (сценарий новее сборки отвергается с
  подсказкой), неизвестная команда и неизвестная переменная называются с
  номером и адресом места. Переменные подставляются **с типом**: строка
  ровно из `"${freq}"` заменяется числом, а не текстом
  ([#333](https://github.com/framefrok/Euterpia_core/issues/333)).
- **`script run|plan|show|record|render`** (issue #333, #335): `plan`
  принимает документ по значению и потому не может ничего записать; `run`
  применяет сценарий одной транзакцией и пишет запись истории, поэтому
  `undo` отменяет сценарий целиком; `record` собирает сценарий из истории
  проекта, а не из вывода терминала; `show` печатает содержимое, ничего не
  исполняя ([#333](https://github.com/framefrok/Euterpia_core/issues/333)).
- **Пакетный режим, stdin и REPL** (issue #334, #97): `--script <файл|->`,
  `--keep-going`, строки-команды в одном процессе с `open`/`save`/
  `save-as`/`status`, приглашение REPL в stderr и завершение по Ctrl-D.
  В `--json` каждая команда даёт отдельную строку (NDJSON), итог —
  последняя; ошибка называет номер строки; оболочка не вызывается никогда
  ([#334](https://github.com/framefrok/Euterpia_core/issues/334),
  [#97](https://github.com/framefrok/Euterpia_core/issues/97)).
- **Сценарий как тест** (issue #335): `script render` рендерит проект со
  сценарием в памяти тем же путём, что `render`, и сверяет результат с
  эталоном — кадры, частота, биты, пик, RMS, SHA-1 файла и текста сценария,
  при `--samples` ещё и SHA-1 сэмплов. Обновление эталона — отдельная
  команда `--update-baseline`, которая печатает, что изменилось;
  golden-прогон исполняется в CI (`tools/script_scenario.sh`,
  `nimble scriptScenario`) ([#335](https://github.com/framefrok/Euterpia_core/issues/335)).

### Изменено
- **Разбор argv вынесен в `cli/dispatch.nim`**: одна команда, строка
  сценария и REPL используют один и тот же разбор и одно правило «проект
  сессии подставляется, только если команда его не назвала».
- **`openDocumentAt`** (`cli/control_bridge`): часы документа внедряются
  явно. Сценарий получает отметку из поля `stamp` или прежнюю отметку
  проекта, поэтому повтор сценария даёт побайтово тот же документ.
- **`renderPreparedProject`** (`cli/cmd_render`): рендер проекта, уже
  находящегося в памяти, — без промежуточного файла и без второй ветки
  рендера.

## [0.3.6] — Единый контракт (v0.3.6)

### Добавлено
- **`libs/cli_spec` — описание команды данными** (issue #330): имя,
  синопсис, аргументы, ключи с типами значений и умолчаниями, пример и поля
  ответа `--json`. Из одной спецификации собираются `--help`, `help --json`,
  автодополнение (`__complete`) и раздел `docs/cli.md`; `validateSpecs`
  находит неполные описания, а CI сверяет раздел байт-в-байт
  ([#330](https://github.com/framefrok/Euterpia_core/issues/330)).
- **История правок в CLI** (issue #331): `undo`, `redo`, `history` поверх
  истории control-слоя; стек лежит сайдкаром `<проект>.history` и переживает
  перезапуск процесса
  ([#331](https://github.com/framefrok/Euterpia_core/issues/331)).
- **Единые коды ошибок** (issue #332): таблица «причина → код возврата»
  данными (`cli/exit_codes.nim`), `errorCode` в каждом отказе `--json`,
  публикация в `help --json` и `docs/cli.md`; причина без строки в таблице
  роняет CI ([#332](https://github.com/framefrok/Euterpia_core/issues/332)).

### Изменено
- **Чтение модели через Query API** (issue #336): `node list/show`,
  `param list/get/set` и `project show` работают с DTO, а не с
  `ProjectFormat`; обход коллекций документа запрещён guard'ом
  (`nimble archGuard`)
  ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- **`.eproj` — основное расширение, `.eut` — историческое** (issue #370):
  список расширений один на все команды
  ([#370](https://github.com/framefrok/Euterpia_core/issues/370)).

## [0.3.5] — Функциональность P3 и полировка (v0.3.5)

### Добавлено
- **Ресемплинг «устройство ↔ проект»** (issue #8): контракт
  `core/src_api`, polyphase-sinc адаптер `adapters/resample` и мост в
  live-пути — проект 44.1 кГц играет в темпе на устройстве 48 кГц и
  наоборот. Очереди предвыделены, `process` без аллокаций; задержка моста
  входит в отчёт (`resamplerLatency`), транспорт идёт со скоростью проекта
  ([#8](https://github.com/framefrok/Euterpia_core/issues/8)).
- **UMP / MIDI 2.0** (issue #38): `core/ump.nim` разбирает MT 0x0/0x2/0x4,
  собирает MIDI 1.0 → UMP и сводит 16/32-битные значения к MIDI 1.0 с
  документированной потерей; `adapters/libremidi` реализует `midi_api` через
  C-фасад с ленивой загрузкой и graceful degrade. RtMidi-адаптер сохранён
  как альтернатива (решение зафиксировано в README адаптера)
  ([#38](https://github.com/framefrok/Euterpia_core/issues/38)).
- **LV2 через Lilv** (issue #39): `adapters/lilv` за `plugin_api` —
  перечисление плагинов бандла, инстанс, аудио/control-порты, параметры и
  latency-порт (идёт в PDC). Lazy-dynlib: нет liblilv — `peUnavailable`.
  Atom/MIDI-порты и состояние LV2 не поддержаны и честно отказывают
  ([#39](https://github.com/framefrok/Euterpia_core/issues/39)).
- **Живой MIDI-вход и продюсер автоматизации** (issue #413):
  `AudioEngine.postMidiEventAtFrame` (SPSC, без аллокаций) доставляет
  события в event-вход выбранной ноды; события вне блока считаются
  `midiLate`, переполнение — `midiDropped`. `play --midi-in 0
  --midi-target 3` играет с порта, автоматизация проекта применяется на
  границе блока (`postLiveAutomation`, двойной буфер) — те же тики, что у
  офлайн-рендера ([#413](https://github.com/framefrok/Euterpia_core/issues/413)).
- **FLAC-lossless и lossy-превью сдачи** (issue #411): встроенный
  FLAC-энкодер (VERBATIM-кадры, CRC-8/CRC-16, точный total_samples),
  round-trip ≤ 1 LSB и `flac -t`; `master --format flac|ogg|mp3`,
  `--preview-bitrate`, поля манифеста `codec`/`lossless`/`role`/`bitrate`.
  OGG/MP3 — превью через `ffmpeg`/`lame`/`oggenc`; нет инструмента — код 2
  ([#411](https://github.com/framefrok/Euterpia_core/issues/411)).
- **Плагины в CLI** (issue #95): `plugin scan/info/params/save`, хостинг
  `plugin:<id>` в графе (osc → плагин → мастер), `node add
  plugin:<id> --path <файл.clap>`, состояние плагина в проекте и его
  восстановление при render/play/record. Сквозной сценарий на mock-плагине
  исполняется в CI (`tools/plugin_cli_scenario.sh`)
  ([#95](https://github.com/framefrok/Euterpia_core/issues/95)).
- **`plugin validate`** (issue #260): честная обёртка официального
  `clap-validator` — поиск `--validator` → `PATH`, человеко- и
  машиночитаемый вывод проверок, коды 0/1/2; нет валидатора — код 2 с
  подсказкой установки ([#260](https://github.com/framefrok/Euterpia_core/issues/260)).
- **Поставка** (issue #229): архивы Linux/Windows/macOS, `install.sh` /
  `install.ps1` с ассоциациями `*.eproj`/`*.eut` (freedesktop MIME, HKCU,
  `CFBundleDocumentTypes`), SHA256, workflow `Release` по тегу и CI-джоб
  `package`, который запускает собранный пакет в `ubuntu:24.04` без Nim
  ([#229](https://github.com/framefrok/Euterpia_core/issues/229)).

### Исправлено
- **PDC зануляла ветвь с задержкой**: анализ времён жизни буферов вправе
  переиспользовать входной буфер PDC-ноды под её выход; прежний порядок
  «записать выход, затем прочитать вход» записывал в кольцо уже нули, и
  первый же плагин с `latency > 0` давал тишину. Вход читается до записи
  выхода; регрессия покрыта тестом `test_pdc` (аудит P3).
- **`play` без `--midi-in` не меняет поведение**: ресемплинг включается
  только при реальном расхождении частот, `--src off` возвращает прежний
  путь; автоматизация без линий ничего не публикует.

### Изменено
- **`midi_api` расширен UMP** (`enableUmp`/`pollUmp`, опциональные поля
  таблицы): RtMidi-адаптер продолжает работать без изменений.
- **`PipelineStep.nodeId` и `EditorNode.sourceId`**: шаг пайплайна знает id
  ноды проекта, хотя `flattenGraph` переприсваивает внутренние id — без
  этого внешнее событие нельзя адресовать конкретной ноде.
- **`loadScene` принимает хук состояния плагина**: Nodes по-прежнему не
  знают форматов плагинов, байты восстанавливает хост (§27).

### Ограничения шага (зафиксированы, а не замалчиваются)
- **libremidi и Lilv не вендорены**: адаптеры компилируются и честно
  деградируют, но для реального хостинга нужна установленная библиотека
  (инструкция — `adapters/libremidi/README.md`). Это осознанно: тащить в
  репозиторий C++-код и C-зависимости без воспроизводимой сборки хуже, чем
  явная зависимость.
- **LV2 Atom/MIDI и состояние**: не поддержаны, `stateSave` возвращает -1;
  плагины с обязательными atom-портами могут давать тишину — ограничение
  адаптера, а не Core.
- **FLAC-энкодер без предсказания**: файл больше, чем у libFLAC (VERBATIM),
  но lossless и читается `flac -t`; предсказание — отдельный шаг.
- **Поставка**: нет подписи кода и `.deb`/`.rpm`/MSI; macOS-архив — под
  архитектуру раннера (`docs/delivery.md`).

## [0.3.4] — Функциональность P2 (v0.3.4)

### Добавлено
- **`render --stems` и `--batch`** (issue #108): по WAV на дорожку с
  `--name-template` (`{track}`, `{name}`, `{index}`), учёт mute/solo и
  ненулевой код, если хоть один стем упал; батч идёт по списку проектов
  последовательно (`--out` — каталог), сцена и движок освобождаются после
  каждого, поэтому RSS не растёт. Сумма стемов совпадает с мастером
  побитово (проверено тестом на 16-битном WAV)
  ([#108](https://github.com/framefrok/Euterpia_core/issues/108)).
- **`midi list` и `midi monitor`** (issue #93): порты входа/выхода из
  RtMidi-адаптера, NDJSON-поток событий, фильтры `--channel`/`--only`,
  относительное время от открытия порта; нет librtmidi — пустой список и
  код 0, а не падение
  ([#93](https://github.com/framefrok/Euterpia_core/issues/93)).
- **`record`** (issue #94): запись входа в WAV через живой сеанс
  (miniaudio), `--channels 1|2`, `--input-channel`, `--input-device`,
  метрики `inputPeakL/R`, `inputXruns`, `droppedFrames`, корректный
  SIGINT и `count-in` через метроном
  ([#94](https://github.com/framefrok/Euterpia_core/issues/94)).
- **`midi import`** (issue #111): SMF → клипы проекта, пересчёт PPQ в 960,
  первый темп и размер переносятся в проект, `--track`/`--map SMF:проект`,
  round-trip импорт → экспорт → импорт; CC/PB/aftertouch/program не входят
  в формат клипа и считаются в `ignoredEvents`, SMPTE/format 2/несколько
  темпов отвергаются явно
  ([#111](https://github.com/framefrok/Euterpia_core/issues/111)).
- **Метроном** (issue #112): нода `euterpia.metronome` (`enabled`,
  `sound`, `accent`, `normal`), клик по сетке транспорта для 4/4, 3/4,
  6/8, 5/4, команда `metronome on|off`, `record --count-in N`
  ([#112](https://github.com/framefrok/Euterpia_core/issues/112)).
- **`automation list|add|rm|clear`** (issue #114): точки линий в тиках и
  единицах параметра, все четыре кривые, замена точки на том же тике,
  лимит 1024; рендер применяет линии на границе чанка, поэтому
  огибающая слышна и измерима
  ([#114](https://github.com/framefrok/Euterpia_core/issues/114)).
- **`project recover` и автосохранение сессии** (issue #110):
  `session start --autosave N` перечитывает проект каждые N секунд и
  пишет снимки через `core/autosave`; SIGKILL оставляет маркер, `project
  recover` восстанавливает последний снимок, делает `.bak` и снимает
  маркер; `--list`/`--from` дают выбор
  ([#110](https://github.com/framefrok/Euterpia_core/issues/110)).
- **Ленивая загрузка dynlib-адаптеров** (issue #267): PortAudio и RtMidi
  грузятся в `backendInit`/`midiInit`, а не в инициализации модуля;
  отсутствие библиотеки — `abeUnavailable`/`meUnavailable`, а не падение
  до `main()`. Имя библиотеки переопределяется
  `EUTERPIA_PORTAUDIO_LIB`/`EUTERPIA_RTMIDI_LIB` для проверки ветки
  «библиотеки нет»
  ([#267](https://github.com/framefrok/Euterpia_core/issues/267)).

### Исправлено
- **Метроном писал за границу planar-буфера**: `writeFrame` считал любой
  буфер interleaved; при подключении к выходу движка это давало SIGSEGV
  на первом клике. Раскладка (`layout`) теперь учитывается.
- **`AudioRecorder` получил in-place инициализацию**: копирование
  значения с уже запущенным `Thread` давало падение worker-потока; хост
  (`record`) создаёт рекордер на месте, возвращающий вариант остался для
  тестов.

### Изменено
- **CLI читает проект через Query API**: `metronome`, `automation` и
  `project recover` не обходят модель; исключения guard'а описаны
  поимённо (`tools/check_architecture.py`).

### Перенесено в v0.3.5
- Адаптерные задачи, требующие вендоренных библиотек или нового поля
  формата проекта: LV2 (#39), libremidi/MIDI 2.0 (#38), ресемплинг (#8),
  кодировщики FLAC/OGG/MP3 (#411) и полный plugin-хост CLI (#95).
  Причина и объём зафиксированы в комментариях к issues; P2-функции CLI
  этого шага закрыты.

Версия пакета — `0.3.4` (релиз).


### Добавлено
- **Нода `euterpia.sequencer`** (issue #87): клипы и дорожки проекта играет
  `SequencerRuntime.processBlock` — без переупаковки в паттерны
  `euterpia.notes`. Позиция блока считается из `ctx.samplePosition` и темпа,
  смещение корректируется на долю тика, поэтому атаки sample-accurate;
  `setCompiledSequencer` привязывает компиляцию на control-path, переполнение
  очереди считается (`droppedEvents`), loop-клипы и mute дорожек работают
  ([#87](https://github.com/framefrok/Euterpia_core/issues/87)).
- **`euterpia device list` и `euterpia play`** (issue #92): живое
  воспроизведение проекта через `backend_manager` (miniaudio) с метриками
  `peak/RMS/xruns/graphVersion/BBT`, NDJSON-потоком в `--json`, ограничением
  `--seconds` и корректным завершением по SIGINT/SIGTERM. Без устройства —
  код 2 и понятное сообщение, а не паника
  ([#92](https://github.com/framefrok/Euterpia_core/issues/92)).
- **Неблокирующее автосохранение** (issue #147): `core/autosave` держит
  writer thread и очередь «версия → снимок», пишет атомарно
  (`.tmp` + rename), ротирует каталог, ведёт маркер незакрытой сессии и
  восстанавливает последний валидный снимок. Политика — интервал ИЛИ число
  правок; снимок не перезаписывает файл пользователя, битый снимок не
  блокирует старт ([#147](https://github.com/framefrok/Euterpia_core/issues/147)).
- **`euterpia master` — сдача материала** (issue #209): LUFS
  (интегрированная/short-term), LRA и true peak ×4 oversampling по
  BS.1770/EBU R128; нормализация к цели с lookahead-лимитером; `--stems` по
  дорожкам с покадровым усилением мастера (сумма стемов сходится к мастеру);
  метаданные RIFF `LIST/INFO`; манифест с SHA-1 файлов; отчёт о том, что
  получилось ([#209](https://github.com/framefrok/Euterpia_core/issues/209)).
- **TPDF-dither и 32-битный PCM** (issue #209): детерминированный dither при
  записи в 16/24 бита, `render --bits 32` — промежуточный файл мастера без
  второго шума квантования, `render --solo-track` — стем дорожки
  ([#209](https://github.com/framefrok/Euterpia_core/issues/209)).
- **Headless runtime-сессия** (`euterpia session start|stop|status`, issue
  #407): долгоживущий процесс-демон владеет `AudioEngine`, CLI общается с ним
  по Unix-socket. `transport play` в одном запуске виден `transport state` в
  другом, позиция идёт по стенным часам, `session stop` закрывает движок и
  записывает финальное состояние в offline-сессию
  ([#407](https://github.com/framefrok/Euterpia_core/issues/407)).
- **`OwnedPipeline`/`BorrowedPipeline`** (issue #402): владение пайплайном
  выражено move-only типом; передача — `sink`, повторная передача или
  двойное освобождение отвергаются API, а не обычаем
  ([#402](https://github.com/framefrok/Euterpia_core/issues/402)).
- **Порты субграфов и namespace `(scopeId, localId)`** (issue #403): два
  вложенных субграфа с одинаковыми локальными id больше не collide; внешние
  связи разрешаются через `subgraphInputs`/`subgraphOutputs`, неразрешимая
  связь — ошибка компиляции `cekInvalidSubgraphPort`
  ([#403](https://github.com/framefrok/Euterpia_core/issues/403)).

### Изменено
- **`EventQueue` держит порядок сам** (issue #397): `pushEvent` вставляет по
  `frameOffset`/`subFrame`, `finalizeEvents` — единая точка подготовки
  очереди. Забытый `sortEvents` больше не даёт тихую неверную обработку
  ([#397](https://github.com/framefrok/Euterpia_core/issues/397)).
- **Модель каналов зафиксирована как стерео** (issue #401): один источник
  `MaxAudioChannels`, нода с `maxChannels > 2` отвергается `validateChannelModel`
  и вердиктом `graph check` `unsupportedChannels`
  ([#401](https://github.com/framefrok/Euterpia_core/issues/401)).
- **Оркестратор/параметры: удалены вторые системы** (issue #396):
  `core/dsp_scheduler.nim`, `core/param_registry.nim` и `core/audio_params.nim`
  удалены как неинтегрированные в `AudioEngine`; тесты и CI-проверки,
  ссылавшиеся на них, убраны. WAV-писатель остаётся один — `wav_codec`
  (рекордер использует его с #356)
  ([#396](https://github.com/framefrok/Euterpia_core/issues/396)).
- **`setFixed` больше не оставляет битый UTF-8** (issue #398): обрезка идёт
  по последней ЦЕЛОЙ последовательности, включая проверку overlong-форм и
  суррогатов; `readFixed` всегда декодируется
  ([#398](https://github.com/framefrok/Euterpia_core/issues/398)).
- **`project validate` проверяет порт в namespace своего сигнала** (issue
  #399): audio/control/event — разные пространства индексов; `sigAudio` на
  control-порт и индекс вне счётчика своего вида — ошибка данных
  ([#399](https://github.com/framefrok/Euterpia_core/issues/399)).
- **Сборка без `-fno-strict-aliasing`** (issue #400): флаг убран; unit,
  integration, CLI и ASan/UBSan проходят без него
  ([#400](https://github.com/framefrok/Euterpia_core/issues/400)).
- **Лимиты компилятора графа** (issue #404): `MaxSubgraphDepth`,
  `MaxFlattenedNodes`, `MaxGraphConnections`, бюджет памяти PDC. Превышение —
  ошибка компиляции/вердикт `graph check`, а не stack overflow или OOM
  ([#404](https://github.com/framefrok/Euterpia_core/issues/404)).
- **Latency-арифметика без `uint32`-wrap** (issue #405): сумма в `uint64`,
  предел `MaxLatencyFrames`, насыщение при разборе проекта; превышение —
  `cekLatencyOverflow`
  ([#405](https://github.com/framefrok/Euterpia_core/issues/405)).
- **#406 закрыт удалением orphan-планировщика**: destructive API
  `deinitScheduler`, который мог уничтожить состояние во время рендера,
  больше не существует; вместе с #396 удалён и сам модуль
  ([#406](https://github.com/framefrok/Euterpia_core/issues/406)).


Версия пакета — `0.3.3` (релиз). Шаг линии **v0.3.3** («функциональность
P1») закрыт (см. `docs/versions.md` §1 — версия растёт на последнем закрытом
шаге).

### Добавлено
- `import` — **импорт аудиофайла в проект** как audio-клипа трека (issue #107):
  читает заголовок через кодек ядра (WAV 16/24/32-bit, моно/стерео), создаёт
  аудиоресурс и клип на дорожке, печатает отчёт (`--json`: кадры, каналы, SR,
  длительность, ресурс, клип). `--copy` копирует файл рядом с проектом; иначе
  хранится ссылка. SR файла ≠ SR проекта — явная ошибка (ресемплинг — #8), а не
  молчаливое ускорение
  ([#107](https://github.com/framefrok/Euterpia_core/issues/107)).
- Формат проекта — **версия 2**: секция `resources` (аудиоресурсы) и поля
  `clip.resourceId`/`clip.offsetFrames`. Сэмплы в проект не встраиваются
  (ссылочная модель, §58); старые проекты v1 читаются без миграции — секция
  просто пуста, а не «неизвестная версия»
  ([#107](https://github.com/framefrok/Euterpia_core/issues/107)).
- Нода **`euterpia.clip`** — плеер аудиоклипов (issue #107): `scene_loader`
  читает аудиоресурсы проекта, привязывает сэмплы к нодам-плеерам (дорожка с
  аудиоклипами → нода, как у `euterpia.notes`), а нода выдаёт звук
  sample-accurate: окно клипа переведено в СЭМПЛЫ, поэтому выборка из ресурса —
  целочисленная. `render` проекта с аудиоклипом воспроизводит файл в пределах
  квантования 16-бит
  ([#107](https://github.com/framefrok/Euterpia_core/issues/107)).
- `undo`, `redo` и `history` — **история правок CLI** (issue #331): отмена и
  повтор последней операции поверх истории control-слоя (#109), список записей
  и текущих глубин стеков. Обратные команды строит `planTransaction`, поэтому
  откат идёт тем же путём, что и обычная правка (нода возвращается вместе со
  связями, автоматизацией и состояниями плагинов)
  ([#331](https://github.com/framefrok/Euterpia_core/issues/331)).
- История **переживает перезапуск процесса**: стек записей лежит сайдкаром
  рядом с проектом (`<проект>.history`, `cli/history_file.nim`, версия формата
  1), потому что CLI — процесс на одну команду. Формат записи берётся у ядра
  (`encodeEntry`/`decodeEntry`), клиент его не дублирует
  ([#331](https://github.com/framefrok/Euterpia_core/issues/331)).
- Изменяющие команды CLI (`node add`/`rm`, `connect`, `disconnect`, `param set`)
  пишут запись истории вместе с проектом; чтение историю не трогает; новая
  правка сбрасывает повтор, как в Commons
  ([#331](https://github.com/framefrok/Euterpia_core/issues/331)).
- Паритет клиентов (#148): действия `edit.undo`, `edit.redo` и
  `view.history` в перечне «действие интерфейса = команда», строки в
  `docs/clients.md`; пара «отменять нечего» и битый/чужой файл истории дают
  документированный код возврата
  ([#331](https://github.com/framefrok/Euterpia_core/issues/331)).
- `cli/exit_codes.nim` — таблица **«причина → код возврата» данными**
  (issue #332): одна строка на каждую причину `ErrorCode` с кодом возврата и
  объяснением. Из неё берут код возврата и кадры ядра (`frameReport`), и
  ошибки самого CLI; `exitRulesProblems` проверяет полноту, а CI-тест
  перебирает `ErrorCode.low..high` — причина без строки роняет сборку, а не
  получает «код по умолчанию» незаметно
  ([#332](https://github.com/framefrok/Euterpia_core/issues/332)).
- В ядре две новые причины: `ecEnvironment` (нет файла, каталога, прав или
  устройства — данные верны, окружение не позволяет) и `ecCheckFailed`
  (вердикт проверки отрицательный: невалидный проект, не компилирующийся
  граф, дефекты аудио выше порога)
  ([#332](https://github.com/framefrok/Euterpia_core/issues/332)).
- `help --json` печатает `errorReasons` — таблицу «причина → код возврата»
  машинно (`name`, `number`, `exit`, `meaning`), и `exitCodeProblems` —
  проверку самой таблицы
  ([#332](https://github.com/framefrok/Euterpia_core/issues/332)).
- В `docs/cli.md` таблица кодов ошибок **генерируется** вместе со справочником
  команд: документация не может разойтись с кодом
  ([#332](https://github.com/framefrok/Euterpia_core/issues/332)).

### Изменено
- Все команды отдают `errorCode` при отказе: раньше ошибки самого CLI
  (`euterpia nonsense`, лишний аргумент) печатали `errorCode: 0`, и агент не
  мог отличить их от «нет ошибки», а теперь причина всегда есть — `usage` от
  `env` отличается не текстом, а числом и кодом возврата
  ([#332](https://github.com/framefrok/Euterpia_core/issues/332)).
- Отказы CLI называют конкретную причину: неверный вызов — `ecInvalidArgument`,
  нет узла/файла — `ecNotFound`, недоступный файл, каталог или устройство —
  `ecEnvironment`, провал `project validate`/`graph check`/`analyze --fail-on`
  — `ecCheckFailed`, баг — `ecInternal`. Класс ответа (`error.kind`:
  `usage`/`env`/`io`/`defects`/`panic`) и коды 0/1/2/3 не изменились
  ([#332](https://github.com/framefrok/Euterpia_core/issues/332)).
- Query API: DTO метаданных (`queryMetadata`), автоматизации
  (`queryAutomationLanes`) и состояний плагинов (`queryPluginStates`), а в
  сводке — `pluginStateBytes`: клиенту больше не нужно обходить формат, чтобы
  показать темп, дорожки автоматизации и объём состояний
  ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- `queryParam` разбирает **адрес параметра** (`node:1.1/param:1`): путь в
  чужую ноду — отказ с подсказкой «адрес параметра должен принадлежать
  указанной ноде», путь в другую сущность — «здесь нужен параметр». Разбор
  живёт в ядре, поэтому CLI и Editor отвечают одинаково
  ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- `euterpia node list`: `--filter <текст>`, `--type <id>`, `--limit <N>` и
  `--offset <N>` — фильтр и окно считает ядро, а отчёт добавляет поля
  `window` (`offset`/`limit`/`total`/`shown`); проект на 1000 нод не
  пересылается целиком ради двадцати строк
  ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- Guard архитектуры: `tools/check_architecture.py` запрещает CLI обращаться к
  коллекциям документа (`graph.nodes`, `graph.connections`,
  `sequencer.tracks`, `sequencer.automationLanes`, `pluginStates`, `metadata`).
  Исключения перечислены поимённо в самой проверке — только валидаторы
  целостности (`project validate`, `graph check`) и пути записи
  ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).

### Изменено
- CLI читает модель через Query API: `node list/show`, `param list/get/set`,
  `connect`/`disconnect` и `project show` получают DTO, а не ходят по
  `ProjectFormat`; `summarize` убран из CLI (счётчики считает ядро),
  `documentTable` больше не строит вторую таблицу адресов — используется
  таблица документа, разрешение ссылок на ноду и порт идёт через
  `queryNode`/`queryNodes` (`#336`, `#141`, MANIFEST §63).
- Сообщения об отказах адресации («нужна нода», «нет ноды с адресом»,
  «нужен параметр») формирует ядро: тот же текст получает любой клиент, а не
  только CLI ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- `param list --json` для ноды с незарегистрированным типом печатает
  параметры из файла (раньше список был пуст, хотя человеческий отчёт их
  показывал) ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- `cli/stamp.nim` — формат отметки времени и часы в одном месте: раньше
  `nowStamp` жил в `cmd_project`, из-за чего импорт замыкался
  (`cmd_project → control_bridge → cmd_project`)
  ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- Удалён мёртвый `cli/addressing.nim`: разбор ссылок, печать адресов и
  таблица handle'ов перешли в ядро (Query API и `Document.handles`), копия в
  клиенте больше не нужна
  ([#336](https://github.com/framefrok/Euterpia_core/issues/336)).
- `libs/cli_spec` — описание команды CLI **данными**: имя, синопсис,
  позиционные аргументы, ключи (вид, тип значения, умолчание,
  обязательность), варианты аргумента, пример вызова и поля ответа
  `--json`. Из одной спецификации собираются человеческая справка
  (`--help`), машинная схема (`help --json`), кандидаты автодополнения
  (`__complete`) и раздел справочника `docs/cli.md`; у 16 команд графа,
  проекта, рендера, нот, инспектора, MIDI, настроек и служебных появилось
  типизированное описание вместо прозы в трёх местах
  ([#330](https://github.com/framefrok/Euterpia_core/issues/330)).
- Служебная `euterpia __reference` и задача **`nimble cliDocs`**: раздел
  справочника генерируется между маркерами `cli-spec:begin`/`cli-spec:end`,
  проза вокруг остаётся рукописной
  ([#330](https://github.com/framefrok/Euterpia_core/issues/330)).
- `help --json` печатает `specProblems` — машинную проверку описаний:
  непустой список означает команду без синопсиса, примера, типа значения
  ключа или поля ответа
  ([#330](https://github.com/framefrok/Euterpia_core/issues/330)).

### Изменено
- CLI-тесты: новый suite «спецификация команд» сверяет раздел `docs/cli.md`
  со свежим выводом `__reference` байт-в-байт, проверяет, что каждый
  объявленный ключ действительно принимается разбором команды, а каждое
  названное в схеме поле `--json` приходит в ответе — правка справки руками
  или забытое поле теперь падают в CI, а не проходят молча
  ([#330](https://github.com/framefrok/Euterpia_core/issues/330)).
- `cli/registry.nim` хранит только соединение описания с телом команды
  (`spec` + `run`); `docs/cli.md`, `README.md` и MANIFEST §21 описывают
  один источник вместо реестра текстов
  ([#330](https://github.com/framefrok/Euterpia_core/issues/330)).
- Расширение файла проекта — `.eproj`: `euterpia init` без аргументов создаёт
  `project.eproj`, и команды (`node`, `connect`, `param`, `graph`, `render`,
  `midi`) понимают `.eproj` в позиционном аргументе. Историческое `.eut`
  принимается наравне — расширение это подпись файла, а не часть формата:
  тип файла ядро определяет по содержимому (`format` = `euterpia-project`,
  `core/project.nim`), поэтому `mv demo.eut demo.eproj` ничего не ломает и
  миграции не требует (MANIFEST §19/§51/§55/§59, §58). Один список расширений
  на все команды — `ProjectSuffixes`/`isProjectPath` в `cli/cmd_project.nim`:
  раньше `cmd_graph` и `cmd_render` держали свои копии строки `.eut` и
  «не понимали» чужой аргумент
  ([#370](https://github.com/framefrok/Euterpia_core/issues/370)).
- `.gitignore`: удалён мёртвый `*.eutp` (0 использований в репозитории)
  ([#370](https://github.com/framefrok/Euterpia_core/issues/370)).

### Исправлено
- Подсказка `euterpia midi` при нечитаемом проекте ссылалась на несуществующую
  команду `euterpia project info`; теперь называет формат и рабочую команду —
  `euterpia project show`
  ([#370](https://github.com/framefrok/Euterpia_core/issues/370)).

### Добавлено
- CLI smoke: расширение проекта — умолчание `project.eproj`, переименование
  `.eut` → `.eproj` без миграции, `.eproj`/`.eut` в позиционном аргументе,
  отказ на постороннее расширение и на два файла проекта в одной команде
  ([#370](https://github.com/framefrok/Euterpia_core/issues/370)).

### Исправлено
- Планировщик DSP: acquire/pin-протокол выбора слота в `renderBlock` (пин ДО
  чтения `activeIndex`) — устранён use-after-free массивов слота при двойном
  свопе A→B→A
  ([#381](https://github.com/framefrok/Euterpia_core/issues/381)).
- Планировщик DSP: `swapSchedule` поднимает воркеры ДО публикации расписания —
  нет spin/nil-разыменования `workerProgress` на переходе «пустая сессия →
  уровни» ([#382](https://github.com/framefrok/Euterpia_core/issues/382)).
- Входной тракт: `inputStatusFlags` копится через OR (был `fetchAdd` по битмаску);
  stride 4-канального входа — по ИСХОДНОМУ числу каналов
  ([#383](https://github.com/framefrok/Euterpia_core/issues/383)).
- Диагностика движка: `frameSnapshot`/`droppedMetrics`/`droppedRetirements`
  атомарные — нет гонки данных RT↔control
  ([#384](https://github.com/framefrok/Euterpia_core/issues/384)).
- Утилизация пайплайнов: audio-поток больше НЕ освобождает память; backpressure
  `postGraphUpdate` держит хранилище ниже ёмкости, `droppedRetirementsCount()`==0
  ([#385](https://github.com/framefrok/Euterpia_core/issues/385)).
- Сглаживание параметров: нода больше не применяет значение конца блока ко всему
  блоку — пер-сэмпловое сглаживание (`ParamRamp`/`beginRamp`), переход не зависит
  от blockSize во всех нодах
  ([#386](https://github.com/framefrok/Euterpia_core/issues/386)).
- Транспорт: единый time/state контракт — `TransportSnapshot.state`, общий
  `positionFromSeconds` (bar/beat/quarter/tick со знаменателем), цикл в долях,
  команда `postSetMeter`
  ([#387](https://github.com/framefrok/Euterpia_core/issues/387)).

### Изменено
- Остатки прямого доступа CLI к документу убраны (#373): `project set` пишет
  метаданные командой `ccSetProjectInfo`, `notation import` — последовательность
  control-команд (`addTrack`/`addClip`/`setClip`) с откатом через историю;
  валидаторы `project validate` и `graph check` читают через Query API, DTO
  расширены (`NodeInfo.fileParams`, тики автоматизации), а в
  `DOCUMENT_ACCESS_ALLOWED` остались только пути ЗАПИСИ.
- WAV: общий писатель ядра (#356) — `audio_recorder` пишет через `wav_codec`
  (дублирующая RIFF-шапка удалена), фасад `audio_file_io` получил
  `readAllAudioFile`/`seekAudioFile`, `cmd_analyze` и `offline_render` ходят
  через фасад.

### Добавлено
- Реальные кодеки аудио (#10): чтение **FLAC, MP3, OGG Vorbis** (вендорены
  dr_flac.h, dr_mp3.h, stb_vorbis.c; плоский C-ABI в `commons/codecs`) и
  **AIFF/AIFC** чтение и запись (`commons/codecs/aiff`). Фасад `audio_file_io`
  декодирует их целиком, `euterpia import` принимает эти форматы. Encode — WAV
  и AIFF (у названных библиотек энкодеров нет).
- `euterpia render`: индикатор прогресса в stderr — проценты,
- `euterpia render`: индикатор прогресса в stderr — проценты,
  отрендерено/всего, прошло, осталось и скорость (×REALTIME) с
  «вращающейся палочкой»; `--progress`/`--no-progress`, `-q` отключает,
  по умолчанию включается только для терминала
  ([#310](https://github.com/framefrok/Euterpia_core/issues/310)).
- `libs/compose/progress` — тот же индикатор для `arr.render(...)` из
  `nim r generate.nim`; одна реализация вместо двух
  ([#310](https://github.com/framefrok/Euterpia_core/issues/310)).
- `OfflineRenderOptions.onProgress` — колбэк прогресса ядра: раз в секунду
  аудио и всегда на последнем кадре; `nil` — не вызывается вовсе
  ([#310](https://github.com/framefrok/Euterpia_core/issues/310)).
- Третья партия инструментов: `euterpia.ukulele`, `euterpia.accordion`
  (баян) и `euterpia.harmonica` (губная гармошка) — всего в реестре
  28 типов ([#321](https://github.com/framefrok/Euterpia_core/issues/321)):
  - `EutReed` — новый C-движок свободноязычковых (язычок в камере):
    разлив из расстроенных язычков, шум меха/дыхания, клац клапана,
    посадка строя после атаки и нелинейность язычка от velocity. Две
    точки входа — баян (разлив 12 центов, камера ≈1.4 кГц) и гармошка
    (сухой строй, ≈2.6 кГц) — `nodes/builtin/instruments/reed.nim`;
  - `EutPluck` получил параметр `nylon` (доля нейлоновой струны), и на нём
    построен `euterpia.ukulele`: мягче возбуждение и быстрее спад верха —
    глухой «деревянный» щипок вместо звона стали;
  - укулеле, баян и гармошка в `builtin_registry`, биндинги и
    `abiCheck` (`EutReedVoice`/`EutReed` — 180/64, `EutPluck` 64→72),
    справочник `docs/libs/compose/instruments.md`.
- `core/control`: control-слой документа — единая командная модель
  (`core/control/commands.nim`, `document.nim`, `error_frame.nim`, issue #139,
  MANIFEST §65). Команды `node.create`, `node.delete`, `graph.connect`,
  `graph.disconnect`, `param.set` приходят конвертом (идентификатор, версия
  API, данные) и возвращают `ErrorFrame` — код причины, сообщение и подсказку,
  а не `bool`. Проверки по описателю типа, правила графа и каскадные удаления
  уехали из CLI в ядро: Core не знает типов нод (§54), описания приходят от
  хозяина документа через `NodeTypeProvider`, а часы внедряются, чтобы CLI и
  Editor давали одинаковый документ. Объявленные, но ещё не реализованные
  команды отвечают `ecUnsupportedCommand`.
- `core/control/history`: транзакции и история поверх `commons/undo_redo`
  (#139, #109, #127). `planTransaction` прогоняет составную операцию на копии и
  собирает ОБРАТНЫЕ команды из состояния до правки: отказ на середине не
  оставляет ни одного изменения, а отмена — точное зеркало; одна составная
  операция даёт одну запись истории. Отмена удаления ноды возвращает её вместе
  со связями, дорожками автоматизации и состояниями плагинов (`node.restoreState`
  — команда отката в общем контракте, а не «магия»). Запись переносима: команды
  сериализуются в JSON с версией формата (§58), испорченная запись даёт код, а
  не «отменит половину».
- CLI: `node add`, `node rm`, `connect`, `disconnect`, `param set` выполняются
  через control-слой; появился `errorCode` в JSON-конверте (код причины
  числом) — остальные команды пока по-старому, миграция продолжится следом.
- `core`: стабильные handle-ID для сущностей документа
  (`core/handles.nim`, issue #143, MANIFEST §35/§36). Handle — значение
  `документ + слот + поколение + вид`: у просроченного адреса возвращается код
  (`heStale`, `heReleased`, `heForeignDocument`, `heKindMismatch`) вместо
  чтения чужой памяти, повторное удаление отвергается, а слот = постоянный
  `id` из формата проекта — поэтому адрес переживает пересборку графа.
  Вложенные сущности адресуются путём `node:3.1/component:1/param:0`
  (подграф → компонент → параметр), клип — `track:1.1/clip:0`
  ([#143](https://github.com/framefrok/Euterpia_core/issues/143)).
- CLI: адреса печатаются в отчётах (`node list`, `node show`,
  `param list/get/set`, `project show`) и принимаются как ссылка на ноду и
  параметр. Полная форма `node:3.1@<документ>` отвергает адрес из чужого
  файла, а удалённая нода даёт «в документе нет ноды с адресом …» вместо
  «не нашлась нода». Команды и их грамматика не изменились — это расширение
  формы ссылки
  ([#143](https://github.com/framefrok/Euterpia_core/issues/143)).
- Клиентский контракт «действие интерфейса = команда»: перечень действий
  (`core/control/actions.nim`) с областями (документ / исполнение / файлы /
  представление / окружение / окно), связью с командами `control`-слоя и
  CLI-парой, а также причинами, по которым команда бывает только в CLI.
  Незакрытые пары названы номерами issue прямо в перечне, а `tests/cli_test.nim`
  (suite «паритет клиентов») сверяет обе стороны с `help --json`: нет
  действия без команды, нет команды без действия или объяснения, нет
  реализованной команды документа без действия. Страница —
  [docs/clients.md](docs/clients.md)
  ([#148](https://github.com/framefrok/Euterpia_core/issues/148)).
- `docs/cli.md`: снята устаревшая сноска о дефекте флагов параметров (#292
  закрыт в PR #291) — дробные и отрицательные значения у дробных параметров
  принимаются.

### Изменено
- `euterpia.guitar`: звук струны стал «живее» — тело корпуса (мягкая полка
  ~2 дБ ниже 200 Гц вместо пустой нижней середины), двухполюсный демпфер
  струны (ВЧ-хвост садится ровнее и короче) и огибающая строя: сильный
  щипок коротко «въезжает» вверх на ~3 цента и садится за ~35 мс.
  Параметры и API не изменились, размеры состояний выросли
  (`EutGuitarVoice` 104→116, `EutGuitar` 80→88 — хост берёт их из
  `eut_abi_sizeof_guitar*`)
  ([#318](https://github.com/framefrok/Euterpia_core/issues/318)).
- `euterpia.harp` и `euterpia.harpsichord` звучат **бит-в-бит** как раньше:
  новый `nylon` у `EutPluck` у них выключен (`0`), поэтому ни возбуждение,
  ни петля не изменились
  ([#321](https://github.com/framefrok/Euterpia_core/issues/321)).
- `euterpia.drums`: удар перестал звучать «синтезатором». Слои (транзиент
  ударника, корпус, подструнник, металлическая группа) получили независимые
  огибающие: у верхних мод корпуса и верхних частичных тарелок спад короче,
  поэтому удар раскрывается во времени, а не гаснет одним тумблером. Шум и
  транзиент фильтруются двухполюсными полосовыми фильтрами (вместо
  однополюсного «тссс» — «проволока» малого и «воздух» тарелок), сила удара
  ведёт яркость и баланс слоёв, а не только уровень, клэп — серия из трёх
  хлопков с общим хвостом, и после суммы стоит пост-ФНЧ ~0.46·sr: гармоники
  мягкого ограничения больше не засоряют ВЧ. Параметры и API не изменились,
  размеры состояний выросли (`EutDrumVoice` 184→328, `EutDrums` 56→72 — хост
  берёт их из `eut_abi_sizeof_drum*`)
  ([#326](https://github.com/framefrok/Euterpia_core/issues/326)).

### Исправлено
- `euterpia.drums`: `drumsReset` (его зовут на остановке транспорта) обнуляет
  и состояние пост-ФНЧ. Раньше оно оставалось от последнего громкого удара и
  вылезало щелчком в первой ноте нового проигрывания
  ([#326](https://github.com/framefrok/Euterpia_core/issues/326)).
- `libs/compose`: раскладка проверяется до сборки проекта. Неизвестный
  тип ноды и опечатка в имени параметра больше не роняют скрипт
  `AssertionDefect` и не теряются молча — они называют проблему и
  перечисляют допустимые значения; пустая партия и пустая раскладка
  дают предупреждение ([#311](https://github.com/framefrok/Euterpia_core/issues/311)).
- Инструменты `flute`, `bagpipe`, `strings`, `bell`, `harp`/`harpsichord`,
  `recorder`, `brass`, `timpani`, `choir`: паника и сброс транспорта
  обнуляют DSP-состояние голосов (фазы, фильтры, линии задержки), как у
  `organ`/`piano`/`guitar`/`drums`, а не только снимают ноты
  ([#316](https://github.com/framefrok/Euterpia_core/issues/316)).
- Убраны мёртвые объявления, шумевшие в каждой сборке:
  неиспользуемый `EutInstVoice` и локальные переменные в `biquad` и
  `compressor` ([#316](https://github.com/framefrok/Euterpia_core/issues/316)).
- Арены ядра выровнены по строке кэша при **любом** аллокаторе: `EventQueue`
  просит 64 байта (`{.align: 64.}` на поле `events`), а `allocShared0` обещает
  только `MemAlign`. Пока память выдавал аллокатор Nim'а целыми страницами,
  выравнивание получалось само; с `-d:useMalloc` она идёт из libc `malloc` с
  выравниванием 16 байт, и обращение к первому событию секвенсора стало UB
  (UBSan: `member access within misaligned address … which requires 64 byte
  alignment`). Выравнивание переехало в общую пару `core/aligned_mem`
  (`alignedSharedAlloc0`/`alignedSharedDealloc`) — на неё же переведены пулы
  вместо частной копии кода, — а арена событий компилятора выделяется и
  освобождается ею; тесты проверяют выравнивание адреса, а не удачу
  аллокатора ([#364](https://github.com/framefrok/Euterpia_core/issues/364),
  [#367](https://github.com/framefrok/Euterpia_core/pull/367)).
- Тест документации встраивания не тянет libpcre и не зависит от переводов
  строк: `std/re` падал на ubuntu-раннере ещё до первой проверки
  (`could not load: libpcre.so`), а сравнение с `"\n  embed:\n"` не переживало
  CRLF из windows-checkout, то есть проверялся перевод строки, а не джоб CI.
  Документ читается нормализованным, идентификаторы и имена nimble-целей
  разбирает свой сканер; проверено мутациями — выдуманный `eutHostPhantom()`,
  переименованный `eutHostPlay` и несуществующая цель валят свой набор
  ([#213](https://github.com/framefrok/Euterpia_core/issues/213),
  [#368](https://github.com/framefrok/Euterpia_core/pull/368)).

## [0.3.1] — Организация и документация (v0.3.1)

Шаг `.1` линии v0.3: релизная механика, справочник CLI, поставка.

### Добавлено
- `CHANGELOG.md` — история линий 0.2 и 0.3 со ссылками на issue/PR
  ([#113](https://github.com/framefrok/Euterpia_core/issues/113)).
- `docs/cli.md` — справочник CLI: режимы вывода, коды возврата,
  JSON-схемы, справочник команд и готовые сценарии
  ([#96](https://github.com/framefrok/Euterpia_core/issues/96)).
- README: раздел «Установка» (`nimble install`, требования, первый
  запуск) ([#113](https://github.com/framefrok/Euterpia_core/issues/113)).
- CI: джоб `artifacts` — сборка CLI и smoke (`--version`, `doctor`) на
  Linux/macOS/Windows с загрузкой артефактов
  ([#113](https://github.com/framefrok/Euterpia_core/issues/113),
  [#229](https://github.com/framefrok/Euterpia_core/issues/229)).

### Изменено
- CI-джоб `miniaudio` расширен до матрицы Linux/macOS/Windows: сборка,
  линковка и smoke на всех трёх ОС
  ([#52](https://github.com/framefrok/Euterpia_core/issues/52)).
- `euterpia help`: колонка справки вычисляется по самой широкой команде,
  поэтому описание больше не слипается с синтаксисом
  ([#96](https://github.com/framefrok/Euterpia_core/issues/96)).
- Версия пакета поднята до `0.3.1`
  ([#113](https://github.com/framefrok/Euterpia_core/issues/113)).

## [0.3.0] — CLI: первый полноценный интерфейс (линия v0.3)

Линия v0.3: ядро получает настоящий интерфейс — CLI с машинным выводом,
детерминизмом и exit-кодами (MANIFEST §19-§21).

### Добавлено
- Каркас CLI: реестр команд, `--help`/`help --json`, `--version`, `doctor`
  ([#88](https://github.com/framefrok/Euterpia_core/issues/88),
  [PR #268](https://github.com/framefrok/Euterpia_core/pull/268)).
- Проект: `init`, `project show|set|validate`
  ([#89](https://github.com/framefrok/Euterpia_core/issues/89),
  [PR #269](https://github.com/framefrok/Euterpia_core/pull/269)).
- Граф: `node list|types|add|rm|show`, `connect`/`disconnect`,
  `param list|get|set`, `graph check`
  ([#90](https://github.com/framefrok/Euterpia_core/issues/90),
  [PR #271](https://github.com/framefrok/Euterpia_core/pull/271)).
- Настройки окружения `config list|get|set|unset|path`
  ([#258](https://github.com/framefrok/Euterpia_core/issues/258),
  [PR #270](https://github.com/framefrok/Euterpia_core/pull/270)).
- Автодополнение оболочки `completion bash|zsh|fish`
  ([#259](https://github.com/framefrok/Euterpia_core/issues/259)).
- Офлайн-рендер `render` и нотация `notation check|import`
  ([#275](https://github.com/framefrok/Euterpia_core/issues/275),
  [PR #289](https://github.com/framefrok/Euterpia_core/pull/289)).
- Инспектор аудио `analyze` — дефекты WAV с локализацией
  ([#290](https://github.com/framefrok/Euterpia_core/issues/290),
  [PR #291](https://github.com/framefrok/Euterpia_core/pull/291)).
- `libs/compose` — «композиция как код» на Nim
  ([#285](https://github.com/framefrok/Euterpia_core/issues/285),
  [PR #303](https://github.com/framefrok/Euterpia_core/pull/303)).

### Изменено
- Поставка: `nim c -d:release` с LTO, `nimble buildRelease`, кэш
  тулчейна Nim в CI ([#42](https://github.com/framefrok/Euterpia_core/issues/42),
  [#249](https://github.com/framefrok/Euterpia_core/issues/249)).
- Лицензия пакета — Proprietary, обязательное поле nimble
  ([#252](https://github.com/framefrok/Euterpia_core/issues/252),
  [PR #253](https://github.com/framefrok/Euterpia_core/pull/253)).

## [0.2.0] — Ядро: фундамент и экосистема (линия v0.2)

Линия v0.2: realtime-ядро, граф и планировщик, ввод/вывод, плагины.

### Добавлено
- Аудио-бэкенды: `audio_backend_api` + PortAudio
  ([#2](https://github.com/framefrok/Euterpia_core/issues/2)),
  miniaudio 0.11.25 ([#31](https://github.com/framefrok/Euterpia_core/issues/31)).
- Входной тракт и запись: драйвер → planar-арена → ноды/рекордер
  ([#3](https://github.com/framefrok/Euterpia_core/issues/3)).
- MIDI: `midi_api` + RtMidi-адаптер, SMF-кодек
  ([#28](https://github.com/framefrok/Euterpia_core/issues/28)).
- Плагины: `plugin_api`, CLAP 1.2 (host/plugin), EUT ABI
  ([#29](https://github.com/framefrok/Euterpia_core/issues/29),
  [#6](https://github.com/framefrok/Euterpia_core/issues/6),
  [#49](https://github.com/framefrok/Euterpia_core/issues/49),
  [#53](https://github.com/framefrok/Euterpia_core/issues/53)).
- Транспорт и таймлайн, секвенсор клипов и автоматизации, BBT ↔ сэмплы
  ([#58](https://github.com/framefrok/Euterpia_core/issues/58)).

### Изменено
- Планировщик: уровневые задачи, постоянный пул воркеров, горячая смена
  графа ([#9](https://github.com/framefrok/Euterpia_core/issues/9)).
- Realtime-дисциплина: guard в debug
  ([#11](https://github.com/framefrok/Euterpia_core/issues/11)),
  аудит `gcsafe` ([#16](https://github.com/framefrok/Euterpia_core/issues/16)).
- CI: матрица трёх ОС, LICENSE и шаблоны
  ([#12](https://github.com/framefrok/Euterpia_core/issues/12)),
  UBSan/ASan ([#13](https://github.com/framefrok/Euterpia_core/issues/13)),
  macOS-джоб ([#42](https://github.com/framefrok/Euterpia_core/issues/42)).

### Исправлено
- Компрессор: кривая gain покрывает весь блок, убран OOB
  ([#64](https://github.com/framefrok/Euterpia_core/issues/64)).
- Рекордер: устаревшая `rcArm` не откатывает `disarm`
  ([#61](https://github.com/framefrok/Euterpia_core/issues/61)).
- BBT-конверсия учитывает знаменатель размера
  ([#58](https://github.com/framefrok/Euterpia_core/issues/58)).
- Пайплайн: аварийная утилизация вместо утечки, прерывание по `stopFlag`
  ([#73](https://github.com/framefrok/Euterpia_core/issues/73),
  [#74](https://github.com/framefrok/Euterpia_core/issues/74)).

## [0.1.0] и ранее

До перенумерации линий (см. README, «Закрыто: фундамент ядра и
экосистема»). Базовая метка репозитория — `v0.2.0-baseline`.

[Unreleased]: https://github.com/framefrok/Euterpia_core/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/framefrok/Euterpia_core/releases/tag/v0.3.1
[0.3.0]: https://github.com/framefrok/Euterpia_core/releases/tag/v0.3.0
[0.2.0]: https://github.com/framefrok/Euterpia_core/releases/tag/v0.2.0-baseline
