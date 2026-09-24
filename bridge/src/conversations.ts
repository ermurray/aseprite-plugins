import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { ResumeState } from "./adapters/Adapter.js";

export type ApprovalState = "pending" | "applied" | "denied" | "cancelled";

/** One entry of what the chat window shows; mirrors the extension's ChatModel items. */
export type HistoryItem =
  | { kind: "user" | "agent" | "activity" | "error" | "notice"; text: string }
  | { kind: "approval"; id: string; text: string; state: ApprovalState };

export interface Conversation {
  id: string;
  createdAt: string;
  updatedAt: string;
  title: string;
  resume?: ResumeState;
  items: HistoryItem[];
}

const SAFE_ID = /^[\w-]{1,64}$/;

export class ConversationStore {
  /** Saves in flight per conversation; saves run one at a time and loads wait for them. */
  private pending = new Map<string, Promise<void>>();

  constructor(private dir: string) {}

  create(): Conversation {
    const now = new Date().toISOString();
    return { id: randomUUID(), createdAt: now, updatedAt: now, title: "New chat", items: [] };
  }

  async load(id: string): Promise<Conversation | undefined> {
    if (!SAFE_ID.test(id)) return undefined;
    await this.pending.get(id)?.catch(() => {});
    try {
      const c = JSON.parse(await readFile(join(this.dir, `${id}.json`), "utf8")) as Conversation;
      return c && typeof c.id === "string" && Array.isArray(c.items) ? c : undefined;
    } catch {
      return undefined;
    }
  }

  /** Snapshots `c` now and writes it after any earlier save of the same conversation. */
  save(c: Conversation): Promise<void> {
    c.updatedAt = new Date().toISOString();
    const json = JSON.stringify(c);
    const prev = this.pending.get(c.id) ?? Promise.resolve();
    const next = prev.catch(() => {}).then(() => this.write(c.id, json));
    this.pending.set(c.id, next);
    const clear = () => {
      if (this.pending.get(c.id) === next) this.pending.delete(c.id);
    };
    next.then(clear, clear);
    return next;
  }

  private async write(id: string, json: string): Promise<void> {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    const path = join(this.dir, `${id}.json`);
    const tmp = `${path}.${randomUUID()}.tmp`;
    await writeFile(tmp, json, { mode: 0o600 });
    await rename(tmp, path);
  }
}

/** Records chat events into history items the same way the window's ChatModel does. */
export class HistoryRecorder {
  private streaming = false;

  constructor(private items: HistoryItem[]) {}

  user(text: string): void {
    this.items.push({ kind: "user", text });
    this.streaming = false;
  }

  agentDelta(delta: string): void {
    const last = this.items[this.items.length - 1];
    if (this.streaming && last?.kind === "agent") {
      last.text += delta;
      return;
    }
    const text = delta.trimStart();
    if (text === "") return;
    this.items.push({ kind: "agent", text });
    this.streaming = true;
  }

  activity(text: string): void {
    this.items.push({ kind: "activity", text });
    this.streaming = false;
  }

  notice(text: string): void {
    this.items.push({ kind: "notice", text });
    this.streaming = false;
  }

  error(message: string, hint?: string): void {
    this.items.push({ kind: "error", text: hint ? `${message}\n${hint}` : message });
    this.streaming = false;
  }

  approval(id: string, text: string): void {
    this.items.push({ kind: "approval", id, text, state: "pending" });
    this.streaming = false;
  }

  resolveApproval(id: string, approved: boolean): void {
    for (const item of this.items) {
      if (item.kind === "approval" && item.id === id && item.state === "pending") item.state = approved ? "applied" : "denied";
    }
  }

  /** Ends a turn: nothing is streaming any more and unanswered cards are cancelled. */
  endTurn(): void {
    this.streaming = false;
    for (const item of this.items) if (item.kind === "approval" && item.state === "pending") item.state = "cancelled";
  }

  title(): string {
    const first = this.items.find((i) => i.kind === "user");
    return first ? first.text.slice(0, 60) : "New chat";
  }
}

/** A compact plain-text recap, used to seed a fresh agent session when the old one is gone. */
export function summarize(items: HistoryItem[], maxItems = 30): string {
  const lines = items
    .filter((i) => i.kind === "user" || i.kind === "agent")
    .slice(-maxItems)
    .map((i) => `${i.kind === "user" ? "Artist" : "You"}: ${i.text.length > 400 ? `${i.text.slice(0, 400)}...` : i.text}`);
  return `Earlier in this chat (your previous session could not be restored, so here is a recap):\n${lines.join("\n")}`;
}
