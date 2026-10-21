#!/usr/bin/env bash
# tools/clean_machine_check.sh
#
# Проверка поставки на «чистой» машине (issue #229).
#
# Запускается ВНУТРИ контейнера без Nim и dev-пакетов. Проверяет, что
# распакованный пакет действительно работает: версия, создание проекта,
# добавление ноды и непустой рендер. Это ловит забытую динамическую
# зависимость и бинарь, собранный флагами, которых нет у пользователя.
#
# Использование: clean_machine_check.sh <каталог-с-архивом>

set -euo pipefail

PKGDIR="${1:-/pkg}"
ARCHIVE="$(ls "$PKGDIR"/euterpia-*.tar.gz | head -1)"
[ -n "$ARCHIVE" ] || { echo "нет архива в $PKGDIR" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
tar xzf "$ARCHIVE"
PKG="$(ls -d euterpia-* | head -1)"
[ -x "$PKG/bin/euterpia" ] || { echo "в архиве нет bin/euterpia" >&2; exit 1; }

echo "— версия"
"$PKG/bin/euterpia" --version

echo "— проект, нода, рендер"
"$PKG/bin/euterpia" init demo.eproj >/dev/null
"$PKG/bin/euterpia" node add osc --name o --file demo.eproj >/dev/null
"$PKG/bin/euterpia" render demo.eproj out.wav --seconds 1 --json > report.json

grep -q '"ok":true' report.json
grep -q '"rendered":true' report.json
test -s out.wav

# Версия в пакете — тот же источник, что у бинаря (#113/#229).
VERSION="$(cat "$PKG/VERSION")"
[ "$("$PKG/bin/euterpia" --version)" = "euterpia $VERSION" ]

# Ассоциации: файлы есть и описывают проект.
test -f "$PKG/share/applications/euterpia.desktop"
test -f "$PKG/share/mime/packages/euterpia.xml"
grep -q 'application/x-euterpia-project' "$PKG/share/mime/packages/euterpia.xml"

# --- v0.3.11 delivery surface (#348, #349, #351) ----------------------------
echo "— open, manual, completion and presets"
"$PKG/bin/euterpia" open demo.eproj > open.txt
grep -q 'nodes: 1' open.txt

test -x "$PKG/bin/euterpia-open"
test -f "$PKG/share/man/man1/euterpia.1"
test -f "$PKG/share/man/man1/euterpia-render.1"
"$PKG/bin/euterpia" __man --check "$PKG/share/man/man1" >/dev/null

test -s "$PKG/share/bash-completion/completions/euterpia"
test -s "$PKG/share/zsh/site-functions/_euterpia"
test -s "$PKG/share/fish/vendor_completions.d/euterpia.fish"
test -s "$PKG/share/powershell/completions/euterpia.ps1"

test -f "$PKG/share/euterpia/presets/templates/band.preset.json"
test -f "$PKG/share/euterpia/presets/setlists/punk-demo.setlist.json"

echo "— quick start from the shipped documentation (#351)"
bash /tools/quickstart.sh "$PKG/bin/euterpia" \
  --doc "$PKG/share/doc/euterpia/quickstart.md" --max-seconds 300

echo "— a missing audio device is an environment error, not a crash"
set +e
"$PKG/bin/euterpia" play demo.eproj --seconds 1 --device 999999 >/dev/null 2>&1
PLAY_CODE=$?
set -e
if [ "$PLAY_CODE" -ne 2 ]; then
  echo "play with a missing device returned $PLAY_CODE, expected 2" >&2
  exit 1
fi

echo "ok: package works on a clean machine without Nim"
