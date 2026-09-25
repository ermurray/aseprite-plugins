local ChatModel = require("agent.chat_model")
local render = require("agent.chat_render")
local Connection = require("agent.connection")
local tools = require("agent.tools")
local inspect = require("agent.tools.inspect")
local project = require("agent.project")
local prefs = require("agent.prefs")
local context = require("agent.context")
local sprites = require("agent.tools.sprites")
local palettes = require("agent.palettes")
local clips = require("agent.clips")
local edit = require("agent.tools.edit")

local ChatWindow = {}
ChatWindow.__index = ChatWindow

local PAD, GAP = 6, 8
local STATUS_TEXT = {
  connected = "Connected",
  connecting = "Connecting...",
  disconnected = "Bridge not running - start it with: cd bridge && npm start",
}
local COLORS = {
  user_label = Color{ r = 110, g = 160, b = 255 },
  agent_label = Color{ r = 120, g = 200, b = 140 },
  activity = Color{ r = 140, g = 140, b = 140 },
  thinking = Color{ r = 140, g = 140, b = 140 },
  notice = Color{ r = 140, g = 140, b = 140 },
  setup = Color{ r = 240, g = 180, b = 80 },
  approval_label = Color{ r = 240, g = 180, b = 80 },
  approval_state = Color{ r = 140, g = 140, b = 140 },
  error = Color{ r = 230, g = 90, b = 80 },
}

local function themeColor(name, fallback)
  local ok, c = pcall(function() return app.theme.color[name] end)
  return (ok and c) or fallback
end

-- Status-bar message (replaceable in tests; Aseprite's app table can't be patched).
function ChatWindow.showTip(text)
  pcall(app.tip, text, 8)
end

function ChatWindow.new(opts)
  local self = setmetatable({
    opts = opts,
    model = ChatModel.new(),
    scroll = 0,
    followTail = true,
    busy = false,
    agentLabel = "Agent",
    viewH = 0,
    contentH = 0,
    lineH = 14,
    open = false,
    autoApprove = false,
    projectRoot = nil,
    projectName = "No project",
    attachNext = false,
    tick = 0,
  }, ChatWindow)
  self.unlockTimer = Timer{
    interval = 0.4,
    ontick = function()
      self.unlockTimer:stop()
      self.model:unlockApply()
      self:syncButtons()
    end,
  }
  self.timer = Timer{
    interval = 0.12,
    ontick = function()
      self.tick = self.tick + 1
      self:repaint()
    end,
  }
  self.conn = Connection.new{
    onMessage = function(m) self:onMessage(m) end,
    onStatus = function(s, d) self:onStatus(s, d) end,
    helloFields = function()
      return { projectRoot = self.projectRoot, conversationId = prefs.getConversation(self.opts.prefs, self.projectRoot) }
    end,
  }
  self:setProject(project.findRoot(app.sprite and app.sprite.filename), true)
  self.siteListener = app.events:on("sitechange", function() self:onSiteChange() end)
  return self
end

function ChatWindow:build()
  local dlg = Dialog{
    title = "Agent Chat",
    resizeable = true,
    onclose = function() self:onClosed() end,
  }
  dlg:label{ id = "project", text = "No project" }
  dlg:button{
    id = "makeproject",
    text = "Set up project",
    onclick = function()
      if self.projectRoot then self:projectSettings() else self:setupProject() end
    end,
  }
  dlg:button{ id = "history", text = "History", onclick = function() self.conn:send{ type = "list_history" } end }
  dlg:button{ id = "clips", text = "Clips", onclick = function() self:showClips() end }
  dlg:newrow()
  dlg:label{ id = "status", text = STATUS_TEXT.disconnected }
  dlg:newrow()
  dlg:button{ id = "connect", text = "Reconnect", onclick = function() self.conn:connect() end }
  dlg:button{ id = "newchat", text = "New chat", onclick = function() self:newChat() end }
  dlg:newrow()
  dlg:canvas{
    id = "history",
    width = 360,
    height = 420,
    hexpand = true,
    vexpand = true,
    onpaint = function(ev) self:paint(ev.context) end,
    onwheel = function(ev) self:scrollBy(ev.deltaY * 3 * self.lineH) end,
  }
  dlg:newrow()
  dlg:button{ id = "apply", text = "Apply", visible = false, onclick = function() self:answerApproval(true) end }
  dlg:check{
    id = "autoapprove",
    text = "Auto-approve edits",
    selected = self.autoApprove,
    onclick = function()
      self.autoApprove = self.dlg.data.autoapprove
      self.conn:send{ type = "set_auto_approve", enabled = self.autoApprove }
    end,
  }
  dlg:check{
    id = "allowdrafts",
    text = "Allow AI drafts",
    selected = self.opts.prefs.allowDrafts == true,
    onclick = function()
      self.opts.prefs.allowDrafts = self.dlg.data.allowdrafts
      self.conn:send{ type = "set_draft_mode", enabled = self.opts.prefs.allowDrafts }
    end,
  }
  dlg:newrow()
  dlg:check{ id = "attach", text = "Attach view", selected = self.attachNext, onclick = function() self.attachNext = self.dlg.data.attach end }
  dlg:newrow()
  dlg:entry{ id = "input", hexpand = true }
  dlg:button{ id = "send", text = "Send", focus = true, onclick = function() self:onSendOrStop() end }
  self.dlg = dlg
end

-- Closing the window only hides it: the chat and the bridge connection live on
-- until New chat or Aseprite quits, so reopening brings the conversation back.
function ChatWindow:show()
  if not self.open then
    self:build()
    self.open = true
    local b = self.opts.prefs.bounds
    if b then
      self.dlg:show{ wait = false, bounds = Rectangle(b.x, b.y, b.w, b.h) }
    else
      self.dlg:show{ wait = false }
    end
    self.dlg:modify{ id = "status", text = STATUS_TEXT[self.conn.status] or self.conn.status }
    self:syncButtons()
    self:syncProjectHeader()
    self:maybeShowSetupHint()
  end
  if self.conn.status == "disconnected" then self.conn:connect() end
end

-- Where tools resolve sprites and what the header shows.
function ChatWindow:setProjectLocal(root)
  self.projectRoot = root
  sprites.projectRoot = root
  self.projectName = root and app.fs.fileName(root) or "No project"
  self:syncProjectHeader()
  self:maybeShowSetupHint()
end

function ChatWindow:setProject(root, silent)
  -- While Claude is replying, the bridge finishes the reply in the old project first, so tools
  -- keep resolving there too; the switch happens when the bridge's conversation message arrives.
  self.pendingRoot = root
  if not (self.busy and self.conn.status == "connected") then self:setProjectLocal(root) end
  if not silent and self.conn.status == "connected" then
    self.conn:send{ type = "open_project", projectRoot = root, conversationId = prefs.getConversation(self.opts.prefs, root) }
  end
end

local SETUP_HINT = "This sprite isn't part of a project yet. A project keeps your brief, shared memory and chat history, and lets Claude see every sprite in the folder. Press Set up project to create one."

function ChatWindow:maybeShowSetupHint()
  if self.projectRoot then
    self.model:clearSetupHint()
  elseif app.sprite then
    self.model:showSetupHint(SETUP_HINT)
  end
  self:repaint()
end

-- Follow the artist's tabs: a saved sprite decides the project; unsaved sprites keep it.
function ChatWindow:onSiteChange()
  local s = app.sprite
  if not s or app.fs.filePath(s.filename) == "" then return end
  local ext = app.fs.fileExtension(s.filename):lower()
  if ext ~= "aseprite" and ext ~= "ase" then return end -- reference images don't pick the project
  local root = project.findRoot(s.filename)
  if root ~= (self.pendingRoot or self.projectRoot) then self:setProject(root) end
end

function ChatWindow:syncProjectHeader()
  if not self.open then return end
  self.dlg:modify{ id = "project", text = self.projectRoot and ("Project: " .. self.projectName) or "No project" }
  self.dlg:modify{ id = "makeproject", text = self.projectRoot and "Project settings" or "Set up project" }
end

-- Hotkey behaviour: hide if open, show if hidden. Hiding keeps the chat, the bridge
-- connection and Claude's session, exactly like closing the window.
function ChatWindow:toggle()
  if self.open then
    self.dlg:close()
  else
    self:show()
  end
end

-- Full shutdown (extension unload).
function ChatWindow:close()
  self.timer:stop()
  self.unlockTimer:stop()
  self.conn:close()
  pcall(function() app.events:off(self.siteListener) end)
  if self.open then self.dlg:close() end
end

function ChatWindow:onClosed()
  local b = self.dlg.bounds
  self.opts.prefs.bounds = { x = b.x, y = b.y, w = b.width, h = b.height }
  self.open = false
end

function ChatWindow:repaint()
  if self.open then self.dlg:repaint() end
end

function ChatWindow:setBusy(busy)
  self.busy = busy
  if busy then
    self.tick = 0
    self.timer:start()
  else
    self.timer:stop()
  end
  self:syncButtons()
end

function ChatWindow:mainButtonText()
  if self.model:pendingApproval() then return "Deny" end
  return self.busy and "Stop" or "Send"
end

function ChatWindow:syncButtons()
  if not self.open then return end
  self.dlg:modify{ id = "send", text = self:mainButtonText() }
  self.dlg:modify{ id = "apply", visible = self.model:applyAvailable() }
end

function ChatWindow:answerApproval(approved)
  if approved and not self.model:applyAvailable() then return end
  local item = self.model:answerPending(approved)
  if not item then return end
  self.conn:send{ type = "approval", approvalId = item.id, approved = approved }
  if self.model.applyLocked then self.unlockTimer:start() end
  self:syncButtons()
  self:repaint()
end

function ChatWindow:onSendOrStop()
  local text = (self.dlg.data.input or ""):match("^%s*(.-)%s*$")
  local action = ChatModel.sendAction(self.busy, text, self.model:pendingApproval() ~= nil)
  if action == "deny" then
    self:answerApproval(false)
    return
  elseif action == "stop" then
    self.cancelRequested = true
    self.conn:send{ type = "cancel" }
    return
  elseif action == "reject_busy" then
    self.model:addLocalError("Still working on the previous message.", "Wait for it to finish, or clear the box and press Stop.")
    self:repaint()
    return
  elseif action == "ignore" then
    return
  end
  if self.conn.status ~= "connected" then
    self.model:addLocalError("Not connected to the bridge.", "Start it with: cd bridge && npm start, then press Reconnect.")
    self:repaint()
    return
  end
  self.model:addUser(text)
  self.cancelRequested = false
  self.followTail = true
  self.dlg:modify{ id = "input", text = "" }
  self.conn:send{ type = "user_message", text = text, context = context.build(self.projectRoot), attach = self.attachNext or nil }
  self.attachNext = false
  if self.open then self.dlg:modify{ id = "attach", selected = false } end
  self:setBusy(true)
  self:repaint()
end

function ChatWindow:newChat()
  if self.busy then self.conn:send{ type = "cancel" } end
  self.conn:send{ type = "new_chat" }
  -- Forget the old conversation locally too: if this New chat never reached the bridge
  -- (disconnected), reconnecting must not bring the old chat back.
  prefs.setConversation(self.opts.prefs, self.projectRoot, nil)
  self.model:clear()
  self:syncButtons()
  self.scroll = 0
  self.followTail = true
  self:setBusy(false)
  self:repaint()
end

function ChatWindow:onStatus(status, detail)
  if self.open then self.dlg:modify{ id = "status", text = STATUS_TEXT[status] or status } end
  if status == "disconnected" and self.busy then
    self.model:addLocalError("Lost connection to the bridge.", detail)
    self.model:endTurn()
    self:setBusy(false)
    self:repaint()
  end
end

function ChatWindow:onMessage(m)
  if not self.open then
    local replied = m.type == "turn_done" and not self.cancelRequested and self.model:lastTurnReplied()
    local tip = ChatModel.hiddenTip(m.type, self.agentLabel, replied)
    if tip then ChatWindow.showTip(tip) end
  end
  if m.type == "ready" or m.type == "conversation" then
    -- The bridge's project is authoritative (it may have rejected a root, or finished a deferred switch).
    local root = m.projectRoot
    if type(root) ~= "string" then root = nil end
    prefs.setConversation(self.opts.prefs, root, m.conversationId)
    self.pendingRoot = nil
    self:setProjectLocal(root)
    if m.history then self.model:loadHistory(m.history, { dropLocal = m.type == "conversation" }) end
    self:maybeShowSetupHint()
    self.followTail = true
    self:syncButtons()
  end
  if m.type == "ready" then
    inspect.snapshotDir = m.snapshotDir
    self.agentLabel = (m.adapter == "claude-code") and "Claude" or tostring(m.adapter)
    self.conn:send{ type = "set_auto_approve", enabled = self.autoApprove }
    self.conn:send{ type = "set_draft_mode", enabled = self.opts.prefs.allowDrafts == true }
  elseif m.type == "history_list" then
    self:showHistory(m.items)
  elseif m.type == "approval_request" then
    self.model:addApproval(m.approvalId, m.summary)
    self:syncButtons()
  elseif m.type == "text_delta" then
    self.model:appendAgent(m.text)
  elseif m.type == "tool_activity" then
    self.model:addActivity(m.summary)
  elseif m.type == "notice" then
    self.model:addNotice(m.text)
  elseif m.type == "tool_call" then
    local res = tools.dispatch(m.name, m.args)
    self.conn:send{ type = "tool_result", callId = m.callId, ok = res.ok, data = res.data, error = res.error }
    if res.ok then app.refresh() end
  elseif m.type == "turn_done" then
    self.model:endTurn()
    self:setBusy(false)
    self:syncButtons()
  elseif m.type == "error" then
    self.model:addError(m.message, m.hint)
  end
  self:repaint()
end

function ChatWindow:scrollBy(dy)
  self.scroll = render.clampScroll(self.scroll + dy, self.contentH, self.viewH)
  self.followTail = self.scroll >= self.contentH - self.viewH - 2
  self:repaint()
end

function ChatWindow:paint(gc)
  self.lineH = gc:measureText("Ag").height + 3
  local lay = render.layout(self.model.items, {
    width = gc.width - 2 * PAD - 6,
    measure = function(s) return gc:measureText(s).width end,
    lineHeight = self.lineH,
    gap = GAP,
    agentLabel = self.agentLabel,
    thinking = (self.busy and not self.model:pendingApproval()) and (self.tick // 3) or nil,
  })
  self.viewH = gc.height
  self.contentH = lay.height + 2 * PAD
  if self.followTail then self.scroll = self.contentH - self.viewH end
  self.scroll = render.clampScroll(self.scroll, self.contentH, self.viewH)

  gc.color = themeColor("window_face", Color{ r = 40, g = 40, b = 48 })
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))

  local textColor = themeColor("text", Color{ r = 230, g = 230, b = 230 })
  for _, line in ipairs(lay.lines) do
    local y = PAD + line.y - self.scroll
    if y > -self.lineH and y < gc.height then
      gc.color = COLORS[line.kind] or textColor
      gc:fillText(line.text, PAD, y)
      if line.kind == "thinking" then
        self:paintSpinner(gc, PAD + gc:measureText(render.thinkingText(self.agentLabel, 3)).width + 8, y + self.lineH // 2 - 2)
      end
    end
  end

  if self.contentH > self.viewH then
    local barH = math.max(20, self.viewH * self.viewH / self.contentH)
    local barY = (self.viewH - barH) * self.scroll / (self.contentH - self.viewH)
    gc.color = Color{ r = 128, g = 128, b = 128, a = 140 }
    gc:fillRect(Rectangle(gc.width - 5, barY, 4, barH))
  end
end

-- Eight pixel dots in a ring; the bright one walks around with the timer tick.
local RING = { { 0, -4 }, { 3, -3 }, { 4, 0 }, { 3, 3 }, { 0, 4 }, { -3, 3 }, { -4, 0 }, { -3, -3 } }

function ChatWindow:paintSpinner(gc, cx, cy)
  local head = self.tick % #RING
  for i, p in ipairs(RING) do
    local age = (head - (i - 1)) % #RING
    gc.color = Color{ r = 120, g = 200, b = 140, a = math.max(40, 255 - age * 40) }
    gc:fillRect(Rectangle(cx + p[1], cy + p[2], 2, 2))
  end
end

function ChatWindow:showHistory(items)
  if #items == 0 then
    ChatWindow.showTip("No saved chats in " .. self.projectName .. " yet")
    return
  end
  local labels, ids = {}, {}
  for i = 1, #items do
    local it = items[i]
    local label = tostring(it.updatedAt):sub(1, 16):gsub("T", " ") .. "  " .. render.displayText(tostring(it.title))
    labels[#labels + 1] = label
    ids[label] = tostring(it.id)
  end
  local d = Dialog{ title = "Chats in " .. self.projectName }
  d:combobox{ id = "chat", options = labels, option = labels[1] }
  d:button{ id = "open", text = "Open", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()
  if d.data.open then self.conn:send{ type = "open_conversation", conversationId = ids[d.data.chat] } end
end

function ChatWindow:setupProject()
  local s = app.sprite
  if not s then
    ChatWindow.showTip("Open or create a sprite first: the project is made around its folder")
    return
  end
  if app.fs.filePath(s.filename) == "" then
    ChatWindow.showTip("Save the sprite first: choose where your project will live")
    app.command.SaveFileAs()
    if app.fs.filePath(s.filename) == "" then return end
  end
  local folders = project.ancestors(s.filename, 5)
  local hasChat = #self.model.items > 0
  local d = Dialog{ title = "Set up project" }
  d:label{ text = "Everything in this folder becomes one project. Answers are optional; you can edit brief.md any time." }
  d:combobox{ id = "root", label = "Project folder", options = folders, option = folders[1] }
  d:entry{ id = "resolution", label = "Sprite size", text = "" }
  d:entry{ id = "palette", label = "Palette", text = "" }
  d:entry{ id = "outline", label = "Outline style", text = "" }
  d:entry{ id = "light", label = "Light direction", text = "" }
  d:entry{ id = "notes", label = "Notes", text = "" }
  local palLabels, palEntries = self:paletteChoices(s)
  d:combobox{ id = "palette", label = "Palette", options = palLabels, option = palLabels[1] }
  d:check{ id = "applypalette", text = "Apply the palette to this sprite", selected = false }
  d:check{ id = "adopt", text = "Bring this chat into the project", selected = hasChat, visible = hasChat }
  d:button{ id = "ok", text = "Create project", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()
  if not d.data.ok then return end
  local entry = palEntries[d.data.palette]
  local pal = entry and palettes.load(entry, s)
  local brief = {
    resolution = d.data.resolution,
    palette = entry and palettes.describe(entry, pal, s) or "",
    outline = d.data.outline,
    light = d.data.light,
    notes = d.data.notes,
  }
  local ok, err = pcall(project.create, d.data.root, brief)
  if not ok then
    self.model:addLocalError("Couldn't set up the project.", tostring(err))
    self:repaint()
    return
  end
  if pal then
    project.savePalette(d.data.root, pal)
    if d.data.applypalette then self:applyPalette(s, pal) end
  end
  self:finishSetup(project.findRoot(s.filename), hasChat and d.data.adopt)
end

-- Palette dropdown entries: labels in order, plus label -> entry.
function ChatWindow:paletteChoices(sprite, extra)
  local labels, byLabel = {}, {}
  local list = palettes.list(sprite)
  if extra then table.insert(list, 1, extra) end
  for _, e in ipairs(list) do
    labels[#labels + 1] = e.label
    byLabel[e.label] = e
  end
  return labels, byLabel
end

function ChatWindow:applyPalette(sprite, pal)
  local ok, err = pcall(edit.transaction, sprite, "apply project palette", function() sprite:setPalette(pal) end)
  if not ok then self.model:addLocalError("Couldn't apply the palette.", tostring(err)) end
end

function ChatWindow:projectSettings()
  local root = self.projectRoot
  if not root then return end
  local b = project.readBrief(root)
  local s = app.sprite
  local labels, byLabel = self:paletteChoices(s, { label = "Keep the project palette", keep = true })
  local d = Dialog{ title = "Project settings - " .. self.projectName }
  if b.handEdited then d:label{ text = "brief.md was edited by hand; use Open brief.md to change it." } end
  local editable = not b.handEdited
  d:entry{ id = "resolution", label = "Sprite size", text = b.resolution, visible = editable }
  d:entry{ id = "outline", label = "Outline style", text = b.outline, visible = editable }
  d:entry{ id = "light", label = "Light direction", text = b.light, visible = editable }
  d:entry{ id = "notes", label = "Notes", text = b.notes, visible = editable }
  d:combobox{ id = "palette", label = "Palette", options = labels, option = labels[1] }
  d:check{ id = "applypalette", text = "Apply the palette to this sprite", selected = false, visible = s ~= nil }
  d:separator()
  local function open(path) os.execute(project.openCommand(path, project.osName())) end
  d:button{ text = "Open project folder", onclick = function() open(root) end }
  d:button{ text = "Open brief.md", onclick = function() open(app.fs.joinPath(root, project.DIR, "brief.md")) end }
  d:button{
    text = "Clear memory...",
    onclick = function()
      local answer = app.alert{ title = "Clear project memory", text = "Remove every note Claude saved in memory.md?", buttons = { "Clear", "Cancel" } }
      if answer == 1 then project.clearMemory(root) end
    end,
  }
  d:newrow()
  d:button{ id = "ok", text = "Save", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()
  if not d.data.ok then return end

  local entry = byLabel[d.data.palette]
  if entry and not entry.keep then
    local pal = palettes.load(entry, s)
    local palettePath = app.fs.joinPath(root, project.DIR, "palette.gpl")
    if pal then
      project.savePalette(root, pal)
      if s and d.data.applypalette then self:applyPalette(s, pal) end
    elseif app.fs.isFile(palettePath) then
      os.remove(palettePath)
    end
    b.palette = palettes.describe(entry, pal, s)
  end
  if editable then
    b.resolution, b.outline, b.light, b.notes = d.data.resolution, d.data.outline, d.data.light, d.data.notes
    project.writeBrief(root, b)
  end
  self.model:addNotice("Project settings saved.")
  self:repaint()
end

-- After the project folder exists: switch to it, optionally bringing the current chat along.
function ChatWindow:finishSetup(root, adopt)
  local adoptId = adopt and prefs.getConversation(self.opts.prefs, nil) or nil
  self.projectRoot = root
  sprites.projectRoot = root
  self.projectName = root and app.fs.fileName(root) or "No project"
  self:syncProjectHeader()
  self.model:clearSetupHint()
  if self.conn.status == "connected" then
    self.conn:send{ type = "open_project", projectRoot = root, adoptConversationId = adoptId }
  end
  self.model:addNotice("Project " .. self.projectName .. " is ready. Its brief is in .artproject/brief.md; edit it any time.")
  self:repaint()
end

function ChatWindow:showClips()
  local root = self.projectRoot
  if not root then
    ChatWindow.showTip("Clips are kept in a project. Press Set up project first.")
    return
  end
  local filter = ""
  while true do
    local list = clips.list(root, filter)
    local labels, byLabel = {}, {}
    for _, c in ipairs(list) do
      local l = clips.label(c)
      labels[#labels + 1] = l
      byLabel[l] = c
    end
    local d = Dialog{ title = "Clips in " .. self.projectName }
    d:entry{ id = "filter", label = "Filter", text = filter }
    d:button{ id = "apply", text = "Filter" }
    d:newrow()
    if #labels == 0 then
      d:label{ text = "No clips yet. Select an area and use Edit > Save Selection as Clip." }
    else
      d:combobox{ id = "clip", options = labels, option = labels[1], onchange = function() d:repaint() end }
      d:canvas{
        id = "preview", width = 160, height = 120,
        onpaint = function(ev)
          local c = byLabel[d.data.clip]
          if not c then return end
          local ok, frames = pcall(function()
            local spr = Sprite{ fromFile = app.fs.joinPath(clips.dir(root), c.file) }
            local img = Image(spr.cels[1].image)
            spr:close()
            return img
          end)
          if ok and frames then
            local scale = math.max(1, math.floor(math.min(160 / frames.width, 120 / frames.height)))
            ev.context:drawImage(frames, Rectangle(0, 0, frames.width, frames.height), Rectangle(0, 0, frames.width * scale, frames.height * scale))
          end
        end,
      }
      d:newrow()
      d:button{ id = "insert", text = "Insert" }
      d:button{ id = "rename", text = "Rename..." }
      d:button{ id = "pin", text = "Pin / Unpin" }
      d:button{ id = "delete", text = "Delete" }
      d:button{ id = "clear", text = "Clear all..." }
    end
    d:button{ id = "close", text = "Close" }
    d:show()
    local data = d.data
    local c = data.clip and byLabel[data.clip]
    if data.apply then
      filter = data.filter or ""
    elseif data.insert and c then
      local r = require("agent.tools").dispatch("insert_clip", { name = c.name })
      ChatWindow.showTip(r.ok and ("Inserted clip " .. c.name) or tostring(r.error))
      self:repaint()
      return
    elseif data.rename and c then
      local r = Dialog{ title = "Rename clip" }
      r:entry{ id = "name", label = "New name", text = c.name }
      r:button{ id = "ok", text = "Rename", focus = true }
      r:button{ id = "cancel", text = "Cancel" }
      r:show()
      if r.data.ok then
        local ok, err = pcall(clips.rename, root, c.name, r.data.name)
        if not ok then ChatWindow.showTip(tostring(err)) end
      end
    elseif data.pin and c then
      clips.pin(root, c.name, not c.pinned)
    elseif data.delete and c then
      clips.delete(root, c.name)
    elseif data.clear then
      local answer = app.alert{ title = "Clear clips", text = "Delete every clip in this project?", buttons = { "Unpinned only", "Including pinned", "Cancel" } }
      if answer == 1 then clips.clear(root, false) elseif answer == 2 then clips.clear(root, true) end
    else
      return
    end
  end
end

-- Edit > Save Selection as Clip (works without the chat window open).
function ChatWindow.saveSelectionAsClip()
  local s = app.sprite
  local root = s and project.findRoot(s.filename)
  if not root then
    ChatWindow.showTip("Clips are kept in a project. Press Set up project first.")
    return
  end
  local d = Dialog{ title = "Save Selection as Clip" }
  d:entry{ id = "name", label = "Name", text = "" }
  d:entry{ id = "tags", label = "Tags (comma separated)", text = "" }
  d:check{ id = "layerOnly", text = "Only the active layer", selected = false }
  d:button{ id = "ok", text = "Save", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()
  if not d.data.ok then return end
  local tags = {}
  for t in (d.data.tags or ""):gmatch("[^,]+") do tags[#tags + 1] = t:match("^%s*(.-)%s*$") end
  local region
  if not s.selection.isEmpty then
    local b = s.selection.bounds
    region = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  local ok, entry, evicted = pcall(clips.save, root, s, {
    name = d.data.name, tags = tags, region = region,
    layer = d.data.layerOnly and app.layer and app.layer.name or nil,
    frames = { app.frame and app.frame.frameNumber or 1 },
  })
  if not ok then
    ChatWindow.showTip(tostring(entry))
  else
    ChatWindow.showTip("Saved clip " .. entry.name .. (evicted and (" (removed " .. evicted .. ", limit reached)") or ""))
  end
end

return ChatWindow
