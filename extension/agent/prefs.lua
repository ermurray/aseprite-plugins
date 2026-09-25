local M = { GLOBAL = "~" }

local function load(p)
  local map = {}
  local ok, decoded = pcall(json.decode, p.conversationsJson or "{}")
  if ok and decoded then
    for k, v in pairs(decoded) do map[tostring(k)] = tostring(v) end
  end
  if p.conversationId then -- migrate the Plan 2 single id
    map[M.GLOBAL] = map[M.GLOBAL] or tostring(p.conversationId)
    p.conversationId = nil
    p.conversationsJson = json.encode(map)
  end
  return map
end

function M.getConversation(p, root)
  return load(p)[root or M.GLOBAL]
end

function M.setConversation(p, root, id)
  local map = load(p)
  map[root or M.GLOBAL] = id
  p.conversationsJson = json.encode(map)
end

return M
