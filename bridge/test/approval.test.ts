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

  it("auto-approve skips cards, except for request_draft_mode", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("layer_ops", { action: "add", name: "A" });
      await ctx.tools.call("request_draft_mode", { quote: "please just block it out" });
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "go" });
    const req = await c.waitFor((m) => m.type === "approval_request");
    expect(req).toMatchObject({ summary: expect.stringContaining("AI Draft") });
    const calls = c.received.filter((m) => m.type === "tool_call");
    expect(calls).toHaveLength(1);
    c.send({ type: "approval", approvalId: (req as any).approvalId, approved: true });
    await c.waitFor((m) => m.type === "turn_done");
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

  it("keeps the AI Draft layer locked until request_draft_mode is approved", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(10, "ai draft")));
      rec.push(await ctx.tools.call("request_draft_mode", { quote: "no really, block it out for me" }));
      rec.push(await ctx.tools.call("set_pixels", px(2000, "AI Draft")));
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "draw it" });
    await approveNext(c, true);
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results[0]).toMatchObject({ ok: false, error: expect.stringContaining("locked") });
    expect(rec.results[1].ok).toBe(true);
    expect(rec.results[2].ok).toBe(true);
    const calls = c.received.filter((m) => m.type === "tool_call").map((m) => (m as any).name);
    expect(calls).toEqual(["ensure_draft_layer", "set_pixels"]);
  });

  it("New chat turns draft mode off again", async () => {
    const rec = recorder();
    let turn = 0;
    const c = await setup(async function* (ctx) {
      turn++;
      if (turn === 1) rec.push(await ctx.tools.call("request_draft_mode", { quote: "block it out please" }));
      else rec.push(await ctx.tools.call("set_pixels", px(5, "AI Draft")));
    });
    c.send({ type: "user_message", text: "one" });
    await approveNext(c, true);
    await c.waitFor((m) => m.type === "turn_done");
    c.send({ type: "new_chat" });
    const before = c.received.length;
    c.send({ type: "user_message", text: "two" });
    await c.waitFor((m) => m.type === "turn_done" && c.received.indexOf(m) >= before);
    expect(rec.results[1]).toMatchObject({ ok: false, error: expect.stringContaining("locked") });
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
