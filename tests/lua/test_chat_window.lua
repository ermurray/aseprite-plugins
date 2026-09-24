local T = require("testlib")
local ChatWindow = require("agent.chat_window")

-- A window with the dialog and connection stubbed out, so window logic runs headless.
local function stubbed(prefs)
  local w = ChatWindow.new{ prefs = prefs or {} }
  w.sent = {}
  w.conn.send = function(_, msg) w.sent[#w.sent + 1] = msg end
  w.conn.status = "disconnected"
  w.open = false
  return w
end

T.test("New chat while disconnected forgets the old conversation, so reconnecting doesn't restore it", function()
  local prefs = { conversationId = "old-chat" }
  local w = stubbed(prefs)
  w.model:addUser("hi")
  w:newChat()
  T.eq(prefs.conversationId, nil)
  T.eq(#w.model.items, 0)
end)

T.test("hidden-window tip after a cancelled turn stays quiet", function()
  local tips = {}
  local realTip = ChatWindow.showTip
  ChatWindow.showTip = function(text) tips[#tips + 1] = text end
  local w = stubbed()
  w.busy = true
  w.model:addUser("q")
  w.model:appendAgent("partial")
  w.cancelRequested = true
  w:onMessage{ type = "turn_done" }
  T.eq(#tips, 0)
  w.busy = true
  w.cancelRequested = false
  w.model:addUser("q2")
  w.model:appendAgent("full answer")
  w:onMessage{ type = "turn_done" }
  T.eq(tips[1], "Agent replied - open Agent Chat to read it")
  ChatWindow.showTip = realTip
end)
