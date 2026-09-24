local ChatModel = require("agent.chat_model")
local render = require("agent.chat_render")
local Connection = require("agent.connection")
local tools = require("agent.tools")
local inspect = require("agent.tools.inspect")

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
  error = Color{ r = 230, g = 90, b = 80 },
}

local function themeColor(name, fallback)
  local ok, c = pcall(function() return app.theme.color[name] end)
  return (ok and c) or fallback
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
  }, ChatWindow)
  self.conn = Connection.new{
    onMessage = function(m) self:onMessage(m) end,
    onStatus = function(s, d) self:onStatus(s, d) end,
  }
  self:build()
  return self
end

function ChatWindow:build()
  local dlg = Dialog{
    title = "Agent Chat",
    resizeable = true,
    onclose = function() self:onClosed() end,
  }
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
  dlg:entry{ id = "input", hexpand = true }
  dlg:button{ id = "send", text = "Send", focus = true, onclick = function() self:onSendOrStop() end }
  self.dlg = dlg
end

function ChatWindow:show()
  local b = self.opts.prefs.bounds
  if b then
    self.dlg:show{ wait = false, bounds = Rectangle(b.x, b.y, b.w, b.h) }
  else
    self.dlg:show{ wait = false }
  end
  if self.conn.status == "disconnected" then self.conn:connect() end
end

function ChatWindow:close()
  self.dlg:close()
end

function ChatWindow:onClosed()
  local b = self.dlg.bounds
  self.opts.prefs.bounds = { x = b.x, y = b.y, w = b.width, h = b.height }
  self.conn:close()
  if self.opts.onclose then self.opts.onclose() end
end

function ChatWindow:repaint()
  self.dlg:repaint()
end

function ChatWindow:setBusy(busy)
  self.busy = busy
  self.dlg:modify{ id = "send", text = busy and "Stop" or "Send" }
end

function ChatWindow:onSendOrStop()
  local text = (self.dlg.data.input or ""):match("^%s*(.-)%s*$")
  local action = ChatModel.sendAction(self.busy, text)
  if action == "stop" then
    self.conn:send{ type = "cancel" }
    return
  elseif action == "reject_busy" then
    self.model:addError("Still working on the previous message.", "Wait for it to finish, or clear the box and press Stop.")
    self:repaint()
    return
  elseif action == "ignore" then
    return
  end
  if self.conn.status ~= "connected" then
    self.model:addError("Not connected to the bridge.", "Start it with: cd bridge && npm start, then press Reconnect.")
    self:repaint()
    return
  end
  self.model:addUser(text)
  self.followTail = true
  self.dlg:modify{ id = "input", text = "" }
  self.conn:send{ type = "user_message", text = text }
  self:setBusy(true)
  self:repaint()
end

function ChatWindow:newChat()
  if self.busy then self.conn:send{ type = "cancel" } end
  self.conn:send{ type = "new_chat" }
  self.model:clear()
  self.scroll = 0
  self.followTail = true
  self:setBusy(false)
  self:repaint()
end

function ChatWindow:onStatus(status, detail)
  local text = STATUS_TEXT[status] or status
  self.dlg:modify{ id = "status", text = text }
  if status == "disconnected" and self.busy then
    self.model:addError("Lost connection to the bridge.", detail)
    self.model:endTurn()
    self:setBusy(false)
    self:repaint()
  end
end

function ChatWindow:onMessage(m)
  if m.type == "ready" then
    inspect.snapshotDir = m.snapshotDir
    self.agentLabel = (m.adapter == "claude-code") and "Claude" or tostring(m.adapter)
  elseif m.type == "text_delta" then
    self.model:appendAgent(m.text)
  elseif m.type == "tool_activity" then
    self.model:addActivity(m.summary)
  elseif m.type == "tool_call" then
    local res = tools.dispatch(m.name, m.args)
    self.conn:send{ type = "tool_result", callId = m.callId, ok = res.ok, data = res.data, error = res.error }
  elseif m.type == "turn_done" then
    self.model:endTurn()
    self:setBusy(false)
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
    end
  end

  if self.contentH > self.viewH then
    local barH = math.max(20, self.viewH * self.viewH / self.contentH)
    local barY = (self.viewH - barH) * self.scroll / (self.contentH - self.viewH)
    gc.color = Color{ r = 128, g = 128, b = 128, a = 140 }
    gc:fillRect(Rectangle(gc.width - 5, barY, 4, barH))
  end
end

return ChatWindow
