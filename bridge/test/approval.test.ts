import { afterEach, describe, expect, it } from "vitest";
import type { AdapterContext, AdapterEvent } from "../src/adapters/Adapter.js";
import type { BridgeMessage } from "../src/protocol.js";
import { startServer, type BridgeServer } from "../src/server.js";
import type { ToolResult } from "../src/toolTypes.js";
import { connectClient, scriptedAdapterFactory, type TestClient } from "./helpers.js";

const TOKEN = "t";
let server: BridgeServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

type Script = (ctx: AdapterContext, text: string) => AsyncIterable<AdapterEvent>;

/** Starts a server whose adapter runs `script`, and a client that answers every tool_call with ok. */
async function setup(script: Script) {
  server = await startServer({ port: 0, token: TOKEN, adapterFactory: scriptedAdapterFactory(script), systemPrompt: "", snapshotDir: "/s" });
  const c = await connectClient(server.port);
  c.ws.on("message", (raw) => {
    const m = JSON.parse(raw.toString()) as BridgeMessage;
    if (m.type === "tool_call") c.send({ type: "tool_result", callId: m.callId, ok: true, data: { did: m.name, args: m.args } });
  });
  c.send({ type: "hello", token: TOKEN, extensionVersion: "t" });
  await c.waitFor((m) => m.type === "ready");
  return c;
}

const px = (n: number, layer = "Body") => ({ layer, pixels: Array.from({ length: n }, (_, i) => ({ x: i, y: 0, color: "#ff0000" })) });

async function approveNext(c: TestClient, approved: boolean) {
  const req = await c.waitFor((m) => m.type === "approval_request" && !(m as any).answered);
  (req as any).answered = true;
  if (req.type !== "approval_request") throw new Error("unreachable");
  c.send({ type: "approval", approvalId: req.approvalId, approved });
  return req;
}

function recorder() {
  const results: ToolResult[] = [];
  return { results, push: (r: ToolResult) => (results.push(r), r) };
}

describe("approval gate", () => {
  it("asks before an edit and forwards it when approved", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(2)));
    });
    c.send({ type: "user_message", text: "fix" });
    const req = await approveNext(c, true);
    expect(req).toMatchObject({ summary: 'Set 2 pixels on the active sprite > "Body"' });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.map((m) => m.type)).toEqual(["ready", "approval_request", "tool_activity", "tool_call", "turn_done"]);
    expect(rec.results[0].ok).toBe(true);
  });

  it("does not forward a declined edit", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("replace_color", { from: "#000000", to: "#111111" }));
    });
    c.send({ type: "user_message", text: "fix" });
    await approveNext(c, false);
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "tool_call")).toBe(false);
    expect(rec.results[0]).toEqual({ ok: false, error: "The artist declined this change. Ask what they would prefer instead." });
  });

  it("read tools never ask", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("get_palette", {});
    });
    c.send({ type: "user_message", text: "look" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "approval_request")).toBe(false);
  });

  it("queues concurrent approvals and answers them in order", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      const all = await Promise.all([
        ctx.tools.call("layer_ops", { action: "add", name: "A" }),
        ctx.tools.call("layer_ops", { action: "add", name: "B" }),
      ]);
      all.forEach((r) => rec.push(r));
    });
    c.send({ type: "user_message", text: "two layers" });
    const first = await approveNext(c, true);
    const second = await approveNext(c, false);
    expect(first.type === "approval_request" && second.type === "approval_request" && first.approvalId !== second.approvalId).toBe(true);
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results.map((r) => r.ok)).toEqual([true, false]);
  });

  it("auto-approve skips cards", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("layer_ops", { action: "add", name: "A" });
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "go" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "approval_request")).toBe(false);
    expect(c.received.filter((m) => m.type === "tool_call")).toHaveLength(1);
  });

  it("setting tools never show a card", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("set_tool", { tool: "pencil", brushSize: 2 });
    });
    c.send({ type: "user_message", text: "set me up" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "approval_request")).toBe(false);
    expect(c.received.filter((m) => m.type === "tool_call")).toHaveLength(1);
  });

  it("cancel resolves a pending approval as declined", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(1)));
    });
    c.send({ type: "user_message", text: "fix" });
    await c.waitFor((m) => m.type === "approval_request");
    c.send({ type: "cancel" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results[0].ok).toBe(false);
    expect(c.received.some((m) => m.type === "tool_call")).toBe(false);
  });
});

describe("draft mode", () => {
  it("has no pixel budget: large and repeated set_pixels calls go through once approved", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(2000)));
      for (let i = 0; i < 5; i++) rec.push(await ctx.tools.call("set_pixels", px(256)));
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "paint a lot" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results.map((r) => r.ok)).toEqual([true, true, true, true, true, true]);
  });

  it("with AI drafts off, draft tools are refused with a pointer to the toggle and no card", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("create_draft_layer", {}));
      rec.push(await ctx.tools.call("set_pixels", px(10, " ai draft ")));
    });
    c.send({ type: "user_message", text: "draw it" });
    await c.waitFor((m) => m.type === "turn_done");
    for (const r of rec.results) expect(r).toMatchObject({ ok: false, error: expect.stringContaining("Allow AI drafts") });
    expect(c.received.some((m) => m.type === "approval_request" || m.type === "tool_call")).toBe(false);
  });

  it("with AI drafts on, create_draft_layer and draft painting go through", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("create_draft_layer", { sprite: "a.aseprite" }));
      rec.push(await ctx.tools.call("set_pixels", { sprite: "a.aseprite", ...px(2000, "AI Draft") }));
    });
    c.send({ type: "set_draft_mode", enabled: true });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "block it out" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results.map((r) => r.ok)).toEqual([true, true]);
    const calls = c.received.filter((m) => m.type === "tool_call").map((m) => (m as any).name);
    expect(calls).toEqual(["ensure_draft_layer", "set_pixels"]);
  });

  it("the drafts toggle is a window setting: New chat keeps it", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("create_draft_layer", {}));
    });
    c.send({ type: "set_draft_mode", enabled: true });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "new_chat" });
    c.send({ type: "user_message", text: "draft" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results[0].ok).toBe(true);
  });

  it("every message tells Claude whether AI drafts are on", async () => {
    const seen: string[] = [];
    const c = await setup(async function* (_ctx, text) {
      seen.push(text);
    });
    c.send({ type: "user_message", text: "hello" });
    await c.waitFor((m) => m.type === "turn_done");
    c.send({ type: "set_draft_mode", enabled: true });
    const before = c.received.length;
    c.send({ type: "user_message", text: "again" });
    await c.waitFor((m) => m.type === "turn_done" && c.received.indexOf(m) >= before);
    expect(seen).toEqual(["[active: none | AI drafts: off]\nhello", "[active: none | AI drafts: on]\nagain"]);
  });

  it("add_color_ramp is forwarded as add_palette_colors", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("add_color_ramp", { base: "#c8503c", steps: 3 });
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "ramp" });
    const call = await c.waitFor((m) => m.type === "tool_call");
    expect(call).toMatchObject({ name: "add_palette_colors" });
    expect(((call as any).args.colors as string[]).length).toBe(3);
  });
});
