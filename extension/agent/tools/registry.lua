local M = { handlers = {} }

function M.register(handlers)
  for name, fn in pairs(handlers) do M.handlers[name] = fn end
end

local function cleanError(e)
  return (tostring(e):gsub("^[^\n]-:%d+: ", ""))
end

function M.dispatch(name, args)
  local fn = M.handlers[name]
  if not fn then return { ok = false, error = "Unknown tool: " .. tostring(name) } end
  local ok, res = pcall(fn, args or {})
  if ok then return { ok = true, data = res } end
  return { ok = false, error = cleanError(res) }
end

return M
