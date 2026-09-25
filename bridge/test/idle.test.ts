import { afterEach, describe, expect, it } from "vitest";
import { startServer, type BridgeServer } from "../src/server.js";
import { connectClient, scriptedAdapterFactory } from "./helpers.js";

let server: BridgeServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

async function* noop() {}

describe("idle shutdown", () => {
  it("fires after the idle time with no window, never while one is connected", async () => {
    let fired = 0;
    server = await startServer({
      port: 0, token: "t", systemPrompt: "", snapshotDir: "/s",
      adapterFactory: scriptedAdapterFactory(noop),
      idle: { ms: 80, onIdle: () => fired++ },
    });
    const c = await connectClient(server.port);
    await new Promise((r) => setTimeout(r, 150));
    expect(fired).toBe(0);
    c.ws.close();
    await new Promise((r) => setTimeout(r, 150));
    expect(fired).toBe(1);
  });
});
