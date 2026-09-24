# Aseprite Agent Chat

An Aseprite extension with a chat window that connects an AI agent (Claude first) to assist the artist: critique, palettes, cleanup, reuse of your own work, and exports. An art assistant, not an art generator.

Status: design phase. See [the design spec](docs/superpowers/specs/2026-09-24-aseprite-agent-chat-design.md).

## Development

Requirements: Aseprite ≥ 1.3.18, Node ≥ 20, Claude Code installed and logged in (`claude`).

```bash
cd bridge && npm install && npm run build
npm start                    # bridge on 127.0.0.1:47821, writes ~/.aseprite-agent/bridge.json
scripts/dev-install.sh       # copy the extension into Aseprite (re-run after changes), then restart Aseprite
```

In Aseprite, choose **Edit → Agent Chat**.

Tests:

```bash
cd bridge && npm test        # bridge (Vitest)
scripts/test-lua.sh          # Lua tools and chat layout, headless Aseprite (set ASEPRITE=... if not auto-found)
cd bridge && npm run smoke -- "hello"   # real Claude round-trip with a fake extension
```
