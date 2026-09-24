import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { Adapter, AdapterContext, AdapterEvent } from "../src/adapters/Adapter.js";
import { ConversationStore } from "../src/conversations.js";
import { startServer, type BridgeServer } from "../src/server.js";
import { connectClient } from "./helpers.js";

let server: BridgeServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

async function setup(store: ConversationStore, contexts: AdapterContext[]) {
  server = await startServer({
    port: 0,
    token: "t",
    systemPrompt: "",
    snapshotDir: "/s",
    store,
    adapterFactory: (ctx) => {
      contexts.push(ctx);
      const adapter: Adapter = {
        name: "fake",
        async *send(text: string): AsyncIterable<AdapterEvent> {
          yield { type: "text_delta", text: `echo ${text.split("\n").pop()}` };
        },
        cancel() {},
        resumeState: () => ({ sessionId: "sdk-1" }),
      };
      return adapter;
    },
  });
  return server;
}

async function hello(port: number, conversationId?: string) {
  const c = await connectClient(port);
  c.send({ type: "hello", token: "t", extensionVersion: "t", ...(conversationId ? { conversationId } : {}) });
  const ready = await c.waitFor((m) => m.type === "ready");
  return { c, ready: ready as any };
}

describe("conversation persistence", () => {
  it("starts a new conversation, records it, and resumes it after a reconnect", async () => {
    const store = new ConversationStore(await mkdtemp(join(tmpdir(), "chats-")));
    const contexts: AdapterContext[] = [];
    const s = await setup(store, contexts);

    const first = await hello(s.port);
    expect(first.ready.conversationId).toMatch(/^[\w-]+$/);
    expect(first.ready.history).toEqual([]);
    first.c.send({ type: "user_message", text: "hello" });
    await first.c.waitFor((m) => m.type === "turn_done");
    first.c.ws.close();

    const again = await hello(s.port, first.ready.conversationId);
    expect(again.ready.conversationId).toBe(first.ready.conversationId);
    expect(again.ready.history).toEqual([
      { kind: "user", text: "hello" },
      { kind: "agent", text: "echo hello" },
    ]);
    expect(contexts[1].resume).toEqual({ sessionId: "sdk-1" });
    expect(contexts[1].resumeSummary).toContain("Artist: hello");
  });

  it("an unknown conversation id starts a fresh conversation", async () => {
    const store = new ConversationStore(await mkdtemp(join(tmpdir(), "chats-")));
    const s = await setup(store, []);
    const { ready } = await hello(s.port, "does-not-exist");
    expect(ready.conversationId).not.toBe("does-not-exist");
    expect(ready.history).toEqual([]);
  });

  it("New chat starts a new conversation and tells the extension its id", async () => {
    const store = new ConversationStore(await mkdtemp(join(tmpdir(), "chats-")));
    const contexts: AdapterContext[] = [];
    const s = await setup(store, contexts);
    const { c, ready } = await hello(s.port);
    c.send({ type: "user_message", text: "one" });
    await c.waitFor((m) => m.type === "turn_done");
    c.send({ type: "new_chat" });
    const conv = (await c.waitFor((m) => m.type === "conversation")) as any;
    expect(conv.conversationId).not.toBe(ready.conversationId);
    expect(conv.history).toEqual([]);
    expect(contexts.at(-1)!.resume).toBeUndefined();
    expect((await store.load(ready.conversationId))?.items).toHaveLength(2);
  });
});
