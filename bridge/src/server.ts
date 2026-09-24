import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import type { AdapterFactory } from "./adapters/Adapter.js";
import { Session } from "./session.js";

export interface ServerOptions {
  port: number;
  host?: string;
  token: string;
  adapterFactory: AdapterFactory;
  systemPrompt: string;
  snapshotDir: string;
  toolTimeoutMs?: number;
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

  wss.on("connection", (ws) => {
    const session = new Session({
      token: opts.token,
      adapterFactory: opts.adapterFactory,
      systemPrompt: opts.systemPrompt,
      snapshotDir: opts.snapshotDir,
      toolTimeoutMs: opts.toolTimeoutMs,
      send: (m) => {
        if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(m));
      },
      close: (code, reason) => ws.close(code, reason),
    });
    ws.on("message", (data, isBinary) => {
      if (!isBinary) void session.handleRaw(data.toString());
    });
    ws.on("close", () => session.dispose());
  });

  return {
    port: (wss.address() as AddressInfo).port,
    close: () =>
      new Promise<void>((resolve) => {
        for (const c of wss.clients) c.terminate();
        wss.close(() => resolve());
      }),
  };
}
