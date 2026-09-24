# Aseprite Agent Chat — Plan 1: Walking Skeleton

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A chat window inside Aseprite where the artist talks to Claude, who can inspect open sprites (info, snapshot, exact pixels, palette) through a local bridge.

**Architecture:** A Lua extension (UI + WebSocket client + sprite tools) talks JSON over `ws://127.0.0.1:47821` to a Node/TypeScript bridge. The bridge authenticates with a token file, runs one agent session per connection through an adapter interface, and forwards the agent's tool calls to the extension. The only adapter is Claude Code, via the Claude Agent SDK.

**Tech Stack:** Aseprite 1.3.18 Lua API (apiVersion 41, built-in `json` and `WebSocket`), Node 24, TypeScript, `ws`, `zod` v4, `@anthropic-ai/claude-agent-sdk` 0.3.x, Vitest, headless Aseprite (`aseprite -b --script`) for Lua tests.

**Spec:** `docs/superpowers/specs/2026-09-24-aseprite-agent-chat-design.md`

### Where this plan sits

The spec covers several subsystems, so it is split into plans that each ship working software:

1. **Plan 1 — Walking skeleton (this plan):** bridge + Claude adapter + read-only tools + chat window. You can chat with Claude about open sprites.
2. Plan 2 — Edits and safety: approval cards, edit tools, pixel budgets, AI Draft quarantine, auto-approve.
3. Plan 3 — Projects and history: `.artproject`, brief/memory, project transcripts + resume, History UI, context stamp, cross-sprite reads, Open & apply.
4. Plan 4 — Reuse and output: `import_from_sprite`, clip library + Clips tab, `export_sprite`.
5. Plan 5 — Packaging: `.aseprite-extension` build, Start bridge button, publish prep.

Plans 2–5 are written when their predecessor has shipped, so that they build on the real code.

## Global Constraints

- Aseprite ≥ 1.3.18 (verified: built-in `json`, `WebSocket`, `Sprite{fromFile}` headless, `app.params`). Dev binary: `~/Library/Application Support/Steam/steamapps/common/Aseprite/Aseprite.app/Contents/MacOS/aseprite` (the `/Applications/Aseprite.app` bundle is a Steam launcher shim). Override with `ASEPRITE=/path`.
- Node ≥ 20. Bridge is ESM (`"type": "module"`, `NodeNext`); relative imports end in `.js`.
- Bridge binds `127.0.0.1` only. Default port `47821` (env `ASEPRITE_AGENT_PORT`). Home dir `~/.aseprite-agent` (env `ASEPRITE_AGENT_HOME`). `bridge.json` = `{port, token, pid}`, mode 0600.
- Lua modules live under `extension/agent/` and are required as `agent.<name>`, so they can't collide with other extensions' modules.
- **Undo rule (verified by probe):** writing into `cel.image` directly (`drawPixel`) is NOT undoable and does NOT roll back on error. Every sprite mutation must use clone → modify → assign (`local c = cel.image:clone(); ...; cel.image = c`) inside `app.transaction`. Plan 1 has no mutations; the rule is recorded for Plan 2.
- Tool errors raised in Lua use `error(msg, 0)` so no file:line prefix leaks to the agent.
- **No emoji in text drawn by Aseprite.** Its UI font is a bitmap font, so emoji render as boxes. This also applies to tool activity summaries.
- Frames are 1-based in every tool argument and result. Layers are reported bottom to top.
- The Claude adapter disables all built-in Claude Code tools (`tools: []`), loads no user or project settings (`settingSources: []`), and allows only `mcp__aseprite__*` tools.
- If you start the bridge and leave it running, append it to `~/.claude/claude-running.md` (`<YYYY-MM-DD HH:MM> | aseprite-plugins | bridge | stop: kill <pid>`) and remove the line when you stop it (user's global instruction).

## Review Focus

1. **Text with no spaces, or non-ASCII text** (a long URL, `héllo`, emoji) must wrap without crashing or overflowing: hard-break long words, split on UTF-8 characters. Tested in Task 6.
2. **Claude calls a tool when no sprite is open**, or names a sprite or frame that doesn't exist. It should get a plain-language error ("No sprite is open in Aseprite.", "Frame 5 does not exist (sprite has 1 frames)."), not a Lua traceback. Tested in Task 7.
3. **The bridge restarts or Aseprite disconnects mid-turn.** Pending tool calls must resolve with an error so the turn ends; the extension must re-read the token and say hello again on reconnect. Broker/session tests in Tasks 2 and 4; reconnect is on the manual checklist in Task 8.
4. **The user sends a second message while Claude is still answering.** It is rejected with a clear "still working" error, not interleaved. Tested in Task 4.
5. **Huge or tiny sprites in snapshots.** A 16×16 sprite is upscaled crisply; a 3000px sprite is downscaled to 2048 max, never upscaled; a region outside the sprite errors. Tested in Task 7.

---

## File Structure

```
aseprite-plugins/
├─ bridge/
│  ├─ package.json, tsconfig.json, vitest.config.ts
│  ├─ src/protocol.ts            message schemas + parser (the shared contract)
│  ├─ src/toolTypes.ts           ToolResult, ToolHost
│  ├─ src/toolBroker.ts          pending tool calls ⇄ extension, timeouts, cancelAll
│  ├─ src/tools/definitions.ts   tool schemas, descriptions, activity summaries
│  ├─ src/tools/mcpResult.ts     ToolResult → MCP result (PNG → image content, path confinement)
│  ├─ src/adapters/Adapter.ts    adapter interface
│  ├─ src/adapters/claudeCode.ts Agent SDK adapter
│  ├─ src/prompt.ts              system prompt
│  ├─ src/session.ts             one per connection: auth, turns, busy, cancel, dispose
│  ├─ src/server.ts              WebSocket server
│  ├─ src/config.ts              home dir, bridge.json, snapshot dir
│  ├─ src/main.ts                entry point
│  ├─ scripts/smoke.ts           manual end-to-end check against real Claude
│  └─ test/*.test.ts, test/helpers.ts
├─ extension/
│  ├─ package.json               Aseprite extension manifest
│  ├─ plugin.lua                 init: package.path + "Agent Chat" command
│  └─ agent/
│     ├─ chat_model.lua          pure: chat items
│     ├─ chat_render.lua         pure: wrap, layout, clampScroll
│     ├─ connection.lua          WebSocket client + bridge.json
│     ├─ chat_window.lua         Dialog UI
│     └─ tools/
│        ├─ init.lua             registers handlers, returns registry
│        ├─ registry.lua         dispatch with pcall
│        ├─ sprites.lua          resolve sprite/frame/layer
│        ├─ color.lua            pixel → hex
│        └─ inspect.lua          get_sprite_info, get_snapshot, get_pixels, get_palette
├─ tests/lua/run.lua, testlib.lua, test_*.lua
└─ scripts/test-lua.sh, scripts/dev-install.sh
```

---

### Task 1: Bridge scaffold and protocol

**Files:**
- Create: `bridge/package.json`, `bridge/tsconfig.json`, `bridge/vitest.config.ts`, `bridge/src/protocol.ts`
- Test: `bridge/test/protocol.test.ts`

**Interfaces:**
- Produces: `ExtensionMessage` (zod schema + type), `BridgeMessage` (type), `parseExtensionMessage(raw: string): ParseResult`, `PROTOCOL_VERSION = 1`.

- [ ] **Step 1: Scaffold the package**

```bash
mkdir -p bridge/src bridge/test bridge/scripts && cd bridge
npm init -y
npm pkg set name=aseprite-agent-bridge version=0.1.0 private=true type=module engines.node=">=20" \
  scripts.build="tsc -p tsconfig.json" scripts.start="node dist/main.js" scripts.dev="tsx src/main.ts" \
  scripts.test="vitest run" scripts.typecheck="tsc -p tsconfig.json --noEmit" scripts.smoke="tsx scripts/smoke.ts"
npm i @anthropic-ai/claude-agent-sdk zod ws
npm i -D typescript vitest tsx @types/ws @types/node
```

`bridge/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "declaration": false,
    "sourceMap": true
  },
  "include": ["src"]
}
```

`bridge/vitest.config.ts`:
```ts
import { defineConfig } from "vitest/config";
export default defineConfig({ test: { include: ["test/**/*.test.ts"], testTimeout: 10_000 } });
```

- [ ] **Step 2: Write the failing test**

`bridge/test/protocol.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { parseExtensionMessage } from "../src/protocol.js";

describe("parseExtensionMessage", () => {
  it("accepts hello", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "hello", token: "t", extensionVersion: "0.1.0" }));
    expect(r).toEqual({ ok: true, message: { type: "hello", token: "t", extensionVersion: "0.1.0" } });
  });

  it("accepts tool_result with arbitrary data", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "tool_result", callId: "c1", ok: true, data: { w: 8 } }));
    expect(r.ok).toBe(true);
  });

  it("accepts tool_result data encoded by Lua as an empty array", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "tool_result", callId: "c1", ok: true, data: [] }));
    expect(r.ok).toBe(true);
  });

  it("rejects invalid JSON", () => {
    expect(parseExtensionMessage("{nope")).toEqual({ ok: false, error: "invalid JSON" });
  });

  it("rejects unknown types", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "launch_missiles" }));
    expect(r.ok).toBe(false);
  });

  it("rejects empty user messages", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "user_message", text: "" }));
    expect(r.ok).toBe(false);
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd bridge && npx vitest run test/protocol.test.ts`
Expected: FAIL, cannot resolve `../src/protocol.js`.

- [ ] **Step 4: Implement**

`bridge/src/protocol.ts`:
```ts
import { z } from "zod";

export const PROTOCOL_VERSION = 1;

const Hello = z.object({ type: z.literal("hello"), token: z.string(), extensionVersion: z.string() });
const UserMessage = z.object({ type: z.literal("user_message"), text: z.string().min(1) });
const Cancel = z.object({ type: z.literal("cancel") });
const NewChat = z.object({ type: z.literal("new_chat") });
const ToolResultMsg = z.object({
  type: z.literal("tool_result"),
  callId: z.string(),
  ok: z.boolean(),
  data: z.unknown().optional(),
  error: z.string().optional(),
});

export const ExtensionMessage = z.discriminatedUnion("type", [Hello, UserMessage, Cancel, NewChat, ToolResultMsg]);
export type ExtensionMessage = z.infer<typeof ExtensionMessage>;

export type BridgeMessage =
  | { type: "ready"; adapter: string; protocolVersion: number; snapshotDir: string }
  | { type: "text_delta"; text: string }
  | { type: "tool_activity"; summary: string }
  | { type: "tool_call"; callId: string; name: string; args: Record<string, unknown> }
  | { type: "turn_done" }
  | { type: "error"; message: string; hint?: string };

export type ParseResult = { ok: true; message: ExtensionMessage } | { ok: false; error: string };

export function parseExtensionMessage(raw: string): ParseResult {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { ok: false, error: "invalid JSON" };
  }
  const r = ExtensionMessage.safeParse(json);
  if (!r.success) {
    return { ok: false, error: r.error.issues.map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`).join("; ") };
  }
  return { ok: true, message: r.data };
}
```

- [ ] **Step 5: Run tests, then typecheck**

Run: `cd bridge && npx vitest run test/protocol.test.ts && npm run typecheck`
Expected: 6 passed; tsc prints nothing.

- [ ] **Step 6: Commit**

```bash
git add bridge/package.json bridge/package-lock.json bridge/tsconfig.json bridge/vitest.config.ts bridge/src/protocol.ts bridge/test/protocol.test.ts
git commit -m "feat(bridge): scaffold package and extension/bridge protocol"
```

---

### Task 2: Tool broker

**Files:**
- Create: `bridge/src/toolTypes.ts`, `bridge/src/toolBroker.ts`
- Test: `bridge/test/toolBroker.test.ts`

**Interfaces:**
- Consumes: `BridgeMessage` (Task 1).
- Produces:
  - `type ToolResult = { ok: true; data: unknown } | { ok: false; error: string }`
  - `interface ToolHost { call(name: string, args: Record<string, unknown>): Promise<ToolResult> }`
  - `class ToolBroker implements ToolHost` with `constructor(send: (m: BridgeMessage) => void, opts: { timeoutMs: number; newId?: () => string })`, `resolve(callId, result): boolean`, `cancelAll(reason: string): void`, `get pendingCount(): number`.

- [ ] **Step 1: Write the failing test**

`bridge/test/toolBroker.test.ts`:
```ts
import { afterEach, describe, expect, it, vi } from "vitest";
import type { BridgeMessage } from "../src/protocol.js";
import { ToolBroker } from "../src/toolBroker.js";

function setup(timeoutMs = 1000) {
  const sent: BridgeMessage[] = [];
  let n = 0;
  const broker = new ToolBroker((m) => sent.push(m), { timeoutMs, newId: () => `c${++n}` });
  return { broker, sent };
}

afterEach(() => vi.useRealTimers());

describe("ToolBroker", () => {
  it("sends tool_call and resolves with the matching result", async () => {
    const { broker, sent } = setup();
    const p = broker.call("get_palette", { sprite: "a.aseprite" });
    expect(sent).toEqual([{ type: "tool_call", callId: "c1", name: "get_palette", args: { sprite: "a.aseprite" } }]);
    expect(broker.resolve("c1", { ok: true, data: { size: 4 } })).toBe(true);
    await expect(p).resolves.toEqual({ ok: true, data: { size: 4 } });
    expect(broker.pendingCount).toBe(0);
  });

  it("ignores unknown call ids", () => {
    const { broker } = setup();
    expect(broker.resolve("nope", { ok: true, data: null })).toBe(false);
  });

  it("times out with an error result", async () => {
    vi.useFakeTimers();
    const { broker } = setup(30_000);
    const p = broker.call("get_snapshot", {});
    vi.advanceTimersByTime(30_000);
    await expect(p).resolves.toEqual({ ok: false, error: "Tool get_snapshot timed out after 30s" });
    expect(broker.pendingCount).toBe(0);
  });

  it("cancelAll resolves every pending call with the reason", async () => {
    const { broker } = setup();
    const a = broker.call("a", {});
    const b = broker.call("b", {});
    broker.cancelAll("Aseprite disconnected");
    await expect(a).resolves.toEqual({ ok: false, error: "Aseprite disconnected" });
    await expect(b).resolves.toEqual({ ok: false, error: "Aseprite disconnected" });
    expect(broker.pendingCount).toBe(0);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd bridge && npx vitest run test/toolBroker.test.ts`
Expected: FAIL, cannot resolve `../src/toolBroker.js`.

- [ ] **Step 3: Implement**

`bridge/src/toolTypes.ts`:
```ts
export type ToolResult = { ok: true; data: unknown } | { ok: false; error: string };

export interface ToolHost {
  call(name: string, args: Record<string, unknown>): Promise<ToolResult>;
}
```

`bridge/src/toolBroker.ts`:
```ts
import { randomUUID } from "node:crypto";
import type { BridgeMessage } from "./protocol.js";
import type { ToolHost, ToolResult } from "./toolTypes.js";

type Pending = { resolve: (r: ToolResult) => void; timer: NodeJS.Timeout };

export class ToolBroker implements ToolHost {
  private pending = new Map<string, Pending>();

  constructor(
    private send: (msg: BridgeMessage) => void,
    private opts: { timeoutMs: number; newId?: () => string },
  ) {}

  call(name: string, args: Record<string, unknown>): Promise<ToolResult> {
    const callId = (this.opts.newId ?? randomUUID)();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(callId);
        resolve({ ok: false, error: `Tool ${name} timed out after ${this.opts.timeoutMs / 1000}s` });
      }, this.opts.timeoutMs);
      this.pending.set(callId, { resolve, timer });
      this.send({ type: "tool_call", callId, name, args });
    });
  }

  resolve(callId: string, result: ToolResult): boolean {
    const p = this.pending.get(callId);
    if (!p) return false;
    clearTimeout(p.timer);
    this.pending.delete(callId);
    p.resolve(result);
    return true;
  }

  cancelAll(reason: string): void {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.resolve({ ok: false, error: reason });
    }
    this.pending.clear();
  }

  get pendingCount(): number {
    return this.pending.size;
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd bridge && npx vitest run test/toolBroker.test.ts`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add bridge/src/toolTypes.ts bridge/src/toolBroker.ts bridge/test/toolBroker.test.ts
git commit -m "feat(bridge): tool broker with timeouts and cancellation"
```

---

### Task 3: Tool definitions and MCP result conversion

**Files:**
- Create: `bridge/src/tools/definitions.ts`, `bridge/src/tools/mcpResult.ts`
- Test: `bridge/test/definitions.test.ts`, `bridge/test/mcpResult.test.ts`

**Interfaces:**
- Consumes: `ToolResult` (Task 2).
- Produces:
  - `interface ToolDef { name: string; description: string; kind: "read" | "edit"; shape: z.ZodRawShape; activity(args: Record<string, unknown>): string }`
  - `TOOL_DEFS: ToolDef[]` (names: `get_sprite_info`, `get_snapshot`, `get_pixels`, `get_palette`), `toolDef(name): ToolDef | undefined`
  - `interface McpToolResult { content: McpContent[]; isError?: boolean }`, `toMcpResult(r: ToolResult, snapshotDir: string): Promise<McpToolResult>`

- [ ] **Step 1: Write the failing tests**

`bridge/test/definitions.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { z } from "zod";
import { TOOL_DEFS, toolDef } from "../src/tools/definitions.js";

describe("tool definitions", () => {
  it("has the four read tools with unique names", () => {
    expect(TOOL_DEFS.map((d) => d.name).sort()).toEqual(["get_palette", "get_pixels", "get_snapshot", "get_sprite_info"]);
    expect(TOOL_DEFS.every((d) => d.kind === "read")).toBe(true);
  });

  it("limits get_pixels regions to 64x64", () => {
    const schema = z.object(toolDef("get_pixels")!.shape);
    expect(schema.safeParse({ region: { x: 0, y: 0, w: 64, h: 64 } }).success).toBe(true);
    expect(schema.safeParse({ region: { x: 0, y: 0, w: 65, h: 1 } }).success).toBe(false);
    expect(schema.safeParse({}).success).toBe(false);
  });

  it("uses 1-based frames", () => {
    const schema = z.object(toolDef("get_snapshot")!.shape);
    expect(schema.safeParse({ frame: 0 }).success).toBe(false);
    expect(schema.safeParse({ frame: 1 }).success).toBe(true);
  });

  it("writes plain-text activity summaries (no emoji)", () => {
    const s = toolDef("get_snapshot")!.activity({ sprite: "knight.aseprite", frame: 3, layer: "Body" });
    expect(s).toBe('Looked at knight.aseprite, frame 3, layer "Body"');
    expect(toolDef("get_sprite_info")!.activity({})).toBe("Inspected the active sprite");
    expect(toolDef("get_pixels")!.activity({ region: { x: 2, y: 3, w: 4, h: 5 } })).toBe("Read 4x5 pixels at (2,3) in the active sprite");
    for (const d of TOOL_DEFS) expect(d.activity({})).toMatch(/^[\x20-\x7E]+$/);
  });
});
```

`bridge/test/mcpResult.test.ts`:
```ts
import { mkdtemp, writeFile, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { toMcpResult } from "../src/tools/mcpResult.js";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "snap-"));
});

const exists = (p: string) => access(p).then(() => true, () => false);

describe("toMcpResult", () => {
  it("wraps plain data as JSON text", async () => {
    expect(await toMcpResult({ ok: true, data: { width: 8 } }, dir)).toEqual({ content: [{ type: "text", text: '{"width":8}' }] });
  });

  it("marks errors", async () => {
    expect(await toMcpResult({ ok: false, error: "No sprite is open in Aseprite." }, dir)).toEqual({
      content: [{ type: "text", text: "Error: No sprite is open in Aseprite." }],
      isError: true,
    });
  });

  it("turns a snapshot into image content and deletes the file", async () => {
    const png = join(dir, "aseagent-1-1.png");
    await writeFile(png, Buffer.from([137, 80, 78, 71]));
    const r = await toMcpResult({ ok: true, data: { pngPath: png, scale: 32 } }, dir);
    expect(r.content[0]).toEqual({ type: "image", data: Buffer.from([137, 80, 78, 71]).toString("base64"), mimeType: "image/png" });
    expect(r.content[1]).toEqual({ type: "text", text: '{"scale":32}' });
    expect(await exists(png)).toBe(false);
  });

  it("refuses paths outside the snapshot dir and does not delete them", async () => {
    const other = await mkdtemp(join(tmpdir(), "other-"));
    const outside = join(other, "aseagent-1-1.png");
    await writeFile(outside, "x");
    const r = await toMcpResult({ ok: true, data: { pngPath: outside } }, dir);
    expect(r.isError).toBe(true);
    expect(await exists(outside)).toBe(true);
  });

  it("refuses traversal and non-snapshot names", async () => {
    for (const p of [join(dir, "..", "aseagent-1.png"), join(dir, "secrets.png"), join(dir, "aseagent-1.txt")]) {
      expect((await toMcpResult({ ok: true, data: { pngPath: p } }, dir)).isError).toBe(true);
    }
  });
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd bridge && npx vitest run test/definitions.test.ts test/mcpResult.test.ts`
Expected: FAIL, modules not found.

- [ ] **Step 3: Implement definitions**

`bridge/src/tools/definitions.ts`:
```ts
import { z } from "zod";

export type ToolKind = "read" | "edit";

export interface ToolDef {
  name: string;
  description: string;
  kind: ToolKind;
  shape: z.ZodRawShape;
  activity(args: Record<string, unknown>): string;
}

const spriteArg = z
  .string()
  .optional()
  .describe("Sprite to use: file name (e.g. knight.aseprite) or full path of an open sprite. Omit for the active sprite.");
const frameArg = z.number().int().min(1).optional().describe("1-based frame number. Omit for the active frame.");
const layerArg = z.string().optional().describe("Name of a (non-group) layer. Omit for the flattened visible image.");

function rect(max?: number) {
  const side = max ? z.number().int().min(1).max(max) : z.number().int().min(1);
  return z.object({ x: z.number().int().min(0), y: z.number().int().min(0), w: side, h: side });
}

const spriteName = (a: Record<string, unknown>) => (typeof a.sprite === "string" ? a.sprite : "the active sprite");

export const TOOL_DEFS: ToolDef[] = [
  {
    name: "get_sprite_info",
    kind: "read",
    description:
      "Describe a sprite: size, color mode, frame count and durations (ms), layer tree (bottom to top) with visibility, opacity and blend mode, tags, palette size, selection, and the active frame and layer if it is the active sprite.",
    shape: { sprite: spriteArg },
    activity: (a) => `Inspected ${spriteName(a)}`,
  },
  {
    name: "get_snapshot",
    kind: "read",
    description:
      "Get a PNG image of a frame (flattened, or one layer), optionally cropped to a region. Small sprites are upscaled with nearest-neighbour so pixels stay crisp; `scale` in the result says by how much. Use get_pixels when exact colors matter.",
    shape: {
      sprite: spriteArg,
      frame: frameArg,
      layer: layerArg,
      region: rect().optional().describe("Crop rectangle in sprite pixels."),
      maxSize: z.number().int().min(64).max(1024).optional().describe("Target long edge in pixels for upscaling (default 512)."),
    },
    activity: (a) => {
      let s = `Looked at ${spriteName(a)}`;
      if (typeof a.frame === "number") s += `, frame ${a.frame}`;
      if (typeof a.layer === "string") s += `, layer "${a.layer}"`;
      return s;
    },
  },
  {
    name: "get_pixels",
    kind: "read",
    description:
      "Read exact pixel colors in a region (max 64x64) as rows of hex colors ('#rrggbb', '#rrggbbaa' when translucent, '.' when transparent). Flattened image unless a layer is given.",
    shape: { sprite: spriteArg, frame: frameArg, layer: layerArg, region: rect(64).describe("Region in sprite pixels, max 64x64.") },
    activity: (a) => {
      const r = a.region as { x: number; y: number; w: number; h: number } | undefined;
      return r ? `Read ${r.w}x${r.h} pixels at (${r.x},${r.y}) in ${spriteName(a)}` : `Read pixels in ${spriteName(a)}`;
    },
  },
  {
    name: "get_palette",
    kind: "read",
    description: "List the sprite's palette as hex colors in index order (index 0 first), plus the transparent index for indexed sprites.",
    shape: { sprite: spriteArg },
    activity: (a) => `Read the palette of ${spriteName(a)}`,
  },
];

export function toolDef(name: string): ToolDef | undefined {
  return TOOL_DEFS.find((d) => d.name === name);
}
```

- [ ] **Step 4: Implement MCP result conversion**

`bridge/src/tools/mcpResult.ts`:
```ts
import { readFile, rm } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import type { ToolResult } from "../toolTypes.js";

export type McpContent = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
export interface McpToolResult {
  content: McpContent[];
  isError?: boolean;
}

const SNAPSHOT_NAME = /^aseagent-[\w-]+\.png$/;

const errorResult = (message: string): McpToolResult => ({ content: [{ type: "text", text: `Error: ${message}` }], isError: true });

function isSnapshotPath(path: string, snapshotDir: string): boolean {
  const p = resolve(path);
  return dirname(p) === resolve(snapshotDir) && SNAPSHOT_NAME.test(basename(p));
}

export async function toMcpResult(r: ToolResult, snapshotDir: string): Promise<McpToolResult> {
  if (!r.ok) return errorResult(r.error);
  const data = (r.data ?? {}) as Record<string, unknown>;
  const pngPath = data.pngPath;
  if (typeof pngPath !== "string") return { content: [{ type: "text", text: JSON.stringify(r.data ?? null) }] };

  const { pngPath: _omit, ...rest } = data;
  if (!isSnapshotPath(pngPath, snapshotDir)) return errorResult("snapshot path is outside the bridge snapshot directory");
  try {
    const buf = await readFile(pngPath);
    return {
      content: [
        { type: "image", data: buf.toString("base64"), mimeType: "image/png" },
        { type: "text", text: JSON.stringify(rest) },
      ],
    };
  } catch (e) {
    return errorResult(`snapshot file unreadable (${(e as Error).message})`);
  } finally {
    await rm(pngPath, { force: true });
  }
}
```

- [ ] **Step 5: Run tests**

Run: `cd bridge && npx vitest run test/definitions.test.ts test/mcpResult.test.ts && npm run typecheck`
Expected: all pass; tsc prints nothing.

- [ ] **Step 6: Commit**

```bash
git add bridge/src/tools bridge/test/definitions.test.ts bridge/test/mcpResult.test.ts
git commit -m "feat(bridge): read tool definitions and MCP result conversion"
```

---

### Task 4: Adapter interface, session, and WebSocket server

**Files:**
- Create: `bridge/src/adapters/Adapter.ts`, `bridge/src/session.ts`, `bridge/src/server.ts`, `bridge/src/config.ts`
- Test: `bridge/test/helpers.ts`, `bridge/test/server.test.ts`, `bridge/test/config.test.ts`

**Interfaces:**
- Consumes: `parseExtensionMessage`, `BridgeMessage`, `PROTOCOL_VERSION` (Task 1); `ToolBroker`, `ToolHost` (Task 2); `toolDef` (Task 3).
- Produces:
  - `AdapterEvent = { type: "text_delta"; text: string } | { type: "error"; message: string; hint?: string }`
  - `interface Adapter { readonly name: string; send(text: string): AsyncIterable<AdapterEvent>; cancel(): void; resumeState(): ResumeState | undefined }`
  - `interface AdapterContext { tools: ToolHost; systemPrompt: string; resume?: ResumeState }`, `type AdapterFactory = (ctx: AdapterContext) => Adapter`, `type ResumeState = Record<string, unknown>`
  - `startServer(opts: ServerOptions): Promise<BridgeServer>` where `BridgeServer = { port: number; close(): Promise<void> }` and `ServerOptions = { port: number; host?: string; token: string; adapterFactory: AdapterFactory; systemPrompt: string; snapshotDir: string; toolTimeoutMs?: number }`
  - `config.ts`: `DEFAULT_PORT = 47821`, `agentHome(env?)`, `snapshotDirFor(home)`, `writeBridgeInfo(home, info)`, `removeBridgeInfo(home)`, `interface BridgeInfo { port: number; token: string; pid: number }`

> **Spec delta:** spec §10 sketched `send()` yielding `tool_call` events plus `submitToolResult()`. Here the adapter instead receives a `ToolHost` and calls tools directly. This matches how the Agent SDK runs in-process MCP tool handlers. The approval gate added in Plan 2 wraps the `ToolHost`, so every adapter still inherits it.

- [ ] **Step 1: Write test helpers**

`bridge/test/helpers.ts`:
```ts
import WebSocket from "ws";
import type { Adapter, AdapterContext, AdapterEvent, AdapterFactory } from "../src/adapters/Adapter.js";
import type { BridgeMessage } from "../src/protocol.js";

export function scriptedAdapterFactory(
  script: (ctx: AdapterContext, text: string) => AsyncIterable<AdapterEvent>,
): AdapterFactory {
  return (ctx) => {
    let cancelled = false;
    const adapter: Adapter = {
      name: "fake",
      async *send(text) {
        cancelled = false;
        for await (const ev of script(ctx, text)) {
          if (cancelled) return;
          yield ev;
        }
      },
      cancel() {
        cancelled = true;
      },
      resumeState: () => undefined,
    };
    return adapter;
  };
}

export interface TestClient {
  ws: WebSocket;
  received: BridgeMessage[];
  send(msg: unknown): void;
  sendRaw(raw: string): void;
  waitFor(pred: (m: BridgeMessage) => boolean, timeoutMs?: number): Promise<BridgeMessage>;
  closed: Promise<{ code: number; reason: string }>;
}

export async function connectClient(port: number): Promise<TestClient> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const received: BridgeMessage[] = [];
  const waiters: { pred: (m: BridgeMessage) => boolean; resolve: (m: BridgeMessage) => void }[] = [];
  ws.on("message", (data) => {
    const m = JSON.parse(data.toString()) as BridgeMessage;
    received.push(m);
    for (const w of [...waiters]) {
      if (w.pred(m)) {
        waiters.splice(waiters.indexOf(w), 1);
        w.resolve(m);
      }
    }
  });
  const closed = new Promise<{ code: number; reason: string }>((resolve) =>
    ws.on("close", (code, reason) => resolve({ code, reason: reason.toString() })),
  );
  await new Promise<void>((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
  return {
    ws,
    received,
    send: (msg) => ws.send(JSON.stringify(msg)),
    sendRaw: (raw) => ws.send(raw),
    waitFor(pred, timeoutMs = 2000) {
      const hit = received.find(pred);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error("waitFor timed out; received: " + JSON.stringify(received))), timeoutMs);
        waiters.push({ pred, resolve: (m) => (clearTimeout(t), resolve(m)) });
      });
    },
    closed,
  };
}
```

- [ ] **Step 2: Write the failing server tests**

`bridge/test/server.test.ts`:
```ts
import { afterEach, describe, expect, it } from "vitest";
import type { AdapterEvent } from "../src/adapters/Adapter.js";
import { startServer, type BridgeServer } from "../src/server.js";
import type { ToolResult } from "../src/toolTypes.js";
import { connectClient, scriptedAdapterFactory } from "./helpers.js";

const TOKEN = "secret-token";
let server: BridgeServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

async function start(script: Parameters<typeof scriptedAdapterFactory>[0], toolTimeoutMs = 2000) {
  server = await startServer({
    port: 0,
    token: TOKEN,
    adapterFactory: scriptedAdapterFactory(script),
    systemPrompt: "test",
    snapshotDir: "/tmp/snaps",
    toolTimeoutMs,
  });
  return server;
}

async function* noop(): AsyncIterable<AdapterEvent> {}

async function authed(port: number) {
  const c = await connectClient(port);
  c.send({ type: "hello", token: TOKEN, extensionVersion: "0.1.0" });
  await c.waitFor((m) => m.type === "ready");
  return c;
}

describe("bridge server", () => {
  it("closes connections with a wrong token", async () => {
    const s = await start(noop);
    const c = await connectClient(s.port);
    c.send({ type: "hello", token: "wrong", extensionVersion: "0.1.0" });
    expect((await c.closed).code).toBe(4001);
  });

  it("closes connections that skip hello", async () => {
    const s = await start(noop);
    const c = await connectClient(s.port);
    c.send({ type: "user_message", text: "hi" });
    expect((await c.closed).code).toBe(4001);
  });

  it("replies ready with adapter name and snapshot dir", async () => {
    const s = await start(noop);
    const c = await authed(s.port);
    expect(c.received[0]).toEqual({ type: "ready", adapter: "fake", protocolVersion: 1, snapshotDir: "/tmp/snaps" });
  });

  it("reports malformed messages without closing", async () => {
    const s = await start(noop);
    const c = await authed(s.port);
    c.sendRaw("{nope");
    const err = await c.waitFor((m) => m.type === "error");
    expect(err).toMatchObject({ type: "error", message: "Bad message: invalid JSON" });
  });

  it("runs a turn with a tool round-trip", async () => {
    const s = await start(async function* (ctx) {
      const r = await ctx.tools.call("get_sprite_info", {});
      yield { type: "text_delta", text: r.ok ? `width=${(r.data as { width: number }).width}` : r.error };
    });
    const c = await authed(s.port);
    c.send({ type: "user_message", text: "how big?" });
    await c.waitFor((m) => m.type === "tool_activity");
    const call = await c.waitFor((m) => m.type === "tool_call");
    if (call.type !== "tool_call") throw new Error("unreachable");
    expect(call.name).toBe("get_sprite_info");
    c.send({ type: "tool_result", callId: call.callId, ok: true, data: { width: 8 } });
    await c.waitFor((m) => m.type === "turn_done");
    const types = c.received.map((m) => m.type);
    expect(types).toEqual(["ready", "tool_activity", "tool_call", "text_delta", "turn_done"]);
    expect(c.received[1]).toEqual({ type: "tool_activity", summary: "Inspected the active sprite" });
    expect(c.received[3]).toEqual({ type: "text_delta", text: "width=8" });
  });

  it("rejects a second message while a turn is running", async () => {
    const s = await start(async function* (ctx) {
      await ctx.tools.call("get_sprite_info", {});
      yield { type: "text_delta", text: "done" };
    });
    const c = await authed(s.port);
    c.send({ type: "user_message", text: "first" });
    await c.waitFor((m) => m.type === "tool_call");
    c.send({ type: "user_message", text: "second" });
    const err = await c.waitFor((m) => m.type === "error");
    expect(err).toMatchObject({ message: expect.stringContaining("Still working") });
  });

  it("cancel resolves pending tools and ends the turn", async () => {
    let seen: ToolResult | undefined;
    const s = await start(async function* (ctx) {
      seen = await ctx.tools.call("get_sprite_info", {});
    });
    const c = await authed(s.port);
    c.send({ type: "user_message", text: "go" });
    await c.waitFor((m) => m.type === "tool_call");
    c.send({ type: "cancel" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(seen).toEqual({ ok: false, error: "Cancelled by user" });
  });

  it("resolves pending tools when Aseprite disconnects", async () => {
    let resolveSeen!: (r: ToolResult) => void;
    const seen = new Promise<ToolResult>((r) => (resolveSeen = r));
    const s = await start(async function* (ctx) {
      resolveSeen(await ctx.tools.call("get_sprite_info", {}));
    });
    const c = await authed(s.port);
    c.send({ type: "user_message", text: "go" });
    await c.waitFor((m) => m.type === "tool_call");
    c.ws.terminate();
    await expect(seen).resolves.toEqual({ ok: false, error: "Aseprite disconnected" });
  });

  it("turns adapter exceptions into error + turn_done", async () => {
    const s = await start(async function* () {
      throw new Error("kaboom");
    });
    const c = await authed(s.port);
    c.send({ type: "user_message", text: "go" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.find((m) => m.type === "error")).toMatchObject({ message: "kaboom" });
  });
});
```

`bridge/test/config.test.ts`:
```ts
import { mkdtemp, readFile, stat, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { agentHome, removeBridgeInfo, snapshotDirFor, writeBridgeInfo } from "../src/config.js";

describe("config", () => {
  it("honours ASEPRITE_AGENT_HOME", () => {
    expect(agentHome({ ASEPRITE_AGENT_HOME: "/x" })).toBe("/x");
    expect(agentHome({})).toMatch(/\.aseprite-agent$/);
  });

  it("writes bridge.json with 0600 and removes it", async () => {
    const home = join(await mkdtemp(join(tmpdir(), "home-")), "nested");
    await writeBridgeInfo(home, { port: 1, token: "t", pid: 2 });
    const p = join(home, "bridge.json");
    expect(JSON.parse(await readFile(p, "utf8"))).toEqual({ port: 1, token: "t", pid: 2 });
    expect((await stat(p)).mode & 0o777).toBe(0o600);
    await removeBridgeInfo(home);
    await expect(access(p)).rejects.toThrow();
  });

  it("puts snapshots under home/tmp", () => {
    expect(snapshotDirFor("/h")).toBe("/h/tmp");
  });
});
```

- [ ] **Step 3: Run them to verify they fail**

Run: `cd bridge && npx vitest run test/server.test.ts test/config.test.ts`
Expected: FAIL, modules not found.

- [ ] **Step 4: Implement the adapter interface**

`bridge/src/adapters/Adapter.ts`:
```ts
import type { ToolHost } from "../toolTypes.js";

export type AdapterEvent = { type: "text_delta"; text: string } | { type: "error"; message: string; hint?: string };

export type ResumeState = Record<string, unknown>;

export interface Adapter {
  readonly name: string;
  /** Runs one user turn, yielding events until the agent has finished replying. */
  send(text: string): AsyncIterable<AdapterEvent>;
  cancel(): void;
  resumeState(): ResumeState | undefined;
}

export interface AdapterContext {
  tools: ToolHost;
  systemPrompt: string;
  resume?: ResumeState;
}

export type AdapterFactory = (ctx: AdapterContext) => Adapter;
```

- [ ] **Step 5: Implement the session**

`bridge/src/session.ts`:
```ts
import { timingSafeEqual } from "node:crypto";
import type { Adapter, AdapterFactory } from "./adapters/Adapter.js";
import { PROTOCOL_VERSION, parseExtensionMessage, type BridgeMessage } from "./protocol.js";
import { ToolBroker } from "./toolBroker.js";
import { toolDef } from "./tools/definitions.js";
import type { ToolHost } from "./toolTypes.js";

export interface SessionDeps {
  token: string;
  send: (m: BridgeMessage) => void;
  close: (code: number, reason: string) => void;
  adapterFactory: AdapterFactory;
  systemPrompt: string;
  snapshotDir: string;
  toolTimeoutMs?: number;
}

function tokensMatch(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export class Session {
  private authed = false;
  private busy = false;
  private adapter?: Adapter;
  private broker: ToolBroker;
  private tools: ToolHost;

  constructor(private deps: SessionDeps) {
    this.broker = new ToolBroker(deps.send, { timeoutMs: deps.toolTimeoutMs ?? 30_000 });
    this.tools = {
      call: (name, args) => {
        const def = toolDef(name);
        this.deps.send({ type: "tool_activity", summary: def ? def.activity(args) : `Used ${name}` });
        return this.broker.call(name, args);
      },
    };
  }

  async handleRaw(raw: string): Promise<void> {
    const parsed = parseExtensionMessage(raw);
    if (!this.authed) {
      if (!parsed.ok || parsed.message.type !== "hello" || !tokensMatch(parsed.message.token, this.deps.token)) {
        this.deps.close(4001, "unauthorized");
        return;
      }
      this.authed = true;
      this.adapter = this.newAdapter();
      this.deps.send({ type: "ready", adapter: this.adapter.name, protocolVersion: PROTOCOL_VERSION, snapshotDir: this.deps.snapshotDir });
      return;
    }
    if (!parsed.ok) {
      this.deps.send({ type: "error", message: `Bad message: ${parsed.error}` });
      return;
    }
    const msg = parsed.message;
    switch (msg.type) {
      case "hello":
        return;
      case "user_message":
        return this.runTurn(msg.text);
      case "cancel":
        this.cancel("Cancelled by user");
        return;
      case "new_chat":
        this.cancel("Chat reset");
        this.adapter = this.newAdapter();
        return;
      case "tool_result":
        this.broker.resolve(msg.callId, msg.ok ? { ok: true, data: msg.data } : { ok: false, error: msg.error ?? "Unknown tool error" });
        return;
    }
  }

  dispose(): void {
    this.cancel("Aseprite disconnected");
  }

  private cancel(reason: string): void {
    this.adapter?.cancel();
    this.broker.cancelAll(reason);
  }

  private newAdapter(): Adapter {
    return this.deps.adapterFactory({ tools: this.tools, systemPrompt: this.deps.systemPrompt });
  }

  private async runTurn(text: string): Promise<void> {
    if (this.busy) {
      this.deps.send({ type: "error", message: "Still working on the previous message. Press Stop or wait for it to finish." });
      return;
    }
    this.busy = true;
    try {
      for await (const ev of this.adapter!.send(text)) this.deps.send(ev);
    } catch (e) {
      this.deps.send({ type: "error", message: e instanceof Error ? e.message : String(e) });
    } finally {
      this.busy = false;
      this.deps.send({ type: "turn_done" });
    }
  }
}
```

- [ ] **Step 6: Implement the server and config**

`bridge/src/server.ts`:
```ts
import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import type { AdapterFactory } from "./adapters/Adapter.js";
import { Session } from "./session.js";

export interface ServerOptions {
  port: number;
  host?: string;
  token: string;
  adapterFactory: AdapterFactory;
  systemPrompt: string;
  snapshotDir: string;
  toolTimeoutMs?: number;
}

export interface BridgeServer {
  port: number;
  close(): Promise<void>;
}

export async function startServer(opts: ServerOptions): Promise<BridgeServer> {
  const wss = new WebSocketServer({ host: opts.host ?? "127.0.0.1", port: opts.port });
  await new Promise<void>((resolve, reject) => {
    wss.once("listening", resolve);
    wss.once("error", reject);
  });

  wss.on("connection", (ws) => {
    const session = new Session({
      token: opts.token,
      adapterFactory: opts.adapterFactory,
      systemPrompt: opts.systemPrompt,
      snapshotDir: opts.snapshotDir,
      toolTimeoutMs: opts.toolTimeoutMs,
      send: (m) => {
        if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(m));
      },
      close: (code, reason) => ws.close(code, reason),
    });
    ws.on("message", (data, isBinary) => {
      if (!isBinary) void session.handleRaw(data.toString());
    });
    ws.on("close", () => session.dispose());
  });

  return {
    port: (wss.address() as AddressInfo).port,
    close: () =>
      new Promise<void>((resolve) => {
        for (const c of wss.clients) c.terminate();
        wss.close(() => resolve());
      }),
  };
}
```

`bridge/src/config.ts`:
```ts
import { chmod, mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEFAULT_PORT = 47821;

export interface BridgeInfo {
  port: number;
  token: string;
  pid: number;
}

export function agentHome(env: Record<string, string | undefined> = process.env): string {
  return env.ASEPRITE_AGENT_HOME ?? join(homedir(), ".aseprite-agent");
}

export function snapshotDirFor(home: string): string {
  return join(home, "tmp");
}

export async function writeBridgeInfo(home: string, info: BridgeInfo): Promise<void> {
  await mkdir(home, { recursive: true, mode: 0o700 });
  const p = join(home, "bridge.json");
  await writeFile(p, JSON.stringify(info), { mode: 0o600 });
  await chmod(p, 0o600);
}

export async function removeBridgeInfo(home: string): Promise<void> {
  await rm(join(home, "bridge.json"), { force: true });
}
```

- [ ] **Step 7: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all test files pass; tsc prints nothing.

- [ ] **Step 8: Commit**

```bash
git add bridge/src/adapters/Adapter.ts bridge/src/session.ts bridge/src/server.ts bridge/src/config.ts bridge/test
git commit -m "feat(bridge): sessions, token auth and WebSocket server"
```

---

### Task 5: Claude Code adapter, system prompt, entry point, and smoke test

**Files:**
- Create: `bridge/src/adapters/claudeCode.ts`, `bridge/src/prompt.ts`, `bridge/src/main.ts`, `bridge/scripts/smoke.ts`
- Test: `bridge/test/claudeCode.test.ts`

**Interfaces:**
- Consumes: `Adapter`, `AdapterContext`, `AdapterEvent`, `AdapterFactory` (Task 4); `TOOL_DEFS`, `ToolDef`, `toMcpResult` (Task 3); `ToolHost` (Task 2); config and `startServer` (Task 4).
- Produces: `claudeCodeAdapterFactory(opts: ClaudeCodeOptions): AdapterFactory`, `ClaudeCodeAdapter`, `createSdkMapper(): (msg) => AdapterEvent | undefined`, `classifyError(e): AdapterEvent`, `makeToolHandler(def, tools, snapshotDir)`, `MCP_SERVER_NAME = "aseprite"`, `SYSTEM_PROMPT`.

- [ ] **Step 1: Write the failing test**

`bridge/test/claudeCode.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import type { AdapterEvent } from "../src/adapters/Adapter.js";
import { ClaudeCodeAdapter, classifyError, createSdkMapper, makeToolHandler } from "../src/adapters/claudeCode.js";
import { toolDef } from "../src/tools/definitions.js";

const delta = (text: string, parent: string | null = null) => ({
  type: "stream_event",
  parent_tool_use_id: parent,
  session_id: "s1",
  event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
});
const messageStart = { type: "stream_event", parent_tool_use_id: null, session_id: "s1", event: { type: "message_start" } };

function fakeQuery(messages: unknown[], calls: any[]) {
  return ((params: any) => {
    calls.push(params);
    return (async function* () {
      for (const m of messages) yield m;
    })();
  }) as any;
}

async function collect(it: AsyncIterable<AdapterEvent>) {
  const out: AdapterEvent[] = [];
  for await (const e of it) out.push(e);
  return out;
}

const noTools = { call: async () => ({ ok: true as const, data: {} }) };

describe("createSdkMapper", () => {
  it("maps top-level text deltas and ignores subagent deltas", () => {
    const map = createSdkMapper();
    expect(map(delta("Hi"))).toEqual({ type: "text_delta", text: "Hi" });
    expect(map(delta("sub", "tool-1"))).toBeUndefined();
  });

  it("separates consecutive assistant messages with a blank line", () => {
    const map = createSdkMapper();
    expect(map(messageStart)).toBeUndefined();
    map(delta("Let me look."));
    expect(map(messageStart)).toEqual({ type: "text_delta", text: "\n\n" });
  });

  it("maps failed results to errors", () => {
    const map = createSdkMapper();
    expect(map({ type: "result", subtype: "error_max_turns", errors: ["too many"] })).toEqual({
      type: "error",
      message: "Claude stopped (error_max_turns): too many",
    });
    expect(map({ type: "result", subtype: "success" })).toBeUndefined();
  });
});

describe("classifyError", () => {
  it("explains a missing CLI", () => {
    expect(classifyError(new Error("spawn claude ENOENT"))).toMatchObject({ hint: expect.stringContaining("claude") });
  });
  it("explains a missing login", () => {
    expect(classifyError(new Error("401 Unauthorized"))).toMatchObject({ hint: expect.stringContaining("log in") });
  });
  it("passes other errors through", () => {
    expect(classifyError(new Error("weird"))).toEqual({ type: "error", message: "weird" });
  });
});

describe("ClaudeCodeAdapter", () => {
  it("streams text and locks Claude Code down to the aseprite tools", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: fakeQuery([delta("Hello")], calls) });
    expect(await collect(a.send("hi"))).toEqual([{ type: "text_delta", text: "Hello" }]);
    const o = calls[0].options;
    expect(calls[0].prompt).toBe("hi");
    expect(o.systemPrompt).toBe("SP");
    expect(o.tools).toEqual([]);
    expect(o.settingSources).toEqual([]);
    expect(o.includePartialMessages).toBe(true);
    expect([...o.allowedTools].sort()).toEqual([
      "mcp__aseprite__get_palette",
      "mcp__aseprite__get_pixels",
      "mcp__aseprite__get_snapshot",
      "mcp__aseprite__get_sprite_info",
    ]);
    expect(Object.keys(o.mcpServers)).toEqual(["aseprite"]);
  });

  it("resumes the SDK session on the next turn", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: fakeQuery([delta("x")], calls) });
    await collect(a.send("one"));
    await collect(a.send("two"));
    expect(calls[0].options.resume).toBeUndefined();
    expect(calls[1].options.resume).toBe("s1");
    expect(a.resumeState()).toEqual({ sessionId: "s1" });
  });

  it("starts from a stored session id", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter(
      { tools: noTools, systemPrompt: "SP", resume: { sessionId: "old" } },
      { snapshotDir: "/s", queryFn: fakeQuery([], calls) },
    );
    await collect(a.send("hi"));
    expect(calls[0].options.resume).toBe("old");
  });

  it("turns SDK exceptions into classified errors", async () => {
    const throwing = (() => {
      throw new Error("spawn claude ENOENT");
    }) as any;
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: throwing });
    const evs = await collect(a.send("hi"));
    expect(evs[0]).toMatchObject({ type: "error", hint: expect.stringContaining("claude") });
  });

  it("cancel aborts the running query", async () => {
    let signal: AbortSignal | undefined;
    const q = ((params: any) => {
      signal = params.options.abortController.signal;
      return (async function* () {
        yield delta("a");
        await new Promise((r) => setTimeout(r, 50));
        if (signal!.aborted) throw new Error("aborted");
        yield delta("b");
      })();
    }) as any;
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: q });
    const out: AdapterEvent[] = [];
    for await (const e of a.send("hi")) {
      out.push(e);
      a.cancel();
    }
    expect(signal!.aborted).toBe(true);
    expect(out).toEqual([{ type: "text_delta", text: "a" }]);
  });
});

describe("makeToolHandler", () => {
  it("forwards to the tool host and converts the result", async () => {
    const seen: unknown[] = [];
    const handler = makeToolHandler(toolDef("get_palette")!, { call: async (n, a) => (seen.push([n, a]), { ok: true, data: { size: 2 } }) }, "/s");
    expect(await handler({ sprite: "a.aseprite" })).toEqual({ content: [{ type: "text", text: '{"size":2}' }] });
    expect(seen).toEqual([["get_palette", { sprite: "a.aseprite" }]]);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd bridge && npx vitest run test/claudeCode.test.ts`
Expected: FAIL, module not found.

- [ ] **Step 3: Implement the adapter**

`bridge/src/adapters/claudeCode.ts`:
```ts
import { createSdkMcpServer, query as sdkQuery, tool } from "@anthropic-ai/claude-agent-sdk";
import { TOOL_DEFS, type ToolDef } from "../tools/definitions.js";
import { toMcpResult, type McpToolResult } from "../tools/mcpResult.js";
import type { ToolHost } from "../toolTypes.js";
import type { Adapter, AdapterContext, AdapterEvent, AdapterFactory, ResumeState } from "./Adapter.js";

export const MCP_SERVER_NAME = "aseprite";

type QueryFn = typeof sdkQuery;

export interface ClaudeCodeOptions {
  snapshotDir: string;
  model?: string;
  queryFn?: QueryFn;
}

export function claudeCodeAdapterFactory(opts: ClaudeCodeOptions): AdapterFactory {
  return (ctx) => new ClaudeCodeAdapter(ctx, opts);
}

export function makeToolHandler(def: ToolDef, tools: ToolHost, snapshotDir: string) {
  return async (args: Record<string, unknown>): Promise<McpToolResult> => toMcpResult(await tools.call(def.name, args), snapshotDir);
}

/** Maps Agent SDK messages to adapter events. Stateful: remembers whether text has been emitted this turn. */
export function createSdkMapper() {
  let emittedText = false;
  return (msg: any): AdapterEvent | undefined => {
    if (msg?.type === "stream_event") {
      if (msg.parent_tool_use_id != null) return undefined;
      const ev = msg.event;
      if (ev?.type === "message_start" && emittedText) return { type: "text_delta", text: "\n\n" };
      if (ev?.type === "content_block_delta" && ev.delta?.type === "text_delta") {
        emittedText = true;
        return { type: "text_delta", text: ev.delta.text };
      }
      return undefined;
    }
    if (msg?.type === "result" && msg.subtype !== "success") {
      const detail = Array.isArray(msg.errors) && msg.errors.length ? `: ${msg.errors.join("; ")}` : "";
      return { type: "error", message: `Claude stopped (${msg.subtype})${detail}` };
    }
    return undefined;
  };
}

export function classifyError(e: unknown): AdapterEvent {
  const message = e instanceof Error ? e.message : String(e);
  if (/ENOENT|spawn|not found/i.test(message)) {
    return { type: "error", message: "Couldn't start Claude Code.", hint: "Install Claude Code so `claude` is on your PATH, then restart the bridge." };
  }
  if (/401|unauthori[sz]ed|not logged in|login|authenticat/i.test(message)) {
    return { type: "error", message: "Claude Code isn't logged in.", hint: "Run `claude` in a terminal and log in, then try again." };
  }
  return { type: "error", message };
}

export class ClaudeCodeAdapter implements Adapter {
  readonly name = "claude-code";
  private sessionId?: string;
  private abort?: AbortController;

  constructor(
    private ctx: AdapterContext,
    private opts: ClaudeCodeOptions,
  ) {
    const s = ctx.resume?.sessionId;
    if (typeof s === "string") this.sessionId = s;
  }

  private mcpServer() {
    return createSdkMcpServer({
      name: MCP_SERVER_NAME,
      version: "0.1.0",
      tools: TOOL_DEFS.map((def) => {
        const handler = makeToolHandler(def, this.ctx.tools, this.opts.snapshotDir);
        return tool(def.name, def.description, def.shape, async (args) => (await handler(args as Record<string, unknown>)) as any);
      }),
    });
  }

  async *send(text: string): AsyncIterable<AdapterEvent> {
    const abort = new AbortController();
    this.abort = abort;
    const map = createSdkMapper();
    try {
      const q = (this.opts.queryFn ?? sdkQuery)({
        prompt: text,
        options: {
          systemPrompt: this.ctx.systemPrompt,
          tools: [],
          allowedTools: TOOL_DEFS.map((d) => `mcp__${MCP_SERVER_NAME}__${d.name}`),
          mcpServers: { [MCP_SERVER_NAME]: this.mcpServer() },
          settingSources: [],
          includePartialMessages: true,
          abortController: abort,
          resume: this.sessionId,
          model: this.opts.model,
          env: { ...process.env, CLAUDE_AGENT_SDK_CLIENT_APP: "aseprite-agent/0.1.0" },
        },
      });
      for await (const msg of q as AsyncIterable<any>) {
        if (abort.signal.aborted) return;
        if (typeof msg?.session_id === "string") this.sessionId = msg.session_id;
        const ev = map(msg);
        if (ev) yield ev;
      }
    } catch (e) {
      if (abort.signal.aborted) return;
      yield classifyError(e);
    } finally {
      if (this.abort === abort) this.abort = undefined;
    }
  }

  cancel(): void {
    this.abort?.abort();
  }

  resumeState(): ResumeState | undefined {
    return this.sessionId ? { sessionId: this.sessionId } : undefined;
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd bridge && npx vitest run test/claudeCode.test.ts && npm run typecheck`
Expected: all pass. If tsc rejects `tool(def.name, def.description, def.shape, …)` because of the zod shape generic, change only the `shape` field type in `ToolDef` to `Record<string, z.ZodType>`. Keep the runtime behaviour identical.

- [ ] **Step 5: System prompt and entry point**

`bridge/src/prompt.ts`:
```ts
export const SYSTEM_PROMPT = `You are an art assistant living inside Aseprite, the pixel-art editor. You help the artist improve their own work: critique, teaching, color and palette advice, and animation feedback.

How you work:
- Look before you speak. Call get_sprite_info and get_snapshot before commenting on a sprite. Use get_pixels when exact colors or single-pixel placement matter; snapshots are resized images and can hide that detail.
- Be specific: point to coordinates, frames (numbered from 1, as in Aseprite), layers, and colors by hex.
- Teach. Name the principle behind each suggestion (light direction, value contrast, hue shifting, silhouette readability, cluster shapes, anti-aliasing, animation arcs and timing) so the artist gets better, not just this sprite.
- Be concise. Lead with the one to three changes that matter most. Plain text only: no markdown tables, no emoji (the chat window's font cannot show them).

You are not an art generator. If the artist asks you to draw, create, or generate artwork for them, push back once, kindly: explain that you are here to help them make it, and offer alternatives such as a construction breakdown, silhouette and proportion guidance, a palette plan, or a critique of their first pass. In this version you have no drawing or editing tools at all; say so plainly if asked to change the sprite.

Sprites: every tool accepts an optional "sprite" argument naming an open sprite by file name. Omit it to use the active sprite. Layers are listed bottom to top.`;
```

`bridge/src/main.ts`:
```ts
import { randomBytes } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { claudeCodeAdapterFactory } from "./adapters/claudeCode.js";
import { DEFAULT_PORT, agentHome, removeBridgeInfo, snapshotDirFor, writeBridgeInfo } from "./config.js";
import { SYSTEM_PROMPT } from "./prompt.js";
import { startServer, type BridgeServer } from "./server.js";

const home = agentHome();
const snapshotDir = snapshotDirFor(home);
await mkdir(snapshotDir, { recursive: true, mode: 0o700 });

const port = Number(process.env.ASEPRITE_AGENT_PORT ?? DEFAULT_PORT);
const token = randomBytes(24).toString("hex");

let server: BridgeServer;
try {
  server = await startServer({
    port,
    token,
    systemPrompt: SYSTEM_PROMPT,
    snapshotDir,
    adapterFactory: claudeCodeAdapterFactory({ snapshotDir, model: process.env.ASEPRITE_AGENT_MODEL }),
  });
} catch (e) {
  if ((e as NodeJS.ErrnoException).code === "EADDRINUSE") {
    console.error(`Port ${port} is in use. Is another bridge already running? (see ${home}/bridge.json)`);
    process.exit(1);
  }
  throw e;
}

await writeBridgeInfo(home, { port: server.port, token, pid: process.pid });
console.log(`aseprite-agent bridge listening on 127.0.0.1:${server.port} (pid ${process.pid})`);

const shutdown = async () => {
  await removeBridgeInfo(home);
  await server.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
```

- [ ] **Step 6: Smoke script (a fake extension against real Claude)**

`bridge/scripts/smoke.ts`:
```ts
// Usage: npm run smoke -- "What do you think of this sprite?"
// Pretends to be the Aseprite extension: answers get_sprite_info with a canned 16x16 knight, errors on other tools.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import WebSocket from "ws";
import { agentHome } from "../src/config.js";

const info = JSON.parse(await readFile(join(agentHome(), "bridge.json"), "utf8"));
const ws = new WebSocket(`ws://127.0.0.1:${info.port}`);
const text = process.argv.slice(2).join(" ") || "Describe the active sprite in one sentence.";

ws.on("open", () => ws.send(JSON.stringify({ type: "hello", token: info.token, extensionVersion: "smoke" })));
ws.on("message", (raw) => {
  const m = JSON.parse(raw.toString());
  if (m.type === "ready") ws.send(JSON.stringify({ type: "user_message", text }));
  else if (m.type === "text_delta") process.stdout.write(m.text);
  else if (m.type === "tool_activity") console.log(`\n[${m.summary}]`);
  else if (m.type === "tool_call") {
    const reply =
      m.name === "get_sprite_info"
        ? { ok: true, data: { sprite: "knight.aseprite", width: 16, height: 16, colorMode: "rgb", frameCount: 4, layers: [{ name: "Body", visible: true }] } }
        : { ok: false, error: "Not available in smoke test" };
    ws.send(JSON.stringify({ type: "tool_result", callId: m.callId, ...reply }));
  } else if (m.type === "error") console.error(`\n[error] ${m.message}${m.hint ? " - " + m.hint : ""}`);
  else if (m.type === "turn_done") {
    console.log("\n[turn done]");
    ws.close();
  }
});
ws.on("close", (code) => code === 4001 && console.error("unauthorized"));
```

- [ ] **Step 7: Build, run the bridge, and smoke-test against real Claude**

```bash
cd bridge && npm run build && npx vitest run
node dist/main.js > /tmp/aseprite-agent-bridge.log 2>&1 &   # note the PID; log it in ~/.claude/claude-running.md
npm run smoke -- "How big is the active sprite and how many frames does it have?"
```
Expected: `[Inspected the active sprite]`, then streamed text mentioning 16x16 and 4 frames, then `[turn done]`. If you get a login or CLI error instead, the hint text must be shown. Stop the bridge with `kill <pid>`, confirm `~/.aseprite-agent/bridge.json` is gone, and remove the running-record line.

- [ ] **Step 8: Commit**

```bash
git add bridge/src/adapters/claudeCode.ts bridge/src/prompt.ts bridge/src/main.ts bridge/scripts/smoke.ts bridge/test/claudeCode.test.ts
git commit -m "feat(bridge): Claude Code adapter, system prompt, entry point and smoke test"
```

---

### Task 6: Lua test harness and pure chat modules

**Files:**
- Create: `scripts/test-lua.sh`, `tests/lua/run.lua`, `tests/lua/testlib.lua`, `extension/agent/chat_model.lua`, `extension/agent/chat_render.lua`
- Test: `tests/lua/test_chat_model.lua`, `tests/lua/test_chat_render.lua`

**Interfaces:**
- Produces:
  - `ChatModel.new()` with `items` (`{kind="user"|"agent"|"activity"|"error", text}`), `:addUser(text)`, `:appendAgent(delta)`, `:addActivity(summary)`, `:addError(message, hint)`, `:endTurn()`, `:clear()`
  - `chat_render.wrap(text, maxWidth, measure) -> {string}`, `chat_render.layout(items, {width, measure, lineHeight, gap, agentLabel}) -> {lines={ {text, kind, y} }, height}`, `chat_render.clampScroll(scroll, contentH, viewH) -> number`
  - Test lib: `T.test(name, fn)`, `T.eq(a, e, msg)`, `T.deepEq(a, e, msg)`, `T.errors(fn, substring)`, `T.finish()`

- [ ] **Step 1: Harness**

`scripts/test-lua.sh` (then `chmod +x scripts/test-lua.sh`):
```bash
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
```

`tests/lua/testlib.lua`:
```lua
local T = { passed = 0, failed = 0 }

function T.show(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. T.show(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function T.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    T.passed = T.passed + 1
    print("  ok   " .. name)
  else
    T.failed = T.failed + 1
    print("  FAIL " .. name .. "\n" .. tostring(err))
  end
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "not equal") .. ": expected " .. T.show(expected) .. ", got " .. T.show(actual), 2)
  end
end

function T.deepEq(actual, expected, msg)
  local a, e = T.show(actual), T.show(expected)
  if a ~= e then error((msg or "not deep-equal") .. ":\n  expected " .. e .. "\n  got      " .. a, 2) end
end

function T.errors(fn, substring)
  local ok, err = pcall(fn)
  if ok then error("expected an error", 2) end
  if substring and not tostring(err):find(substring, 1, true) then
    error("error " .. T.show(tostring(err)) .. " does not contain " .. T.show(substring), 2)
  end
end

function T.finish()
  print(("%d passed, %d failed"):format(T.passed, T.failed))
  if T.failed > 0 then error("TESTS FAILED", 0) end
end

return T
```

`tests/lua/run.lua`:
```lua
local root = app.params.root
package.path = app.fs.joinPath(root, "extension", "?.lua") .. ";"
  .. app.fs.joinPath(root, "extension", "?", "init.lua") .. ";"
  .. app.fs.joinPath(root, "tests", "lua", "?.lua") .. ";" .. package.path

local T = require("testlib")
local only = app.params.only or ""
local suites = { "test_chat_model", "test_chat_render", "test_tools_inspect" }

for _, name in ipairs(suites) do
  if only == "" or name:find(only, 1, true) then
    local path = app.fs.joinPath(root, "tests", "lua", name .. ".lua")
    if app.fs.isFile(path) then
      print(name)
      require(name)
    end
  end
end
T.finish()
```

- [ ] **Step 2: Write failing tests**

`tests/lua/test_chat_model.lua`:
```lua
local T = require("testlib")
local ChatModel = require("agent.chat_model")

T.test("consecutive agent deltas merge into one item", function()
  local m = ChatModel.new()
  m:addUser("hi")
  m:appendAgent("Hel")
  m:appendAgent("lo")
  T.deepEq(m.items, { { kind = "user", text = "hi" }, { kind = "agent", text = "Hello" } })
end)

T.test("activity splits agent text into separate items", function()
  local m = ChatModel.new()
  m:appendAgent("Let me look.")
  m:addActivity("Looked at knight.aseprite")
  m:appendAgent("The outline is thick.")
  T.eq(#m.items, 3)
  T.eq(m.items[3].kind, "agent")
end)

T.test("endTurn starts a fresh agent item next time", function()
  local m = ChatModel.new()
  m:appendAgent("a")
  m:endTurn()
  m:appendAgent("b")
  T.eq(#m.items, 2)
end)

T.test("errors include the hint on a new line", function()
  local m = ChatModel.new()
  m:addError("Claude Code isn't logged in.", "Run `claude` and log in.")
  T.deepEq(m.items[1], { kind = "error", text = "Claude Code isn't logged in.\nRun `claude` and log in." })
  m:addError("plain", nil)
  T.eq(m.items[2].text, "plain")
end)

T.test("clear empties the chat", function()
  local m = ChatModel.new()
  m:addUser("x")
  m:clear()
  T.eq(#m.items, 0)
end)
```

`tests/lua/test_chat_render.lua`:
```lua
local T = require("testlib")
local R = require("agent.chat_render")

local function chars(s) return utf8.len(s) or #s end

T.test("wraps on word boundaries", function()
  T.deepEq(R.wrap("hello world", 5, chars), { "hello", "world" })
  T.deepEq(R.wrap("a b c", 100, chars), { "a b c" })
end)

T.test("hard-breaks words longer than the width", function()
  T.deepEq(R.wrap("abcdefghij", 4, chars), { "abcd", "efgh", "ij" })
  T.deepEq(R.wrap("see https://example.com/very/long", 10, chars),
    { "see", "https://ex", "ample.com/", "very/long" })
end)

T.test("keeps paragraphs and blank lines", function()
  T.deepEq(R.wrap("one\n\ntwo", 10, chars), { "one", "", "two" })
  T.deepEq(R.wrap("", 10, chars), { "" })
end)

T.test("splits on UTF-8 characters, not bytes", function()
  T.deepEq(R.wrap("héllo wörld", 5, chars), { "héllo", "wörld" })
  T.deepEq(R.wrap("ééééé", 2, chars), { "éé", "éé", "é" })
end)

T.test("survives invalid UTF-8", function()
  local lines = R.wrap("ab\255\254cd", 2, function(s) return #s end)
  T.eq(#lines > 0, true)
end)

T.test("lays out labels, text, activity and gaps", function()
  local items = {
    { kind = "user", text = "hi" },
    { kind = "agent", text = "yo" },
    { kind = "activity", text = "Looked at a" },
  }
  local lay = R.layout(items, { width = 20, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude" })
  T.deepEq(lay.lines, {
    { text = "You", kind = "user_label", y = 0 },
    { text = "hi", kind = "user", y = 10 },
    { text = "Claude", kind = "agent_label", y = 25 },
    { text = "yo", kind = "agent", y = 35 },
    { text = "- Looked at a", kind = "activity", y = 50 },
  })
  T.eq(lay.height, 60)
end)

T.test("clampScroll keeps the view inside the content", function()
  T.eq(R.clampScroll(-5, 100, 40), 0)
  T.eq(R.clampScroll(500, 100, 40), 60)
  T.eq(R.clampScroll(10, 30, 40), 0)
end)
```

- [ ] **Step 3: Run them to verify they fail**

Run: `scripts/test-lua.sh chat`
Expected: non-zero exit; the output shows `module 'agent.chat_model' not found`.

- [ ] **Step 4: Implement**

`extension/agent/chat_model.lua`:
```lua
local ChatModel = {}
ChatModel.__index = ChatModel

function ChatModel.new()
  return setmetatable({ items = {}, streaming = false }, ChatModel)
end

function ChatModel:addUser(text)
  self.items[#self.items + 1] = { kind = "user", text = text }
  self.streaming = false
end

function ChatModel:appendAgent(delta)
  local last = self.items[#self.items]
  if self.streaming and last and last.kind == "agent" then
    last.text = last.text .. delta
  else
    self.items[#self.items + 1] = { kind = "agent", text = delta }
    self.streaming = true
  end
end

function ChatModel:addActivity(summary)
  self.items[#self.items + 1] = { kind = "activity", text = summary }
  self.streaming = false
end

function ChatModel:addError(message, hint)
  local text = message
  if hint and hint ~= "" then text = text .. "\n" .. hint end
  self.items[#self.items + 1] = { kind = "error", text = text }
  self.streaming = false
end

function ChatModel:endTurn()
  self.streaming = false
end

function ChatModel:clear()
  self.items = {}
  self.streaming = false
end

return ChatModel
```

`extension/agent/chat_render.lua`:
```lua
local R = {}

local function splitChars(s)
  local out = {}
  local ok = pcall(function()
    for _, code in utf8.codes(s) do out[#out + 1] = utf8.char(code) end
  end)
  if not ok then
    out = {}
    for i = 1, #s do out[#out + 1] = s:sub(i, i) end
  end
  return out
end

function R.wrap(text, maxWidth, measure)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local candidate = (line == "") and word or (line .. " " .. word)
      if measure(candidate) <= maxWidth then
        line = candidate
      else
        if line ~= "" then
          lines[#lines + 1] = line
          line = ""
        end
        if measure(word) <= maxWidth then
          line = word
        else
          for _, ch in ipairs(splitChars(word)) do
            if line ~= "" and measure(line .. ch) > maxWidth then
              lines[#lines + 1] = line
              line = ch
            else
              line = line .. ch
            end
          end
        end
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

local LABELS = { user = "You" }
local PREFIX = { activity = "- ", error = "! " }

function R.layout(items, opts)
  local lines, y = {}, 0
  for i, item in ipairs(items) do
    if i > 1 then y = y + opts.gap end
    local label = LABELS[item.kind] or (item.kind == "agent" and (opts.agentLabel or "Agent")) or nil
    if label then
      lines[#lines + 1] = { text = label, kind = item.kind .. "_label", y = y }
      y = y + opts.lineHeight
    end
    for _, l in ipairs(R.wrap((PREFIX[item.kind] or "") .. item.text, opts.width, opts.measure)) do
      lines[#lines + 1] = { text = l, kind = item.kind, y = y }
      y = y + opts.lineHeight
    end
  end
  return { lines = lines, height = y }
end

function R.clampScroll(scroll, contentHeight, viewHeight)
  return math.max(0, math.min(scroll, math.max(0, contentHeight - viewHeight)))
end

return R
```

- [ ] **Step 5: Run tests**

Run: `scripts/test-lua.sh chat`
Expected: every test prints `ok`, and the output ends with `12 passed, 0 failed` and exit code 0. (`test_tools_inspect` is skipped because the file doesn't exist yet.)

- [ ] **Step 6: Commit**

```bash
git add scripts/test-lua.sh tests/lua extension/agent/chat_model.lua extension/agent/chat_render.lua
git commit -m "feat(extension): headless Lua test harness, chat model and text layout"
```

---

### Task 7: Sprite inspection tools (Lua)

**Files:**
- Create: `extension/agent/tools/registry.lua`, `extension/agent/tools/sprites.lua`, `extension/agent/tools/color.lua`, `extension/agent/tools/inspect.lua`, `extension/agent/tools/init.lua`
- Test: `tests/lua/test_tools_inspect.lua`

**Interfaces:**
- Consumes: tool names and argument shapes from Task 3 (`sprite`, `frame` 1-based, `layer`, `region {x,y,w,h}`, `maxSize`).
- Produces:
  - `require("agent.tools")` returns the registry: `.dispatch(name, args) -> {ok=true, data=...} | {ok=false, error=string}`
  - `inspect.snapshotDir` (string, set from the bridge's `ready` message), `inspect.snapshotScale(w, h, maxSize) -> number`
  - Result shapes: `get_sprite_info -> {sprite, path, width, height, colorMode, frameCount, frameDurationsMs, layers, tags, paletteSize, activeFrame?, activeLayer?, selection?}`; `get_snapshot -> {pngPath, sprite, frame, layer?, region?, width, height, scale}`; `get_pixels -> {sprite, frame, x, y, w, h, legend, rows}`; `get_palette -> {sprite, size, colors, transparentIndex?}`

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_tools_inspect.lua`:
```lua
local T = require("testlib")
local tools = require("agent.tools")
local inspect = require("agent.tools.inspect")
local color = require("agent.tools.color")

local pc = app.pixelColor
local tmp = app.fs.joinPath(app.fs.tempPath, "aseagent-tests")
app.fs.makeAllDirectories(tmp)

local function closeAll()
  while #app.sprites > 0 do app.sprites[1]:close() end
end

-- 4x3 RGB sprite, layer "Body": (0,0) red, (1,0) green, rest transparent.
local function rgbSprite(name)
  local s = Sprite(4, 3)
  local cel = s.cels[1]
  local img = cel.image:clone()
  img:drawPixel(0, 0, pc.rgba(255, 0, 0, 255))
  img:drawPixel(1, 0, pc.rgba(0, 255, 0, 255))
  cel.image = img
  s.layers[1].name = "Body"
  if name then s:saveAs(app.fs.joinPath(tmp, name)) end
  app.sprite = s
  return s
end

local function call(name, args)
  return tools.dispatch(name, args or {})
end

T.test("get_sprite_info describes the active sprite", function()
  closeAll()
  rgbSprite()
  local r = call("get_sprite_info")
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 4)
  T.eq(r.data.height, 3)
  T.eq(r.data.colorMode, "rgb")
  T.eq(r.data.frameCount, 1)
  T.eq(r.data.layers[1].name, "Body")
  T.eq(r.data.layers[1].blendMode, "normal")
  T.eq(r.data.activeFrame, 1)
end)

T.test("no open sprite gives a plain error", function()
  closeAll()
  local r = call("get_sprite_info")
  T.eq(r.ok, false)
  T.eq(r.error, "No sprite is open in Aseprite.")
end)

T.test("sprites resolve by file name, and unknown names list open sprites", function()
  closeAll()
  rgbSprite("first.aseprite")
  local other = Sprite(2, 2)
  app.sprite = other
  local r = call("get_sprite_info", { sprite = "first.aseprite" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 4)
  T.eq(r.data.activeFrame, nil, "not the active sprite")
  local bad = call("get_sprite_info", { sprite = "nope.aseprite" })
  T.eq(bad.ok, false)
  T.eq(bad.error:find("Sprite 'nope.aseprite' is not open", 1, true) ~= nil, true, bad.error)
end)

T.test("get_pixels returns hex rows with '.' for transparent", function()
  closeAll()
  rgbSprite()
  local r = call("get_pixels", { region = { x = 0, y = 0, w = 4, h = 1 } })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.rows, { "#ff0000 #00ff00 . ." })
  T.eq(r.data.frame, 1)
end)

T.test("get_pixels clips to the sprite and rejects oversized or outside regions", function()
  closeAll()
  rgbSprite()
  local r = call("get_pixels", { region = { x = 2, y = 0, w = 10, h = 1 } })
  T.eq(r.data.w, 2)
  T.eq(call("get_pixels", { region = { x = 0, y = 0, w = 65, h = 1 } }).error,
    "Region is limited to 64x64 pixels; use get_snapshot for larger areas.")
  T.eq(call("get_pixels", { region = { x = 10, y = 10, w = 2, h = 2 } }).error, "Region is outside the sprite.")
end)

T.test("get_pixels reads a single layer", function()
  closeAll()
  local s = rgbSprite()
  s:newLayer().name = "Empty"
  local r = call("get_pixels", { layer = "Empty", region = { x = 0, y = 0, w = 2, h = 1 } })
  T.deepEq(r.data.rows, { ". ." })
  T.eq(call("get_pixels", { layer = "Ghost", region = { x = 0, y = 0, w = 1, h = 1 } }).error, "Layer 'Ghost' not found.")
end)

T.test("accepts JSON numbers decoded as floats", function()
  closeAll()
  rgbSprite()
  local r = call("get_pixels", { frame = 1.0, region = { x = 0.0, y = 0.0, w = 2.0, h = 1.0 } })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.rows, { "#ff0000 #00ff00" })
end)

T.test("frames are 1-based and validated", function()
  closeAll()
  rgbSprite()
  T.eq(call("get_pixels", { frame = 5, region = { x = 0, y = 0, w = 1, h = 1 } }).error,
    "Frame 5 does not exist (sprite has 1 frames).")
end)

T.test("indexed sprites report palette colors", function()
  closeAll()
  local s = Sprite(2, 1, ColorMode.INDEXED)
  local pal = s.palettes[1]
  pal:resize(3)
  pal:setColor(1, Color{ r = 10, g = 20, b = 30, a = 255 })
  local cel = s.cels[1]
  local img = cel.image:clone()
  img:drawPixel(0, 0, s.transparentColor)
  img:drawPixel(1, 0, 1)
  cel.image = img
  app.sprite = s
  local px = call("get_pixels", { region = { x = 0, y = 0, w = 2, h = 1 } })
  T.deepEq(px.data.rows, { ". #0a141e" })
  local p = call("get_palette")
  T.eq(p.data.size, 3)
  T.eq(p.data.colors[2], "#0a141e")
  T.eq(p.data.transparentIndex, 0)
  T.eq(call("get_sprite_info").data.colorMode, "indexed")
end)

T.test("pixelToHex handles translucency and grayscale", function()
  T.eq(color.pixelToHex(pc.rgba(1, 2, 3, 128), ColorMode.RGB), "#01020380")
  T.eq(color.pixelToHex(pc.rgba(1, 2, 3, 0), ColorMode.RGB), ".")
  T.eq(color.pixelToHex(pc.graya(200, 255), ColorMode.GRAYSCALE), "#c8c8c8")
end)

T.test("snapshotScale upscales small sprites and caps big ones", function()
  T.eq(inspect.snapshotScale(16, 16, 512), 32)
  T.eq(inspect.snapshotScale(1000, 10, 512), 1)
  T.eq(inspect.snapshotScale(3000, 10, 512), 2048 / 3000)
end)

T.test("get_snapshot writes an upscaled PNG into the snapshot dir", function()
  closeAll()
  inspect.snapshotDir = tmp
  local s = Sprite(16, 16)
  app.sprite = s
  local r = call("get_snapshot")
  T.eq(r.ok, true, r.error)
  T.eq(r.data.scale, 32)
  T.eq(app.fs.filePath(r.data.pngPath), app.fs.filePath(app.fs.joinPath(tmp, "x.png")))
  T.eq(app.fs.fileName(r.data.pngPath):match("^aseagent%-[%w%-]+%.png$") ~= nil, true, r.data.pngPath)
  local img = Image{ fromFile = r.data.pngPath }
  T.eq(img.width, 512)
  os.remove(r.data.pngPath)
end)

T.test("get_snapshot crops regions and rejects regions outside the sprite", function()
  closeAll()
  inspect.snapshotDir = tmp
  rgbSprite()
  local r = call("get_snapshot", { region = { x = 0, y = 0, w = 2, h = 2 }, maxSize = 64 })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 64)
  T.deepEq(r.data.region, { x = 0, y = 0, w = 2, h = 2 })
  os.remove(r.data.pngPath)
  T.eq(call("get_snapshot", { region = { x = 50, y = 50, w = 2, h = 2 } }).error, "Region is outside the sprite.")
end)

T.test("get_snapshot without a bridge connection explains itself", function()
  closeAll()
  rgbSprite()
  inspect.snapshotDir = nil
  T.eq(call("get_snapshot").error, "Snapshot directory unknown (bridge not connected).")
end)

T.test("unknown tools and internal errors are reported, not thrown", function()
  T.eq(call("launch_missiles").error, "Unknown tool: launch_missiles")
end)

closeAll()
```

- [ ] **Step 2: Run them to verify they fail**

Run: `scripts/test-lua.sh inspect`
Expected: non-zero exit, `module 'agent.tools' not found`.

- [ ] **Step 3: Implement registry, sprites, and color**

`extension/agent/tools/registry.lua`:
```lua
local M = { handlers = {} }

function M.register(handlers)
  for name, fn in pairs(handlers) do M.handlers[name] = fn end
end

local function cleanError(e)
  return (tostring(e):gsub("^[^\n]-:%d+: ", ""))
end

function M.dispatch(name, args)
  local fn = M.handlers[name]
  if not fn then return { ok = false, error = "Unknown tool: " .. tostring(name) } end
  local ok, res = pcall(fn, args or {})
  if ok then return { ok = true, data = res } end
  return { ok = false, error = cleanError(res) }
end

return M
```

`extension/agent/tools/sprites.lua`:
```lua
local M = {}

function M.name(sprite)
  return app.fs.fileName(sprite.filename)
end

function M.openList()
  local names = {}
  for _, s in ipairs(app.sprites) do names[#names + 1] = M.name(s) end
  return #names > 0 and table.concat(names, ", ") or "(none)"
end

function M.resolve(ref)
  if ref == nil or ref == "" then
    local s = app.sprite
    if not s then error("No sprite is open in Aseprite.", 0) end
    return s
  end
  for _, s in ipairs(app.sprites) do
    if s.filename == ref or M.name(s) == ref then return s end
  end
  error("Sprite '" .. ref .. "' is not open. Open sprites: " .. M.openList(), 0)
end

function M.frame(sprite, n)
  n = n and (math.tointeger(n) or n)
  if n == nil then
    if app.sprite == sprite and app.frame then return app.frame end
    return sprite.frames[1]
  end
  local ok, f = pcall(function() return sprite.frames[n] end)
  if not ok or not f then
    error(("Frame %d does not exist (sprite has %d frames)."):format(n, #sprite.frames), 0)
  end
  return f
end

function M.layer(sprite, name)
  local function find(layers)
    for _, l in ipairs(layers) do
      if l.name == name then return l end
      if l.isGroup then
        local hit = find(l.layers)
        if hit then return hit end
      end
    end
  end
  local l = find(sprite.layers)
  if not l then error("Layer '" .. name .. "' not found.", 0) end
  return l
end

return M
```

`extension/agent/tools/color.lua`:
```lua
local M = {}
local pc = app.pixelColor

function M.hex(r, g, b, a)
  if a == nil or a == 255 then return string.format("#%02x%02x%02x", r, g, b) end
  return string.format("#%02x%02x%02x%02x", r, g, b, a)
end

function M.fromColor(c)
  return M.hex(c.red, c.green, c.blue, c.alpha)
end

-- Converts a raw pixel value to "#rrggbb[aa]", or "." when fully transparent.
function M.pixelToHex(value, colorMode, palette, transparentIndex)
  if colorMode == ColorMode.RGB then
    local a = pc.rgbaA(value)
    if a == 0 then return "." end
    return M.hex(pc.rgbaR(value), pc.rgbaG(value), pc.rgbaB(value), a)
  elseif colorMode == ColorMode.GRAYSCALE then
    local a = pc.grayaA(value)
    if a == 0 then return "." end
    local v = pc.grayaV(value)
    return M.hex(v, v, v, a)
  end
  if value == transparentIndex then return "." end
  if value >= #palette then return "?" end
  local c = palette:getColor(value)
  if c.alpha == 0 then return "." end
  return M.fromColor(c)
end

M.COLOR_MODES = {
  [ColorMode.RGB] = "rgb",
  [ColorMode.GRAYSCALE] = "grayscale",
  [ColorMode.INDEXED] = "indexed",
}

return M
```

- [ ] **Step 4: Implement inspect and init**

`extension/agent/tools/inspect.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")

local M = { snapshotDir = nil }

local BLEND_NAMES = {}
for _, n in ipairs{ "NORMAL", "MULTIPLY", "SCREEN", "OVERLAY", "DARKEN", "LIGHTEN", "COLOR_DODGE", "COLOR_BURN",
  "HARD_LIGHT", "SOFT_LIGHT", "DIFFERENCE", "EXCLUSION", "HUE", "SATURATION", "COLOR", "LUMINOSITY",
  "ADDITION", "SUBTRACT", "DIVIDE" } do
  if BlendMode[n] ~= nil then BLEND_NAMES[BlendMode[n]] = n:lower() end
end

local function layerTree(layers)
  local out = {}
  for _, l in ipairs(layers) do
    local e = { name = l.name, visible = l.isVisible, isGroup = l.isGroup, opacity = l.opacity }
    if l.isGroup then
      e.layers = layerTree(l.layers)
    else
      e.blendMode = BLEND_NAMES[l.blendMode] or tostring(l.blendMode)
    end
    out[#out + 1] = e
  end
  return out
end

-- Flattened visible image of a frame, or one layer's cel placed at its position.
local function render(sprite, frame, layerName)
  local img = Image(sprite.spec)
  img:clear()
  if layerName then
    local cel = sprites.layer(sprite, layerName):cel(frame)
    if cel then img:drawImage(cel.image, cel.position) end
  else
    img:drawSprite(sprite, frame)
  end
  return img
end

-- Intersects a {x,y,w,h} region with the sprite bounds; errors when empty.
local function clip(sprite, r)
  local x, y, w, h = math.floor(r.x), math.floor(r.y), math.floor(r.w), math.floor(r.h)
  local x1, y1 = math.max(0, x), math.max(0, y)
  local x2, y2 = math.min(sprite.width, x + w), math.min(sprite.height, y + h)
  if x2 <= x1 or y2 <= y1 then error("Region is outside the sprite.", 0) end
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

function M.get_sprite_info(args)
  local s = sprites.resolve(args.sprite)
  local durations = {}
  for i, f in ipairs(s.frames) do durations[i] = math.floor(f.duration * 1000 + 0.5) end
  local tags = {}
  for _, t in ipairs(s.tags) do
    tags[#tags + 1] = { name = t.name, from = t.fromFrame.frameNumber, to = t.toFrame.frameNumber }
  end
  local info = {
    sprite = sprites.name(s),
    path = s.filename,
    width = s.width,
    height = s.height,
    colorMode = color.COLOR_MODES[s.colorMode] or "other",
    frameCount = #s.frames,
    frameDurationsMs = durations,
    layers = layerTree(s.layers),
    tags = tags,
    paletteSize = #s.palettes[1],
  }
  if app.sprite == s then
    info.activeFrame = app.frame and app.frame.frameNumber
    info.activeLayer = app.layer and app.layer.name
  end
  if not s.selection.isEmpty then
    local b = s.selection.bounds
    info.selection = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  return info
end

function M.snapshotScale(w, h, maxSize)
  local long = math.max(w, h)
  if long > 2048 then return 2048 / long end
  return math.max(1, math.floor(maxSize / long))
end

local counter = 0

function M.get_snapshot(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local img = render(s, frame, args.layer)
  local region
  if args.region then
    region = clip(s, args.region)
    img = Image(img, Rectangle(region.x, region.y, region.w, region.h))
  end
  if not M.snapshotDir then error("Snapshot directory unknown (bridge not connected).", 0) end
  local scale = M.snapshotScale(img.width, img.height, args.maxSize or 512)
  if scale ~= 1 then
    img:resize(math.max(1, math.floor(img.width * scale + 0.5)), math.max(1, math.floor(img.height * scale + 0.5)))
  end
  counter = counter + 1
  local path = app.fs.joinPath(M.snapshotDir, ("aseagent-%d-%d.png"):format(os.time(), counter))
  img:saveAs{ filename = path, palette = s.palettes[1] }
  return {
    pngPath = path,
    sprite = sprites.name(s),
    frame = frame.frameNumber,
    layer = args.layer,
    region = region,
    width = img.width,
    height = img.height,
    scale = scale,
  }
end

function M.get_pixels(args)
  local s = sprites.resolve(args.sprite)
  local r = args.region
  if not r then error("region is required.", 0) end
  if r.w > 64 or r.h > 64 then error("Region is limited to 64x64 pixels; use get_snapshot for larger areas.", 0) end
  local frame = sprites.frame(s, args.frame)
  r = clip(s, r)
  local img = render(s, frame, args.layer)
  local pal = s.palettes[1]
  local rows = {}
  for y = r.y, r.y + r.h - 1 do
    local row = {}
    for x = r.x, r.x + r.w - 1 do
      row[#row + 1] = color.pixelToHex(img:getPixel(x, y), s.colorMode, pal, s.transparentColor)
    end
    rows[#rows + 1] = table.concat(row, " ")
  end
  return {
    sprite = sprites.name(s),
    frame = frame.frameNumber,
    x = r.x, y = r.y, w = r.w, h = r.h,
    legend = "'.' = transparent; colors are #rrggbb or #rrggbbaa",
    rows = rows,
  }
end

function M.get_palette(args)
  local s = sprites.resolve(args.sprite)
  local pal = s.palettes[1]
  local colors = {}
  for i = 0, #pal - 1 do colors[#colors + 1] = color.fromColor(pal:getColor(i)) end
  return {
    sprite = sprites.name(s),
    size = #pal,
    colors = colors,
    transparentIndex = (s.colorMode == ColorMode.INDEXED) and s.transparentColor or nil,
  }
end

return M
```

`extension/agent/tools/init.lua`:
```lua
local registry = require("agent.tools.registry")
local inspect = require("agent.tools.inspect")

registry.register{
  get_sprite_info = inspect.get_sprite_info,
  get_snapshot = inspect.get_snapshot,
  get_pixels = inspect.get_pixels,
  get_palette = inspect.get_palette,
}

return registry
```

> `require("agent.tools")` resolves to `agent/tools/init.lua` through the `?/init.lua` entry already in `tests/lua/run.lua` (Task 6); `plugin.lua` (Task 8) adds the same entry.

- [ ] **Step 5: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all three suites print `ok` for every test, and the run ends with `0 failed`, exit 0. If `Image(img, Rectangle(...))` is rejected by this Aseprite version, replace it with `local sub = Image(region.w, region.h, img.colorMode); sub:drawImage(img, Point(-region.x, -region.y)); img = sub`.

- [ ] **Step 6: Commit**

```bash
git add extension/agent/tools tests/lua/test_tools_inspect.lua
git commit -m "feat(extension): sprite inspection tools with headless tests"
```

---

### Task 8: Connection, chat window, extension manifest, and end-to-end check

**Files:**
- Create: `extension/package.json`, `extension/plugin.lua`, `extension/agent/connection.lua`, `extension/agent/chat_window.lua`, `scripts/dev-install.sh`
- Modify: `README.md` (add a "Development" section)

**Interfaces:**
- Consumes: `ChatModel`, `chat_render` (Task 6); `require("agent.tools").dispatch`, `inspect.snapshotDir` (Task 7); bridge protocol (Task 1: `hello`, `user_message`, `cancel`, `new_chat`, `tool_result` out; `ready`, `text_delta`, `tool_activity`, `tool_call`, `turn_done`, `error` in).
- Produces: `Connection.new{onMessage, onStatus}` with `:connect() -> bool`, `:send(tbl)`, `:close()`, `.status`, and `Connection.readBridgeInfo(path)`, `Connection.infoPath()`; `ChatWindow.new{prefs, onclose}` with `:show()`.

This task is UI glue that headless Aseprite can't drive. Verification is the manual checklist in Step 6.

- [ ] **Step 1: Manifest and plugin entry**

`extension/package.json`:
```json
{
  "name": "aseprite-agent",
  "displayName": "Agent Chat",
  "description": "Chat with an AI art assistant (Claude first) that helps you make your own pixel art.",
  "version": "0.1.0",
  "author": { "name": "ermurray" },
  "license": "MIT",
  "categories": ["Scripts"],
  "contributes": { "scripts": [{ "path": "./plugin.lua" }] }
}
```

`extension/plugin.lua`:
```lua
local window

function init(plugin)
  package.path = app.fs.joinPath(plugin.path, "?.lua") .. ";"
    .. app.fs.joinPath(plugin.path, "?", "init.lua") .. ";" .. package.path
  local ChatWindow = require("agent.chat_window")

  plugin:newCommand{
    id = "AgentChat",
    title = "Agent Chat",
    group = "edit_insert",
    onclick = function()
      if not window then
        window = ChatWindow.new{ prefs = plugin.preferences, onclose = function() window = nil end }
      end
      window:show()
    end,
  }
end

function exit(plugin)
  if window then window:close() end
end
```

- [ ] **Step 2: Connection**

`extension/agent/connection.lua`:
```lua
local Connection = {}
Connection.__index = Connection

local VERSION = "0.1.0"

function Connection.infoPath()
  local home = os.getenv("ASEPRITE_AGENT_HOME")
    or app.fs.joinPath(os.getenv("HOME") or os.getenv("USERPROFILE") or "", ".aseprite-agent")
  return app.fs.joinPath(home, "bridge.json")
end

function Connection.readBridgeInfo(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("a")
  f:close()
  local ok, info = pcall(json.decode, raw)
  if ok and type(info) == "table" and info.port and info.token then return info end
  return nil
end

function Connection.new(opts)
  return setmetatable({ opts = opts, ws = nil, token = nil, status = "disconnected" }, Connection)
end

function Connection:setStatus(status, detail)
  self.status = status
  self.opts.onStatus(status, detail)
end

function Connection:connect()
  self:close()
  local info = Connection.readBridgeInfo(Connection.infoPath())
  if not info then
    self:setStatus("disconnected", "Bridge not running")
    return false
  end
  self.token = info.token
  self:setStatus("connecting")
  self.ws = WebSocket{
    url = "ws://127.0.0.1:" .. math.tointeger(info.port),
    deflate = false,
    minreconnectwait = 1,
    maxreconnectwait = 10,
    onreceive = function(kind, data, err) self:onReceive(kind, data, err) end,
  }
  self.ws:connect()
  return true
end

function Connection:onReceive(kind, data, err)
  if kind == WebSocketMessageType.OPEN then
    -- Re-read the token on every (re)connect: a restarted bridge has a new one.
    local info = Connection.readBridgeInfo(Connection.infoPath())
    if info then self.token = info.token end
    self:send{ type = "hello", token = self.token, extensionVersion = VERSION }
  elseif kind == WebSocketMessageType.TEXT then
    local ok, msg = pcall(json.decode, data)
    if ok and type(msg) == "table" then
      if msg.type == "ready" then self:setStatus("connected") end
      self.opts.onMessage(msg)
    end
  elseif kind == WebSocketMessageType.CLOSE then
    self:setStatus("disconnected", err)
  elseif WebSocketMessageType.ERROR ~= nil and kind == WebSocketMessageType.ERROR then
    self:setStatus("disconnected", err)
  end
end

function Connection:send(tbl)
  if self.ws then self.ws:sendText(json.encode(tbl)) end
end

function Connection:close()
  if self.ws then
    self.ws:close()
    self.ws = nil
  end
end

return Connection
```

- [ ] **Step 3: Chat window**

`extension/agent/chat_window.lua`:
```lua
local ChatModel = require("agent.chat_model")
local render = require("agent.chat_render")
local Connection = require("agent.connection")
local tools = require("agent.tools")
local inspect = require("agent.tools.inspect")

local ChatWindow = {}
ChatWindow.__index = ChatWindow

local PAD, GAP = 6, 8
local STATUS_TEXT = {
  connected = "Connected",
  connecting = "Connecting...",
  disconnected = "Bridge not running - start it with: cd bridge && npm start",
}
local COLORS = {
  user_label = Color{ r = 110, g = 160, b = 255 },
  agent_label = Color{ r = 120, g = 200, b = 140 },
  activity = Color{ r = 140, g = 140, b = 140 },
  error = Color{ r = 230, g = 90, b = 80 },
}

local function themeColor(name, fallback)
  local ok, c = pcall(function() return app.theme.color[name] end)
  return (ok and c) or fallback
end

function ChatWindow.new(opts)
  local self = setmetatable({
    opts = opts,
    model = ChatModel.new(),
    scroll = 0,
    followTail = true,
    busy = false,
    agentLabel = "Agent",
    viewH = 0,
    contentH = 0,
    lineH = 14,
  }, ChatWindow)
  self.conn = Connection.new{
    onMessage = function(m) self:onMessage(m) end,
    onStatus = function(s, d) self:onStatus(s, d) end,
  }
  self:build()
  return self
end

function ChatWindow:build()
  local dlg = Dialog{
    title = "Agent Chat",
    resizeable = true,
    onclose = function() self:onClosed() end,
  }
  dlg:label{ id = "status", text = STATUS_TEXT.disconnected }
  dlg:newrow()
  dlg:button{ id = "connect", text = "Reconnect", onclick = function() self.conn:connect() end }
  dlg:button{ id = "newchat", text = "New chat", onclick = function() self:newChat() end }
  dlg:newrow()
  dlg:canvas{
    id = "history",
    width = 360,
    height = 420,
    hexpand = true,
    vexpand = true,
    onpaint = function(ev) self:paint(ev.context) end,
    onwheel = function(ev) self:scrollBy(ev.deltaY * 3 * self.lineH) end,
  }
  dlg:newrow()
  dlg:entry{ id = "input", hexpand = true }
  dlg:button{ id = "send", text = "Send", focus = true, onclick = function() self:onSendOrStop() end }
  self.dlg = dlg
end

function ChatWindow:show()
  local b = self.opts.prefs.bounds
  if b then
    self.dlg:show{ wait = false, bounds = Rectangle(b.x, b.y, b.w, b.h) }
  else
    self.dlg:show{ wait = false }
  end
  if self.conn.status == "disconnected" then self.conn:connect() end
end

function ChatWindow:close()
  self.dlg:close()
end

function ChatWindow:onClosed()
  local b = self.dlg.bounds
  self.opts.prefs.bounds = { x = b.x, y = b.y, w = b.width, h = b.height }
  self.conn:close()
  if self.opts.onclose then self.opts.onclose() end
end

function ChatWindow:repaint()
  self.dlg:repaint()
end

function ChatWindow:setBusy(busy)
  self.busy = busy
  self.dlg:modify{ id = "send", text = busy and "Stop" or "Send" }
end

function ChatWindow:onSendOrStop()
  if self.busy then
    self.conn:send{ type = "cancel" }
    return
  end
  local text = (self.dlg.data.input or ""):match("^%s*(.-)%s*$")
  if text == "" then return end
  if self.conn.status ~= "connected" then
    self.model:addError("Not connected to the bridge.", "Start it with: cd bridge && npm start, then press Reconnect.")
    self:repaint()
    return
  end
  self.model:addUser(text)
  self.followTail = true
  self.dlg:modify{ id = "input", text = "" }
  self.conn:send{ type = "user_message", text = text }
  self:setBusy(true)
  self:repaint()
end

function ChatWindow:newChat()
  if self.busy then self.conn:send{ type = "cancel" } end
  self.conn:send{ type = "new_chat" }
  self.model:clear()
  self.scroll = 0
  self.followTail = true
  self:setBusy(false)
  self:repaint()
end

function ChatWindow:onStatus(status, detail)
  local text = STATUS_TEXT[status] or status
  self.dlg:modify{ id = "status", text = text }
  if status == "disconnected" and self.busy then
    self.model:addError("Lost connection to the bridge.", detail)
    self.model:endTurn()
    self:setBusy(false)
    self:repaint()
  end
end

function ChatWindow:onMessage(m)
  if m.type == "ready" then
    inspect.snapshotDir = m.snapshotDir
    self.agentLabel = (m.adapter == "claude-code") and "Claude" or tostring(m.adapter)
  elseif m.type == "text_delta" then
    self.model:appendAgent(m.text)
  elseif m.type == "tool_activity" then
    self.model:addActivity(m.summary)
  elseif m.type == "tool_call" then
    local res = tools.dispatch(m.name, m.args)
    self.conn:send{ type = "tool_result", callId = m.callId, ok = res.ok, data = res.data, error = res.error }
  elseif m.type == "turn_done" then
    self.model:endTurn()
    self:setBusy(false)
  elseif m.type == "error" then
    self.model:addError(m.message, m.hint)
  end
  self:repaint()
end

function ChatWindow:scrollBy(dy)
  self.scroll = render.clampScroll(self.scroll + dy, self.contentH, self.viewH)
  self.followTail = self.scroll >= self.contentH - self.viewH - 2
  self:repaint()
end

function ChatWindow:paint(gc)
  self.lineH = gc:measureText("Ag").height + 3
  local lay = render.layout(self.model.items, {
    width = gc.width - 2 * PAD - 6,
    measure = function(s) return gc:measureText(s).width end,
    lineHeight = self.lineH,
    gap = GAP,
    agentLabel = self.agentLabel,
  })
  self.viewH = gc.height
  self.contentH = lay.height + 2 * PAD
  if self.followTail then self.scroll = self.contentH - self.viewH end
  self.scroll = render.clampScroll(self.scroll, self.contentH, self.viewH)

  gc.color = themeColor("window_face", Color{ r = 40, g = 40, b = 48 })
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))

  local textColor = themeColor("text", Color{ r = 230, g = 230, b = 230 })
  for _, line in ipairs(lay.lines) do
    local y = PAD + line.y - self.scroll
    if y > -self.lineH and y < gc.height then
      gc.color = COLORS[line.kind] or textColor
      gc:fillText(line.text, PAD, y)
    end
  end

  if self.contentH > self.viewH then
    local barH = math.max(20, self.viewH * self.viewH / self.contentH)
    local barY = (self.viewH - barH) * self.scroll / (self.contentH - self.viewH)
    gc.color = Color{ r = 128, g = 128, b = 128, a = 140 }
    gc:fillRect(Rectangle(gc.width - 5, barY, 4, barH))
  end
end

return ChatWindow
```

- [ ] **Step 4: Dev install script**

`scripts/dev-install.sh` (then `chmod +x scripts/dev-install.sh`):
```bash
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
```

- [ ] **Step 5: README development section**

Append to `README.md`:
````markdown
## Development

Requirements: Aseprite ≥ 1.3.18, Node ≥ 20, Claude Code installed and logged in (`claude`).

```bash
cd bridge && npm install && npm run build
npm start                    # bridge on 127.0.0.1:47821, writes ~/.aseprite-agent/bridge.json
scripts/dev-install.sh       # link the extension into Aseprite, then restart Aseprite
```

In Aseprite, choose **Edit → Agent Chat**.

Tests:

```bash
cd bridge && npm test        # bridge (Vitest)
scripts/test-lua.sh          # Lua tools and chat layout, headless Aseprite (set ASEPRITE=... if not auto-found)
cd bridge && npm run smoke -- "hello"   # real Claude round-trip with a fake extension
```
````

- [ ] **Step 6: Install, run, and walk the manual checklist**

```bash
cd bridge && npm run build && (node dist/main.js > /tmp/aseprite-agent-bridge.log 2>&1 &)   # log PID in ~/.claude/claude-running.md
scripts/dev-install.sh
```
Restart Aseprite and open or create a small sprite, then check each item:
1. **Edit → Agent Chat** exists and opens a resizable window; the status reads "Connected". (If the menu item is missing, use the fallback install printed by `dev-install.sh`, and note which method worked in the README.)
2. Type "What do you see?" and press Send. The button becomes Stop, and the history shows "You", then activity lines ("Inspected ...", "Looked at ..."), then Claude's streamed reply. The button returns to Send.
3. Ask "What exact colors are in the top-left 4x4?" Claude calls get_pixels and quotes hex values that match the sprite.
4. Open a second sprite and ask about "the other sprite" by file name. Claude uses `sprite: "<name>"` and answers about it.
5. Send a long message with a URL and no spaces, plus some accented text. It wraps inside the window with no horizontal overflow. The mouse wheel scrolls, and scrolling up stops auto-follow during streaming.
6. Press Stop mid-reply. The turn ends and the button returns to Send.
7. Ask "draw me a knight". Claude pushes back and offers alternatives, and says it has no drawing tools.
8. Kill the bridge (`kill <pid>`) while idle. The status turns to "Bridge not running". Restart the bridge and press Reconnect (or wait for auto-reconnect). The status returns to "Connected" and chatting works again, which proves the new token is re-read.
9. Close and reopen the window. It comes back at the same position and size.
10. Press New chat. The history clears, and Claude no longer remembers the previous conversation.

Fix anything that fails before committing. Known points to verify during this step: whether Enter in the input field triggers Send (the `focus = true` button), and which `app.theme.color` keys exist (fallback colors are used otherwise). Stop the bridge afterwards and remove the running-record line.

- [ ] **Step 7: Commit**

```bash
git add extension/package.json extension/plugin.lua extension/agent/connection.lua extension/agent/chat_window.lua scripts/dev-install.sh README.md
git commit -m "feat(extension): chat window, bridge connection and Aseprite command"
```

---

## Self-Review Notes

- **Spec coverage in Plan 1:** §2 architecture and layout; §5 read tools, except `analyze_colors`, `list_clips` and `list_project_sprites`, which are deferred to the plans that own analysis, clips and projects (`analyze_colors` goes to Plan 2 with the palette tools); §7 protocol subset plus token security; §10 adapter (with the documented delta); §11 window basics (floating, resizable, remembered bounds, status, New chat, streaming, scroll); §12 rows for bridge down, disconnect mid-turn, tool errors, timeout, CLI missing or not logged in, Stop, bad token; §13 test layers. Everything else is assigned to Plans 2–5 in the header.
- **Deferred UI from spec §11:** History ▾, the Chat/Clips tabs, Attach and Clip buttons, the Auto-approve toggle, and Start bridge. Each belongs to the plan that owns its feature.
