#!/usr/bin/env bash
# compositions/dark-fantasy/build.sh
#
# Сборка и рендер «Cathedral of Ash» библиотекой libs/compose (issue #300):
# генератор сам пишет .notes, .eut и .wav — обёртка почти не нужна. Здесь
# только отдельный nimcache (иначе два генератора «generate.nim» делят кэш)
# и проверка инспектором.
#
# Использование:  ./build.sh [путь-к-euterpia]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
E="${1:-${EUTERPIA:-$HERE/../../build/euterpia}}"
ROOT="$HERE/../.."

echo "--- generate + render + MIDI (libs/compose) ---"
nim c -r --hints:off --nimcache:"$ROOT/build/nc_compose_dark" \
    --out:"$ROOT/build/compose_dark" "$HERE/generate.nim"

echo "--- analyze ---"
"$E" analyze "$HERE/ensemble.wav" --fail-on error
