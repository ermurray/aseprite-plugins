import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import type { AdapterFactory } from "./adapters/Adapter.js";
import type { StoreRegistry } from "./stores.js";
import { Session } from "./session.js";

export interface ServerOptions {
  port: number;
  host?: string;
  token: string;
  adapterFactory: AdapterFactory;
  systemPrompt: string;
  snapshotDir: string;
  toolTimeoutMs?: number;
  stores?: StoreRegistry;
  /** Called when no window has been connected for `ms` (the bridge then shuts itself down). */
  idle?: { ms: number; onIdle(): void };
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

  let idleTimer: NodeJS.Timeout | undefined;
  const armIdle = () => {
    if (!opts.idle || wss.clients.size > 0) return;
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (wss.clients.size === 0) opts.idle!.onIdle();
    }, opts.idle.ms);
  };
  armIdle();

  wss.on("connection", (ws) => {
    clearTimeout(idleTimer);
    const session = new Session({
      token: opts.token,
      adapterFactory: opts.adapterFactory,
      systemPrompt: opts.systemPrompt,
      snapshotDir: opts.snapshotDir,
      toolTimeoutMs: opts.toolTimeoutMs,
      stores: opts.stores,
      send: (m) => {
        if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(m));
      },
      close: (code, reason) => ws.close(code, reason),
    });
    ws.on("message", (data, isBinary) => {
      if (!isBinary) void session.handleRaw(data.toString());
    });
    ws.on("close", () => {
      session.dispose();
      armIdle();
    });
  });

  return {
    port: (wss.address() as AddressInfo).port,
    close: () =>
      new Promise<void>((resolve) => {
        clearTimeout(idleTimer);
        for (const c of wss.clients) c.terminate();
        wss.close(() => resolve());
      }),
  };
}
