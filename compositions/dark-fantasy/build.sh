#!/usr/bin/env bash
# compositions/dark-fantasy/build.sh
#
# Сборка «Cathedral of Ash» ТОЛЬКО через CLI (MANIFEST §19): ноды, связи,
# параметры, импорт нотации и рендер. Editor не нужен.
#
# Порядок импорта партий важен: загрузчик сцены сопоставляет дорожки с
# нотными нодами по возрастанию id, поэтому партии идут в том же порядке,
# в каком создавались нотные ноды (лютня, пиано, орган, ударные).
#
# Использование:  ./build.sh [путь-к-euterpia]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
E="${1:-${EUTERPIA:-$HERE/../../build/euterpia}}"
PROJ="$HERE/ensemble.eut"
OUT="$HERE/ensemble.wav"

rm -f "$PROJ"

run() { "$E" "$@"; }

python3 "$HERE/generate.py"

run init "$PROJ" --tempo 76 --name "Cathedral of Ash"

# --- ноды: 4 партии (ноты + инструмент) и сумматор ---
run node add euterpia.notes  --name LuteNotes   --file "$PROJ" >/dev/null
run node add euterpia.guitar --name Guitar      --file "$PROJ" >/dev/null
run node add euterpia.notes  --name HarpNotes   --file "$PROJ" >/dev/null
run node add euterpia.piano  --name Piano       --file "$PROJ" >/dev/null
run node add euterpia.notes  --name ChoirNotes  --file "$PROJ" >/dev/null
run node add euterpia.organ  --name Organ       --file "$PROJ" >/dev/null
run node add euterpia.notes  --name WarNotes    --file "$PROJ" >/dev/null
run node add euterpia.drums  --name Drums       --file "$PROJ" >/dev/null
run node add euterpia.mix    --name Mix         --file "$PROJ" >/dev/null

# --- события: ноты каждой партии в свой инструмент ---
run connect LuteNotes:event:0  Guitar:event:0 --file "$PROJ" >/dev/null
run connect HarpNotes:event:0  Piano:event:0  --file "$PROJ" >/dev/null
run connect ChoirNotes:event:0 Organ:event:0  --file "$PROJ" >/dev/null
run connect WarNotes:event:0   Drums:event:0  --file "$PROJ" >/dev/null

# --- аудио: все в сумматор ---
run connect Guitar:out Mix:audio:0 --file "$PROJ" >/dev/null
run connect Piano:out  Mix:audio:1 --file "$PROJ" >/dev/null
run connect Organ:out  Mix:audio:2 --file "$PROJ" >/dev/null
run connect Drums:out  Mix:audio:3 --file "$PROJ" >/dev/null

# --- тембры и баланс (лютня слева, арфа справа, орган/барабаны в центре) ---
run param set Guitar level -4  --file "$PROJ" >/dev/null
run param set Guitar tone  0.60 --file "$PROJ" >/dev/null
run param set Guitar pan  -0.20 --file "$PROJ" >/dev/null
run param set Piano  level -5  --file "$PROJ" >/dev/null
run param set Piano  tone  0.50 --file "$PROJ" >/dev/null
run param set Piano  pan   0.22 --file "$PROJ" >/dev/null
run param set Organ  level -5  --file "$PROJ" >/dev/null
run param set Organ  bars  0.62 --file "$PROJ" >/dev/null
run param set Drums  level -4  --file "$PROJ" >/dev/null
run param set Mix    level   0  --file "$PROJ" >/dev/null

# --- партитуры: порядок дорожек = порядок нотных нод ---
run notation import "$HERE/guitar.notes" --track 0 --name lute   --file "$PROJ" >/dev/null
run notation import "$HERE/piano.notes"  --track 1 --name harp   --file "$PROJ" >/dev/null
run notation import "$HERE/organ.notes"  --track 2 --name choir  --file "$PROJ" >/dev/null
run notation import "$HERE/drums.notes"  --track 3 --name war    --file "$PROJ" >/dev/null

echo "--- graph check ---"
run graph check --file "$PROJ" | tail -3

echo "--- render ---"
run render "$PROJ" "$OUT" --bits 16 | tail -6

echo "--- analyze ---"
run analyze "$OUT" || true
