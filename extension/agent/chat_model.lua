local ChatModel = {}
ChatModel.__index = ChatModel

function ChatModel.new()
  return setmetatable({ items = {}, streaming = false }, ChatModel)
end

function ChatModel:addUser(text)
  self.items[#self.items + 1] = { kind = "user", text = text }
  self.streaming = false
end

function ChatModel:appendAgent(delta)
  local last = self.items[#self.items]
  if self.streaming and last and last.kind == "agent" then
    last.text = last.text .. delta
  else
    delta = delta:gsub("^%s+", "")
    if delta == "" then return end
    self.items[#self.items + 1] = { kind = "agent", text = delta }
    self.streaming = true
  end
end

function ChatModel:addActivity(summary)
  self.items[#self.items + 1] = { kind = "activity", text = summary }
  self.streaming = false
end

function ChatModel:addNotice(text)
  self.items[#self.items + 1] = { kind = "notice", text = text }
  self.streaming = false
end

-- Status-bar hint for bridge events that happen while the chat window is hidden.
function ChatModel.hiddenTip(messageType, agentLabel, replied)
  if messageType == "approval_request" then return agentLabel .. " is waiting for your approval - open Agent Chat" end
  if messageType == "turn_done" and replied then return agentLabel .. " replied - open Agent Chat to read it" end
  return nil
end

-- True when the latest turn ended with Claude's text (not an error, not nothing).
function ChatModel:lastTurnReplied()
  for i = #self.items, 1, -1 do
    local kind = self.items[i].kind
    if kind == "agent" then return true end
    if kind == "error" or kind == "user" then return false end
  end
  return false
end

-- An error that exists only in this window (not known to the bridge), e.g. "Lost connection".
function ChatModel:addLocalError(message, hint)
  self:addError(message, hint)
  self.items[#self.items].localOnly = true
end

function ChatModel:addError(message, hint)
  local text = message
  if hint and hint ~= "" then text = text .. "\n" .. hint end
  self.items[#self.items + 1] = { kind = "error", text = text }
  self.streaming = false
end

function ChatModel:endTurn()
  self.streaming = false
  for _, item in ipairs(self.items) do
    if item.kind == "approval" and item.state == "pending" then item.state = "cancelled" end
  end
end

function ChatModel:addApproval(id, summary)
  self.items[#self.items + 1] = { kind = "approval", id = id, text = summary, state = "pending" }
  self.streaming = false
end

function ChatModel:resolveApproval(id, approved)
  for _, item in ipairs(self.items) do
    if item.kind == "approval" and item.id == id and item.state == "pending" then
      item.state = approved and "applied" or "denied"
    end
  end
end

-- Answers the first pending card. If another card is queued behind it, Apply stays locked
-- until unlockApply(), so a double-click can't approve a card the artist hasn't read.
function ChatModel:answerPending(approved)
  local item = self:pendingApproval()
  if not item then return nil end
  self:resolveApproval(item.id, approved)
  self.applyLocked = self:pendingApproval() ~= nil
  return item
end

function ChatModel:unlockApply()
  self.applyLocked = false
end

function ChatModel:applyAvailable()
  return self:pendingApproval() ~= nil and not self.applyLocked
end

function ChatModel:pendingApproval()
  for _, item in ipairs(self.items) do
    if item.kind == "approval" and item.state == "pending" then return item end
  end
  return nil
end

-- What the Send/Stop/Deny button (and Enter) should do. A typed follow-up while busy is
-- rejected rather than silently cancelling; with an approval pending, Enter denies it.
function ChatModel.sendAction(busy, text, approvalPending)
  local empty = (text or ""):match("^%s*$") ~= nil
  if approvalPending then return empty and "deny" or "reject_busy" end
  if busy then return empty and "stop" or "reject_busy" end
  return empty and "ignore" or "send"
end

-- Replaces the chat with saved history from the bridge (json userdata or tables).
-- Cards that were still pending can no longer be answered, so they show as cancelled.
function ChatModel:loadHistory(items, opts)
  -- Window-only lines at the end (e.g. "Lost connection") survive a reload of the same chat.
  local keep = {}
  if not (opts and opts.dropLocal) then
    for i = #self.items, 1, -1 do
      if not self.items[i].localOnly then break end
      table.insert(keep, 1, self.items[i])
    end
  end
  self.items = {}
  self.streaming = false
  self.applyLocked = false
  for i = 1, #items do
    local it = items[i]
    local item = { kind = tostring(it.kind), text = tostring(it.text) }
    if item.kind == "approval" then
      item.id = tostring(it.id)
      item.state = (it.state == "pending") and "cancelled" or tostring(it.state)
    end
    self.items[#self.items + 1] = item
  end
  for _, item in ipairs(keep) do self.items[#self.items + 1] = item end
end

function ChatModel:showSetupHint(text)
  for _, it in ipairs(self.items) do
    if it.kind == "setup" then return end
  end
  self.items[#self.items + 1] = { kind = "setup", text = text, localOnly = true }
  self.streaming = false
end

function ChatModel:clearSetupHint()
  for i = #self.items, 1, -1 do
    if self.items[i].kind == "setup" then table.remove(self.items, i) end
  end
end

function ChatModel:clear()
  self.items = {}
  self.streaming = false
end

return ChatModel
