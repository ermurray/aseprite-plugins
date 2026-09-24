#!/usr/bin/env bash
# Runs Lua tests inside headless Aseprite. Usage: scripts/test-lua.sh [test_name_filter]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASE="${ASEPRITE:-}"
if [ -z "$ASE" ]; then
  for c in \
    "$HOME/Library/Application Support/Steam/steamapps/common/Aseprite/Aseprite.app/Contents/MacOS/aseprite" \
    "/Applications/Aseprite.app/Contents/MacOS/aseprite" \
    "$(command -v aseprite || true)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then ASE="$c"; break; fi
  done
fi
[ -n "$ASE" ] || { echo "Aseprite binary not found; set ASEPRITE=/path/to/aseprite" >&2; exit 1; }
exec "$ASE" -b --script-param root="$ROOT" --script-param only="${1:-}" --script "$ROOT/tests/lua/run.lua"
