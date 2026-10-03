#!/usr/bin/env bash
# compositions/neo-romantic/build_via_cli.sh
#
# Альтернативная сборка «Neo-Romantic Ensemble» ТОЛЬКО через CLI (MANIFEST
# §19): ноды, связи, параметры, импорт нотации — как это сделал бы человек
# или агент без нашего кода. Партитуры (.notes) пишет generate.nim
# (libs/compose). Результат совпадает с build.sh.
#
# Использование:  ./build_via_cli.sh [путь-к-euterpia]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
E="${1:-${EUTERPIA:-$HERE/../../build/euterpia}}"
PROJ="$HERE/ensemble_cli.eut"
OUT="$HERE/ensemble_cli.wav"

rm -f "$PROJ"
run() { "$E" "$@"; }

run init "$PROJ" --tempo 92 --name "Neo-Romantic Ensemble"

# --- ноды: 4 партии (ноты + инструмент) и сумматор ---
run node add euterpia.notes  --name LeadNotes   --file "$PROJ" >/dev/null
run node add euterpia.guitar --name Guitar      --file "$PROJ" >/dev/null
run node add euterpia.notes  --name PianoNotes  --file "$PROJ" >/dev/null
run node add euterpia.piano  --name Piano       --file "$PROJ" >/dev/null
run node add euterpia.notes  --name OrganNotes  --file "$PROJ" >/dev/null
run node add euterpia.organ  --name Organ       --file "$PROJ" >/dev/null
run node add euterpia.notes  --name DrumNotes   --file "$PROJ" >/dev/null
run node add euterpia.drums  --name Drums       --file "$PROJ" >/dev/null
run node add euterpia.mix    --name Mix         --file "$PROJ" >/dev/null

# --- события: ноты каждой партии в свой инструмент ---
run connect LeadNotes:event:0  Guitar:event:0 --file "$PROJ" >/dev/null
run connect PianoNotes:event:0 Piano:event:0  --file "$PROJ" >/dev/null
run connect OrganNotes:event:0 Organ:event:0  --file "$PROJ" >/dev/null
run connect DrumNotes:event:0  Drums:event:0  --file "$PROJ" >/dev/null

# --- аудио: все инструменты в сумматор ---
run connect Guitar:out Mix:audio:0 --file "$PROJ" >/dev/null
run connect Piano:out  Mix:audio:1 --file "$PROJ" >/dev/null
run connect Organ:out  Mix:audio:2 --file "$PROJ" >/dev/null
run connect Drums:out  Mix:audio:3 --file "$PROJ" >/dev/null

# --- тембры и баланс ---
run param set Guitar level -2   --file "$PROJ" >/dev/null
run param set Guitar tone  0.62 --file "$PROJ" >/dev/null
run param set Guitar pan  -0.15 --file "$PROJ" >/dev/null
run param set Piano  level -3   --file "$PROJ" >/dev/null
run param set Piano  tone  0.55 --file "$PROJ" >/dev/null
run param set Piano  pan   0.15 --file "$PROJ" >/dev/null
run param set Organ  level -4   --file "$PROJ" >/dev/null
run param set Organ  bars  0.55 --file "$PROJ" >/dev/null
run param set Drums  level -3   --file "$PROJ" >/dev/null
run param set Mix    level   0  --file "$PROJ" >/dev/null

# --- партитуры: порядок дорожек = порядок нотных нод ---
run notation import "$HERE/guitar.notes" --track 0 --name guitar --file "$PROJ" >/dev/null
run notation import "$HERE/piano.notes"  --track 1 --name piano  --file "$PROJ" >/dev/null
run notation import "$HERE/organ.notes"  --track 2 --name organ  --file "$PROJ" >/dev/null
run notation import "$HERE/drums.notes"  --track 3 --name drums  --file "$PROJ" >/dev/null

echo "--- graph check ---"
run graph check --file "$PROJ" | tail -3

echo "--- render ---"
run render "$PROJ" "$OUT" --bits 16 | tail -6

echo "--- analyze ---"
run analyze "$OUT" || true
