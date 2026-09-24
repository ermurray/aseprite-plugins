#!/usr/bin/env bash
# Copies extension/ into Aseprite's user extensions folder (Aseprite skips symlinked
# extension folders). Re-run after changing extension code, then restart Aseprite.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname)" in
  Darwin) EXT_DIR="$HOME/Library/Application Support/Aseprite/extensions" ;;
  Linux)  EXT_DIR="$HOME/.config/aseprite/extensions" ;;
  *) echo "Unsupported OS; install manually" >&2; exit 1 ;;
esac
DEST="$EXT_DIR/aseprite-agent"
mkdir -p "$EXT_DIR"
[ -L "$DEST" ] && rm "$DEST"
rsync -a --delete "$ROOT/extension/" "$DEST/"
echo "Copied $ROOT/extension -> $DEST"
echo "Restart Aseprite to load it. If 'Agent Chat' still does not appear under Edit, use the fallback:"
echo "  (cd extension && zip -r ../aseprite-agent.aseprite-extension .) and open that file with Aseprite."
