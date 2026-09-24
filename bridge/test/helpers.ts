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
