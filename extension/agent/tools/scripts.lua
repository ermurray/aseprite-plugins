local M = { dir = nil }

function M.folder()
  return M.dir or app.fs.joinPath(app.fs.userConfigPath, "scripts", "Agent")
end

-- "path/Name.lua:4: msg" -> "line 4: msg" (keeps messages readable for Claude and the artist).
local function withLine(msg)
  return (tostring(msg):gsub("^[^\n]-%.lua:(%d+):%s*", "line %1: "))
end

local function checkName(name)
  name = tostring(name or "")
  if not name:match("^[%w _%-]+$") or #name > 60 then
    error("Script names use letters, numbers, spaces, - and _ (max 60).", 0)
  end
  return name
end

function M.write_script(args)
  local name = checkName(args.name)
  local code = tostring(args.code)
  if #code > 20000 then error("Scripts are limited to 20000 characters.", 0) end
  app.fs.makeAllDirectories(M.folder())
  local path = app.fs.joinPath(M.folder(), name .. ".lua")
  local f = assert(io.open(path, "w"))
  f:write("-- " .. tostring(args.description):gsub("\n", " ") .. "\n")
  f:write("-- Written by Claude in Agent Chat on " .. os.date("%Y-%m-%d") .. "; approved by the artist.\n\n")
  f:write(code)
  if code:sub(-1) ~= "\n" then f:write("\n") end
  f:close()
  return { name = name, path = path }
end

function M.run_script(args)
  local name = checkName(args.name)
  local path = app.fs.joinPath(M.folder(), name .. ".lua")
  if not app.fs.isFile(path) then error("There is no saved script called '" .. name .. "'.", 0) end
  local chunk, syntaxErr = loadfile(path)
  if not chunk then error("Script has a syntax error at " .. withLine(syntaxErr), 0) end
  local out, realPrint = {}, print
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(function()
    if app.sprite then app.transaction("Script: " .. name, chunk) else chunk() end
  end)
  print = realPrint
  if not ok then error("Script error at " .. withLine(err), 0) end
  app.refresh()
  local output = table.concat(out, "\n")
  if #output > 4000 then output = output:sub(1, 4000) .. "\n[...truncated]" end
  return { name = name, output = output }
end

return M
