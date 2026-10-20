#!/usr/bin/env bash
# tools/script_scenario.sh
#
# Сценарий как тест (issues #333, #335): golden-прогон в CI.
#
# Проверяется то, чего не видит unit-тест библиотеки:
#   * `script plan` не меняет проект — снимок файла до/после;
#   * `script run` применяет сценарий и оставляет запись истории;
#   * один и тот же сценарий даёт побайтово тот же WAV (детерминизм);
#   * эталон рендера ловится по метрикам и сэмплам, а расхождение — код 1;
#   * `--update-baseline --dry-run` НЕ переписывает эталон;
#   * `--script`/stdin в `--json` дают NDJSON: каждая строка — JSON.
#
# Использование: tools/script_scenario.sh build/euterpia
# Код возврата: 0 — сценарий прошёл, 1 — нет.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

CLI="${1:-build/euterpia}"
BASE="tests/scenarios/golden.base.eproj"
SCENARIO="tests/scenarios/golden.eus"
BASELINE="tests/scenarios/golden.baseline.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$CLI" ] || fail "CLI не найден или не исполняемый: $CLI"
CLI="$(cd "$(dirname "$CLI")" && pwd)/$(basename "$CLI")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sha() { python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha1(open(sys.argv[1], 'rb').read()).hexdigest())
PY
}

echo "— script plan не меняет проект"
BASE_SHA="$(sha "$BASE")"
PLAN1="$("$CLI" script plan "$SCENARIO" --file "$BASE" --json)" ||
  fail "script plan вернул ошибку"
BASE_SHA2="$(sha "$BASE")"
[ "$BASE_SHA" = "$BASE_SHA2" ] || fail "plan изменил проект"
echo "$PLAN1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"], d
assert d["changed"] is True, "план не увидел изменений"
assert d["counts"]["nodes"]["delta"] == 2, d["counts"]
assert d["counts"]["connections"]["delta"] == 1, d["counts"]
' || fail "plan: неверная схема/сводка"
PLAN2="$("$CLI" script plan "$SCENARIO" --file "$BASE" --json)" ||
  fail "повторный plan вернул ошибку"
[ "$PLAN1" = "$PLAN2" ] || fail "вывод плана недетерминирован"

echo "— script run применяет сценарий одной транзакцией"
cp "$BASE" "$WORK/run.eproj"
"$CLI" script run "$SCENARIO" --file "$WORK/run.eproj" >/dev/null ||
  fail "script run вернул ошибку"
python3 - "$WORK/run.eproj" <<'PY' || fail "run: проект не тот"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["graph"]["nodes"][0]["parameters"]["freq"] == 220.0, d["graph"]["nodes"]
assert len(d["graph"]["connections"]) == 1
PY
[ -f "$WORK/run.eproj.history" ] || fail "run не записал историю"

echo "— повторный run отвергается и не оставляет половины изменений"
RUN_SHA="$(sha "$WORK/run.eproj")"
if "$CLI" script run "$SCENARIO" --file "$WORK/run.eproj" >/dev/null 2>&1; then
  fail "повторный run должен отказать: сценарий не идемпотентен"
fi
[ "$RUN_SHA" = "$(sha "$WORK/run.eproj")" ] ||
  fail "неудачный run изменил проект"

echo "— script build собирает с нуля и повторяется"
"$CLI" script build "$SCENARIO" --file "$WORK/build-a.eproj" \
  --base "$BASE" >/dev/null || fail "script build (a) вернул ошибку"
"$CLI" script build "$SCENARIO" --file "$WORK/build-b.eproj" \
  --base "$BASE" >/dev/null || fail "script build (b) вернул ошибку"
cmp -s "$WORK/build-a.eproj" "$WORK/build-b.eproj" ||
  fail "две сборки из одного сценария различаются"
"$CLI" graph check "$WORK/build-a.eproj" >/dev/null ||
  fail "собранный проект не проходит graph check"
BUILD_SHA="$(sha "$WORK/build-a.eproj")"
if "$CLI" script build "$SCENARIO" --file "$WORK/build-a.eproj" \
     --base "$BASE" >/dev/null 2>&1; then
  fail "повторный build без --force должен отказать"
fi
[ "$BUILD_SHA" = "$(sha "$WORK/build-a.eproj")" ] ||
  fail "отказ build изменил проект"

echo "— build архивирует историю, init --force — тоже (#416)"
cp "$BASE" "$WORK/hist.eproj"
"$CLI" script run "$SCENARIO" --file "$WORK/hist.eproj" >/dev/null ||
  fail "run для проверки архива истории"
"$CLI" script build "$SCENARIO" --file "$WORK/hist.eproj" --force >/dev/null ||
  fail "build --force поверх истории"
[ -f "$WORK/hist.eproj.history.bak" ] ||
  fail "build не архивировал историю"
if "$CLI" undo "$WORK/hist.eproj" >/dev/null 2>&1; then
  fail "undo после build должен сказать «отменять нечего»"
fi
"$CLI" init "$WORK/initarch.eproj" --force >/dev/null ||
  fail "init (свежий)"
"$CLI" node add osc --file "$WORK/initarch.eproj" >/dev/null ||
  fail "node add для проверки архива"
"$CLI" init "$WORK/initarch.eproj" --force >/dev/null ||
  fail "init --force"
[ -f "$WORK/initarch.eproj.history.bak" ] ||
  fail "init --force не архивировал историю"

echo "— golden-рендер детерминирован"
"$CLI" script render "$SCENARIO" --file "$BASE" --out "$WORK/a.wav" \
  --seconds 1 --baseline "$BASELINE" --samples >/dev/null 2>&1 ||
  fail "рендер не совпал с эталоном"
"$CLI" script render "$SCENARIO" --file "$BASE" --out "$WORK/b.wav" \
  --seconds 1 --baseline "$BASELINE" --samples >/dev/null 2>&1 ||
  fail "второй рендер не совпал с эталоном"
cmp -s "$WORK/a.wav" "$WORK/b.wav" || fail "два прогона дали разные WAV"

echo "— правка сценария ловится эталоном (код 1)"
sed 's/"freq": 220/"freq": 330/' "$SCENARIO" > "$WORK/loud.eus"
DIFF="$("$CLI" --json script render "$WORK/loud.eus" --file "$BASE" \
  --out "$WORK/loud.wav" --seconds 1 --baseline "$BASELINE" --samples)"
DIFF_CODE=$?
[ "$DIFF_CODE" = "1" ] || fail "расхождение с эталоном дало код $DIFF_CODE, а не 1"
echo "$DIFF" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert not d["ok"], d
assert d["differences"], "различия не названы"
assert any("сценарий изменился" in item for item in d["differences"]), d["differences"]
' || fail "расхождение: различия не описаны"

echo "— эталон не переписывается молча"
BASELINE_SHA="$(sha "$BASELINE")"
"$CLI" script render "$SCENARIO" --file "$BASE" --out "$WORK/c.wav" \
  --seconds 1 --baseline "$BASELINE" --update-baseline --dry-run \
  >/dev/null 2>&1 || fail "dry-run обновления эталона вернул ошибку"
[ "$BASELINE_SHA" = "$(sha "$BASELINE")" ] ||
  fail "--dry-run переписал эталон"

echo "— --script и stdin дают NDJSON (--json)"
cat > "$WORK/batch.txt" <<EOF
# сценарий строк-команд: проект открывается один раз
open $WORK/run.eproj
node list
status
EOF
"$CLI" --json --script "$WORK/batch.txt" > "$WORK/batch.ndjson" ||
  fail "--script вернул ошибку"
"$CLI" --json < "$WORK/batch.txt" > "$WORK/stdin.ndjson" ||
  fail "stdin-сценарий вернул ошибку"
python3 - "$WORK/batch.ndjson" "$WORK/stdin.ndjson" <<'PY' || fail "NDJSON невалиден"
import json, sys
for path in sys.argv[1:]:
    lines = [l for l in open(path, encoding='utf-8').read().splitlines() if l.strip()]
    assert lines, path
    for line in lines:
        obj = json.loads(line)
        assert obj.get("schema") == 1, (path, line)
    last = json.loads(lines[-1])
    assert last["executed"] >= 2, last
    assert last["failed"] == 0, last
PY

echo "— НЕ исполняется shell: строка с ; остаётся аргументом"
cat > "$WORK/unsafe.txt" <<EOF
open $WORK/run.eproj
node add osc; touch $WORK/shell-ran
EOF
if "$CLI" --script "$WORK/unsafe.txt" >/dev/null 2>&1; then
  fail "строка с ';' должна была отказать"
fi
[ -e "$WORK/shell-ran" ] && fail "shell-команда из сценария исполнилась"

echo "ok: сценарий прошёл — план, транзакция, сборка, golden-рендер и NDJSON (#333, #335, #416)"
