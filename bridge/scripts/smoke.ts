// Usage: npm run smoke -- "What do you think of this sprite?"
// Pretends to be the Aseprite extension: answers get_sprite_info with a canned 16x16 knight, errors on other tools.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import WebSocket from "ws";
import { agentHome } from "../src/config.js";

const info = JSON.parse(await readFile(join(agentHome(), "bridge.json"), "utf8"));
const ws = new WebSocket(`ws://127.0.0.1:${info.port}`);
const text = process.argv.slice(2).join(" ") || "Describe the active sprite in one sentence.";

ws.on("open", () => ws.send(JSON.stringify({ type: "hello", token: info.token, extensionVersion: "smoke" })));
ws.on("message", (raw) => {
  const m = JSON.parse(raw.toString());
  if (m.type === "ready") ws.send(JSON.stringify({ type: "user_message", text }));
  else if (m.type === "text_delta") process.stdout.write(m.text);
  else if (m.type === "tool_activity") console.log(`\n[${m.summary}]`);
  else if (m.type === "tool_call") {
    const reply =
      m.name === "get_sprite_info"
        ? { ok: true, data: { sprite: "knight.aseprite", width: 16, height: 16, colorMode: "rgb", frameCount: 4, layers: [{ name: "Body", visible: true }] } }
        : { ok: false, error: "Not available in smoke test" };
    ws.send(JSON.stringify({ type: "tool_result", callId: m.callId, ...reply }));
  } else if (m.type === "error") console.error(`\n[error] ${m.message}${m.hint ? " - " + m.hint : ""}`);
  else if (m.type === "turn_done") {
    console.log("\n[turn done]");
    ws.close();
  }
});
ws.on("close", (code) => code === 4001 && console.error("unauthorized"));
