#!/usr/bin/env bash
# tools/quickstart.sh
#
# Run the executable quick-start from docs/quickstart.md (#351).
#
# The documentation is the source of truth: this script extracts the
# `quickstart:begin`/`quickstart:end` block and executes it in a temporary
# directory. A stale command in the document therefore fails CI instead of
# misleading a new user.
#
# Usage: tools/quickstart.sh [path-to-euterpia] [--doc FILE] [--max-seconds N]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${1:-$ROOT/build/euterpia}"
if [ "${CLI#-}" != "$CLI" ]; then
  CLI="$ROOT/build/euterpia"
else
  shift || true
fi
DOC="$ROOT/docs/quickstart.md"
MAX_SECONDS=300

while [ "$#" -gt 0 ]; do
  case "$1" in
    --doc) DOC="$2"; shift 2 ;;
    --max-seconds) MAX_SECONDS="$2"; shift 2 ;;
    *) echo "quickstart: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -x "$CLI" ] || { echo "quickstart: no executable: $CLI" >&2; exit 1; }
[ -f "$DOC" ] || { echo "quickstart: no document: $DOC" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "quickstart: awk is required" >&2; exit 1; }

BLOCK="$(awk '
  /<!-- quickstart:begin -->/ {inside=1; next}
  /<!-- quickstart:end -->/ {inside=0}
  inside {print}
' "$DOC")"
[ -n "$BLOCK" ] || { echo "quickstart: empty command block in $DOC" >&2; exit 1; }

# Strip the markdown fence; keep only commands.
COMMANDS="$(printf '%s\n' "$BLOCK" | awk '
  /^```/ {next}
  {print}
')"
[ -n "$COMMANDS" ] || { echo "quickstart: no commands in the block" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
ln -s "$(cd "$(dirname "$CLI")" && pwd)/$(basename "$CLI")" "$WORK/bin/euterpia"
export PATH="$WORK/bin:$PATH"
# Make repository presets visible when running from a checkout; installed
# packages are found through the binary's prefix automatically.
if [ -d "$ROOT/presets" ]; then
  export EUTERPIA_PRESETS="$ROOT/presets"
fi

SCRIPT="$WORK/quickstart.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'set -x'
  printf '%s\n' "$COMMANDS"
} > "$SCRIPT"
chmod +x "$SCRIPT"

echo "— quick start from $DOC"
START="$(date +%s)"
( cd "$WORK" && bash "$SCRIPT" )
ELAPSED=$(( $(date +%s) - START ))

for artifact in quickstart.eproj quickstart.wav; do
  [ -s "$WORK/$artifact" ] || {
    echo "quickstart: missing artifact: $artifact" >&2
    exit 1
  }
done

if [ "$ELAPSED" -gt "$MAX_SECONDS" ]; then
  echo "quickstart: took ${ELAPSED}s, limit is ${MAX_SECONDS}s" >&2
  exit 1
fi
echo "ok: quick start completed in ${ELAPSED}s (<${MAX_SECONDS}s), project and sound produced"
