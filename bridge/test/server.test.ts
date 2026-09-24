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

describe("new chat during a running turn", () => {
  it("drops the old turn's output and accepts the next message immediately", async () => {
    let first = true;
    const s = await start(async function* (ctx, text) {
      if (first) {
        first = false;
        await ctx.tools.call("get_sprite_info", {});
        await ctx.tools.call("get_palette", {});
        yield { type: "text_delta", text: "stale" };
        return;
      }
      yield { type: "text_delta", text: `fresh:${text}` };
    });
    const c = await authed(s.port);
    c.send({ type: "user_message", text: "one" });
    await c.waitFor((m) => m.type === "tool_call");
    const before = c.received.length;
    c.send({ type: "cancel" });
    c.send({ type: "new_chat" });
    c.send({ type: "user_message", text: "two" });
    await c.waitFor((m) => m.type === "text_delta" && m.text === "fresh:two");
    await c.waitFor((m) => m.type === "turn_done");
    await new Promise((r) => setTimeout(r, 50));
    const after = c.received.slice(before);
    expect(after).toEqual([{ type: "text_delta", text: "fresh:two" }, { type: "turn_done" }]);
  });
});
