# Changelog

Все значимые изменения EUTERPIA. Формат — по мотивам
[Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — по
правилам проекта (`docs/versions.md`, MANIFEST §105).

Правило релиза (#113): **у каждого пункта есть ссылка на issue или PR**.
Версия пакета — единственная константа `euterpia_version.nim`, поэтому
`euterpia --version`, поле `version` пакета и имя тега совпадают.

## [Unreleased]

Версия пакета — `0.3.2`: шаг линии **v0.3.2** («критическое и архитектурное»)
закрыт (см. `docs/versions.md` §1 — версия растёт на последнем закрытом шаге).

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

## [0.3.2] — Незакрытое

### Добавлено
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
