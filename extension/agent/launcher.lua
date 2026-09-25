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
