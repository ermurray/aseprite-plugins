import { randomBytes } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { claudeCodeAdapterFactory } from "./adapters/claudeCode.js";
import { DEFAULT_PORT, agentHome, chatsDirFor, removeBridgeInfo, snapshotDirFor, writeBridgeInfo } from "./config.js";
import { ConversationStore } from "./conversations.js";
import { SYSTEM_PROMPT } from "./prompt.js";
import { startServer, type BridgeServer } from "./server.js";

const home = agentHome();
const snapshotDir = snapshotDirFor(home);
await mkdir(snapshotDir, { recursive: true, mode: 0o700 });

const port = Number(process.env.ASEPRITE_AGENT_PORT ?? DEFAULT_PORT);
const token = randomBytes(24).toString("hex");

let server: BridgeServer;
try {
  server = await startServer({
    port,
    token,
    systemPrompt: SYSTEM_PROMPT,
    snapshotDir,
    store: new ConversationStore(chatsDirFor(home)),
    adapterFactory: claudeCodeAdapterFactory({ snapshotDir, model: process.env.ASEPRITE_AGENT_MODEL }),
  });
} catch (e) {
  if ((e as NodeJS.ErrnoException).code === "EADDRINUSE") {
    console.error(`Port ${port} is in use. Is another bridge already running? (see ${home}/bridge.json)`);
    process.exit(1);
  }
  throw e;
}

await writeBridgeInfo(home, { port: server.port, token, pid: process.pid });
console.log(`aseprite-agent bridge listening on 127.0.0.1:${server.port} (pid ${process.pid})`);

const shutdown = async () => {
  await removeBridgeInfo(home);
  await server.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
