local launcher = require("agent.launcher")

local Connection = {}
Connection.__index = Connection

local VERSION = "0.9.0"

function Connection.infoPath()
  local home = os.getenv("ASEPRITE_AGENT_HOME")
    or app.fs.joinPath(os.getenv("HOME") or os.getenv("USERPROFILE") or "", ".aseprite-agent")
  return app.fs.joinPath(home, "bridge.json")
end

-- Aseprite's json.decode returns userdata (indexable), not Lua tables, even for
-- top-level strings; so check for the fields we need instead of type(x) == "table".
local function decodeObject(raw, requiredField)
  local ok, value = pcall(function()
    local v = json.decode(raw)
    if (type(v) == "table" or type(v) == "userdata") and type(v[requiredField]) == "string" then return v end
  end)
  return ok and value or nil
end

function Connection.decodeMessage(raw)
  return decodeObject(raw, "type")
end

function Connection.readBridgeInfo(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("a")
  f:close()
  local info = decodeObject(raw, "token")
  if info and info.port then return info end
  return nil
end

function Connection.new(opts)
  return setmetatable({ opts = opts, ws = nil, token = nil, status = "disconnected" }, Connection)
end

function Connection:setStatus(status, detail)
  self.status = status
  self.opts.onStatus(status, detail)
end

function Connection:connect()
  self:close()
  local path = Connection.infoPath()
  local info = Connection.readBridgeInfo(path)
  if not info then
    self:setStatus("disconnected", "Assistant not running")
    if self.opts.onNeedsBridge then self.opts.onNeedsBridge("missing") end
    return false
  end
  if info.pid and not launcher.isBridgePid(info.pid) then
    os.remove(path)
    self:setStatus("disconnected", "Assistant not running")
    if self.opts.onNeedsBridge then self.opts.onNeedsBridge("stale") end
    return false
  end
  self.token = info.token
  self.port = info.port
  self.opened = false
  self:setStatus("connecting")
  local ws
  ws = WebSocket{
    url = "ws://127.0.0.1:" .. math.tointeger(info.port),
    deflate = false,
    minreconnectwait = 1,
    maxreconnectwait = 10,
    onreceive = function(kind, data, err) return self:handlerFor(ws)(kind, data, err) end,
  }
  self.ws = ws
  ws:connect()
  return true
end

-- Events are only handled for the current socket: a replaced socket's late
-- CLOSE must not mark the new connection as disconnected.
function Connection:handlerFor(ws)
  return function(kind, data, err)
    if self.ws == ws then self:onReceive(kind, data, err) end
  end
end

function Connection:onReceive(kind, data, err)
  if kind == WebSocketMessageType.OPEN then
    self.opened = true
    -- Re-read the token on every (re)connect: a restarted bridge has a new one.
    local info = Connection.readBridgeInfo(Connection.infoPath())
    if info then self.token = info.token end
    local fields = self.opts.helloFields and self.opts.helloFields() or {}
    self:send{
      type = "hello",
      token = self.token,
      extensionVersion = VERSION,
      projectRoot = fields.projectRoot,
      conversationId = fields.conversationId,
    }
  elseif kind == WebSocketMessageType.TEXT then
    local msg = Connection.decodeMessage(data)
    if msg then
      if msg.type == "ready" then self:setStatus("connected") end
      self.opts.onMessage(msg)
    end
  elseif (kind == WebSocketMessageType.CLOSE or (WebSocketMessageType.ERROR ~= nil and kind == WebSocketMessageType.ERROR))
    and self.opened == false then
    -- Never reached the bridge: whatever bridge.json points at is gone. Stop dialing it and start fresh.
    local info = Connection.readBridgeInfo(Connection.infoPath())
    if info and self.port and math.tointeger(info.port) == math.tointeger(self.port) then os.remove(Connection.infoPath()) end
    self:close()
    self:setStatus("disconnected", err)
    if self.opts.onNeedsBridge then self.opts.onNeedsBridge("unreachable") end
  elseif kind == WebSocketMessageType.CLOSE then
    self:setStatus("disconnected", err)
  elseif WebSocketMessageType.ERROR ~= nil and kind == WebSocketMessageType.ERROR then
    self:setStatus("disconnected", err)
  end
end

function Connection:send(tbl)
  if self.ws then self.ws:sendText(json.encode(tbl)) end
end

function Connection:close()
  if self.ws then
    self.ws:close()
    self.ws = nil
  end
end

return Connection
