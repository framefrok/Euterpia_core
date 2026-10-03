#!/usr/bin/env bash
# compositions/neo-romantic/build.sh
#
# Сборка «Neo-Romantic Ensemble» БИБЛИОТЕКОЙ libs/compose (Nim, #285):
# проект (.eut) строит наш код, рендер и проверка — командами CLI.
# Альтернативный путь (тот же состав только через CLI, §19) — build_via_cli.sh;
# результат обязан совпадать.
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
