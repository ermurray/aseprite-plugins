local T = require("testlib")
local F = require("fixtures")
local Connection = require("agent.connection")

T.test("readBridgeInfo parses bridge.json written by the bridge", function()
  local dir = app.fs.joinPath(app.fs.tempPath, "aseagent-tests")
  app.fs.makeAllDirectories(dir)
  local p = app.fs.joinPath(dir, "bridge.json")
  local f = io.open(p, "w")
  f:write('{"port":47821,"token":"abc","pid":1}')
  f:close()
  local info = Connection.readBridgeInfo(p)
  T.eq(info ~= nil, true, "info should parse")
  T.eq(math.tointeger(info.port), 47821)
  T.eq(info.token, "abc")
  T.eq(Connection.readBridgeInfo(app.fs.joinPath(dir, "missing.json")), nil)
end)

T.test("decodeMessage accepts object messages and rejects others", function()
  local m = Connection.decodeMessage('{"type":"ready","adapter":"claude-code"}')
  T.eq(m ~= nil, true)
  T.eq(m.type, "ready")
  T.eq(Connection.decodeMessage('"just a string"'), nil)
  T.eq(Connection.decodeMessage("{bad"), nil)
end)

T.test("events from a replaced socket are ignored", function()
  local statuses = {}
  local c = Connection.new{ onMessage = function() end, onStatus = function(s) statuses[#statuses + 1] = s end }
  local old, new = {}, {}
  local oldHandler = c:handlerFor(old)
  c.ws = new
  c.status = "connected"
  oldHandler(WebSocketMessageType.CLOSE, "", "closed")
  T.eq(c.status, "connected")
  T.eq(#statuses, 0)
  c:handlerFor(new)(WebSocketMessageType.CLOSE, "", "closed")
  T.eq(c.status, "disconnected")
end)

T.test("hello carries the project and the conversation to resume", function()
  local sent = {}
  local c = Connection.new{
    onMessage = function() end,
    onStatus = function() end,
    helloFields = function() return { projectRoot = "/art/game", conversationId = "conv-1" } end,
  }
  c.token = "tok"
  c.send = function(_, msg) sent[#sent + 1] = msg end
  c:onReceive(WebSocketMessageType.OPEN, "", nil)
  T.eq(sent[1].type, "hello")
  T.eq(sent[1].projectRoot, "/art/game")
  T.eq(sent[1].conversationId, "conv-1")
end)

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

T.test("a live pid that isn't the bridge counts as stale", function()
  local home = F.unique("agent home2")
  app.fs.makeAllDirectories(home)
  local asked = {}
  local c = Connection.new{ onMessage = function() end, onStatus = function() end, onNeedsBridge = function(r) asked[#asked + 1] = r end }
  local realPath = Connection.infoPath
  Connection.infoPath = function() return app.fs.joinPath(home, "bridge.json") end
  local p = io.popen("echo $PPID"); local aseprite = p:read("l"); p:close()
  local f = io.open(app.fs.joinPath(home, "bridge.json"), "w")
  f:write('{"port":47998,"token":"t","pid":' .. aseprite .. '}'); f:close()
  T.eq(c:connect(), false)
  T.eq(asked[1], "stale")
  Connection.infoPath = realPath
end)

T.test("a socket that closes before it ever opened asks for a new bridge", function()
  local asked = {}
  local c = Connection.new{ onMessage = function() end, onStatus = function() end, onNeedsBridge = function(r) asked[#asked + 1] = r end }
  c.opened = false
  c:onReceive(WebSocketMessageType.CLOSE, "", "refused")
  T.eq(asked[1], "unreachable")
  c.opened = true
  c:onReceive(WebSocketMessageType.CLOSE, "", "bye")
  T.eq(#asked, 1, "a normal disconnect after OPEN just reconnects")
end)
