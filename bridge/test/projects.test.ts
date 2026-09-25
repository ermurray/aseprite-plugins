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
    expect(result).toMatchObject({ ok: false, error: expect.stringContaining("Set up project") });
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
  it("setting up a project can bring the current chat into it", async () => {
    await setup();
    const { c, ready } = await hello();
    await turn(c, { text: "before the project existed" });
    const root = await makeProject();
    c.send({ type: "open_project", projectRoot: root, adoptConversationId: ready.conversationId });
    const conv = (await c.waitFor((m) => m.type === "conversation")) as any;
    expect(conv.conversationId).toBe(ready.conversationId);
    expect(conv.projectRoot).toBe(root);
    expect(conv.history[0]).toEqual({ kind: "user", text: "before the project existed" });
    expect(await readdir(join(root, ".artproject", "chats"))).toEqual([`${ready.conversationId}.json`]);
    c.send({ type: "list_history" });
    await c.waitFor((m) => m.type === "history_list");
    c.send({ type: "open_project", projectRoot: null });
    await c.waitFor((m) => m.type === "conversation" && (m as any).projectRoot === null);
    c.send({ type: "list_history" });
    const globalList = (await c.waitFor((m) => m.type === "history_list" && (m as any).items.length === 0)) as any;
    expect(globalList.items).toEqual([]);
  });

  it("ignores adopt requests for another conversation or a non-project folder", async () => {
    await setup();
    const { c, ready } = await hello();
    await turn(c, { text: "stay" });
    const plain = await mkdtemp(join(tmpdir(), "plain-"));
    c.send({ type: "open_project", projectRoot: plain, adoptConversationId: ready.conversationId });
    const conv = (await c.waitFor((m) => m.type === "conversation")) as any;
    expect(conv.projectRoot).toBeNull();
    expect(await readdir(plain)).toEqual([]);
  });

  it("New chat while a project switch is pending starts the new chat in the new project", async () => {
    let release!: () => void;
    await setup({ hold: new Promise<void>((r) => (release = r)) });
    const a = await makeProject();
    const b = await makeProject();
    const { c } = await hello({ projectRoot: a });
    c.send({ type: "user_message", text: "long" });
    await new Promise((r) => setTimeout(r, 20));
    c.send({ type: "open_project", projectRoot: b });
    c.send({ type: "new_chat" });
    const conv = (await c.waitFor((m) => m.type === "conversation")) as any;
    expect(conv.projectRoot).toBe(b);
    release();
    await new Promise((r) => setTimeout(r, 50));
    expect(c.received.filter((m) => m.type === "conversation")).toHaveLength(1);
  });

  it("adopting while Claude is busy happens after the reply, and keeps the chat", async () => {
    let release!: () => void;
    await setup({ hold: new Promise<void>((r) => (release = r)) });
    const { c, ready } = await hello();
    c.send({ type: "user_message", text: "keep me" });
    await new Promise((r) => setTimeout(r, 20));
    const root = await makeProject();
    c.send({ type: "open_project", projectRoot: root, adoptConversationId: ready.conversationId });
    release();
    const conv = (await c.waitFor((m) => m.type === "conversation")) as any;
    expect(conv).toMatchObject({ projectRoot: root, conversationId: ready.conversationId });
    expect(conv.history[0]).toEqual({ kind: "user", text: "keep me" });
  });

  it("a failed adopt reports an error, keeps the chat where it was, and keeps the bridge alive", async () => {
    await setup();
    const { c, ready } = await hello();
    await turn(c, { text: "precious" });
    const root = await makeProject();
    const { chmod } = await import("node:fs/promises");
    await chmod(join(root, ".artproject"), 0o500);
    try {
      c.send({ type: "open_project", projectRoot: root, adoptConversationId: ready.conversationId });
      const err = (await c.waitFor((m) => m.type === "error")) as any;
      expect(err.message).toContain("Couldn't move this chat");
      c.send({ type: "list_history" });
      const list = (await c.waitFor((m) => m.type === "history_list")) as any;
      expect(list.items.map((i: any) => i.id)).toContain(ready.conversationId);
    } finally {
      await chmod(join(root, ".artproject"), 0o700);
    }
  });

  it("does not recreate a deleted .artproject folder when saving", async () => {
    await setup();
    const root = await makeProject();
    const { c } = await hello({ projectRoot: root });
    await turn(c, { text: "one" });
    const { rm, access } = await import("node:fs/promises");
    await rm(join(root, ".artproject"), { recursive: true, force: true });
    await turn(c, { text: "two" });
    await expect(access(join(root, ".artproject"))).rejects.toThrow();
  });

  it("the opens-as-tab note compares exact project paths", async () => {
    await setup({
      toolCalls: async (tools) => {
        await tools.call("layer_ops", { sprite: "knight.aseprite", action: "add", name: "A" });
      },
    });
    const { c } = await hello();
    c.send({ type: "user_message", text: "x", context: { activeSprite: "sub/knight.aseprite", openSprites: ["sub/knight.aseprite"] } });
    const req = (await c.waitFor((m) => m.type === "approval_request")) as any;
    expect(req.summary).toContain("(opens it as a tab)");
    c.send({ type: "approval", approvalId: req.approvalId, approved: false });
    await c.waitFor((m) => m.type === "turn_done");
  });
});
