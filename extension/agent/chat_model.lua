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
function ChatModel:loadHistory(items)
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
end

function ChatModel:clear()
  self.items = {}
  self.streaming = false
end

return ChatModel
