# Поставка EUTERPIA (issue #229)

Документ отвечает на вопрос «у меня Linux / macOS / Windows — смогу ли я
работать?» проверяемыми утверждениями, а не обещаниями.

## Что поставляется

По тегу `v*` workflow `Release` (`.github/workflows/release.yml`) собирает три
архива — Linux x86_64, Windows x86_64, macOS (arm64/x86_64 по архитектуре
раннера) — и публикует их в GitHub Release вместе с SHA256.

Состав архива (одинаковый на всех ОС, кроме `.exe`/`.app`):

```
euterpia-<версия>-<ос>-<арх>/
  bin/euterpia[.exe]
  VERSION
  install.sh | install.ps1        установка без пакетного менеджера
  uninstall.sh | uninstall.ps1
  share/applications/euterpia.desktop   (Linux)
  share/mime/packages/euterpia.xml      (Linux)
  share/doc/euterpia/{README,CHANGELOG,MANIFEST,cli,clients,embedding,delivery}.md
  Euterpia.app/Contents/…               (macOS: app bundle + Info.plist)
```

### Additional payload since v0.3.11 (#348, #349)

Every archive now also contains:

```text
  bin/euterpia-open              file-association helper (cd + `euterpia open`)
  share/man/man1/euterpia*.1     overview and one page per command
  share/bash-completion/completions/euterpia
  share/zsh/site-functions/_euterpia
  share/fish/vendor_completions.d/euterpia.fish
  share/powershell/completions/euterpia.ps1
  share/euterpia/presets/{templates,setlists,params}   data presets
```

The manual and completion scripts are generated from the command
specification at package time, so the shipped binary and its documentation
cannot describe different command surfaces. The desktop file and the Windows
registry association invoke `euterpia-open`, which changes to the project
directory before running `euterpia open <file>`.

## Ассоциации файлов проекта

Расширения: `*.eproj` (текущий формат) и `*.eut` (историческое имя).

| ОС | Механизм | Права |
|---|---|---|
| Linux | MIME `application/x-euterpia-project` + `.desktop`, регистрируется `install.sh` через `update-mime-database`/`xdg-mime` (если есть) | пользовательские (`~/.local`) |
| Windows | `HKCU\Software\Classes\Euterpia.Project` + `.eproj`/`.eut`, `install.ps1` | без администратора |
| macOS | `CFBundleDocumentTypes` в `Info.plist` внутри `Euterpia.app` | без администратора |

Если утилит `update-mime-database`/`xdg-mime` в системе нет, файлы MIME и
`.desktop` всё равно устанавливаются — ассоциация просто не активируется
автоматически; это не ошибка установки.

## Зависимости

* **miniaudio** вендорен в репозитории (`adapters/miniaudio`) — внешних
  пакетов не требует; на Windows/macOS линкуются системные библиотеки
  (WASAPI/CoreAudio), это делает C-шим.
* **libportaudio / librtmidi / liblilv / фасад libremidi** — опциональны и
  грузятся через `dynlib` при первом обращении. Нет библиотеки — команда
  отвечает «недоступно» (код 2), процесс не падает (issue #267).
* **FLAC-энкодер** встроен: `master --format flac` не требует внешних
  инструментов. OGG/MP3-превью используют `ffmpeg`, `lame` или `oggenc`,
  если они установлены; иначе — код 2 с подсказкой (issue #411).

## Версия и тег

Версия объявлена ровно в одном месте — `euterpia_version.nim`. Из неё берут
значение `euterpia --version`, поле `version` пакета nimble и имя тега:

* `tools/package.sh`/`tools/package.ps1` сверяют `euterpia --version` с
  `euterpia_version.nim` и падают при расхождении;
* workflow `Release` сверяет тег (`v0.3.5` → `0.3.5`) с тем же файлом;
* CI-джоб `artifacts` проверяет то же на трёх ОС.

## Проверка на чистой машине

Джоб CI `package` собирает release-бинарь на Ubuntu, упаковывает его и
запускает **в контейнере `ubuntu:24.04` без Nim, компиляторов и dev-пакетов**:

1. `--version` печатает ожидаемую версию;
2. `init demo.eproj` создаёт проект;
3. `node add osc` добавляет ноду;
4. `render demo.eproj out.wav --seconds 1` даёт непустой WAV (`rendered: true`,
   `silent: false`).

Это ловит две типичные ошибки поставки: забытую динамическую зависимость и
бинарь, собранный с флагами, которых нет у пользователя.

Локально тот же сценарий можно повторить вручную:

```bash
nim c -d:release --hints:off --out:build/euterpia cli.nim
tools/package.sh build/euterpia
docker run --rm \
  -v "$PWD/tools:/tools:ro" \
  -v "$PWD/build/dist:/pkg:ro" \
  ubuntu:24.04 bash /tools/clean_machine_check.sh /pkg
```

Since v0.3.11 the same container also checks the delivery surface:

1. `euterpia open demo.eproj` reads the project produced by `init`;
2. `euterpia __man --check share/man/man1` proves the manual matches the
   shipped binary;
3. completion scripts for bash/zsh/fish/PowerShell exist in the archive;
4. `tools/quickstart.sh --doc share/doc/euterpia/quickstart.md` runs the
   documented quick start (preset → setlist → render → analyze) with the
   packaged presets;
5. `play` on a machine without an audio device exits with code **2**, not a
   crash — the "missing system library/device" contract.

## Ограничения (честно)

* **Подписи кода нет.** Windows SmartScreen и macOS Gatekeeper могут
  предупредить о неподписанном бинаре; это осознанно до появления
  сертификатов.
* **Нет `.deb`/`.rpm`/MSI.** Установщики — скрипты в архиве; пакетные
  менеджеры — отдельная задача, и обещать их раньше, чем появится
  воспроизводимая сборка пакетов, не нужно.
* **macOS universal:** архив собирается под архитектуру раннера
  (`macos-latest` — arm64); универсальный бинарь потребует `lipo` двух
  сборок и будет добавлен, когда появится реальная потребность.
* **Версия в UI:** пользовательского интерфейса (Editor) пока нет — линия
  GUI начинается с v0.4. Сейчас версия сверяется в CLI (`--version`), поле
  `version` пакета и тег; `doctor` печатает ту же константу. Когда появится
  окно «О программе», оно обязано брать `EuterpiaVersion`, а не свою строку.
