local T = require("testlib")
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
