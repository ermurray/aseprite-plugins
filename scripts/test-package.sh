#!/usr/bin/env bash
# Builds the extension package and checks its contents and that the bundled bridge runs standalone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/package.sh" >/dev/null
VERSION="$(node -p "require('$ROOT/extension/package.json').version")"
PKG="$ROOT/dist/aseprite-agent-$VERSION.aseprite-extension"
[ -f "$PKG" ] || { echo "missing $PKG"; exit 1; }
LIST="$(unzip -l "$PKG")"
for f in package.json plugin.lua agent/chat_window.lua agent/tools/init.lua bridge/bridge.mjs LICENSE README.md; do
  echo "$LIST" | grep -q " $f\$" || { echo "package lacks $f"; exit 1; }
done
TMP="$(mktemp -d)"
unzip -q "$PKG" -d "$TMP"
[ "$(node "$TMP/bridge/bridge.mjs" --version)" = "$VERSION" ] || { echo "bundled bridge version differs from the extension ($VERSION)"; exit 1; }
echo "package OK"
