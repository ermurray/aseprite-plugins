local sprites = require("agent.tools.sprites")

local M = { handlers = {}, kinds = {} }

function M.register(handlers, kind)
  for name, fn in pairs(handlers) do
    M.handlers[name] = fn
    M.kinds[name] = kind or "read"
  end
end

local function cleanError(e)
  return (tostring(e):gsub("^[^\n]-:%d+: ", ""))
end

function M.dispatch(name, args)
  local fn = M.handlers[name]
  if not fn then return { ok = false, error = "Unknown tool: " .. tostring(name) } end
  args = args or {}
  local handle
  local ok, res = pcall(function()
    handle = sprites.openIfNeeded(args.sprite, M.kinds[name])
    return fn(args)
  end)
  if handle and handle.close then handle.close() end
  if not ok then return { ok = false, error = cleanError(res) } end
  if handle and handle.openedAsTab and type(res) == "table" then res.openedAsTab = handle.openedAsTab end
  return { ok = true, data = res }
end

return M
