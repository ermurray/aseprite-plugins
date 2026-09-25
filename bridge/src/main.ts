import { randomBytes } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { claudeCodeAdapterFactory } from "./adapters/claudeCode.js";
import { findClaude } from "./claudePath.js";
import { DEFAULT_PORT, agentHome, chatsDirFor, removeBridgeInfo, snapshotDirFor, writeBridgeInfo } from "./config.js";
import { StoreRegistry } from "./stores.js";
import { SYSTEM_PROMPT } from "./prompt.js";
import { startServer, type BridgeServer } from "./server.js";

export const VERSION = "0.9.0";
if (process.argv.includes("--version")) {
  console.log(VERSION);
  process.exit(0);
}

const home = agentHome();
const snapshotDir = snapshotDirFor(home);
await mkdir(snapshotDir, { recursive: true, mode: 0o700 });

const port = Number(process.env.ASEPRITE_AGENT_PORT ?? DEFAULT_PORT);
const token = randomBytes(24).toString("hex");
const claudePath = await findClaude(process.env, homedir());
const idleMinutes = Number(process.env.ASEPRITE_AGENT_IDLE_MINUTES ?? 15);

let server: BridgeServer;
try {
  server = await startServer({
    port,
    token,
    systemPrompt: SYSTEM_PROMPT,
    snapshotDir,
    stores: new StoreRegistry(chatsDirFor(home)),
    adapterFactory: claudeCodeAdapterFactory({ snapshotDir, model: process.env.ASEPRITE_AGENT_MODEL, claudePath }),
    // Started by the extension, so stop by itself once no chat window has been connected for a while.
    idle: idleMinutes > 0 ? { ms: idleMinutes * 60_000, onIdle: () => void shutdown() } : undefined,
  });
} catch (e) {
  if ((e as NodeJS.ErrnoException).code === "EADDRINUSE") {
    console.error(`Port ${port} is in use. Is another bridge already running? (see ${home}/bridge.json)`);
    process.exit(1);
  }
  throw e;
}

await writeBridgeInfo(home, { port: server.port, token, pid: process.pid });
console.log(`aseprite-agent bridge ${VERSION} listening on 127.0.0.1:${server.port} (pid ${process.pid})`);
console.log(`claude: ${claudePath ?? "not found (set ASEPRITE_AGENT_CLAUDE)"}`);

async function shutdown(): Promise<void> {
  await removeBridgeInfo(home);
  await server.close();
  process.exit(0);
}
process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
