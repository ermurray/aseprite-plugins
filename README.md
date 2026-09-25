# Aseprite Agent Chat

An Aseprite extension with a chat window that connects an AI agent (Claude first) to assist the artist: critique, palettes, cleanup, reuse of your own work, and exports. An art assistant, not an art generator.

## Install

1. Install [Claude Code](https://claude.com/claude-code) and log in (run `claude` once in a terminal).
2. Install Node.js 20 or newer (nodejs.org, or `brew install node`).
3. Download `aseprite-agent-<version>.aseprite-extension` and open it with Aseprite
   (or Edit > Preferences > Extensions > Add Extension), then restart Aseprite.
4. Edit > Agent Chat (bind a key in Edit > Keyboard Shortcuts). The assistant starts by itself
   the first time; it stops by itself about 15 minutes after Aseprite closes.

## What it does

An art assistant, not an art generator: critique and teaching, palette and color help, small approved
edits (one undo each), teaching marks, FX (dither, pixel-perfect, selout, gradients, normal maps),
tool setup, extension recommendations, scripts you approve, clips, imports and exports.
Projects (a folder with `.artproject/`) keep a brief, memory, palette and chat history.

Design: [spec](docs/superpowers/specs/2026-09-24-aseprite-agent-chat-design.md) and the [plans](docs/superpowers/plans/).

## Development

Requirements: Aseprite ≥ 1.3.18, Node ≥ 20, Claude Code installed and logged in (`claude`).

```bash
cd bridge && npm install && npm run build
ASEPRITE_AGENT_IDLE_MINUTES=0 npm start   # bridge on 127.0.0.1:47821 (0 = never idle-stop while developing)
scripts/dev-install.sh       # copy the extension + bundled bridge into Aseprite (re-run after changes), then restart Aseprite
scripts/package.sh           # build dist/aseprite-agent-<version>.aseprite-extension
```

In Aseprite, choose **Edit → Agent Chat**.

Tests:

```bash
cd bridge && npm test        # bridge (Vitest)
scripts/test-lua.sh          # Lua tools and chat layout, headless Aseprite (set ASEPRITE=... if not auto-found)
cd bridge && npm run smoke -- "hello"   # real Claude round-trip with a fake extension
```
