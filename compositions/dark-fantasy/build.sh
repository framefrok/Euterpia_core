#!/usr/bin/env bash
# compositions/dark-fantasy/build.sh
#
# Сборка «Cathedral of Ash» БИБЛИОТЕКОЙ libs/compose (Nim, issue #285):
# проект (.eut) строится нашим кодом — ноды, связи, параметры из описателей,
# дорожки с нотами, — а рендер и проверка идут через CLI.
#
# Альтернативный путь (сборка тем же составом только через CLI, §19) —
# в build_via_cli.sh; результат обязан совпадать.
#
# Использование:  ./build.sh [путь-к-euterpia]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
E="${1:-${EUTERPIA:-$HERE/../../build/euterpia}}"
PROJ="$HERE/ensemble.eut"
OUT="$HERE/ensemble.wav"

rm -f "$PROJ"

run() { "$E" "$@"; }

echo "--- generate (libs/compose, Nim) ---"
nim r --hints:off "$HERE/generate.nim"

echo "--- graph check ---"
run graph check --file "$PROJ" | tail -3

echo "--- render ---"
run render "$PROJ" "$OUT" --bits 16 | tail -6

echo "--- analyze ---"
run analyze "$OUT" || true
