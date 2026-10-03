#!/usr/bin/env bash
# compositions/neo-romantic/build.sh
#
# Сборка и рендер «Neo-Romantic Ensemble» библиотекой libs/compose (issue #300):
# генератор пишет .notes, .eut и .wav сам; обёртка добавляет отдельный nimcache
# и проверку инспектором.
#
# Использование:  ./build.sh [путь-к-euterpia]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
E="${1:-${EUTERPIA:-$HERE/../../build/euterpia}}"
ROOT="$HERE/../.."

echo "--- generate + render + MIDI (libs/compose) ---"
nim c -r --hints:off --nimcache:"$ROOT/build/nc_compose_neo" \
    --out:"$ROOT/build/compose_neo" "$HERE/generate.nim"

echo "--- analyze ---"
"$E" analyze "$HERE/ensemble.wav" --fail-on error
