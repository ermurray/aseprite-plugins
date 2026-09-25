import { mkdtemp, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ConversationStore, HistoryRecorder, summarize } from "../src/conversations.js";

describe("ConversationStore", () => {
  it("creates, saves and loads conversations", async () => {
    const dir = join(await mkdtemp(join(tmpdir(), "chats-")), "chats");
    const store = new ConversationStore(dir);
    const c = store.create();
    expect(c.id).toMatch(/^[\w-]+$/);
    c.items.push({ kind: "user", text: "hi" });
    c.resume = { sessionId: "s1" };
    await store.save(c);
    const back = await store.load(c.id);
    expect(back?.items).toEqual([{ kind: "user", text: "hi" }]);
    expect(back?.resume).toEqual({ sessionId: "s1" });
    expect(await readdir(dir)).toEqual([`${c.id}.json`]);
  });

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

  it("removes a conversation file, and ignores missing ones", async () => {
    const store = new ConversationStore(await mkdtemp(join(tmpdir(), "chats-")));
    const c = store.create();
    await store.save(c);
    await store.remove(c.id);
    expect(await store.load(c.id)).toBeUndefined();
    await store.remove("never-existed");
  });

  it("returns undefined for unknown or unsafe ids", async () => {
    const store = new ConversationStore(await mkdtemp(join(tmpdir(), "chats-")));
    expect(await store.load("nope")).toBeUndefined();
    expect(await store.load("../../etc/passwd")).toBeUndefined();
  });
});

describe("ConversationStore under concurrency", () => {
  it("serialises saves of the same conversation and loads wait for them", async () => {
    const store = new ConversationStore(await mkdtemp(join(tmpdir(), "chats-")));
    const c = store.create();
    const saves = [];
    for (let n = 0; n < 20; n++) {
      c.items = Array.from({ length: n % 2 ? 1 : 50 }, (_, k) => ({ kind: "user" as const, text: `m${n}-${k}` }));
      saves.push(store.save({ ...c, items: [...c.items] }));
    }
    const loaded = store.load(c.id);
    await Promise.all(saves);
    const back = await loaded;
    expect(back?.items).toHaveLength(1);
    expect(back?.items[0].text).toBe("m19-0");
  });

  it("treats a file with the wrong shape as missing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "chats-"));
    const { writeFile } = await import("node:fs/promises");
    await writeFile(join(dir, "bad.json"), JSON.stringify({ id: "bad" }));
    expect(await new ConversationStore(dir).load("bad")).toBeUndefined();
  });
});

describe("HistoryRecorder", () => {
  it("records what the chat window shows", () => {
    const items: any[] = [];
    const r = new HistoryRecorder(items);
    r.user("fix it");
    r.agentDelta("Let me ");
    r.agentDelta("look.");
    r.activity("Looked at a");
    r.agentDelta("\n\n");
    r.agentDelta("Done.");
    r.approval("a1", "Add layer");
    r.approval("a2", "Rename");
    r.resolveApproval("a1", true);
    r.error("Oops", "try again");
    r.endTurn();
    expect(items).toEqual([
      { kind: "user", text: "fix it" },
      { kind: "agent", text: "Let me look." },
      { kind: "activity", text: "Looked at a" },
      { kind: "agent", text: "Done." },
      { kind: "approval", id: "a1", text: "Add layer", state: "applied" },
      { kind: "approval", id: "a2", text: "Rename", state: "cancelled" },
      { kind: "error", text: "Oops\ntry again" },
    ]);
  });

  it("titles a conversation after its first message", () => {
    const items: any[] = [];
    const r = new HistoryRecorder(items);
    expect(r.title()).toBe("New chat");
    r.user("x".repeat(100));
    expect(r.title()).toHaveLength(60);
  });
});

describe("summarize", () => {
  it("renders recent user and agent lines for a fresh session", () => {
    const s = summarize([
      { kind: "user", text: "make the sky warmer" },
      { kind: "activity", text: "Looked at a" },
      { kind: "agent", text: "Try #f0a060." },
    ]);
    expect(s).toContain("Artist: make the sky warmer");
    expect(s).toContain("You: Try #f0a060.");
    expect(s).not.toContain("Looked at a");
  });
});
