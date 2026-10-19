#!/usr/bin/env bash
# tools/plugin_cli_scenario.sh
#
# Сквозной приёмочный сценарий issue #95 (и часть #260):
#
#   plugin scan → node add plugin:<id> → connect → plugin save → render
#
# Проверяется то, что нельзя проверить unit-тестом: пользовательский путь
# «взять .clap и получить звук», состояние плагина переживает save/load,
# а `plugin validate` честно отказывает без валидатора (код 2).
#
# Использование: tools/plugin_cli_scenario.sh build/euterpia build/libmockclap.so
# Код возврата: 0 — сценарий прошёл, 1 — нет.

set -u

CLI="${1:-build/euterpia}"
MOCK="${2:-build/libmockclap.so}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$CLI" ] || fail "CLI не найден или не исполняемый: $CLI"
# Абсолютный путь: сценарий меняет рабочий каталог на временный проект.
CLI="$(cd "$(dirname "$CLI")" && pwd)/$(basename "$CLI")"
[ -f "$MOCK" ] || fail "mock-плагин не собран: $MOCK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCK_ABS="$(cd "$(dirname "$MOCK")" && pwd)/$(basename "$MOCK")"

echo "— scan"
SCAN="$("$CLI" plugin scan "$MOCK_ABS" --json)" || fail "plugin scan вернул ошибку"
echo "$SCAN" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"], d
assert d["plugins"], "плагины не найдены"
assert d["plugins"][0]["id"], "пустой id"
assert d["plugins"][0]["params"] >= 1, "нет параметров"
' || fail "scan: неверная схема/данные"

PLUGIN_ID="$(echo "$SCAN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plugins"][0]["id"])')"
echo "  найден: $PLUGIN_ID"

echo "— info"
"$CLI" plugin info "$MOCK_ABS" --index 0 --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"], d
assert d["plugin"]["paramList"], "info не вернул параметры"
' || fail "plugin info: нет списка параметров"

echo "— проект: osc → plugin → master"
cd "$WORK" || fail "не удалось перейти в $WORK"
"$CLI" init p.eproj >/dev/null || fail "init"
"$CLI" node add osc --name o --file p.eproj >/dev/null || fail "node add osc"
"$CLI" node add "plugin:$PLUGIN_ID" --path "$MOCK_ABS" --name p \
  --file p.eproj >/dev/null || fail "node add plugin"
"$CLI" connect 1:out 2:in --file p.eproj >/dev/null || fail "connect"

echo "— save состояния"
SAVE="$("$CLI" plugin save p.eproj 2 --json)" || fail "plugin save"
echo "$SAVE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"], d
assert d["state"]["bytes"] > 0, "состояние пустое"
assert len(d["state"]["sha1"]) == 40, "нет sha1"
' || fail "save: неверная схема"

# Повторный save обязан дать те же байты (детерминизм состояния).
SAVE2="$("$CLI" plugin save p.eproj 2 --json)" || fail "plugin save (повтор)"
H1="$(echo "$SAVE" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"]["sha1"])')"
H2="$(echo "$SAVE2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"]["sha1"])')"
[ "$H1" = "$H2" ] || fail "состояние недетерминировано: $H1 != $H2"

echo "— params"
"$CLI" plugin params p.eproj 2 --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"], d
assert d["params"], "нет параметров инстанса"
' || fail "plugin params"

echo "— render"
"$CLI" render p.eproj out.wav --seconds 0.5 --master 2 --json \
  > render.json || fail "render"
python3 - <<'PY' || fail "render: выход пустой или файл не записан"
import json, os
d = json.load(open("render.json", encoding="utf-8"))
assert d["ok"], d
assert d["rendered"], d
assert not d["silent"], "плагин в графе не дал звука"
assert d["peak"] > 0.01, d["peak"]
assert os.path.getsize("out.wav") > 1024
PY

echo "— validate: без валидатора код 2"
set +e
"$CLI" plugin validate "$MOCK_ABS" --validator /nonexistent/clap-validator \
  --json > validate.json 2>/dev/null
CODE=$?
set -e
[ "$CODE" = "2" ] || fail "validate без валидатора: код $CODE, ожидался 2"

echo "OK: сценарий плагинов пройден"
