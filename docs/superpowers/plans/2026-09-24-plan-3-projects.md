# Aseprite Agent Chat — Plan 3: Projects

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chats belong to a project folder. A project is a folder containing `.artproject/`, which holds the brief, memory, chats and settings. Claude sees the project's brief and memory, knows exactly which sprite you're on, can read any sprite in the project (opening it in the background if needed), can open unopened sprites to edit them, and can propose memory notes. A History list reopens older chats.

**Architecture:**
- **Extension:** discovers the project root by walking up from the active sprite's folder, and follows tab changes (`sitechange`). It tells the bridge the current project (`hello`, `open_project`) and attaches a context stamp to every message.
- **Bridge:** keeps one `ConversationStore` per project (`<root>/.artproject/chats`), with the existing global store as the no-project fallback. It rebuilds the system prompt each turn from the base prompt plus `brief.md` and `memory.md`, and runs `propose_memory` itself (with approval), writing to `memory.md`.
- **Lua tool registry:** transparently opens unopened project sprites. For reads they open in the background and are closed afterwards; for edits they open as a tab and stay open.

**Tech Stack:** Same as Plans 1–2 (Aseprite 1.3.18 Lua; Node 24/TypeScript 7; zod 4; Agent SDK 0.3.x; Vitest; headless Aseprite tests).

**Spec:** `docs/superpowers/specs/2026-09-24-aseprite-agent-chat-design.md` §3 (Projects), §4 (Conversations and history), §11 (window). Plans 1–2 are merged on `main`.

## Global Constraints

- **Everything from Plans 1–2 still applies:**
  - 127.0.0.1 only; `agent.*` Lua modules; `error(msg, 0)`.
  - No emoji in drawn text, and text passes through `displayText`.
  - 1-based frames; the clone→assign undo rule; json userdata with float numbers.
  - Record the bridge in `~/.claude/claude-running.md`, and run `scripts/dev-install.sh` after extension changes.
- **Project marker:** a directory named exactly `.artproject` inside the root. Files:
  - `project.json`: `{"version":1,"exports":{"location":"alongside"},"clips":{"max":20}}` (read by Plan 4);
  - `brief.md` and `memory.md`;
  - `chats/<id>.json`.
- **The bridge only writes inside a project root if `<root>/.artproject` already exists as a directory** and `root` is absolute. The extension creates the marker, and only when the artist presses **Make project**.
- **Project-relative sprite paths** use `/` separators, e.g. `characters/knight.aseprite`. With a project open, `sprites.name()` returns the relative path (it falls back to the file name for files outside the project).
- **Size limits:** `brief.md` and `memory.md` are each capped at 8000 characters when read into the prompt, with `[...truncated]` appended.
- **The context stamp** replaces Plan 2's bare `[AI drafts: on|off]` line with `[active: <sprite> - frame F/N - layer "L" - selection WxH at (X,Y) | open: a, b | AI drafts: on|off]`. Slash commands still go through untouched.
- **Switching projects never interrupts a running turn:** an `open_project` that arrives while Claude is busy is applied right after that turn's `turn_done`.
- **Plugin preferences** store the conversation map as a JSON string (`prefs.conversationsJson`, keyed by project root, with `"~"` for no project), so we don't rely on `plugin.preferences` serializing nested tables. The old `prefs.conversationId` migrates to key `"~"`.

## Review Focus

1. **Switching tabs between sprites in different projects while Claude is replying.** The reply finishes in its own conversation, and then the window switches to the other project's chat. No reply text leaks into the other project's history. Covered by the deferred-switch test in Task 2.
2. **Unsaved sprites and sprites outside any project.** An unsaved sprite keeps the current project. A saved sprite outside any project switches to "No project" and the global chats. Neither crashes the context stamp or `sprites.name`. Covered in Tasks 4 and 6.
3. **Reading an unopened project sprite.** It opens in the background and is closed afterwards, the artist's active tab is restored, and nothing is left open even if the tool errors. Covered in Task 5.
4. **Projects that are hard to read:** missing or empty `brief.md`/`memory.md`, a huge brief, a `.artproject` folder that was deleted while open, or a `projectRoot` from the extension that isn't a real project. Each falls back gracefully: no crash, no writes outside a real project. Covered in Tasks 1–2.
5. **Folder names with spaces or accents, and a project root that is a filesystem root.** Relative paths and `findRoot` terminate and stay correct. Covered in Task 4.

---

## File Structure

```
bridge/src/
  project.ts         NEW  isProjectRoot, projectName, readProjectNotes, appendMemory, buildSystemPrompt
  stores.ts          NEW  StoreRegistry: one ConversationStore per project (+ global)
  stamp.ts           NEW  MessageContext + formatStamp
  conversations.ts   + ConversationStore.list()
  protocol.ts        + hello.projectRoot, user_message.context/attach, open_project, list_history,
                       open_conversation; ready/conversation.projectRoot+projectName, history_list
  adapters/Adapter.ts + send(text, opts?: { systemPrompt?: string })
  adapters/claudeCode.ts  uses opts.systemPrompt
  tools/definitions.ts    + list_project_sprites (read), propose_memory (edit, runs in bridge)
  session.ts         project-aware conversations, per-turn prompt, stamp, local tools, "opens it as a tab" hint
  server.ts, main.ts `stores` replaces `store`
  prompt.ts          context-stamp wording
extension/agent/
  project.lua        NEW  findRoot, relative, absolute, listSprites, create, briefMarkdown
  prefs.lua          NEW  per-project conversation ids in plugin preferences
  context.lua        NEW  builds the per-message context table
  tools/sprites.lua  + projectRoot, relative names, openIfNeeded
  tools/registry.lua + tool kinds; opens unopened project sprites around a call
  tools/analyze.lua  + list_project_sprites
  tools/init.lua     registers reads/edits separately
  connection.lua     hello fields from opts.helloFields()
  chat_window.lua    project header, Make project dialog, History dialog, sitechange, Attach view
tests/lua/test_project.lua, test_prefs_context.lua, test_open_sprites.lua   NEW
```

---

### Task 1: Project helpers, store registry, and context stamp (bridge)

**Files:**
- Create: `bridge/src/project.ts`, `bridge/src/stores.ts`, `bridge/src/stamp.ts`
- Modify: `bridge/src/conversations.ts` (add `list`)
- Test: `bridge/test/project.test.ts`, `bridge/test/stamp.test.ts`, `bridge/test/conversations.test.ts` (add)

**Interfaces:**
- Produces:
  - `PROJECT_DIR = ".artproject"`, `isProjectRoot(root: unknown): Promise<boolean>`, `projectName(root: string | null): string`, `interface ProjectNotes { brief: string; memory: string }`, `readProjectNotes(root): Promise<ProjectNotes>`, `appendMemory(root, note): Promise<void>`, `buildSystemPrompt(base, project?: { name: string; notes: ProjectNotes }): string`
  - `class StoreRegistry { constructor(globalDir: string); get(root: string | null): ConversationStore }`
  - `interface MessageContext { activeSprite?: string; frame?: number; frameCount?: number; layer?: string; selection?: { x: number; y: number; w: number; h: number }; openSprites?: string[] }`, `formatStamp(ctx: MessageContext | undefined, draftMode: boolean, attach: boolean): string`
  - `ConversationStore.list(): Promise<{ id: string; title: string; updatedAt: string }[]>` (newest first, skips unreadable files)

- [ ] **Step 1: Write the failing tests**

`bridge/test/project.test.ts`:
```ts
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { appendMemory, buildSystemPrompt, isProjectRoot, projectName, readProjectNotes } from "../src/project.js";

async function project(files: Record<string, string> = {}) {
  const root = await mkdtemp(join(tmpdir(), "proj "));
  await mkdir(join(root, ".artproject"));
  for (const [name, text] of Object.entries(files)) await writeFile(join(root, ".artproject", name), text);
  return root;
}

describe("project helpers", () => {
  it("recognises only absolute folders that contain .artproject", async () => {
    const root = await project();
    expect(await isProjectRoot(root)).toBe(true);
    expect(await isProjectRoot(join(root, "nope"))).toBe(false);
    expect(await isProjectRoot("relative/path")).toBe(false);
    expect(await isProjectRoot(null)).toBe(false);
    expect(await isProjectRoot(await mkdtemp(join(tmpdir(), "plain-")))).toBe(false);
  });

  it("names projects after their folder", () => {
    expect(projectName("/art/My Game")).toBe("My Game");
    expect(projectName(null)).toBe("No project");
  });

  it("reads brief and memory, tolerating missing files and capping size", async () => {
    const root = await project({ "brief.md": "32x32 characters\n", "memory.md": "x".repeat(9000) });
    const notes = await readProjectNotes(root);
    expect(notes.brief).toBe("32x32 characters");
    expect(notes.memory.length).toBeLessThan(8100);
    expect(notes.memory.endsWith("[...truncated]")).toBe(true);
    expect(await readProjectNotes(await project())).toEqual({ brief: "", memory: "" });
  });

  it("appends one tidy line per memory note", async () => {
    const root = await project({ "memory.md": "# Project memory\n" });
    await appendMemory(root, "  Hero uses a   2px outline\n");
    expect(await readFile(join(root, ".artproject", "memory.md"), "utf8")).toBe("# Project memory\n- Hero uses a 2px outline\n");
  });

  it("builds the system prompt from the base plus project notes", () => {
    const withNotes = buildSystemPrompt("BASE", { name: "Game", notes: { brief: "Light from top-left.", memory: "- 2px outline" } });
    expect(withNotes.startsWith("BASE")).toBe(true);
    expect(withNotes).toContain("Project: Game.");
    expect(withNotes).toContain("Light from top-left.");
    expect(withNotes).toContain("- 2px outline");
    expect(withNotes).toContain("propose_memory");
    expect(buildSystemPrompt("BASE", { name: "Game", notes: { brief: "", memory: "" } })).toContain("no brief yet");
    expect(buildSystemPrompt("BASE", undefined)).toContain("There is no project open");
  });
});
```

`bridge/test/stamp.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { formatStamp } from "../src/stamp.js";

describe("formatStamp", () => {
  it("describes the active sprite, open tabs and the drafts switch", () => {
    expect(
      formatStamp(
        { activeSprite: "characters/knight.aseprite", frame: 3, frameCount: 8, layer: "Body", selection: { x: 20, y: 14, w: 12, h: 8 }, openSprites: ["characters/knight.aseprite", "ref.png"] },
        false,
        false,
      ),
    ).toBe('[active: characters/knight.aseprite - frame 3/8 - layer "Body" - selection 12x8 at (20,14) | open: characters/knight.aseprite, ref.png | AI drafts: off]');
  });

  it("handles no sprite and adds the attach note", () => {
    expect(formatStamp(undefined, true, false)).toBe("[active: none | AI drafts: on]");
    expect(formatStamp({ activeSprite: "a.aseprite" }, false, true)).toBe(
      "[active: a.aseprite | AI drafts: off]\n[The artist attached the current view: look at it with get_snapshot before answering.]",
    );
  });
});
```

Add to `bridge/test/conversations.test.ts` (inside the `ConversationStore` describe):
```ts
  it("lists conversations newest first and skips unreadable files", async () => {
    const dir = await mkdtemp(join(tmpdir(), "chats-"));
    const store = new ConversationStore(dir);
    const a = store.create();
    a.title = "first";
    await store.save(a);
    await new Promise((r) => setTimeout(r, 5));
    const b = store.create();
    b.title = "second";
    await store.save(b);
    const { writeFile } = await import("node:fs/promises");
    await writeFile(join(dir, "junk.json"), "{nope");
    const list = await store.list();
    expect(list.map((c) => c.title)).toEqual(["second", "first"]);
    expect(list[0]).toEqual({ id: b.id, title: "second", updatedAt: expect.any(String) });
    expect(await new ConversationStore(join(dir, "missing")).list()).toEqual([]);
  });
```

`bridge/test/stores.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { StoreRegistry } from "../src/stores.js";

describe("StoreRegistry", () => {
  it("returns one shared store per project, and the global store for no project", () => {
    const r = new StoreRegistry("/home/.aseprite-agent/chats");
    expect(r.get("/art/game")).toBe(r.get("/art/game"));
    expect(r.get(null)).toBe(r.get(null));
    expect(r.get("/art/game")).not.toBe(r.get(null));
    expect((r.get("/art/game") as any).dir).toBe("/art/game/.artproject/chats");
    expect((r.get(null) as any).dir).toBe("/home/.aseprite-agent/chats");
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npx vitest run test/project.test.ts test/stamp.test.ts test/stores.test.ts test/conversations.test.ts`
Expected: FAIL. The modules are not found and `store.list` is not a function.

- [ ] **Step 3: Implement**

`bridge/src/project.ts`:
```ts
import { appendFile, readFile, stat } from "node:fs/promises";
import { basename, isAbsolute, join } from "node:path";

export const PROJECT_DIR = ".artproject";
const NOTE_LIMIT = 8000;

export async function isProjectRoot(root: unknown): Promise<boolean> {
  if (typeof root !== "string" || !isAbsolute(root)) return false;
  try {
    return (await stat(join(root, PROJECT_DIR))).isDirectory();
  } catch {
    return false;
  }
}

export function projectName(root: string | null): string {
  return root ? basename(root) : "No project";
}

export interface ProjectNotes {
  brief: string;
  memory: string;
}

async function readCapped(path: string): Promise<string> {
  try {
    const text = (await readFile(path, "utf8")).trim();
    return text.length > NOTE_LIMIT ? `${text.slice(0, NOTE_LIMIT)}\n[...truncated]` : text;
  } catch {
    return "";
  }
}

export async function readProjectNotes(root: string): Promise<ProjectNotes> {
  return {
    brief: await readCapped(join(root, PROJECT_DIR, "brief.md")),
    memory: await readCapped(join(root, PROJECT_DIR, "memory.md")),
  };
}

export async function appendMemory(root: string, note: string): Promise<void> {
  await appendFile(join(root, PROJECT_DIR, "memory.md"), `- ${note.replace(/\s+/g, " ").trim()}\n`);
}

export function buildSystemPrompt(base: string, project?: { name: string; notes: ProjectNotes }): string {
  if (!project) {
    return `${base}\n\nThere is no project open. The artist can create one with "Make project" in the chat window; projects keep a brief, shared memory and chat history.`;
  }
  const parts = [base, `Project: ${project.name}. Sprite paths in messages and tools are relative to the project folder.`];
  parts.push(project.notes.brief ? `Project brief (written by the artist; follow it):\n${project.notes.brief}` : "The project has no brief yet.");
  if (project.notes.memory) parts.push(`Project memory (notes the artist approved earlier):\n${project.notes.memory}`);
  parts.push("When you and the artist settle a lasting decision (a style rule, palette choice, proportions), offer to save it with propose_memory.");
  return parts.join("\n\n");
}
```

`bridge/src/stores.ts`:
```ts
import { join } from "node:path";
import { ConversationStore } from "./conversations.js";
import { PROJECT_DIR } from "./project.js";

/** One ConversationStore per chats folder, shared by all sessions so saves stay serialised. */
export class StoreRegistry {
  private stores = new Map<string, ConversationStore>();

  constructor(private globalDir: string) {}

  get(root: string | null): ConversationStore {
    const dir = root ? join(root, PROJECT_DIR, "chats") : this.globalDir;
    let store = this.stores.get(dir);
    if (!store) {
      store = new ConversationStore(dir);
      this.stores.set(dir, store);
    }
    return store;
  }
}
```
In `conversations.ts`, make the constructor parameter readable (`constructor(readonly dir: string) {}`) and add inside `ConversationStore`:
```ts
  async list(): Promise<{ id: string; title: string; updatedAt: string }[]> {
    let names: string[];
    try {
      names = (await readdir(this.dir)).filter((n) => n.endsWith(".json"));
    } catch {
      return [];
    }
    const out: { id: string; title: string; updatedAt: string }[] = [];
    for (const name of names) {
      const c = await this.load(name.slice(0, -5));
      if (c) out.push({ id: c.id, title: c.title, updatedAt: c.updatedAt });
    }
    return out.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }
```
(add `readdir` to the `node:fs/promises` import).

`bridge/src/stamp.ts`:
```ts
export interface MessageContext {
  activeSprite?: string;
  frame?: number;
  frameCount?: number;
  layer?: string;
  selection?: { x: number; y: number; w: number; h: number };
  openSprites?: string[];
}

/** The note in front of every artist message so Claude knows where they are. */
export function formatStamp(ctx: MessageContext | undefined, draftMode: boolean, attach: boolean): string {
  const parts: string[] = [];
  if (ctx?.activeSprite) {
    let a = `active: ${ctx.activeSprite}`;
    if (ctx.frame) a += ` - frame ${ctx.frame}${ctx.frameCount ? `/${ctx.frameCount}` : ""}`;
    if (ctx.layer) a += ` - layer "${ctx.layer}"`;
    if (ctx.selection) a += ` - selection ${ctx.selection.w}x${ctx.selection.h} at (${ctx.selection.x},${ctx.selection.y})`;
    parts.push(a);
  } else {
    parts.push("active: none");
  }
  if (ctx?.openSprites?.length) parts.push(`open: ${ctx.openSprites.join(", ")}`);
  parts.push(`AI drafts: ${draftMode ? "on" : "off"}`);
  let stamp = `[${parts.join(" | ")}]`;
  if (attach) stamp += "\n[The artist attached the current view: look at it with get_snapshot before answering.]";
  return stamp;
}
```

- [ ] **Step 4: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all pass. tsc is clean.

- [ ] **Step 5: Commit**

```bash
git add bridge/src/project.ts bridge/src/stores.ts bridge/src/stamp.ts bridge/src/conversations.ts bridge/test
git commit -m "feat(bridge): project helpers, per-project conversation stores, context stamp"
```

---

### Task 2: Project-aware sessions (bridge)

**Files:**
- Modify: `bridge/src/protocol.ts`, `bridge/src/adapters/Adapter.ts`, `bridge/src/adapters/claudeCode.ts`, `bridge/src/session.ts`, `bridge/src/server.ts`, `bridge/src/main.ts`, `bridge/src/prompt.ts`
- Test: `bridge/test/projects.test.ts` (new); update `bridge/test/persistence.test.ts` (`store` → `stores`), `bridge/test/approval.test.ts` (stamp format), `bridge/test/prompt.test.ts`, `bridge/test/claudeCode.test.ts`

**Interfaces:**
- Consumes: Task 1 exports.
- Produces (protocol):
  - **Extension → bridge:**
    - `hello{…, projectRoot?: string | null, conversationId?}`
    - `user_message{text, context?: MessageContext, attach?: boolean}`
    - `open_project{projectRoot: string | null, conversationId?}`
    - `list_history`
    - `open_conversation{conversationId}`
  - **Bridge → extension:**
    - `ready{…, projectRoot: string | null, projectName, conversationId, history}`
    - `conversation{conversationId, projectRoot, projectName, history}`
    - `history_list{items: {id, title, updatedAt}[]}`
- `ServerOptions.stores?: StoreRegistry` replaces `store`. `Adapter.send(text, opts?: { systemPrompt?: string })`.

- [ ] **Step 1: Write the failing tests**

`bridge/test/projects.test.ts`:
```ts
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { Adapter, AdapterEvent } from "../src/adapters/Adapter.js";
import { startServer, type BridgeServer } from "../src/server.js";
import { StoreRegistry } from "../src/stores.js";
import { connectClient } from "./helpers.js";

let server: BridgeServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

async function makeProject(brief = "") {
  const root = await mkdtemp(join(tmpdir(), "game "));
  await mkdir(join(root, ".artproject"));
  if (brief) await writeFile(join(root, ".artproject", "brief.md"), brief);
  await writeFile(join(root, ".artproject", "memory.md"), "# Project memory\n");
  return root;
}

interface Turn { text: string; systemPrompt?: string }

async function setup(opts: { hold?: Promise<void>; toolCalls?: (tools: any) => Promise<void> } = {}) {
  const turns: Turn[] = [];
  const stores = new StoreRegistry(await mkdtemp(join(tmpdir(), "global-")));
  server = await startServer({
    port: 0,
    token: "t",
    systemPrompt: "BASE",
    snapshotDir: "/s",
    stores,
    adapterFactory: (ctx) => {
      const adapter: Adapter = {
        name: "fake",
        async *send(text: string, o?: { systemPrompt?: string }): AsyncIterable<AdapterEvent> {
          turns.push({ text, systemPrompt: o?.systemPrompt });
          if (opts.toolCalls) await opts.toolCalls(ctx.tools);
          if (opts.hold) await opts.hold;
          yield { type: "text_delta", text: `reply to ${text.split("\n").pop()}` };
        },
        cancel() {},
        resumeState: () => undefined,
      };
      return adapter;
    },
  });
  return { turns, stores };
}

async function hello(extra: object = {}) {
  const c = await connectClient(server!.port);
  c.ws.on("message", (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.type === "tool_call") c.send({ type: "tool_result", callId: m.callId, ok: true, data: {} });
  });
  c.send({ type: "hello", token: "t", extensionVersion: "t", ...extra });
  const ready = (await c.waitFor((m) => m.type === "ready")) as any;
  return { c, ready };
}

async function turn(c: Awaited<ReturnType<typeof hello>>["c"], msg: object) {
  const before = c.received.length;
  c.send({ type: "user_message", ...msg });
  await c.waitFor((m) => m.type === "turn_done" && c.received.indexOf(m) >= before);
  return c.received.slice(before);
}

describe("projects", () => {
  it("keeps a project's chats inside the project and names it in ready", async () => {
    await setup();
    const root = await makeProject();
    const { c, ready } = await hello({ projectRoot: root });
    expect(ready).toMatchObject({ projectRoot: root, projectName: root.split("/").pop() });
    await turn(c, { text: "hi" });
    expect(await readdir(join(root, ".artproject", "chats"))).toEqual([`${ready.conversationId}.json`]);
  });

  it("treats a folder that is not a project as no project (and writes nothing there)", async () => {
    await setup();
    const plain = await mkdtemp(join(tmpdir(), "plain-"));
    const { c, ready } = await hello({ projectRoot: plain });
    expect(ready.projectRoot).toBeNull();
    await turn(c, { text: "hi" });
    expect(await readdir(plain)).toEqual([]);
  });

  it("sends the brief and memory in the system prompt of every turn, re-read each time", async () => {
    const { turns } = await setup();
    const root = await makeProject("Light comes from the top-left.");
    const { c } = await hello({ projectRoot: root });
    await turn(c, { text: "one" });
    expect(turns[0].systemPrompt).toContain("BASE");
    expect(turns[0].systemPrompt).toContain("Light comes from the top-left.");
    await writeFile(join(root, ".artproject", "brief.md"), "Light comes from the right.");
    await turn(c, { text: "two" });
    expect(turns[1].systemPrompt).toContain("Light comes from the right.");
  });

  it("stamps each message with the artist's context", async () => {
    const { turns } = await setup();
    const { c } = await hello();
    await turn(c, { text: "look", context: { activeSprite: "hero.aseprite", frame: 2, frameCount: 4, openSprites: ["hero.aseprite"] }, attach: true });
    expect(turns[0].text).toBe(
      "[active: hero.aseprite - frame 2/4 | open: hero.aseprite | AI drafts: off]\n[The artist attached the current view: look at it with get_snapshot before answering.]\nlook",
    );
  });

  it("open_project switches to that project's chat and reports it", async () => {
    await setup();
    const a = await makeProject();
    const b = await makeProject();
    const { c } = await hello({ projectRoot: a });
    await turn(c, { text: "in a" });
    c.send({ type: "open_project", projectRoot: b });
    const conv = (await c.waitFor((m) => m.type === "conversation")) as any;
    expect(conv).toMatchObject({ projectRoot: b, history: [] });
    await turn(c, { text: "in b" });
    expect((await readdir(join(b, ".artproject", "chats"))).length).toBe(1);
    expect((await readdir(join(a, ".artproject", "chats"))).length).toBe(1);
  });

  it("a project switch during a reply waits for the reply to finish", async () => {
    let release!: () => void;
    await setup({ hold: new Promise<void>((r) => (release = r)) });
    const a = await makeProject();
    const b = await makeProject();
    const { c, ready } = await hello({ projectRoot: a });
    c.send({ type: "user_message", text: "long" });
    await new Promise((r) => setTimeout(r, 20));
    c.send({ type: "open_project", projectRoot: b });
    await new Promise((r) => setTimeout(r, 20));
    expect(c.received.some((m) => m.type === "conversation")).toBe(false);
    release();
    const conv = (await c.waitFor((m) => m.type === "conversation")) as any;
    expect(conv.projectRoot).toBe(b);
    const saved = JSON.parse(await readFile(join(a, ".artproject", "chats", `${ready.conversationId}.json`), "utf8"));
    expect(saved.items.map((i: any) => i.kind)).toEqual(["user", "agent"]);
  });

  it("lists history for the current project and reopens an older chat", async () => {
    await setup();
    const root = await makeProject();
    const { c, ready } = await hello({ projectRoot: root });
    await turn(c, { text: "first chat" });
    c.send({ type: "new_chat" });
    await c.waitFor((m) => m.type === "conversation");
    await turn(c, { text: "second chat" });
    c.send({ type: "list_history" });
    const list = (await c.waitFor((m) => m.type === "history_list")) as any;
    expect(list.items.map((i: any) => i.title)).toEqual(["second chat", "first chat"]);
    const before = c.received.length;
    c.send({ type: "open_conversation", conversationId: ready.conversationId });
    const conv = (await c.waitFor((m) => m.type === "conversation" && c.received.indexOf(m) >= before)) as any;
    expect(conv.conversationId).toBe(ready.conversationId);
    expect(conv.history[0]).toEqual({ kind: "user", text: "first chat" });
  });

  it("propose_memory asks for approval and appends to memory.md", async () => {
    const root = await makeProject();
    await setup({
      toolCalls: async (tools) => {
        await tools.call("propose_memory", { note: "Hero uses a 2px outline" });
      },
    });
    const { c } = await hello({ projectRoot: root });
    c.send({ type: "user_message", text: "remember that" });
    const req = (await c.waitFor((m) => m.type === "approval_request")) as any;
    expect(req.summary).toBe('Save to project memory: "Hero uses a 2px outline"');
    c.send({ type: "approval", approvalId: req.approvalId, approved: true });
    await c.waitFor((m) => m.type === "turn_done");
    expect(await readFile(join(root, ".artproject", "memory.md"), "utf8")).toContain("- Hero uses a 2px outline");
    expect(c.received.some((m) => m.type === "tool_call")).toBe(false);
  });

  it("propose_memory without a project explains how to make one", async () => {
    let result: any;
    await setup({
      toolCalls: async (tools) => {
        result = await tools.call("propose_memory", { note: "x" });
      },
    });
    const { c } = await hello();
    c.send({ type: "set_auto_approve", enabled: true });
    await turn(c, { text: "remember" });
    expect(result).toMatchObject({ ok: false, error: expect.stringContaining("Make project") });
  });

  it("edit cards say when the sprite will be opened as a tab", async () => {
    await setup({
      toolCalls: async (tools) => {
        await tools.call("layer_ops", { sprite: "chars/knight.aseprite", action: "add", name: "A" });
      },
    });
    const { c } = await hello();
    c.send({ type: "user_message", text: "add a layer", context: { activeSprite: "hero.aseprite", openSprites: ["hero.aseprite"] } });
    const req = (await c.waitFor((m) => m.type === "approval_request")) as any;
    expect(req.summary).toBe('Add layer "A" to chars/knight.aseprite (opens it as a tab)');
    c.send({ type: "approval", approvalId: req.approvalId, approved: false });
    await c.waitFor((m) => m.type === "turn_done");
  });
});
```

Update the existing tests:
- `persistence.test.ts`: in every `startServer({... store, ...})` call, replace `store` with `stores: new StoreRegistry(dir)`, where `dir` is the directory previously given to `new ConversationStore(...)`. Keep `store` as `registry.get(null)` wherever the test calls `store.load(...)`. Add `import { StoreRegistry } from "../src/stores.js";`.
- `approval.test.ts`, test "every message tells Claude whether AI drafts are on": expect `["[active: none | AI drafts: off]\nhello", "[active: none | AI drafts: on]\nagain"]`.
- `prompt.test.ts`: replace the phrase `"[AI drafts: on]"` with `"AI drafts: on"`.
- `claudeCode.test.ts`: add
```ts
  it("uses the per-turn system prompt when given", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: fakeQuery([], calls) });
    await collect(a.send("hi", { systemPrompt: "PROJECT SP" }));
    await collect(a.send("again"));
    expect(calls[0].options.systemPrompt).toBe("PROJECT SP");
    expect(calls[1].options.systemPrompt).toBe("SP");
  });
```
(inside the `ClaudeCodeAdapter` describe).

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npx vitest run`
Expected: FAIL. The projects tests fail (no project handling), and the updated tests fail on the stamp and on `stores`.

- [ ] **Step 3: Implement the protocol, adapter and prompt changes**

In `protocol.ts`:
```ts
import { z } from "zod";
import type { HistoryItem } from "./conversations.js";

const Rect = z.object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() });
const Context = z.object({
  activeSprite: z.string().optional(),
  frame: z.number().optional(),
  frameCount: z.number().optional(),
  layer: z.string().optional(),
  selection: Rect.optional(),
  openSprites: z.array(z.string()).optional(),
});
```
- `Hello` gets `projectRoot: z.string().nullable().optional()`.
- `UserMessage` becomes `z.object({ type: z.literal("user_message"), text: z.string().min(1), context: Context.optional(), attach: z.boolean().optional() })`.
- Add these to the union:
```ts
const OpenProject = z.object({ type: z.literal("open_project"), projectRoot: z.string().nullable().optional(), conversationId: z.string().optional() });
const ListHistory = z.object({ type: z.literal("list_history") });
const OpenConversation = z.object({ type: z.literal("open_conversation"), conversationId: z.string() });
```
- `BridgeMessage` changes:
```ts
  | { type: "ready"; adapter: string; protocolVersion: number; snapshotDir: string; projectRoot: string | null; projectName: string; conversationId: string; history: HistoryItem[] }
  | { type: "conversation"; conversationId: string; projectRoot: string | null; projectName: string; history: HistoryItem[] }
  | { type: "history_list"; items: { id: string; title: string; updatedAt: string }[] }
```

In `Adapter.ts`: `send(text: string, opts?: { systemPrompt?: string }): AsyncIterable<AdapterEvent>;`

In `claudeCode.ts`:
- Change `send(text)` to `send(text, opts?: { systemPrompt?: string })`, and pass `opts` through to both `attempt(...)` calls.
- Change `attempt(text)` to `attempt(text, opts?)`, using `systemPrompt: opts?.systemPrompt ?? this.ctx.systemPrompt`.

In `prompt.ts`, replace the sentence that begins `Each message from the artist starts with a note like` with:
```
Each message from the artist starts with a context note like "[active: characters/knight.aseprite - frame 2/4 - layer "Body" | open: characters/knight.aseprite, ref.png | AI drafts: off]": the sprite, frame and layer they are looking at, the open tabs, and the "Allow AI drafts" switch.
```

- [ ] **Step 4: Implement the session changes**

In `session.ts`:
- Replace the `store` dependency with `stores?: StoreRegistry`.
- Add these fields:
```ts
  private projectRoot: string | null = null;
  private pendingProject?: { root: string | null; conversationId?: string };
  private lastContext?: MessageContext;
```
- Add these helpers:
```ts
  private store(): ConversationStore | undefined {
    return this.deps.stores?.get(this.projectRoot);
  }

  private async validRoot(root: unknown): Promise<string | null> {
    return (await isProjectRoot(root)) ? (root as string) : null;
  }

  /** Opens a project's conversation (the given one if it exists there, else a new one). */
  private async openProject(root: string | null, conversationId?: string): Promise<void> {
    this.projectRoot = root;
    const saved = conversationId ? await this.store()?.load(conversationId) : undefined;
    this.useConversation(saved ?? this.newConversation());
  }

  private conversationMessage(): BridgeMessage {
    return {
      type: "conversation",
      conversationId: this.conv.id,
      projectRoot: this.projectRoot,
      projectName: projectName(this.projectRoot),
      history: this.conv.items,
    };
  }

  private async systemPromptNow(): Promise<string> {
    if (!this.projectRoot || !(await isProjectRoot(this.projectRoot))) return buildSystemPrompt(this.deps.systemPrompt, undefined);
    return buildSystemPrompt(this.deps.systemPrompt, { name: projectName(this.projectRoot), notes: await readProjectNotes(this.projectRoot) });
  }
```
- `newConversation()` uses `(this.store() ?? new ConversationStore("")).create()`.
- `persist(conv, adapter)` gains a third parameter `store: ConversationStore | undefined` and saves to it (not `this.deps.store`). Capture `const store = this.store();` at the start of `runTurn` and pass it to both `persist` calls, so a turn always saves into the project it started in.
- On `hello`, after authentication:
```ts
      await this.openProject(await this.validRoot(parsed.message.projectRoot), parsed.message.conversationId);
      this.deps.send({
        type: "ready",
        adapter: this.adapter!.name,
        protocolVersion: PROTOCOL_VERSION,
        snapshotDir: this.deps.snapshotDir,
        projectRoot: this.projectRoot,
        projectName: projectName(this.projectRoot),
        conversationId: this.conv.id,
        history: this.conv.items,
      });
```
(this replaces the previous load/`useConversation`/`ready` block).
- `startNewChat()` sends `this.conversationMessage()` instead of the old `conversation` literal.
- Add these switch cases:
```ts
      case "open_project": {
        const root = await this.validRoot(msg.projectRoot);
        if (this.busy) {
          this.pendingProject = { root, conversationId: msg.conversationId };
          return;
        }
        await this.openProject(root, msg.conversationId);
        this.deps.send(this.conversationMessage());
        return;
      }
      case "list_history":
        this.deps.send({ type: "history_list", items: (await this.store()?.list()) ?? [] });
        return;
      case "open_conversation": {
        if (this.busy) {
          this.deps.send({ type: "error", message: "Finish or stop the current reply before opening another chat." });
          return;
        }
        const saved = await this.store()?.load(msg.conversationId);
        if (!saved) {
          this.deps.send({ type: "error", message: "That chat no longer exists." });
          return;
        }
        this.useConversation(saved);
        this.deps.send(this.conversationMessage());
        return;
      }
```
- `runTurn(text)` becomes `runTurn(text, context?: MessageContext, attach = false)`. The `user_message` case calls `this.runTurn(msg.text, msg.context, msg.attach)`. At the start of the turn, set `this.lastContext = context;`. Build the prompt as:
```ts
      const prompt = cmd ? cmd.raw : `${formatStamp(context, this.draftMode, attach)}\n${text}`;
      for await (const ev of adapter.send(prompt, { systemPrompt: await this.systemPromptNow() })) if (current()) this.emit(ev);
```
- After `turn_done` is sent in `runTurn`'s `finally`, apply any deferred switch:
```ts
      if (current() && this.pendingProject) {
        const next = this.pendingProject;
        this.pendingProject = undefined;
        await this.openProject(next.root, next.conversationId);
        this.deps.send(this.conversationMessage());
      }
```
- In `toolsFor`, add the "opens it as a tab" hint and support bridge-local tools. Replace the approval call and the forward section with:
```ts
          if (!this.autoApprove) {
            const approved = await this.askApproval(this.summaryFor(def, args), args.sprite);
            ...unchanged...
          }
        }
        this.emit({ type: "tool_activity", summary: def.activity(args) });
        if (def.runInBridge) return def.runInBridge(args, { projectRoot: this.projectRoot });
        const fwd = def.forward ? def.forward(args) : { name, args };
        return this.broker.call(fwd.name, fwd.args);
```
and add:
```ts
  private summaryFor(def: ToolDef, args: Record<string, unknown>): string {
    const summary = def.summarize!(args);
    const open = this.lastContext?.openSprites;
    const sprite = args.sprite;
    if (typeof sprite === "string" && open && !open.includes(sprite) && !open.some((o) => o.endsWith(`/${sprite}`))) {
      return `${summary} (opens it as a tab)`;
    }
    return summary;
  }
```
- Imports: `StoreRegistry` (type), `isProjectRoot`, `projectName`, `readProjectNotes`, `buildSystemPrompt` from `./project.js`, and `formatStamp`/`MessageContext` from `./stamp.js`.

`server.ts`: the `store?: ConversationStore` option becomes `stores?: StoreRegistry`, passed through as `stores`.
`main.ts`: pass `stores: new StoreRegistry(chatsDirFor(home))` instead of `store`.

- [ ] **Step 5: Add the bridge-local tools to the definitions**

In `definitions.ts`, add this to `ToolDef`:
```ts
  /** Tools the bridge runs itself (no extension round-trip). */
  runInBridge?(args: Record<string, unknown>, env: { projectRoot: string | null }): Promise<ToolResult>;
```
(import `type ToolResult` from `../toolTypes.js` and `appendMemory` from `../project.js`), and add these entries:
```ts
  {
    name: "list_project_sprites",
    kind: "read",
    description:
      "List every .aseprite/.ase file in the current project (paths relative to the project folder) and whether each is open. Any of them can be passed as `sprite` to other tools, even if it is not open: reads open it in the background, edits open it as a tab.",
    shape: {},
    activity: () => "Listed the project's sprites",
  },
  {
    name: "propose_memory",
    kind: "edit",
    description:
      "Save a lasting project decision to the project's memory.md (one short sentence, e.g. 'Hero uses a 2px dark outline, never black'). The artist approves it first. Only works inside a project.",
    shape: { note: z.string().min(3).max(300) },
    activity: () => "Saved a note to project memory",
    summarize: (a) => `Save to project memory: "${a.note}"`,
    runInBridge: async (a, env) => {
      if (!env.projectRoot) {
        return { ok: false, error: 'There is no project yet. The artist can create one with "Make project" in the chat window.' };
      }
      await appendMemory(env.projectRoot, String(a.note));
      return { ok: true, data: { saved: true } };
    },
  },
```
In `definitions.test.ts`, add `"list_project_sprites"` and `"propose_memory"` to the expected name list. (The Lua handler for `list_project_sprites` and its entry in the handler-coverage test come in Task 5.)

- [ ] **Step 6: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all pass. tsc is clean.

- [ ] **Step 7: Commit**

```bash
git add bridge/src bridge/test
git commit -m "feat(bridge): project-aware chats, brief/memory in the prompt, context stamp, propose_memory, history"
```

---

### Task 3: Lua project helpers

**Files:**
- Create: `extension/agent/project.lua`
- Test: `tests/lua/test_project.lua` (add it to the `run.lua` suite list)

**Interfaces:**
- Produces:
  - `project.DIR = ".artproject"`
  - `project.findRoot(path) -> root|nil` (`path` is a file or folder; walks up; stops at the filesystem root)
  - `project.relative(root, path) -> "a/b.aseprite"|nil`
  - `project.absolute(root, rel) -> path`
  - `project.listSprites(root) -> {rel...}` (sorted; skips dot folders)
  - `project.briefMarkdown(brief) -> string`
  - `project.create(root, brief) -> dir` (errors: `"Folder not found: <root>"`, `"This folder is already a project."`)
  - `project.ancestors(path, max) -> {dir...}` (the file's folder first, then its parents)

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_project.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local project = require("agent.project")

local base = app.fs.joinPath(F.tmp, "proj tests " .. os.time())
local game = app.fs.joinPath(base, "My Gäme")
app.fs.makeAllDirectories(app.fs.joinPath(game, "chars", "enemies"))
app.fs.makeAllDirectories(app.fs.joinPath(game, ".hidden"))

local function touch(path)
  local f = io.open(path, "w"); f:write("x"); f:close()
end
touch(app.fs.joinPath(game, "chars", "hero.aseprite"))
touch(app.fs.joinPath(game, "chars", "enemies", "slime.ase"))
touch(app.fs.joinPath(game, "chars", "notes.txt"))
touch(app.fs.joinPath(game, ".hidden", "secret.aseprite"))

T.test("create writes the project files and refuses to run twice", function()
  local dir = project.create(game, { resolution = "32x32", palette = "", outline = "1px dark", light = "top-left", notes = "Cozy village" })
  T.eq(app.fs.isDirectory(app.fs.joinPath(dir, "chats")), true)
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "project.json")), true)
  local f = io.open(app.fs.joinPath(dir, "brief.md")); local brief = f:read("a"); f:close()
  T.eq(brief:find("Sprite size: 32x32", 1, true) ~= nil, true, brief)
  T.eq(brief:find("Palette: (not set)", 1, true) ~= nil, true, brief)
  T.eq(brief:find("Cozy village", 1, true) ~= nil, true, brief)
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "memory.md")), true)
  T.errors(function() project.create(game, {}) end, "This folder is already a project.")
  T.errors(function() project.create(app.fs.joinPath(base, "nope"), {}) end, "Folder not found")
end)

T.test("findRoot walks up from a file or folder, and returns nil outside projects", function()
  T.eq(project.findRoot(app.fs.joinPath(game, "chars", "enemies", "slime.ase")), game)
  T.eq(project.findRoot(app.fs.joinPath(game, "chars")), game)
  T.eq(project.findRoot(base), nil)
  T.eq(project.findRoot(""), nil)
  T.eq(project.findRoot(nil), nil)
  T.eq(project.findRoot("/"), nil, "terminates at the filesystem root")
end)

T.test("relative and absolute paths round-trip with / separators", function()
  local abs = app.fs.joinPath(game, "chars", "hero.aseprite")
  T.eq(project.relative(game, abs), "chars/hero.aseprite")
  T.eq(project.absolute(game, "chars/hero.aseprite"), abs)
  T.eq(project.relative(game, app.fs.joinPath(base, "other.aseprite")), nil)
  T.eq(project.relative(game .. "x", abs), nil, "a sibling folder with a shared prefix is not inside")
end)

T.test("listSprites finds sprites recursively and skips hidden folders", function()
  T.deepEq(project.listSprites(game), { "chars/enemies/slime.ase", "chars/hero.aseprite" })
end)

T.test("ancestors lists the file's folder first", function()
  local list = project.ancestors(app.fs.joinPath(game, "chars", "hero.aseprite"), 3)
  T.deepEq(list, { app.fs.joinPath(game, "chars"), game, base })
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh test_project`
Expected: `module 'agent.project' not found`.

- [ ] **Step 3: Implement**

`extension/agent/project.lua`:
```lua
local M = { DIR = ".artproject" }

local function trimSep(p)
  return (p:gsub("[/\\]+$", ""))
end

function M.findRoot(path)
  if type(path) ~= "string" or path == "" then return nil end
  local dir = app.fs.isDirectory(path) and path or app.fs.filePath(path)
  while dir and dir ~= "" do
    if app.fs.isDirectory(app.fs.joinPath(dir, M.DIR)) then return dir end
    local parent = app.fs.filePath(trimSep(dir))
    if parent == "" or parent == dir then break end
    dir = parent
  end
  return nil
end

function M.relative(root, path)
  if type(root) ~= "string" or type(path) ~= "string" then return nil end
  local prefix = trimSep(root) .. app.fs.pathSeparator
  if path:sub(1, #prefix) ~= prefix then return nil end
  return (path:sub(#prefix + 1):gsub("\\", "/"))
end

function M.absolute(root, rel)
  local parts = { root }
  for piece in tostring(rel):gmatch("[^/\\]+") do parts[#parts + 1] = piece end
  return app.fs.normalizePath(app.fs.joinPath(table.unpack(parts)))
end

function M.listSprites(root)
  local out = {}
  local function walk(dir, rel)
    for _, name in ipairs(app.fs.listFiles(dir)) do
      local full = app.fs.joinPath(dir, name)
      local r = rel == "" and name or (rel .. "/" .. name)
      if app.fs.isDirectory(full) then
        if name:sub(1, 1) ~= "." then walk(full, r) end
      else
        local ext = app.fs.fileExtension(name):lower()
        if ext == "aseprite" or ext == "ase" then out[#out + 1] = r end
      end
    end
  end
  walk(root, "")
  table.sort(out)
  return out
end

function M.ancestors(path, max)
  local out = {}
  local dir = app.fs.filePath(path)
  while dir ~= "" and #out < (max or 5) do
    out[#out + 1] = dir
    local parent = app.fs.filePath(trimSep(dir))
    if parent == dir then break end
    dir = parent
  end
  return out
end

local function field(v)
  v = v and tostring(v):match("^%s*(.-)%s*$") or ""
  return v ~= "" and v or "(not set)"
end

function M.briefMarkdown(b)
  b = b or {}
  return table.concat({
    "# Project brief",
    "",
    "- Sprite size: " .. field(b.resolution),
    "- Palette: " .. field(b.palette),
    "- Outline style: " .. field(b.outline),
    "- Light direction: " .. field(b.light),
    "",
    "## Notes",
    "",
    field(b.notes),
    "",
  }, "\n")
end

local CONFIG = '{\n  "version": 1,\n  "exports": { "location": "alongside" },\n  "clips": { "max": 20 }\n}\n'
local MEMORY = "# Project memory\n\nLasting decisions Claude proposed and you approved.\n\n"

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

function M.create(root, brief)
  if not app.fs.isDirectory(root) then error("Folder not found: " .. tostring(root), 0) end
  local dir = app.fs.joinPath(root, M.DIR)
  if app.fs.isDirectory(dir) then error("This folder is already a project.", 0) end
  app.fs.makeAllDirectories(app.fs.joinPath(dir, "chats"))
  write(app.fs.joinPath(dir, "project.json"), CONFIG)
  write(app.fs.joinPath(dir, "brief.md"), M.briefMarkdown(brief))
  write(app.fs.joinPath(dir, "memory.md"), MEMORY)
  return dir
end

return M
```
Add `"test_project"` to the suite list in `tests/lua/run.lua`.

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.

> If `app.fs.normalizePath` produces a different but equivalent form (e.g. resolving `/var` to `/private/var`), compare `project.absolute(...)` against `app.fs.normalizePath(abs)` in the test instead of `abs`.

- [ ] **Step 5: Commit**

```bash
git add extension/agent/project.lua tests/lua/test_project.lua tests/lua/run.lua
git commit -m "feat(extension): project discovery, relative paths, sprite listing and project creation"
```

---

### Task 4: Preferences map and message context (Lua)

**Files:**
- Create: `extension/agent/prefs.lua`, `extension/agent/context.lua`
- Test: `tests/lua/test_prefs_context.lua` (add it to the suite list)

**Interfaces:**
- Produces:
  - `prefs.GLOBAL = "~"`, `prefs.getConversation(p, root) -> id|nil`, `prefs.setConversation(p, root, id|nil)`. Stored in `p.conversationsJson`, and migrates `p.conversationId`.
  - `context.build(root) -> {activeSprite?, frame?, frameCount?, layer?, selection?, openSprites}` (names are project-relative when inside `root`).

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_prefs_context.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local prefs = require("agent.prefs")
local context = require("agent.context")

T.test("conversation ids are remembered per project, and the old single id migrates", function()
  local p = { conversationId = "old" }
  T.eq(prefs.getConversation(p, nil), "old")
  T.eq(p.conversationId, nil)
  prefs.setConversation(p, "/art/game", "g1")
  T.eq(prefs.getConversation(p, "/art/game"), "g1")
  T.eq(prefs.getConversation(p, nil), "old")
  prefs.setConversation(p, "/art/game", nil)
  T.eq(prefs.getConversation(p, "/art/game"), nil)
  T.eq(type(p.conversationsJson), "string")
  p.conversationsJson = "{broken"
  T.eq(prefs.getConversation(p, nil), nil, "corrupt preference is treated as empty")
end)

T.test("context describes the active sprite, frame, layer, selection and open tabs", function()
  F.closeAll()
  local s = F.rgbSprite("ctx.aseprite")
  s.selection = Selection(Rectangle(1, 0, 2, 2))
  local ctx = context.build(nil)
  T.eq(ctx.activeSprite, "ctx.aseprite")
  T.eq(ctx.frame, 1)
  T.eq(ctx.frameCount, 1)
  T.eq(ctx.layer, "Body")
  T.deepEq(ctx.selection, { x = 1, y = 0, w = 2, h = 2 })
  T.deepEq(ctx.openSprites, { "ctx.aseprite" })
  local rel = context.build(F.tmp)
  T.eq(rel.activeSprite, "ctx.aseprite", "project-relative inside the project root")
end)

T.test("context with no open sprite is just an empty tab list", function()
  F.closeAll()
  T.deepEq(context.build(nil), { openSprites = {} })
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh prefs_context`
Expected: `module 'agent.prefs' not found`.

- [ ] **Step 3: Implement**

`extension/agent/prefs.lua`:
```lua
local M = { GLOBAL = "~" }

local function load(p)
  local map = {}
  local ok, decoded = pcall(json.decode, p.conversationsJson or "{}")
  if ok and decoded then
    for k, v in pairs(decoded) do map[tostring(k)] = tostring(v) end
  end
  if p.conversationId then -- migrate the Plan 2 single id
    map[M.GLOBAL] = map[M.GLOBAL] or tostring(p.conversationId)
    p.conversationId = nil
    p.conversationsJson = json.encode(map)
  end
  return map
end

function M.getConversation(p, root)
  return load(p)[root or M.GLOBAL]
end

function M.setConversation(p, root, id)
  local map = load(p)
  map[root or M.GLOBAL] = id
  p.conversationsJson = json.encode(map)
end

return M
```
> Aseprite's `json.encode` of an empty Lua table may produce `[]`. `load` treats an empty `[]` like `{}`, because `pairs` over it yields nothing.

`extension/agent/context.lua`:
```lua
local project = require("agent.project")

local M = {}

local function nameOf(sprite, root)
  return project.relative(root, sprite.filename) or app.fs.fileName(sprite.filename)
end

function M.build(root)
  local ctx = { openSprites = {} }
  for _, s in ipairs(app.sprites) do ctx.openSprites[#ctx.openSprites + 1] = nameOf(s, root) end
  local s = app.sprite
  if not s then return ctx end
  ctx.activeSprite = nameOf(s, root)
  ctx.frameCount = #s.frames
  if app.frame then ctx.frame = app.frame.frameNumber end
  if app.layer then ctx.layer = app.layer.name end
  if not s.selection.isEmpty then
    local b = s.selection.bounds
    ctx.selection = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  return ctx
end

return M
```
Add `"test_prefs_context"` to the suite list.

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add extension/agent/prefs.lua extension/agent/context.lua tests/lua/test_prefs_context.lua tests/lua/run.lua
git commit -m "feat(extension): per-project conversation preferences and message context"
```

---

### Task 5: Project-aware sprite resolution and opening unopened sprites (Lua)

**Files:**
- Modify: `extension/agent/tools/sprites.lua`, `extension/agent/tools/registry.lua`, `extension/agent/tools/init.lua`, `extension/agent/tools/analyze.lua`
- Test: `tests/lua/test_open_sprites.lua` (add it to the suite list)

**Interfaces:**
- Consumes: `project.*` (Task 3).
- Produces:
  - `sprites.projectRoot` (set by the window), `sprites.name(s)` (relative inside the project), and `sprites.resolve(ref)`, which matches the full path, the file name or the relative path.
  - `sprites.openIfNeeded(ref, mode) -> handle|nil`, where `mode` is `"read"` or `"edit"`. A read handle has `:close()`; an edit handle has `.openedAsTab`.
  - `registry.register(handlers, kind)`, where `kind` is `"read"` or `"edit"`.
  - `registry.dispatch` opens unopened project sprites around the call. It adds `openedAsTab` to an edit's result data.
  - Handler `list_project_sprites{} -> {project, sprites[{path, open}]}`.

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_open_sprites.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")

local root = app.fs.joinPath(F.tmp, "open tests " .. os.time())
app.fs.makeAllDirectories(app.fs.joinPath(root, "chars"))
project.create(root, {})

local function saveSprite(rel, w)
  local s = Sprite(w, w)
  s:saveAs(project.absolute(root, rel))
  s:close()
end
saveSprite("chars/knight.aseprite", 8)
saveSprite("chars/slime.aseprite", 6)

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end

local function setup()
  F.closeAll()
  sprites.projectRoot = root
  local active = Sprite(2, 2)
  active:saveAs(app.fs.joinPath(root, "active.aseprite"))
  app.sprite = active
  return active
end

T.test("names are project-relative inside a project", function()
  local active = setup()
  T.eq(sprites.name(active), "active.aseprite")
  T.eq(call("get_sprite_info").data.sprite, "active.aseprite")
end)

T.test("reading an unopened project sprite opens it in the background and closes it again", function()
  local active = setup()
  local r = call("get_sprite_info", { sprite = "chars/knight.aseprite" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 8)
  T.eq(#app.sprites, 1, "closed again")
  T.eq(app.sprite == active, true, "the artist's tab is active again")
end)

T.test("a failing read still closes the background sprite", function()
  local active = setup()
  local r = call("get_pixels", { sprite = "chars/knight.aseprite", region = { x = 50, y = 50, w = 1, h = 1 } })
  T.eq(r.ok, false)
  T.eq(#app.sprites, 1)
  T.eq(app.sprite == active, true)
end)

T.test("editing an unopened project sprite opens it as a tab and keeps it open", function()
  local active = setup()
  local r = call("layer_ops", { sprite = "chars/slime.aseprite", action = "add", name = "Shade" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.openedAsTab, "chars/slime.aseprite")
  T.eq(#app.sprites, 2)
  T.eq(app.sprite == active, true, "the artist stays on their tab")
end)

T.test("unknown sprites still give the plain error", function()
  setup()
  T.eq(call("get_sprite_info", { sprite = "chars/ghost.aseprite" }).error:find("is not open", 1, true) ~= nil, true)
end)

T.test("list_project_sprites lists project files and which are open", function()
  setup()
  local r = call("list_project_sprites")
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.sprites, {
    { path = "active.aseprite", open = true },
    { path = "chars/knight.aseprite", open = false },
    { path = "chars/slime.aseprite", open = false },
  })
  sprites.projectRoot = nil
  T.eq(call("list_project_sprites").error, "No project is open. The artist can create one with Make project in the chat window.")
end)

sprites.projectRoot = nil
F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh open_sprites`
Expected: failures. Names are not relative, reads of unopened sprites error, and `list_project_sprites` is unknown.

- [ ] **Step 3: Implement sprites**

In `extension/agent/tools/sprites.lua`, add `local project = require("agent.project")` and `M.projectRoot = nil`, then replace `M.name` and `M.resolve`:
```lua
function M.name(sprite)
  return project.relative(M.projectRoot, sprite.filename) or app.fs.fileName(sprite.filename)
end

function M.resolve(ref)
  if ref == nil or ref == "" then
    local s = app.sprite
    if not s then error("No sprite is open in Aseprite.", 0) end
    return s
  end
  for _, s in ipairs(app.sprites) do
    if s.filename == ref or app.fs.fileName(s.filename) == ref or M.name(s) == ref then return s end
  end
  error("Sprite '" .. ref .. "' is not open. Open sprites: " .. M.openList(), 0)
end

-- An unopened project sprite named by `ref` is opened for the duration of a tool call:
-- in the background (and closed afterwards) for reads, as a tab (left open) for edits.
function M.openIfNeeded(ref, mode)
  if type(ref) ~= "string" or ref == "" or not M.projectRoot then return nil end
  if pcall(M.resolve, ref) then return nil end
  local abs = project.absolute(M.projectRoot, ref)
  if not app.fs.isFile(abs) or not project.relative(M.projectRoot, abs) then return nil end
  local prev = app.sprite
  if mode == "edit" then
    local opened = app.open(abs)
    if not opened then error("Couldn't open " .. ref .. ".", 0) end
    if prev then app.sprite = prev end
    return { openedAsTab = M.name(opened) }
  end
  local bg = Sprite{ fromFile = abs }
  if prev then app.sprite = prev end
  return {
    close = function()
      bg:close()
      if prev then pcall(function() app.sprite = prev end) end
    end,
  }
end
```

- [ ] **Step 4: Implement the registry and init**

Replace `extension/agent/tools/registry.lua` with:
```lua
local sprites = require("agent.tools.sprites")

local M = { handlers = {}, kinds = {} }

function M.register(handlers, kind)
  for name, fn in pairs(handlers) do
    M.handlers[name] = fn
    M.kinds[name] = kind or "read"
  end
end

local function cleanError(e)
  return (tostring(e):gsub("^[^\n]-:%d+: ", ""))
end

function M.dispatch(name, args)
  local fn = M.handlers[name]
  if not fn then return { ok = false, error = "Unknown tool: " .. tostring(name) } end
  args = args or {}
  local handle
  local ok, res = pcall(function()
    handle = sprites.openIfNeeded(args.sprite, M.kinds[name])
    return fn(args)
  end)
  if handle and handle.close then handle.close() end
  if not ok then return { ok = false, error = cleanError(res) } end
  if handle and handle.openedAsTab and type(res) == "table" then res.openedAsTab = handle.openedAsTab end
  return { ok = true, data = res }
end

return M
```

In `extension/agent/tools/init.lua`, split the single `registry.register{...}` into two calls. The first registers the read handlers (`get_sprite_info`, `get_snapshot`, `get_pixels`, `get_palette`, `analyze_colors`, `list_open_sprites`, `list_project_sprites = analyze.list_project_sprites`) with kind `"read"`. The second registers every other handler with kind `"edit"`.

In `extension/agent/tools/analyze.lua`, add `local project = require("agent.project")` and:
```lua
function M.list_project_sprites()
  local root = sprites.projectRoot
  if not root then error("No project is open. The artist can create one with Make project in the chat window.", 0) end
  local open = {}
  for _, s in ipairs(app.sprites) do open[sprites.name(s)] = true end
  local list = {}
  for _, rel in ipairs(project.listSprites(root)) do list[#list + 1] = { path = rel, open = open[rel] == true } end
  return { project = app.fs.fileName(root), sprites = list }
end
```
Also, in `list_open_sprites`, `name` already comes from `sprites.name`, so it is relative inside a project.

Add `"test_open_sprites"` to the suite list, and add `"list_project_sprites"` to the handler-coverage list in `tests/lua/test_analyze.lua`.

- [ ] **Step 5: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add extension/agent/tools tests/lua
git commit -m "feat(extension): project-relative sprites; tools open unopened project sprites (background for reads, tab for edits)"
```

---

### Task 6: The chat window becomes project-aware

**Files:**
- Modify: `extension/agent/connection.lua`, `extension/agent/chat_window.lua`, `extension/plugin.lua`
- Test: `tests/lua/test_chat_window.lua` (add cases), `tests/lua/test_connection.lua` (update the hello test)

**Interfaces:**
- Consumes: `prefs`, `context`, `project`, `sprites.projectRoot` (Tasks 3–5); protocol (Task 2).
- Produces:
  - `Connection.new{..., helloFields = function() return {projectRoot=..., conversationId=...} end}`. This replaces `conversationId`.
  - `ChatWindow:setProject(root)`, `ChatWindow:onSiteChange()`, `ChatWindow:showHistory(items)`, `ChatWindow:makeProject()`
  - A header row: the project label, plus **Make project** (visible without a project) and **History** buttons.
  - An **Attach view** checkbox, which resets after each send.

- [ ] **Step 1: Write the failing tests**

In `tests/lua/test_connection.lua`, replace the test `"hello carries the conversation to resume"` with:
```lua
T.test("hello carries the project and the conversation to resume", function()
  local sent = {}
  local c = Connection.new{
    onMessage = function() end,
    onStatus = function() end,
    helloFields = function() return { projectRoot = "/art/game", conversationId = "conv-1" } end,
  }
  c.token = "tok"
  c.send = function(_, msg) sent[#sent + 1] = msg end
  c:onReceive(WebSocketMessageType.OPEN, "", nil)
  T.eq(sent[1].type, "hello")
  T.eq(sent[1].projectRoot, "/art/game")
  T.eq(sent[1].conversationId, "conv-1")
end)
```

Add to `tests/lua/test_chat_window.lua` (the file already defines `stubbed`):
```lua
local F = require("fixtures")
local project = require("agent.project")
local sprites = require("agent.tools.sprites")
local prefs = require("agent.prefs")

local root = app.fs.joinPath(F.tmp, "window proj " .. os.time())
app.fs.makeAllDirectories(root)
project.create(root, {})

T.test("switching to a sprite in another project asks the bridge for that project's chat", function()
  F.closeAll()
  local p = {}
  prefs.setConversation(p, root, "proj-chat")
  local w = stubbed(p)
  w.conn.status = "connected"
  local s = Sprite(2, 2)
  s:saveAs(app.fs.joinPath(root, "a.aseprite"))
  app.sprite = s
  w:onSiteChange()
  T.eq(w.projectRoot, root)
  T.eq(sprites.projectRoot, root)
  T.deepEq(w.sent[#w.sent], { type = "open_project", projectRoot = root, conversationId = "proj-chat" })
  local before = #w.sent
  w:onSiteChange()
  T.eq(#w.sent, before, "same project: nothing sent")
  sprites.projectRoot = nil
end)

T.test("an unsaved sprite keeps the current project", function()
  F.closeAll()
  local w = stubbed({})
  w:setProject(root)
  app.sprite = Sprite(2, 2)
  w:onSiteChange()
  T.eq(w.projectRoot, root)
  sprites.projectRoot = nil
end)

T.test("ready and conversation messages remember the chat per project", function()
  local p = {}
  local w = stubbed(p)
  w:onMessage{ type = "conversation", conversationId = "c9", projectRoot = root, projectName = "x", history = json.decode("[]") }
  T.eq(prefs.getConversation(p, root), "c9")
  w.projectRoot = root
  w:newChat()
  T.eq(prefs.getConversation(p, root), nil)
end)

T.test("sending a message attaches the context and the attach flag, then clears the flag", function()
  F.closeAll()
  local w = stubbed({})
  w.conn.status = "connected"
  w.attachNext = true
  w.dlg = { data = { input = "what do you think?" }, modify = function() end, repaint = function() end }
  app.sprite = Sprite(2, 2)
  w:onSendOrStop()
  local msg = w.sent[#w.sent]
  T.eq(msg.type, "user_message")
  T.eq(msg.attach, true)
  T.eq(type(msg.context.openSprites), "table")
  T.eq(w.attachNext, false)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh chat_window && scripts/test-lua.sh connection`
Expected: failures. `onSiteChange`, `setProject` and `helloFields` are missing.

- [ ] **Step 3: Implement the connection change**

In `connection.lua`, replace the hello send with:
```lua
    local fields = self.opts.helloFields and self.opts.helloFields() or {}
    self:send{
      type = "hello",
      token = self.token,
      extensionVersion = VERSION,
      projectRoot = fields.projectRoot,
      conversationId = fields.conversationId,
    }
```

- [ ] **Step 4: Implement the window changes**

In `chat_window.lua`:
- Add these requires:
```lua
local project = require("agent.project")
local prefs = require("agent.prefs")
local context = require("agent.context")
local sprites = require("agent.tools.sprites")
```
- In `ChatWindow.new`, replace the connection's `conversationId = …` option with:
```lua
    helloFields = function()
      return { projectRoot = self.projectRoot, conversationId = prefs.getConversation(self.opts.prefs, self.projectRoot) }
    end,
```
Also add the fields `projectRoot = nil, projectName = "No project", attachNext = false`. After constructing, set the project from the active sprite and subscribe to tab changes:
```lua
  self:setProject(project.findRoot(app.sprite and app.sprite.filename), true)
  self.siteListener = app.events:on("sitechange", function() self:onSiteChange() end)
```
- In `close()`, add `pcall(function() app.events:off(self.siteListener) end)`.
- Add these methods:
```lua
function ChatWindow:setProject(root, silent)
  self.projectRoot = root
  sprites.projectRoot = root
  self.projectName = root and app.fs.fileName(root) or "No project"
  self:syncProjectHeader()
  if not silent and self.conn.status == "connected" then
    self.conn:send{ type = "open_project", projectRoot = root, conversationId = prefs.getConversation(self.opts.prefs, root) }
  end
end

-- Follow the artist's tabs: a saved sprite decides the project; unsaved sprites keep it.
function ChatWindow:onSiteChange()
  local s = app.sprite
  if not s or app.fs.filePath(s.filename) == "" then return end
  local root = project.findRoot(s.filename)
  if root ~= self.projectRoot then self:setProject(root) end
end

function ChatWindow:syncProjectHeader()
  if not self.open then return end
  self.dlg:modify{ id = "project", text = self.projectRoot and ("Project: " .. self.projectName) or "No project" }
  self.dlg:modify{ id = "makeproject", visible = self.projectRoot == nil }
end
```
- In `build()`, add a header row at the top, before the status label:
```lua
  dlg:label{ id = "project", text = "No project" }
  dlg:button{ id = "makeproject", text = "Make project", onclick = function() self:makeProject() end }
  dlg:button{ id = "history", text = "History", onclick = function() self.conn:send{ type = "list_history" } end }
  dlg:newrow()
```
Also, just before the input entry, add:
```lua
  dlg:check{ id = "attach", text = "Attach view", selected = self.attachNext, onclick = function() self.attachNext = self.dlg.data.attach end }
```
- In `show()`, after `self:syncButtons()`, call `self:syncProjectHeader()`.
- In `onSendOrStop`, replace `self.conn:send{ type = "user_message", text = text }` with:
```lua
  self.conn:send{ type = "user_message", text = text, context = context.build(self.projectRoot), attach = self.attachNext or nil }
  self.attachNext = false
  if self.open then self.dlg:modify{ id = "attach", selected = false } end
```
- In `onMessage`, change the `ready`/`conversation` block to remember per project and update the header:
```lua
  if m.type == "ready" or m.type == "conversation" then
    prefs.setConversation(self.opts.prefs, m.projectRoot, m.conversationId)
    if m.projectName then
      self.projectName = m.projectName
      self:syncProjectHeader()
    end
    if m.history then self.model:loadHistory(m.history, { dropLocal = m.type == "conversation" }) end
    self.followTail = true
    self:syncButtons()
  end
```
(this replaces the previous `self.opts.prefs.conversationId = m.conversationId` line), and add a branch:
```lua
  elseif m.type == "history_list" then
    self:showHistory(m.items)
```
- In `newChat`, replace `self.opts.prefs.conversationId = nil` with `prefs.setConversation(self.opts.prefs, self.projectRoot, nil)`.
- Add the two dialogs:
```lua
function ChatWindow:showHistory(items)
  if #items == 0 then
    ChatWindow.showTip("No saved chats in " .. self.projectName .. " yet")
    return
  end
  local labels, ids = {}, {}
  for i = 1, #items do
    local it = items[i]
    local label = tostring(it.updatedAt):sub(1, 16):gsub("T", " ") .. "  " .. render.displayText(tostring(it.title))
    labels[#labels + 1] = label
    ids[label] = tostring(it.id)
  end
  local d = Dialog{ title = "Chats in " .. self.projectName }
  d:combobox{ id = "chat", options = labels, option = labels[1] }
  d:button{ id = "open", text = "Open", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()
  if d.data.open then self.conn:send{ type = "open_conversation", conversationId = ids[d.data.chat] } end
end

function ChatWindow:makeProject()
  local s = app.sprite
  if not s or app.fs.filePath(s.filename) == "" then
    ChatWindow.showTip("Save the sprite first: the project is made from its folder")
    return
  end
  local folders = project.ancestors(s.filename, 5)
  local d = Dialog{ title = "Make project" }
  d:combobox{ id = "root", label = "Project folder", options = folders, option = folders[1] }
  d:entry{ id = "resolution", label = "Sprite size", text = "" }
  d:entry{ id = "palette", label = "Palette", text = "" }
  d:entry{ id = "outline", label = "Outline style", text = "" }
  d:entry{ id = "light", label = "Light direction", text = "" }
  d:entry{ id = "notes", label = "Notes", text = "" }
  d:button{ id = "ok", text = "Create", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()
  if not d.data.ok then return end
  local ok, err = pcall(project.create, d.data.root, d.data)
  if not ok then
    self.model:addLocalError("Couldn't make the project.", tostring(err))
    self:repaint()
    return
  end
  self:setProject(project.findRoot(s.filename))
end
```
- `plugin.lua` needs no change: `exit` already calls `window:close()`, which now also unsubscribes.

- [ ] **Step 5: Run the tests and a headless load check**

Run: `scripts/test-lua.sh` (all pass). Then run the scratch load check (`require("agent.chat_window")` and `ChatWindow.new{ prefs = {} }` under `aseprite -b`). Expected: `load true` and `new true`.

- [ ] **Step 6: Install and commit**

```bash
scripts/dev-install.sh
git add extension tests
git commit -m "feat(extension): project header, Make project, History, tab-following projects, Attach view"
```

- [ ] **Step 7: Manual checklist (the artist runs these in Aseprite)**

Rebuild and restart the bridge, restart Aseprite, then:
1. Open a saved sprite that isn't in a project. The header says **No project** and **Make project** is visible. Click it, pick the folder, fill a couple of brief fields, and press Create. The header shows **Project: <folder>**, and `<folder>/.artproject/` contains `brief.md`, `memory.md`, `project.json` and `chats/`.
2. Ask "what's in my brief?". Claude answers from `brief.md`. Edit `brief.md` in a text editor, ask again, and Claude sees the change.
3. Ask Claude to "remember that the hero uses a 2px outline". An approval card reading *Save to project memory: "…"* appears. Apply, and the line is appended to `memory.md`.
4. Ask "what sprites are in this project?". It lists them. Ask about one that isn't open. Claude reads it without leaving a new tab open, and your active tab doesn't change.
5. Ask for an edit on an unopened sprite. The card ends with "(opens it as a tab)". Apply: the sprite opens as a tab, the edit is there, and you stay on your tab.
6. Open a sprite from a *different* project (or one outside any project). The header and chat switch to that project's conversation. Switch back, and the first project's chat returns.
7. Switch projects while Claude is mid-reply. The reply finishes first, then the chat switches.
8. **History**: after a New chat, open History, pick the older chat and press Open. It loads.
9. Tick **Attach view** and ask "how does this look?". Claude looks at a snapshot first. The checkbox clears after sending.

---

## Self-Review Notes

- **Spec coverage:**
  - §3: discovery, creation with a brief, `project.json` defaults, the no-project fallback, and brief/memory ownership (`propose_memory` goes through approval; Claude never writes `brief.md`).
  - §4: project-scoped conversations, History, the context stamp, `list_project_sprites`, reading non-active sprites (background open), and editing them (opened as a tab, noted on the card).
  - §11: the header, Make project, History, and the Attach button.
- **Deviations (rulings):**
  - **Attach view** adds an instruction to look with `get_snapshot`, rather than embedding the image in the prompt. Claude already has the tool, and embedding needs streaming-input prompts.
  - **The Make project folder** is chosen from the sprite's ancestor folders. The Lua `Dialog` has no folder picker.
  - **Conversation ids** are stored as JSON in preferences.
  - **"Open & apply"** is folded into the normal Apply: the card says "(opens it as a tab)", and applying it opens the tab.
- **Deferred to Plan 4:** reading `project.json` (exports and clips).
