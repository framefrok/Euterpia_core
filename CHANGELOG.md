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
