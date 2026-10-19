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

echo "ok: пакет работает на чистой машине без Nim"
