#!/usr/bin/env bash
# Links extension/ into Aseprite's user extensions folder. Restart Aseprite afterwards.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname)" in
  Darwin) EXT_DIR="$HOME/Library/Application Support/Aseprite/extensions" ;;
  Linux)  EXT_DIR="$HOME/.config/aseprite/extensions" ;;
  *) echo "Unsupported OS; install manually" >&2; exit 1 ;;
esac
mkdir -p "$EXT_DIR"
ln -sfn "$ROOT/extension" "$EXT_DIR/aseprite-agent"
echo "Linked $ROOT/extension -> $EXT_DIR/aseprite-agent"
echo "If 'Agent Chat' does not appear under Edit after restarting Aseprite, use the fallback:"
echo "  (cd extension && zip -r ../aseprite-agent.aseprite-extension .) and open that file with Aseprite."
