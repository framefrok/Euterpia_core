#!/usr/bin/env bash
# compositions/dark-requiem/build.sh
#
# "A Requiem for the Hollow Crown" - a dark-fantasy test piece built ONLY
# through the CLI (#348-#351). It is a working demonstration of the whole
# command surface: a custom graph, notation import, parameter automation,
# strict validation, project diff, offline render, inspector with an HTML
# report, one-shot watch, CI gate, delivery master and a recorded scenario.
#
# Usage: ./build.sh [path-to-euterpia]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
E="${1:-${EUTERPIA:-$ROOT/build/euterpia}}"
WORK="$HERE/build"
PROJ="$WORK/requiem.eproj"
OUT="$WORK/requiem.wav"
DELIVERY="$WORK/delivery"

[ -x "$E" ] || { echo "dark-requiem: no executable: $E" >&2; exit 1; }
rm -rf "$WORK"
mkdir -p "$WORK" "$DELIVERY"

run() {
  echo "+ euterpia $*"
  "$E" "$@"
}

# --- project ---------------------------------------------------------------
run init "$PROJ" --tempo 72 --name "A Requiem for the Hollow Crown" \
  --author "EUTERPIA test suite" >/dev/null

# --- graph: 6 voices, a crypt delay and a master mixer ---------------------
run node add euterpia.notes   --id 1  --name StringsNotes --file "$PROJ" >/dev/null
run node add euterpia.strings --id 2  --name Strings      --file "$PROJ" >/dev/null
run node add euterpia.notes   --id 3  --name ChoirNotes   --file "$PROJ" >/dev/null
run node add euterpia.choir   --id 4  --name Choir        --file "$PROJ" >/dev/null
run node add euterpia.notes   --id 5  --name HarpNotes    --file "$PROJ" >/dev/null
run node add euterpia.harp    --id 6  --name Harp         --file "$PROJ" >/dev/null
run node add euterpia.notes   --id 7  --name FluteNotes   --file "$PROJ" >/dev/null
run node add euterpia.flute   --id 8  --name Flute        --file "$PROJ" >/dev/null
run node add euterpia.notes   --id 9  --name TimpaniNotes --file "$PROJ" >/dev/null
run node add euterpia.timpani --id 10 --name Timpani      --file "$PROJ" >/dev/null
run node add euterpia.notes   --id 11 --name BellNotes    --file "$PROJ" >/dev/null
run node add euterpia.bell    --id 12 --name Bell         --file "$PROJ" >/dev/null
run node add euterpia.delay   --id 13 --name Crypt        --file "$PROJ" >/dev/null
run node add euterpia.mix     --id 14 --name Mix          --file "$PROJ" >/dev/null

# events: each notes node drives its instrument
for pair in "1 2" "3 4" "5 6" "7 8" "9 10" "11 12"; do
  set -- $pair
  run connect "$1:event:0" "$2:event:0" --file "$PROJ" >/dev/null
done

# audio: voices into the mixer; harp also feeds the crypt delay
run connect Strings:out Mix:audio:0 --file "$PROJ" >/dev/null
run connect Choir:out   Mix:audio:1 --file "$PROJ" >/dev/null
run connect Harp:out    Mix:audio:2 --file "$PROJ" >/dev/null
run connect Harp:out    Crypt:in:0  --file "$PROJ" >/dev/null
run connect Crypt:out   Mix:audio:6 --file "$PROJ" >/dev/null
run connect Flute:out   Mix:audio:3 --file "$PROJ" >/dev/null
run connect Timpani:out Mix:audio:4 --file "$PROJ" >/dev/null
run connect Bell:out    Mix:audio:5 --file "$PROJ" >/dev/null

# --- voices ----------------------------------------------------------------
run param set Strings level -12  --file "$PROJ" >/dev/null
run param set Strings tone  0.35 --file "$PROJ" >/dev/null
run param set Strings vibrato 12 --file "$PROJ" >/dev/null
run param set Strings ensemble 10 --file "$PROJ" >/dev/null
run param set Strings pan  -0.25 --file "$PROJ" >/dev/null
run param set Choir  level -18  --file "$PROJ" >/dev/null
run param set Choir  tone  0.42 --file "$PROJ" >/dev/null
run param set Choir  vibrato 7 --file "$PROJ" >/dev/null
run param set Harp   level -14  --file "$PROJ" >/dev/null
run param set Harp   tone  0.55 --file "$PROJ" >/dev/null
run param set Harp   damping 0.7 --file "$PROJ" >/dev/null
run param set Harp   pan   0.22 --file "$PROJ" >/dev/null
run param set Flute  level -13  --file "$PROJ" >/dev/null
run param set Flute  tone  0.62 --file "$PROJ" >/dev/null
run param set Flute  breath 0.32 --file "$PROJ" >/dev/null
run param set Timpani level -12 --file "$PROJ" >/dev/null
run param set Timpani decay 2.4 --file "$PROJ" >/dev/null
run param set Bell   level -18  --file "$PROJ" >/dev/null
run param set Bell   decay 8.0  --file "$PROJ" >/dev/null
run param set Bell   tone  0.4  --file "$PROJ" >/dev/null
run param set Crypt  time_l 0.36 --file "$PROJ" >/dev/null
run param set Crypt  time_r 0.48 --file "$PROJ" >/dev/null
run param set Crypt  feedback 0.35 --file "$PROJ" >/dev/null
run param set Crypt  mix 0.25   --file "$PROJ" >/dev/null
run param set Mix    level -6   --file "$PROJ" >/dev/null

# --- score: track order must match the note-node order ---------------------
run notation check "$HERE/score/strings.notes" --time-sig 4/4
run notation import "$HERE/score/strings.notes" --track 0 --name strings --file "$PROJ" >/dev/null
run notation import "$HERE/score/choir.notes"   --track 1 --name choir   --file "$PROJ" >/dev/null
run notation import "$HERE/score/harp.notes"    --track 2 --name harp    --file "$PROJ" >/dev/null
run notation import "$HERE/score/flute.notes"   --track 3 --name flute   --file "$PROJ" >/dev/null
run notation import "$HERE/score/timpani.notes" --track 4 --name timpani --file "$PROJ" >/dev/null
run notation import "$HERE/score/bell.notes"    --track 5 --name bell    --file "$PROJ" >/dev/null

# --- structure before sound ------------------------------------------------
run graph check "$PROJ" | tail -3
run project validate --strict "$PROJ" | tail -3


# --- automation: the piece breathes ---------------------------------------
cp "$PROJ" "$WORK/before-automation.eproj"
for point in "0 -14" "5760 -10" "11520 -8" "17280 -11" "23040 -14"; do
  set -- $point
  run automation add "$PROJ" --node 14 --param level --tick "$1" --value "$2" --curve smooth >/dev/null
done
for point in "0 -30" "5760 -20" "11520 -16" "17280 -22"; do
  set -- $point
  run automation add "$PROJ" --node 4 --param level --tick "$1" --value "$2" --curve smooth >/dev/null
done
for point in "0 -30" "5760 -16" "11520 -20" "17280 -12" "23040 -26"; do
  set -- $point
  run automation add "$PROJ" --node 12 --param level --tick "$1" --value "$2" --curve smooth >/dev/null
done

# A diff is a verdict: automation changed the project, so --exit-code is 1.
if "$E" project diff "$WORK/before-automation.eproj" "$PROJ" --exit-code \
     > "$WORK/diff.txt" 2>&1; then
  echo "dark-requiem: project diff did not detect automation" >&2
  exit 1
fi
echo "project diff: differences detected (automation), sample:"
grep -m 3 'lane:' "$WORK/diff.txt" || true

# --- sound -----------------------------------------------------------------
run render "$PROJ" "$OUT" --bits 24 | tail -6
run analyze "$OUT" --html "$WORK/report.html" --fail-on error | head -12

# A one-shot watch render proves the iterative loop without keeping a process.
run watch "$PROJ" --out "$WORK/preview.wav" --seconds 4 --once | tail -3

# CI gate: validate -> graph -> render -> analyze on a short fragment.
run ci check "$PROJ" --seconds 2 > "$WORK/ci.txt"
tail -3 "$WORK/ci.txt"

# Delivery master: 24-bit FLAC with metadata (no external encoder needed).
run master "$PROJ" --format flac --out "$DELIVERY/requiem.flac" \
  --target -16 --ceiling -1 --bits 24 \
  --meta "title=A Requiem for the Hollow Crown" \
  --meta "artist=EUTERPIA test suite" \
  --meta "genre=Dark fantasy" \
  --meta "comment=Built entirely through the EUTERPIA CLI" > /dev/null

# Record the build as a scenario and show what a rebuild would do, without
# writing it (script plan takes the document by value).
run script record "$WORK/requiem.eus" "$PROJ" --last 200 \
  --description "dark requiem built via CLI" > /dev/null
run script plan --build "$WORK/requiem.eus" --file "$WORK/rebuilt.eproj" \
  --base "$PROJ" | tail -4

echo
echo "dark-requiem: done"
echo "  project : $PROJ"
echo "  wav     : $OUT"
echo "  flac    : $DELIVERY/requiem.flac"
echo "  report  : $WORK/report.html"
echo "  scenario: $WORK/requiem.eus"

