# Aseprite Agent Chat — Plan 6: Packaging

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install like any extension and run without a terminal:
- a single `aseprite-agent-<version>.aseprite-extension` that contains the bridge as one bundled JS file (about 2 MB);
- the chat window finds Node 20+ and starts the bridge automatically;
- the bridge uses the artist's installed Claude Code and shuts itself down when idle;
- a README, an MIT license, and a big-test checklist for the final manual run.

**Architecture:**
- **Bridge:** `esbuild` bundles `src/main.ts` into `dist/bridge.mjs`. `main.ts` gains `--version`, finds the `claude` executable itself (the GUI-launched bridge has a minimal PATH), passes it to the Agent SDK as `pathToClaudeCodeExecutable` (so the SDK's 224 MB platform binary is never needed), and exits after `ASEPRITE_AGENT_IDLE_MINUTES` (default 15) with no connected window.
- **Extension:** `launcher.lua` finds a Node ≥ 20 (env, preference, nvm, volta, fnm, Homebrew, /usr/local, login shell) and starts `<plugin>/bridge/bridge.mjs` detached with a log file. `Connection` detects a missing or dead bridge (stale `bridge.json` pid) and asks the window to start it, then retries until `ready`.
- **Packaging:** `scripts/package.sh` stages `extension/` + `bridge.mjs` and zips them into `dist/`. `scripts/dev-install.sh` installs the same layout.

**Tech Stack:** Plans 1–5 + `esbuild` (dev dependency).

**Spec:** §11 (the Start bridge button, the launch command) and §1 (the audience includes publishing later).

## Global Constraints

- **Verified during planning:**
  - `esbuild --bundle --platform=node --format=esm --target=node20` with a `createRequire` banner produces a working bridge with no `node_modules`.
  - With `pathToClaudeCodeExecutable` set to the installed `claude`, a real reply came back.
  - On this machine a GUI login shell resolves `node` to `/usr/local/bin/node` **v10**. So Node discovery must check versions and prefer ≥ 20: nvm's `~/.nvm/versions/node/v24.11.1` wins here.
  - `claude` lives at `~/.local/bin/claude`.
- **Version is 0.9.0 everywhere:** `extension/package.json`, `bridge/package.json`, `connection.lua` `VERSION`, and the SDK client-app string.
- **The extension layout in the zip:** `package.json`, `plugin.lua`, `agent/…`, `bridge/bridge.mjs`, `LICENSE`, `README.md`.
- **Error texts shown to the artist:**
  - `Node.js 20 or newer is needed to run the assistant.` with hint `Install it from nodejs.org (or: brew install node), then press Reconnect.`
  - `The assistant's bridge didn't start.` with hint `See <log path>.`
- **macOS and Linux are supported.** Windows launching is out of scope for 0.9 (the message says so).

## Review Focus

1. **A stale `bridge.json`** (bridge crashed or the machine rebooted) must trigger a fresh start, not endless reconnect attempts to a dead port.
2. **Old or missing Node:** v10 on PATH plus v24 in nvm picks v24; no Node at all gives the clear error, not a silent hang.
3. **Two Aseprite windows or rapid Reconnect clicks** must not start two bridges. The port is already in use, so a second start exits, and the window then connects to the first one.
4. **The idle shutdown** never kills a bridge with a connected window, and it removes `bridge.json` when it exits.
5. **The packaged zip** contains everything needed, and the bundled bridge runs from a folder with no `node_modules`.

---

### Task 1: Bridge: find Claude, idle shutdown, `--version`, bundle

**Files:**
- Create: `bridge/src/claudePath.ts`, `bridge/scripts/bundle.mjs`
- Modify: `bridge/src/adapters/claudeCode.ts` (`claudePath` option), `bridge/src/server.ts` (idle callback), `bridge/src/main.ts`, `bridge/package.json`
- Test: `bridge/test/claudePath.test.ts`, `bridge/test/idle.test.ts`, `bridge/test/bundle.test.ts`, `bridge/test/claudeCode.test.ts` (add a case)

**Interfaces:**
- `findClaude(env, home, isExecutable: (p) => Promise<boolean>) -> Promise<string | undefined>`
- `ClaudeCodeOptions.claudePath?: string` → `options.pathToClaudeCodeExecutable`
- `ServerOptions.idle?: { ms: number; onIdle(): void }`. The timer starts when the last client disconnects (and at startup) and is cleared when a client connects.
- `node dist/bridge.mjs --version` prints `0.9.0` and exits 0.

- [ ] **Step 1: Write the failing tests**

`bridge/test/claudePath.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { findClaude } from "../src/claudePath.js";

const only = (...ok: string[]) => async (p: string) => ok.includes(p);

describe("findClaude", () => {
  it("prefers ASEPRITE_AGENT_CLAUDE, then PATH, then well-known install locations", async () => {
    expect(await findClaude({ ASEPRITE_AGENT_CLAUDE: "/x/claude" }, "/h", only("/x/claude"))).toBe("/x/claude");
    expect(await findClaude({ PATH: "/a:/b" }, "/h", only("/b/claude"))).toBe("/b/claude");
    expect(await findClaude({ PATH: "/usr/bin" }, "/h", only("/h/.local/bin/claude"))).toBe("/h/.local/bin/claude");
    expect(await findClaude({}, "/h", only("/opt/homebrew/bin/claude"))).toBe("/opt/homebrew/bin/claude");
    expect(await findClaude({}, "/h", only("/h/.claude/local/claude"))).toBe("/h/.claude/local/claude");
    expect(await findClaude({}, "/h", only())).toBeUndefined();
  });
});
```

`bridge/test/idle.test.ts`:
```ts
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
```

`bridge/test/bundle.test.ts`:
```ts
import { execFile } from "node:child_process";
import { copyFile, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { bundle } from "../scripts/bundle.mjs";

const run = promisify(execFile);

describe("bundled bridge", () => {
  it("runs from a folder with no node_modules", async () => {
    const out = await bundle();
    const dir = await mkdtemp(join(tmpdir(), "bundle-"));
    await copyFile(out, join(dir, "bridge.mjs"));
    const { stdout } = await run(process.execPath, [join(dir, "bridge.mjs"), "--version"]);
    expect(stdout.trim()).toBe("0.9.0");
  }, 60_000);
});
```

Add to `claudeCode.test.ts` (in the `ClaudeCodeAdapter` describe):
```ts
  it("passes the discovered claude executable to the SDK", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", claudePath: "/h/.local/bin/claude", queryFn: fakeQuery([], calls) });
    await collect(a.send("hi"));
    expect(calls[0].options.pathToClaudeCodeExecutable).toBe("/h/.local/bin/claude");
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npm i -D esbuild && npx vitest run`
Expected: FAIL. `claudePath.js` and `bundle.mjs` are missing, the idle option is ignored, and `pathToClaudeCodeExecutable` is undefined.

- [ ] **Step 3: Implement**

`bridge/src/claudePath.ts`:
```ts
import { access, constants } from "node:fs/promises";
import { join } from "node:path";

export async function isExecutable(p: string): Promise<boolean> {
  try {
    await access(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** Finds the installed Claude Code CLI. Aseprite starts the bridge with a minimal PATH, so check known spots too. */
export async function findClaude(
  env: Record<string, string | undefined>,
  home: string,
  exec: (p: string) => Promise<boolean> = isExecutable,
): Promise<string | undefined> {
  const candidates: string[] = [];
  if (env.ASEPRITE_AGENT_CLAUDE) candidates.push(env.ASEPRITE_AGENT_CLAUDE);
  for (const dir of (env.PATH ?? "").split(":").filter(Boolean)) candidates.push(join(dir, "claude"));
  candidates.push(
    join(home, ".local", "bin", "claude"),
    join(home, ".claude", "local", "claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    join(home, ".npm-global", "bin", "claude"),
  );
  for (const c of candidates) if (await exec(c)) return c;
  return undefined;
}
```

In `claudeCode.ts`:
- Add `claudePath?: string;` to `ClaudeCodeOptions`.
- In the query options, add `pathToClaudeCodeExecutable: this.opts.claudePath,`.
- Change the client app string to `"aseprite-agent/0.9.0"`.

In `server.ts`:
- Add `idle?: { ms: number; onIdle(): void };` to `ServerOptions`.
- After `listening`:
```ts
  let idleTimer: NodeJS.Timeout | undefined;
  const armIdle = () => {
    if (!opts.idle || wss.clients.size > 0) return;
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (wss.clients.size === 0) opts.idle!.onIdle();
    }, opts.idle.ms);
  };
  armIdle();
```
- In the `connection` handler, first line: `clearTimeout(idleTimer);`. In the `close` handler, after `session.dispose()`: `armIdle();`.
- In `close()`, also call `clearTimeout(idleTimer)`.

`bridge/scripts/bundle.mjs`:
```js
// Bundles the bridge into one ESM file that runs with plain Node (no node_modules).
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

export async function bundle() {
  const outfile = join(root, "dist", "bridge.mjs");
  await build({
    entryPoints: [join(root, "src", "main.ts")],
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node20",
    outfile,
    banner: { js: "import { createRequire as __agentRequire } from 'module'; const require = __agentRequire(import.meta.url);" },
    external: ["bufferutil", "utf-8-validate"],
    logLevel: "warning",
  });
  return outfile;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = await bundle();
  console.log(`bundled ${out}`);
}
```

`bridge/src/main.ts`, at the very top, after the imports:
```ts
export const VERSION = "0.9.0";
if (process.argv.includes("--version")) {
  console.log(VERSION);
  process.exit(0);
}
```
Then:
- add `import { homedir } from "node:os";` and `import { findClaude } from "./claudePath.js";`;
- compute `const claudePath = await findClaude(process.env, homedir());`;
- pass `claudePath` into `claudeCodeAdapterFactory({ snapshotDir, model: …, claudePath })`;
- pass `idle` into `startServer`:
```ts
    idle: Number(process.env.ASEPRITE_AGENT_IDLE_MINUTES ?? 15) > 0
      ? { ms: Number(process.env.ASEPRITE_AGENT_IDLE_MINUTES ?? 15) * 60_000, onIdle: () => void shutdown() }
      : undefined,
```
`shutdown` is used before it's defined, so turn it into a `function shutdown()` declaration (hoisted) with the same body. Log `claude: <path or "not found">` at startup.

`bridge/package.json`: set `"version": "0.9.0"` and add the script `"bundle": "node scripts/bundle.mjs"`.

- [ ] **Step 4: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all pass. `bundle.test.ts` builds and runs the bundle.

- [ ] **Step 5: Commit**

```bash
git add bridge && git commit -m "feat(bridge): find the installed claude, idle shutdown, --version, single-file bundle"
```

---

### Task 2: Lua launcher: find Node, start the bridge, detect stale bridges

**Files:**
- Create: `extension/agent/launcher.lua`
- Test: `tests/lua/test_launcher.lua` (add it to the suite list)

**Interfaces:**
- `launcher.parseVersion("v24.11.1\n") -> 24, 11, 1`
- `launcher.pick(list{{path, major}}) -> path|nil` (the newest with major ≥ 20)
- `launcher.candidates(env, home) -> {paths}`
- `launcher.findNode(opts{preferred}) -> path|nil, triedCount`
- `launcher.bridgeScript(pluginPath) -> path|nil`
- `launcher.pidAlive(pid) -> bool`
- `launcher.startCommand(node, script, log) -> shell string`
- `launcher.start(pluginPath, opts) -> {ok, error?, hint?, log?}`

- [ ] **Step 1: Write the failing test**

`tests/lua/test_launcher.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local L = require("agent.launcher")

T.test("parses node versions and picks the newest usable one", function()
  T.deepEq({ L.parseVersion("v24.11.1\n") }, { 24, 11, 1 })
  T.eq(L.parseVersion("nonsense"), nil)
  T.eq(L.pick({ { path = "/usr/local/bin/node", major = 10 }, { path = "/nvm/v24/bin/node", major = 24 }, { path = "/nvm/v22/bin/node", major = 22 } }), "/nvm/v24/bin/node")
  T.eq(L.pick({ { path = "/old", major = 18 } }), nil)
end)

T.test("candidates include env, nvm, volta, homebrew and system paths", function()
  local list = L.candidates({ ASEPRITE_AGENT_NODE = "/custom/node" }, "/h")
  T.eq(list[1], "/custom/node")
  local joined = table.concat(list, "\n")
  for _, p in ipairs{ "/h/.volta/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node" } do
    T.eq(joined:find(p, 1, true) ~= nil, true, p)
  end
end)

T.test("findNode finds a real Node 20+ on this machine", function()
  local node = L.findNode({})
  T.eq(node ~= nil, true)
  local p = io.popen('"' .. node .. '" -v')
  local major = L.parseVersion(p:read("a"))
  p:close()
  T.eq(major >= 20, true)
end)

T.test("pidAlive tells live processes from dead ones", function()
  local p = io.popen("echo $PPID")
  local pid = tonumber(p:read("l"))
  p:close()
  T.eq(L.pidAlive(pid), true)
  T.eq(L.pidAlive(999999), false)
  T.eq(L.pidAlive(nil), false)
end)

T.test("the start command runs detached with a log and quotes paths", function()
  local cmd = L.startCommand("/a b/node", "/ext dir/bridge/bridge.mjs", "/h/.aseprite-agent/bridge.log")
  T.eq(cmd, 'nohup "/a b/node" "/ext dir/bridge/bridge.mjs" > "/h/.aseprite-agent/bridge.log" 2>&1 &')
end)

T.test("bridgeScript finds bridge/bridge.mjs inside the plugin folder", function()
  local dir = F.unique("plugin")
  app.fs.makeAllDirectories(app.fs.joinPath(dir, "bridge"))
  T.eq(L.bridgeScript(dir), nil)
  local f = io.open(app.fs.joinPath(dir, "bridge", "bridge.mjs"), "w"); f:write("//"); f:close()
  T.eq(L.bridgeScript(dir), app.fs.joinPath(dir, "bridge", "bridge.mjs"))
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh launcher`
Expected: `module 'agent.launcher' not found`.

- [ ] **Step 3: Implement**

`extension/agent/launcher.lua`:
```lua
-- Finds Node 20+ and starts the bundled bridge in the background (macOS/Linux).
local M = { MIN_MAJOR = 20 }

local function q(s) return '"' .. tostring(s):gsub('"', '\\"') .. '"' end

function M.parseVersion(text)
  local a, b, c = tostring(text or ""):match("v(%d+)%.(%d+)%.(%d+)")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c)
end

function M.pick(list)
  local best
  for _, n in ipairs(list) do
    if n.major and n.major >= M.MIN_MAJOR and (not best or n.major > best.major) then best = n end
  end
  return best and best.path or nil
end

local function listDir(dir)
  local ok, names = pcall(app.fs.listFiles, dir)
  return ok and names or {}
end

function M.candidates(env, home)
  local out = {}
  local function add(p) if p and p ~= "" then out[#out + 1] = p end end
  add(env.ASEPRITE_AGENT_NODE)
  for _, v in ipairs(listDir(app.fs.joinPath(home, ".nvm", "versions", "node"))) do
    add(app.fs.joinPath(home, ".nvm", "versions", "node", v, "bin", "node"))
  end
  add(app.fs.joinPath(home, ".volta", "bin", "node"))
  for _, v in ipairs(listDir(app.fs.joinPath(home, ".local", "share", "fnm", "node-versions"))) do
    add(app.fs.joinPath(home, ".local", "share", "fnm", "node-versions", v, "installation", "bin", "node"))
  end
  add("/opt/homebrew/bin/node")
  add("/usr/local/bin/node")
  add("/usr/bin/node")
  return out
end

local function versionOf(path)
  if not app.fs.isFile(path) then return nil end
  local p = io.popen(q(path) .. " -v 2>/dev/null")
  if not p then return nil end
  local out = p:read("a")
  p:close()
  return (M.parseVersion(out))
end

function M.findNode(opts)
  local env = setmetatable({}, { __index = function(_, k) return os.getenv(k) end })
  local home = os.getenv("HOME") or ""
  local list = {}
  local paths = M.candidates(env, home)
  if opts and opts.preferred then table.insert(paths, 1, opts.preferred) end
  local p = io.popen("/bin/sh -lc 'command -v node' 2>/dev/null")
  if p then
    local found = p:read("l")
    p:close()
    if found and found ~= "" then paths[#paths + 1] = found end
  end
  for _, path in ipairs(paths) do list[#list + 1] = { path = path, major = versionOf(path) } end
  return M.pick(list), #paths
end

function M.bridgeScript(pluginPath)
  local p = app.fs.joinPath(pluginPath, "bridge", "bridge.mjs")
  return app.fs.isFile(p) and p or nil
end

function M.pidAlive(pid)
  pid = tonumber(pid)
  if not pid then return false end
  return os.execute("kill -0 " .. math.floor(pid) .. " 2>/dev/null") == true
end

function M.startCommand(node, script, log)
  return "nohup " .. q(node) .. " " .. q(script) .. " > " .. q(log) .. " 2>&1 &"
end

function M.agentHome()
  return os.getenv("ASEPRITE_AGENT_HOME") or app.fs.joinPath(os.getenv("HOME") or "", ".aseprite-agent")
end

function M.start(pluginPath, opts)
  if app.fs.pathSeparator == "\\" then
    return { ok = false, error = "Starting the bridge automatically isn't supported on Windows yet.", hint = "Run: node bridge/bridge.mjs from the extension folder." }
  end
  local script = M.bridgeScript(pluginPath)
  if not script then
    return { ok = false, error = "The bridge is missing from this install.", hint = "Reinstall the extension, or for development run scripts/dev-install.sh." }
  end
  local node = M.findNode(opts)
  if not node then
    return { ok = false, error = "Node.js 20 or newer is needed to run the assistant.", hint = "Install it from nodejs.org (or: brew install node), then press Reconnect." }
  end
  app.fs.makeAllDirectories(M.agentHome())
  local log = app.fs.joinPath(M.agentHome(), "bridge.log")
  os.execute(M.startCommand(node, script, log))
  return { ok = true, log = log, node = node }
end

return M
```

Add `"test_launcher"` to the suite list.

- [ ] **Step 4: Run the tests, then commit**

Run: `scripts/test-lua.sh`. Expected: all pass.
```bash
git add extension/agent/launcher.lua tests/lua && git commit -m "feat(extension): find Node 20+ and start the bundled bridge"
```

---

### Task 3: Auto-start in the connection and window

**Files:**
- Modify: `extension/agent/connection.lua`, `extension/agent/chat_window.lua`
- Test: `tests/lua/test_connection.lua`, `tests/lua/test_chat_window.lua`

**Interfaces:**
- `Connection.new{ …, onNeedsBridge = function(reason) end }`.
- `Connection:connect()` calls `onNeedsBridge("missing" | "stale")` when `bridge.json` is absent, or its pid isn't alive (and removes the stale file), instead of dialing a dead port.
- `ChatWindow:startBridge(reason)` starts the bridge via the launcher (at most once every 15 s), shows "Starting the assistant...", polls every 0.5 s for up to 15 s, then connects or shows the error with the log path.
- `STATUS_TEXT.disconnected` becomes `"Assistant not running"`, and `STATUS_TEXT.starting` is `"Starting the assistant..."`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/lua/test_connection.lua`:
```lua
T.test("a missing or stale bridge.json asks for a bridge instead of dialing a dead port", function()
  local home = F.unique("agent home")
  app.fs.makeAllDirectories(home)
  local asked = {}
  local c = Connection.new{ onMessage = function() end, onStatus = function() end, onNeedsBridge = function(r) asked[#asked + 1] = r end }
  local realPath = Connection.infoPath
  Connection.infoPath = function() return app.fs.joinPath(home, "bridge.json") end
  T.eq(c:connect(), false)
  T.eq(asked[1], "missing")
  local f = io.open(app.fs.joinPath(home, "bridge.json"), "w")
  f:write('{"port":47999,"token":"t","pid":999999}'); f:close()
  T.eq(c:connect(), false)
  T.eq(asked[2], "stale")
  T.eq(app.fs.isFile(app.fs.joinPath(home, "bridge.json")), false, "stale file removed")
  Connection.infoPath = realPath
end)
```
(add `local F = require("fixtures")` at the top of the file if it isn't there).

Add to `tests/lua/test_chat_window.lua`:
```lua
T.test("startBridge reports a missing Node clearly and doesn't retry in a tight loop", function()
  local launcher = require("agent.launcher")
  local realStart = launcher.start
  local calls = 0
  launcher.start = function() calls = calls + 1; return { ok = false, error = "Node.js 20 or newer is needed to run the assistant.", hint = "Install it" } end
  local w = stubbed({})
  w.pluginPath = "/nowhere"
  w:startBridge("missing")
  w:startBridge("missing")
  T.eq(calls, 1, "a second request within 15s doesn't start again")
  T.eq(w.model.items[#w.model.items].text, "Node.js 20 or newer is needed to run the assistant.\nInstall it")
  launcher.start = realStart
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh connection && scripts/test-lua.sh chat_window`
Expected: failures (no `onNeedsBridge`, no `startBridge`).

- [ ] **Step 3: Implement the connection change**

In `connection.lua`, add `local launcher = require("agent.launcher")` and replace the start of `Connection:connect()` (up to `self.token = info.token`) with:
```lua
function Connection:connect()
  self:close()
  local path = Connection.infoPath()
  local info = Connection.readBridgeInfo(path)
  if not info then
    self:setStatus("disconnected", "Assistant not running")
    if self.opts.onNeedsBridge then self.opts.onNeedsBridge("missing") end
    return false
  end
  if info.pid and not launcher.pidAlive(info.pid) then
    os.remove(path)
    self:setStatus("disconnected", "Assistant not running")
    if self.opts.onNeedsBridge then self.opts.onNeedsBridge("stale") end
    return false
  end
  self.token = info.token
```
Also set `local VERSION = "0.9.0"`.

- [ ] **Step 4: Implement the window change**

In `chat_window.lua`:
- Add `local launcher = require("agent.launcher")`.
- Change `STATUS_TEXT` to:
```lua
local STATUS_TEXT = {
  connected = "Connected",
  connecting = "Connecting...",
  starting = "Starting the assistant...",
  disconnected = "Assistant not running",
}
```
- In `ChatWindow.new`, add `onNeedsBridge = function(reason) self:startBridge(reason) end,` to the `Connection.new{…}` options, and store `pluginPath = opts.pluginPath` on self.
- Add:
```lua
-- Starts the bundled bridge (at most once per 15s) and keeps trying to connect for 15s.
function ChatWindow:startBridge(reason)
  local now = os.clock()
  if self.lastStart and now - self.lastStart < 15 then return end
  self.lastStart = now
  local r = launcher.start(self.pluginPath or "", { preferred = self.opts.prefs.nodePath })
  if not r.ok then
    self.model:addLocalError(r.error, r.hint)
    self:repaint()
    return
  end
  if self.open then self.dlg:modify{ id = "status", text = STATUS_TEXT.starting } end
  local tries = 0
  self.startTimer = Timer{
    interval = 0.5,
    ontick = function()
      tries = tries + 1
      local info = Connection.readBridgeInfo(Connection.infoPath())
      if info then
        self.startTimer:stop()
        self.conn:connect()
      elseif tries >= 30 then
        self.startTimer:stop()
        self.model:addLocalError("The assistant's bridge didn't start.", "See " .. r.log .. ".")
        if self.open then self.dlg:modify{ id = "status", text = STATUS_TEXT.disconnected } end
        self:repaint()
      end
    end,
  }
  self.startTimer:start()
end
```
- In `close()`, add `if self.startTimer then self.startTimer:stop() end`.
- The "Not connected" local error hint becomes `"Press Reconnect; the assistant starts automatically."`.
- `plugin.lua` passes `pluginPath = plugin.path` in `ChatWindow.new{ prefs = plugin.preferences, pluginPath = plugin.path }`.

> `os.clock()` is CPU time, but it only has to increase between clicks. If it proves too coarse in the UI, the manual test notices double starts; switch to `os.time()` then.

- [ ] **Step 5: Run the tests, load check, commit**

Run: `scripts/test-lua.sh` (all pass) and the headless load check.
```bash
git add extension tests && git commit -m "feat(extension): start the bridge automatically when it's missing or stale"
```

---

### Task 4: Packaging, dev install, docs and license

**Files:**
- Create: `scripts/package.sh`, `scripts/test-package.sh`, `LICENSE`
- Modify: `scripts/dev-install.sh`, `extension/package.json`, `.gitignore`, `README.md`

- [ ] **Step 1: Write the failing check**

`scripts/test-package.sh`:
```bash
#!/usr/bin/env bash
# Builds the extension package and checks its contents and that the bundled bridge runs standalone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/package.sh" >/dev/null
PKG="$ROOT/dist/aseprite-agent-0.9.0.aseprite-extension"
[ -f "$PKG" ] || { echo "missing $PKG"; exit 1; }
LIST="$(unzip -l "$PKG")"
for f in package.json plugin.lua agent/chat_window.lua agent/tools/init.lua bridge/bridge.mjs LICENSE README.md; do
  echo "$LIST" | grep -q " $f\$" || { echo "package lacks $f"; exit 1; }
done
TMP="$(mktemp -d)"
unzip -q "$PKG" -d "$TMP"
[ "$(node "$TMP/bridge/bridge.mjs" --version)" = "0.9.0" ] || { echo "bundled bridge failed"; exit 1; }
grep -q '"version": "0.9.0"' "$TMP/package.json" || { echo "wrong extension version"; exit 1; }
echo "package OK"
```
`chmod +x scripts/test-package.sh`, then run it. Expected: it fails, because `scripts/package.sh` doesn't exist yet.

- [ ] **Step 2: Implement packaging**

`scripts/package.sh`:
```bash
#!/usr/bin/env bash
# Builds dist/aseprite-agent-<version>.aseprite-extension (extension + bundled bridge).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(node -p "require('$ROOT/extension/package.json').version")"
(cd "$ROOT/bridge" && npm run --silent bundle >/dev/null)
STAGE="$(mktemp -d)"
rsync -a --exclude bridge "$ROOT/extension/" "$STAGE/"
mkdir -p "$STAGE/bridge"
cp "$ROOT/bridge/dist/bridge.mjs" "$STAGE/bridge/bridge.mjs"
cp "$ROOT/LICENSE" "$ROOT/README.md" "$STAGE/"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/aseprite-agent-$VERSION.aseprite-extension"
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" .)
echo "$OUT"
```

`scripts/dev-install.sh`: after the `rsync` of `extension/`, add:
```bash
(cd "$ROOT/bridge" && npm run --silent bundle >/dev/null)
mkdir -p "$DEST/bridge"
cp "$ROOT/bridge/dist/bridge.mjs" "$DEST/bridge/bridge.mjs"
```
(and change the rsync to `rsync -a --delete --exclude bridge "$ROOT/extension/" "$DEST/"` so it doesn't delete the copied bundle).

`extension/package.json`: set `"version": "0.9.0"`.
`.gitignore`: add `dist/` (already present) and `extension/bridge/`.

`LICENSE`: the standard MIT license text, `Copyright (c) 2026 ermurray`.

`README.md`: replace the "Status" line and add:
````markdown
## Install

1. Install [Claude Code](https://claude.com/claude-code) and log in (run `claude` once in a terminal).
2. Install Node.js 20 or newer (nodejs.org, or `brew install node`).
3. Download `aseprite-agent-<version>.aseprite-extension` and open it with Aseprite
   (or Edit > Preferences > Extensions > Add Extension), then restart Aseprite.
4. Edit > Agent Chat (bind a key in Edit > Keyboard Shortcuts). The assistant starts by itself
   the first time; it stops after 15 minutes without an open chat window.

## What it does

An art assistant, not an art generator: critique and teaching, palette and color help, small approved
edits (one undo each), teaching marks, FX (dither, pixel-perfect, selout, gradients, normal maps),
tool setup, extension recommendations, scripts you approve, clips, imports and exports.
Projects (a folder with `.artproject/`) keep a brief, memory, palette and chat history.
````
Keep the existing Development section, and add `scripts/package.sh` to it.

- [ ] **Step 3: Run the checks**

Run: `scripts/test-package.sh` (expect `package OK`), `scripts/test-lua.sh`, and `cd bridge && npx vitest run && npm run typecheck`.

- [ ] **Step 4: Install and commit**

Run `scripts/dev-install.sh`. The installed copy now has `bridge/bridge.mjs`.
Stop the old manually started bridge (`kill <pid>`, and update `~/.claude/claude-running.md`), so that the extension's auto-start is what runs during the big test.
```bash
git add scripts LICENSE README.md extension/package.json .gitignore && git commit -m "build: package the extension with the bundled bridge; MIT license and install docs"
```

---

### Task 5: The big-test checklist

**Files:**
- Create: `docs/big-test.md`

- [ ] **Step 1:** Collect the manual checklists from Plans 1–6 (Plan 1 Task 8, Plan 2 Task 9, Plan 3 Tasks 6–8, Plan 4 Task 7, Plan 5 Task 6, and this plan's items below) into one ordered document with a checkbox per step, grouped as:
  1. Install and start
  2. Chat basics
  3. Edits and approvals
  4. Drafts
  5. Saved chats and slash commands
  6. Projects
  7. FX and maps
  8. Tools, extensions and scripts
  9. Clips, imports and exports

  Plan 6 items:
  - Install from `dist/aseprite-agent-0.9.0.aseprite-extension` via Preferences → Extensions, and restart. Agent Chat opens, the status shows "Starting the assistant...", then "Connected", with no terminal.
  - Quit Aseprite. Within 15 minutes, `~/.aseprite-agent/bridge.json` disappears and no `bridge.mjs` process remains (`ps aux | grep bridge.mjs`).
  - Kill the bridge while the window is open, then press Reconnect: it restarts automatically.
  - Temporarily rename `~/.nvm` (or set `ASEPRITE_AGENT_NODE=/usr/local/bin/node` to the v10 Node) to see the Node error, then restore it.
- [ ] **Step 2:** Commit: `git add docs/big-test.md && git commit -m "docs: the final big-test checklist"`.

---

## Self-Review Notes

- **Spec coverage:**
  - §11: the Start bridge button is now automatic start plus Reconnect.
  - §1: publishing (package, license, README).
  - Runtime requirements: Node 20+ and Claude Code, with clear errors when either is missing.
- **Deviations:**
  - Automatic start replaces a dedicated "Start bridge" button; Reconnect also triggers it.
  - Windows auto-start is deferred.
  - The SDK's bundled Claude binary isn't shipped; the installed `claude` is used instead.
