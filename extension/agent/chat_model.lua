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
end

function ChatModel:clear()
  self.items = {}
  self.streaming = false
end

return ChatModel
