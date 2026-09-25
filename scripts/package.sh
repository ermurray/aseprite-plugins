#!/usr/bin/env bash
# Builds dist/aseprite-agent-<version>.aseprite-extension (extension + bundled bridge).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(node -p "require('$ROOT/extension/package.json').version")"
(cd "$ROOT/bridge" && npm run --silent bundle >/dev/null)
STAGE="$(mktemp -d)"
rsync -a --exclude bridge "$ROOT/extension/" "$STAGE/"
mkdir -p "$STAGE/bridge"
cp "$ROOT/bridge/dist/bridge.mjs" "$STAGE/bridge/bridge.mjs"
cp "$ROOT/LICENSE" "$ROOT/README.md" "$STAGE/"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/aseprite-agent-$VERSION.aseprite-extension"
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" .)
echo "$OUT"
