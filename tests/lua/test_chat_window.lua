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

local root = F.unique("window proj ")
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
  w.dlg = { data = {}, modify = function() end, repaint = function() end }
  w.input:setText("what do you think?")
  app.sprite = Sprite(2, 2)
  w:onSendOrStop()
  local msg = w.sent[#w.sent]
  T.eq(msg.type, "user_message")
  T.eq(msg.attach, true)
  T.eq(type(msg.context.openSprites), "table")
  T.eq(w.attachNext, false)
end)

T.test("a saved sprite outside any project shows the setup hint once; a project clears it", function()
  F.closeAll()
  local w = stubbed({})
  local outside = F.unique("loose ")
  app.fs.makeAllDirectories(outside)
  local s = Sprite(2, 2)
  s:saveAs(app.fs.joinPath(outside, "loose.aseprite"))
  app.sprite = s
  w:maybeShowSetupHint()
  w:maybeShowSetupHint()
  local hints = 0
  for _, it in ipairs(w.model.items) do if it.kind == "setup" then hints = hints + 1 end end
  T.eq(hints, 1)
  w:setProject(root)
  for _, it in ipairs(w.model.items) do T.eq(it.kind ~= "setup", true) end
  sprites.projectRoot = nil
end)

T.test("finishSetup switches to the new project and brings the current chat along", function()
  local p = {}
  prefs.setConversation(p, nil, "loose-chat")
  local w = stubbed(p)
  w.conn.status = "connected"
  w.model:addUser("earlier")
  w:finishSetup(root, true)
  T.eq(w.projectRoot, root)
  T.deepEq(w.sent[#w.sent], { type = "open_project", projectRoot = root, adoptConversationId = "loose-chat" })
  T.eq(w.model.items[#w.model.items].kind, "notice")
  w:finishSetup(root, false)
  T.eq(w.sent[#w.sent].adoptConversationId, nil)
  sprites.projectRoot = nil
end)

T.test("while Claude is busy, a tab switch waits for the bridge before tools change project", function()
  F.closeAll()
  local w = stubbed({})
  w.conn.status = "connected"
  w.busy = true
  local s = Sprite(2, 2)
  s:saveAs(app.fs.joinPath(root, "busy.aseprite"))
  app.sprite = s
  w:onSiteChange()
  T.eq(w.sent[#w.sent].type, "open_project")
  T.eq(sprites.projectRoot, nil, "tools keep resolving against the old project")
  w:onMessage{ type = "conversation", conversationId = "c1", projectRoot = root, projectName = "p", history = json.decode("[]") }
  T.eq(sprites.projectRoot, root)
  T.eq(w.projectRoot, root)
  sprites.projectRoot = nil
end)

T.test("reference tabs outside the project don't switch the chat away", function()
  F.closeAll()
  local w = stubbed({})
  w:setProject(root)
  local elsewhere = F.unique("refs ")
  app.fs.makeAllDirectories(elsewhere)
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(elsewhere, "ref.png"))
  app.sprite = ref
  w:onSiteChange()
  T.eq(w.projectRoot, root)
  sprites.projectRoot = nil
end)

T.test("the setup hint survives the bridge's conversation reply", function()
  F.closeAll()
  local w = stubbed({})
  local loose = F.unique("loose2 ")
  app.fs.makeAllDirectories(loose)
  local s = Sprite(2, 2)
  s:saveAs(app.fs.joinPath(loose, "l.aseprite"))
  app.sprite = s
  w:onSiteChange()
  w:onMessage{ type = "conversation", conversationId = "g", projectName = "No project", history = json.decode("[]") }
  local hint = false
  for _, it in ipairs(w.model.items) do if it.kind == "setup" then hint = true end end
  T.eq(hint, true)
end)

T.test("the Clips button explains that clips need a project", function()
  local tips = {}
  local real = ChatWindow.showTip
  ChatWindow.showTip = function(t) tips[#tips + 1] = t end
  local w = stubbed({})
  w.projectRoot = nil
  w:showClips()
  T.eq(tips[1], "Clips are kept in a project. Press Set up project first.")
  ChatWindow.showTip = real
end)

T.test("startBridge reports a missing Node clearly, and a failed start can be retried at once", function()
  local launcher = require("agent.launcher")
  local realStart = launcher.start
  local calls = 0
  launcher.start = function() calls = calls + 1; return { ok = false, error = "Node.js 20 or newer is needed to run the assistant.", hint = "Install it" } end
  local w = stubbed({})
  w.pluginPath = "/nowhere"
  w:startBridge("missing")
  w:startBridge("missing")
  T.eq(calls, 2, "a failed start isn't throttled, so installing Node then pressing Reconnect works")
  T.eq(w.model.items[#w.model.items].text, "Node.js 20 or newer is needed to run the assistant.\nInstall it")
  launcher.start = realStart
end)

T.test("startBridge throttles by wall time, says so, and never leaves two timers running", function()
  local launcher = require("agent.launcher")
  local realStart, realNow = launcher.start, ChatWindow.now
  local calls, t = 0, 1000
  launcher.start = function() calls = calls + 1; return { ok = true, log = "/tmp/x.log" } end
  ChatWindow.now = function() return t end
  local w = stubbed({})
  w:startBridge("missing")
  local first = w.startTimer
  w:startBridge("missing")
  T.eq(calls, 1)
  T.eq(w.model.items[#w.model.items].text, "Still starting the assistant...")
  t = t + 20
  w:startBridge("missing")
  T.eq(calls, 2, "allowed again after 15 seconds of wall time")
  T.eq(first.isRunning, false, "the older poll timer is stopped")
  w.startTimer:stop()
  launcher.start, ChatWindow.now = realStart, realNow
end)

T.test("Enter in the input box sends and clears it; Shift+Enter keeps typing", function()
  F.closeAll()
  local w = stubbed({})
  w.conn.status = "connected"
  w.dlg = { data = {}, modify = function() end, repaint = function() end }
  local stopped = 0
  local function ev(code, key, mods)
    local e = { code = code, key = key or "", stopPropagation = function() stopped = stopped + 1 end }
    for k, v in pairs(mods or {}) do e[k] = v end
    return e
  end
  w:onInputKey(ev("Key", "h"))
  w:onInputKey(ev("Key", "i"))
  w:onInputKey(ev("Enter", "", { shiftKey = true }))
  w:onInputKey(ev("Key", "x"))
  T.eq(w.input.text, "hi\nx")
  w:onInputKey(ev("Enter"))
  T.eq(w.sent[#w.sent].type, "user_message")
  T.eq(w.sent[#w.sent].text, "hi\nx")
  T.eq(w.input.text, "", "cleared after sending")
  T.eq(stopped, 5, "every handled key is kept away from Aseprite's shortcuts")
  w:onInputKey(ev("KeyZ", "z", { metaKey = true }))
  T.eq(stopped, 5, "Cmd+Z still reaches Aseprite")
end)
