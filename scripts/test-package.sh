#!/usr/bin/env bash
# Builds the extension package and checks its contents and that the bundled bridge runs standalone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/package.sh" >/dev/null
PKG="$ROOT/dist/aseprite-agent-0.9.0.aseprite-extension"
[ -f "$PKG" ] || { echo "missing $PKG"; exit 1; }
LIST="$(unzip -l "$PKG")"
for f in package.json plugin.lua agent/chat_window.lua agent/tools/init.lua bridge/bridge.mjs LICENSE README.md; do
  echo "$LIST" | grep -q " $f\$" || { echo "package lacks $f"; exit 1; }
done
TMP="$(mktemp -d)"
unzip -q "$PKG" -d "$TMP"
[ "$(node "$TMP/bridge/bridge.mjs" --version)" = "0.9.0" ] || { echo "bundled bridge failed"; exit 1; }
grep -q '"version": "0.9.0"' "$TMP/package.json" || { echo "wrong extension version"; exit 1; }
echo "package OK"
