# Changelog

Все значимые изменения EUTERPIA. Формат — по мотивам
[Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — по
правилам проекта (`docs/versions.md`, MANIFEST §105).

Правило релиза (#113): **у каждого пункта есть ссылка на issue или PR**.
Версия пакета — единственная константа `euterpia_version.nim`, поэтому
`euterpia --version`, поле `version` пакета и имя тега совпадают.

## [Unreleased]

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


### Исправлено
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
