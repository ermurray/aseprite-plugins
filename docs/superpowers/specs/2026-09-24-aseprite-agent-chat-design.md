# Aseprite Agent Chat — Design

**Date:** 2026-09-24
**Status:** Draft for review

## 1. Purpose

An Aseprite extension that adds a chat window where an artist can talk to an AI
agent (Claude first) that **assists their art process**: critique, teaching,
palette work, cleanup, animation housekeeping, reuse of their own work, and
exports.

It is an art tool, not an art generator. The agent advises and makes small,
targeted, approved edits. Generating artwork is possible but deliberately
discouraged and quarantined (see §6).

**Audience:** the author first; designed so it can be packaged and published
to other Aseprite users later without restructuring.

### Success criteria (v1)

- Chat window opens inside Aseprite, streams Claude's replies, and survives
  switching sprites.
- Claude can inspect any sprite in the project (active or not) and tell sprites
  apart unambiguously.
- Every edit is shown as an approval card, names its target sprite, and undoes
  with a single Ctrl+Z.
- Conversations persist per project and can be resumed with agent context intact.
- Clips can be saved, browsed, inserted, and cleared; exports land next to their
  source by default.
- "Draw me X" requests get pushback; any generated blockout only ever lands on
  an "AI Draft" layer.

### Out of scope (v1)

- Docked panel (Aseprite's Lua `Dialog` API cannot dock yet; tracked upstream
  in aseprite/aseprite#5327, milestone v1.4-beta1).
- Adapters other than Claude Code (interface designed, not implemented).
- Browser-based chat view (protocol allows it later).
- Anthropic API-key adapter (planned for publishing).

## 2. Architecture

```
Aseprite extension (Lua)                  Bridge (Node + TypeScript, local)
 ├─ Chat window (Dialog + canvas)    ⇄     ├─ WebSocket server 127.0.0.1:<port>
 ├─ WebSocket client                 WS    ├─ Session / project / transcript store
 ├─ Tool executor (sprite I/O,             ├─ Tool layer (schemas, approval, budgets)
 │   transactions)                         ├─ Adapter interface
 └─ Clips UI, project setup                │    └─ ClaudeCodeAdapter (Agent SDK)
                                           └─ System prompt
```

- **Extension** = UI and sprite access only. No AI logic.
- **Bridge** = conversation, agent adapter, tool definitions, approval gating,
  pixel budgets, persistence. Knows Aseprite only through tool schemas.
- Chosen over (B) browser chat + tool-only extension and (C) MCP-only/terminal
  chat, because the user wants the chat inside Aseprite. The protocol keeps (B)
  cheap to add later, and the tool layer can be exposed as an MCP server later.

### Repository layout

```
aseprite-plugins/
├─ extension/                 → packaged as aseprite-agent.aseprite-extension
│  ├─ package.json            Aseprite extension manifest
│  ├─ plugin.lua              init/exit; registers commands:
│  │                            "Agent Chat" (Edit menu + shortcut)
│  │                            "Save Selection as Clip" (Edit menu)
│  ├─ chat_window.lua         Dialog: history canvas, input, Send/Stop, 📎, 📌,
│  │                            status dot, New chat, History ▾, Chat/Clips tabs
│  ├─ chat_render.lua         pure text wrap + layout (no Aseprite deps)
│  ├─ approval_card.lua       renders approval cards, handles Apply/Deny
│  ├─ clips_view.lua          thumbnail grid, filter, insert/rename/delete/pin/clear
│  ├─ connection.lua          WebSocket client, token, reconnect, JSON routing
│  ├─ project.lua             find .artproject upward; create project
│  ├─ context.lua             builds the per-message context stamp
│  ├─ tools/                  inspect.lua, pixels.lua, palette.lua, layers.lua,
│  │                          frames.lua, commands.lua, annotate.lua,
│  │                          import.lua, clips.lua, export.lua
│  └─ json.lua                use Aseprite's built-in json if present, else vendored
├─ bridge/
│  ├─ src/server.ts           WS server, token check, one session per connection
│  ├─ src/protocol.ts         message types (shared contract)
│  ├─ src/session.ts          active project, active conversation, turn state
│  ├─ src/project.ts          project.json load/defaults, paths
│  ├─ src/transcripts.ts      JSONL conversation store
│  ├─ src/clips.ts            clips.json index, LRU eviction, pinning
│  ├─ src/tools/              schemas + approval summaries + budget checks
│  ├─ src/adapters/Adapter.ts adapter interface
│  ├─ src/adapters/claudeCode.ts
│  └─ src/prompt.ts           system prompt
├─ tests/                     Aseprite headless test runner + fixture sprites
└─ docs/superpowers/specs/
```

## 3. Projects

Aseprite has no project concept, so the extension defines one: **a folder
containing `.artproject/`**. The folder name is a single constant.

```
my-game-art/
├─ .artproject/
│  ├─ project.json   settings (below)
│  ├─ brief.md       artist-owned style guide; read at the start of every chat
│  ├─ memory.md      agent-suggested notes, added only via approval
│  ├─ palette.gpl    optional master palette
│  ├─ chats/         <conversationId>.jsonl transcripts
│  └─ clips/         <name>.aseprite + clips.json
├─ characters/knight.aseprite
├─ characters/knight.png          ← exports live next to their source by default
└─ tiles/grass.aseprite
```

- **Discovery:** from the active sprite's directory, walk up to the first
  ancestor containing `.artproject/`. That folder is the project root.
- **Creation:** never manual. The chat window offers **"Make this folder a
  project"**, lets the user pick the root, creates `.artproject/`, and walks
  through a short brief (resolution, palette limits, outline style, light
  direction) written to `brief.md`.
- **No project:** chat falls back to a temporary conversation in
  `~/.aseprite-agent/chats/`, and the window keeps offering to create a project.
- **Unsaved sprites** (no path) belong to whichever project is currently active
  in the window, or to the fallback if none.
- **Ownership:** the agent never writes `brief.md`. It may propose additions to
  `memory.md` via approval cards. Both files are included in the system context.

### project.json (defaults)

```json
{
  "version": 1,
  "exports": { "location": "alongside" },
  "clips": { "max": 20 },
  "budgets": { "pixelsPerCall": 256, "pixelsPerTurn": 1024 },
  "aiDraft": { "layerName": "AI Draft", "opacity": 102 }
}
```

`exports.location` may instead be `"folder"` with `"path": "exports/"` and
`"mirrorTree": true` (→ `exports/characters/knight.png`). Opacity is 0–255
(102 ≈ 40%).

## 4. Conversations and history

- Conversations are **scoped to the project**, stored in
  `.artproject/chats/<id>.jsonl`. Each line is one event: user message (with
  context stamp), assistant text, tool call summary, tool result summary,
  approval decision. Snapshot images are **not** stored.
- The window opens the project's most recent conversation. **New chat** starts
  another. **History ▾** lists the project's conversations (title = first user
  message, date, sprites touched).
- Switching sprite tabs does **not** switch conversations.
- **Agent context resume:** each transcript header stores adapter resume state
  (for Claude Code: the Agent SDK session id). Opening a past conversation
  resumes the agent with its own context, not just replayed display text. If
  resume fails (session expired/missing), the adapter starts a new session
  seeded with a compact summary of the transcript and the chat says so.

### Telling sprites apart

- Every user message is prefixed (visible to the agent, shown subtly in the UI)
  with a context stamp, e.g.
  `[active: characters/knight.aseprite · frame 3/8 · layer "Body" · selection 12×8 @ (20,14) · open: knight, slime]`.
- Every tool takes a `sprite` argument: project-relative path; defaults to the
  active sprite. Unsaved sprites are addressed as `untitled:<n>`.
- `list_project_sprites` returns all `.aseprite`/`.ase` files under the root
  (ignoring `.artproject/`), with which ones are open.
- Tool activity lines and approval cards always name the target sprite.

### Reading and editing non-active sprites

- **Read:** the extension opens the file in the background, reads, closes it,
  and restores the previously active sprite. If it is already open, the open
  document is used (so unsaved changes are visible).
  *(To verify during planning: that open/close in a script is clean and does not
  disturb the user's tab state; fallback is reading via a hidden `Sprite{fromFile=}`
  if available.)*
- **Edit:** only on open sprites. If the target is not open, the approval card
  offers **Open & apply**, which opens it as a tab and applies the edit into
  that document's undo history. The user decides whether to save.

## 5. Tools

All tools take `sprite` (default: active). Coordinates are sprite pixels.
Frames are 1-based, matching Aseprite's UI.

### Read tools — no approval

| Tool | Returns |
|---|---|
| `list_project_sprites` | Paths, open state |
| `get_sprite_info` | Size, color mode, layer tree (name, visibility, opacity, blend mode), frames + durations, tags, selection, active layer/frame |
| `get_snapshot` | PNG of a frame / layer / region, nearest-neighbour upscaled to ~512px on the long edge, with the scale factor |
| `get_pixels` | Exact colors for a region ≤ 64×64 as a grid (hex, or index in indexed mode) |
| `get_palette` | Palette entries |
| `analyze_colors` | Used colors + counts, near-duplicate pairs (ΔE threshold), unused palette entries |
| `list_clips` | Clip names, tags, sizes, frames, pinned, last used |

### Edit tools — approval required

| Tool | Notes |
|---|---|
| `set_palette`, `add_color_ramp` | Ramp takes base color, steps, hue-shift degrees |
| `replace_color` | Across a layer/frames/whole sprite; tolerance |
| `recolor_region` | Within a selection/rect |
| `layer_ops` | add, rename, reorder, visibility, opacity, blend mode |
| `frame_ops` | add, duplicate, durations, tags |
| `run_command` | Allowlist of built-in commands (e.g. Outline, Flip, color adjustments) applied to a selection/layer |
| `set_pixels` | Subject to pixel budgets (§6) |
| `annotate` | Circles, arrows, marks, short labels on the **"Agent Notes"** layer (created on demand, top of stack). Not budgeted. |
| `import_from_sprite` | Region/layer/frame range from another project sprite → new layer `⤵ <sprite> / <layer>`, pixels selected. Optional flip. Not budgeted. |
| `save_clip`, `insert_clip`, `delete_clip` | See §8. `insert_clip` behaves like `import_from_sprite`. |
| `export_sprite` | PNG / GIF / sprite sheet + JSON via Aseprite's export; path from project rules (§9) |
| `propose_memory` | Appends a line to `memory.md` |
| `request_draft_mode` | Records the artist's explicit insistence on a blockout (quoted); unlocks the AI Draft layer for this conversation (§6) |

### Approval flow

1. Bridge receives a tool call from the adapter, validates args, computes a
   human summary (e.g. *"Replace #c8503c → #b8443a on knight.aseprite › 'Body',
   frames 1–8 (312 px)"*), pixel count, and palette implications.
2. Bridge sends `approval_request`. Extension draws a card: **Apply / Deny**,
   plus contextual extras (**Open & apply**; for imports **Map to nearest** vs
   **Add missing colors to palette**; editable placement).
3. On Apply, bridge sends `tool_call`; extension executes inside
   `app.transaction("Agent: <summary>", fn)` wrapped in `pcall`.
4. Per-conversation **"Auto-approve edits"** toggle skips cards for edit tools,
   except `export_sprite`, `delete_clip`, and anything that must open a file.

Approval lives in the bridge's tool layer, not in the adapter, so every future
adapter inherits it.

## 6. The anti-generation stance

The tool discourages generation through friction at three levels.

1. **Prompt level.** System prompt defines the agent as an art mentor and
   assistant. On "draw/make me X" requests it pushes back once, explains why,
   and offers alternatives: construction breakdown, silhouette/proportion guide
   via `annotate`, palette, reference-style critique of the artist's first pass.
2. **Tool level.** `set_pixels` is capped at `pixelsPerCall` (256) and
   `pixelsPerTurn` (1024) outside the AI Draft layer. Enough for cleanup and
   fixes; impractical for painting a sprite. Over-budget calls are rejected
   with an explanatory error the agent relays.
3. **Quarantine.** If the artist insists after pushback, the agent may block
   out on the **"AI Draft"** layer only: created at 40% opacity, pixel budget
   lifted for that layer only, and the agent tells the artist to redraw over it
   and delete the layer. Nothing generated lands on the artist's layers.
   Enforcement is in the bridge: a `set_pixels` call targeting "AI Draft" is
   only allowed after the conversation has recorded an explicit insistence
   (the agent must call `request_draft_mode` with the user's quote, which shows
   its own approval card).

`import_from_sprite`, `insert_clip`, and `annotate` are not budgeted: they move
the artist's own work or draw on a notes layer.

## 7. Protocol

JSON text messages over WebSocket. Every message has `type`; request/response
pairs carry `id` / `callId`.

**Extension → bridge:** `hello{token, extensionVersion}`,
`context{activeSprite, projectRoot, openSprites}` (sent on connect and on
`sitechange`), `user_message{text, attachSnapshot}`, `cancel`,
`approval{callId, approved, options}`, `tool_result{callId, ok, data | error}`,
`new_chat`, `list_history`, `open_conversation{id}`, `create_project{root, brief}`,
`clips_ui{action, ...}` (user-initiated clip actions).

**Bridge → extension:** `session{projectRoot, conversationId, history}`,
`text_delta{text}`, `tool_activity{summary, sprite}`, `approval_request{callId,
summary, sprite, pixelCount, extras}`, `tool_call{callId, name, args}`,
`turn_done`, `status{adapter, state}`, `error{message, hint}`.

**Images** travel as temp file paths in the OS temp dir, not base64. The bridge
deletes them after reading.

**Security:** bridge binds to `127.0.0.1` only. On start it writes a random
token to `~/.aseprite-agent/bridge.json` (`{port, token, pid}`, mode 0600); the
extension reads it and sends it in `hello`. Connections without the token are
closed.

## 8. Clip library

- Stored per project: `.artproject/clips/<name>.aseprite` (keeps layers, frames,
  palette) plus `clips.json` (`name, tags, source{sprite, layer, region, frames},
  createdAt, lastUsedAt, pinned`).
- **Save:** Edit → *Save Selection as Clip* or 📌 in the window (name + tags
  prompt), or agent `save_clip` (approval).
- **Clips tab:** thumbnail grid (generated from the clip file, cached), filter by
  name/tag; per clip **Insert**, **Rename**, **Delete**, **Pin/Unpin**; plus
  **Clear all…** with confirmation (pinned clips included only if the user ticks
  "also pinned"). Clear-all is UI-only; the agent has no tool for it.
- **Limit:** `clips.max` (default 20). "Recent" = most recently saved or
  inserted. Saving beyond the limit evicts the least-recently-used **unpinned**
  clip, and the confirmation names it. If all clips are pinned and the limit is
  reached, saving is refused with a message.
- **Insert:** new layer named `⤵ clip / <name>`, pixels selected for the Move
  tool; multi-frame clips align from the current frame, adding frames if needed.
  Palette mismatch handling is the same as `import_from_sprite`.

## 9. Exports

- Default: `"location": "alongside"` → output goes in the same folder as the
  source `.aseprite` file (`knight.aseprite` → `knight.png`,
  `knight_sheet.png` + `knight_sheet.json`).
- Alternative: `"location": "folder"`, `"path"`, `"mirrorTree"`.
- Per-request override: the user can name any destination ("export to
  `../game/assets/`"); the approval card shows the final absolute path(s).
- Formats: PNG (frame or all frames), GIF, sprite sheet (+JSON) using
  Aseprite's own export commands.

## 10. Agent adapters

```ts
interface Adapter {
  start(opts: { systemPrompt: string; resume?: ResumeState }): Promise<void>;
  send(message: UserMessage): AsyncIterable<AdapterEvent>;
  // AdapterEvent: text_delta | tool_call | turn_done | error
  submitToolResult(callId: string, result: ToolResult): void;
  cancel(): void;
  resumeState(): ResumeState;   // persisted in transcript header
}
```

**ClaudeCodeAdapter (v1):** uses the Claude Agent SDK, which drives the user's
installed and logged-in `claude` CLI (subscription auth, no API key).

- Custom tools registered via an in-process SDK MCP server; handlers delegate
  to the bridge tool layer (validation → approval → forward to extension →
  result).
- All built-in Claude Code tools disabled (no Bash, file read/write, web).
  Only the aseprite tools are allowed.
- Streaming partial messages enabled for `text_delta`.
- Resume via stored session id.
- *(Exact SDK option names verified against current SDK docs during planning.)*

Future adapters (API key, other vendors, local models) implement the same
interface; approval, budgets, persistence, and tools are shared.

## 11. Chat window UI

- Floating, resizable `Dialog`; size and position remembered in
  `plugin.preferences`. All window code confined to `chat_window.lua` so
  docking can replace it when Aseprite supports it.
- Header: project name (or "No project · Make this folder a project"),
  status dot (green / amber connecting / red), **Start bridge** when red,
  **New chat**, **History ▾**, **Chat | Clips** tabs.
- Body: canvas-rendered history (word wrap, scroll via wheel and scrollbar,
  distinct styles for user / agent / tool activity / approval cards / errors),
  auto-scroll while streaming unless the user has scrolled up.
- Footer: multi-line-ish input entry, **📎** (attach snapshot of active view),
  **📌** (save selection as clip), **Send** (Enter) / **Stop** while a turn runs,
  **Auto-approve edits** toggle.
- **Start bridge:** launches `node <extension>/bridge/dist/server.js` detached;
  the extension then reads `bridge.json` and connects. Users can also run the
  bridge manually during development.

## 12. Error handling

| Situation | Behaviour |
|---|---|
| Bridge not running | Red dot, Start bridge button, reconnect with backoff (WebSocket `minreconnectwait`/`maxreconnectwait`) |
| Disconnect mid-turn | Bridge cancels the turn, transcript saved up to that point; UI marks the turn interrupted |
| Lua tool error | `pcall` inside the transaction → transaction rolled back → `{ok:false, error}` → agent relays it |
| Tool timeout | 30 s, then error result |
| `claude` missing / not logged in | `error` with hint ("Run `claude` in a terminal and log in") |
| Sprite closed/moved | Error naming the path; agent reports it |
| Over budget | Rejected before reaching the extension, explanatory error |
| Stop pressed | Adapter cancelled; pending approval cards resolved as Deny |
| Bad token | Connection closed; UI suggests restarting the bridge |
| Resume failed | New session seeded with transcript summary; chat notes it |

## 13. Testing

- **Bridge (Vitest):** protocol parsing/validation, approval gating incl.
  auto-approve exceptions, pixel budgets and draft-mode gating, project
  discovery/defaults, transcript store, clip LRU/pinning/eviction, export path
  rules. Integration test: fake adapter + fake extension WS client running a
  full turn with an approval.
- **Extension (headless Aseprite):** `aseprite -b --script tests/run.lua` runs
  each tool against fixture sprites and asserts pixels, palette, layers, frames,
  and that a single undo reverts each edit. Pure modules (`chat_render`,
  `project`) are tested in the same runner.
- **UI:** manual checklist (open/close window, stream, scroll, approval card,
  clips tab, start bridge, reconnect), since the dialog canvas cannot be driven
  programmatically.

## 14. Open items to verify during planning

- Aseprite version installed and minimum supported (WebSocket, `json`, and
  dialog canvas features all require 1.3+).
- Background open/read/close of non-active sprites without disturbing tabs.
- Launching a detached Node process from an extension (`os.execute` / `io.popen`)
  and any Aseprite script-security prompts.
- Current Claude Agent SDK API for custom tools, disabling built-ins, streaming,
  and resume.

### Verified 2026-09-24 (Aseprite 1.3.18, apiVersion 41; Agent SDK 0.3.281)

- `json`, `WebSocket`, `app.params`, `os.execute`/`io.popen` are available; `Sprite{fromFile=}` opens/closes cleanly in batch mode (UI tab behaviour still to confirm in Plan 3).
- **Undo:** mutating `cel.image` in place is neither undoable nor rolled back on error. Clone → modify → assign (`cel.image = copy`) inside `app.transaction` is one undo step and rolls back when the function errors. All edit tools must use this pattern.
- Extensions don't load in batch mode, so Lua tests require modules directly; UI is verified manually.
- Agent SDK: `tools: []` disables built-ins, `settingSources: []` skips user/project settings, `resume`, `includePartialMessages`, `abortController`, `createSdkMcpServer` + `tool()` (zod v4).
- **Adapter interface delta (supersedes §10 sketch):** adapters receive a `ToolHost` and call tools directly (matching SDK in-process MCP handlers) instead of yielding `tool_call` events. The approval gate wraps the `ToolHost`, so all adapters still inherit it.
- Snapshots are written to a bridge-owned dir (`~/.aseprite-agent/tmp`, announced in `ready`); the bridge only reads/deletes `aseagent-*.png` files directly inside it.
- The Aseprite UI font can't render emoji: buttons are text-labelled (e.g. "Attach", "Clip") rather than 📎/📌.
