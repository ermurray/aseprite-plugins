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

local F = require("fixtures")
local project = require("agent.project")
local sprites = require("agent.tools.sprites")
local prefs = require("agent.prefs")

local root = app.fs.joinPath(F.tmp, "window proj " .. os.time())
app.fs.makeAllDirectories(root)
project.create(root, {})

T.test("switching to a sprite in another project asks the bridge for that project's chat", function()
  F.closeAll()
  local p = {}
  prefs.setConversation(p, root, "proj-chat")
  local w = stubbed(p)
  w.conn.status = "connected"
  local s = Sprite(2, 2)
  s:saveAs(app.fs.joinPath(root, "a.aseprite"))
  app.sprite = s
  w:onSiteChange()
  T.eq(w.projectRoot, root)
  T.eq(sprites.projectRoot, root)
  T.deepEq(w.sent[#w.sent], { type = "open_project", projectRoot = root, conversationId = "proj-chat" })
  local before = #w.sent
  w:onSiteChange()
  T.eq(#w.sent, before, "same project: nothing sent")
  sprites.projectRoot = nil
end)

T.test("an unsaved sprite keeps the current project", function()
  F.closeAll()
  local w = stubbed({})
  w:setProject(root)
  app.sprite = Sprite(2, 2)
  w:onSiteChange()
  T.eq(w.projectRoot, root)
  sprites.projectRoot = nil
end)

T.test("ready and conversation messages remember the chat per project", function()
  local p = {}
  local w = stubbed(p)
  w:onMessage{ type = "conversation", conversationId = "c9", projectRoot = root, projectName = "x", history = json.decode("[]") }
  T.eq(prefs.getConversation(p, root), "c9")
  w.projectRoot = root
  w:newChat()
  T.eq(prefs.getConversation(p, root), nil)
end)

T.test("sending a message attaches the context and the attach flag, then clears the flag", function()
  F.closeAll()
  local w = stubbed({})
  w.conn.status = "connected"
  w.attachNext = true
  w.dlg = { data = { input = "what do you think?" }, modify = function() end, repaint = function() end }
  app.sprite = Sprite(2, 2)
  w:onSendOrStop()
  local msg = w.sent[#w.sent]
  T.eq(msg.type, "user_message")
  T.eq(msg.attach, true)
  T.eq(type(msg.context.openSprites), "table")
  T.eq(w.attachNext, false)
end)
