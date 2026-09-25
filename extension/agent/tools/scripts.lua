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

-- Tab and newline are fine; any other control character could hide code from the approval card.
local function checkVisible(text, what)
  if text:find("[%z\1-\8\11\12\13\14-\31\127]") then
    error("The " .. what .. " contains hidden control characters.", 0)
  end
end

-- FNV-1a: a fingerprint of exactly what the artist approved.
local function fingerprint(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return string.format("%08x", h)
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function approvalsPath() return app.fs.joinPath(M.folder(), ".approved.json") end

local function loadApprovals()
  local raw = readAll(approvalsPath())
  local ok, decoded = pcall(json.decode, raw or "{}")
  local map = {}
  if ok and decoded then for k, v in pairs(decoded) do map[tostring(k)] = tostring(v) end end
  return map
end

local function saveApprovals(map)
  local f = assert(io.open(approvalsPath(), "w"))
  f:write(json.encode(map))
  f:close()
end

function M.write_script(args)
  local name = checkName(args.name)
  local code, description = tostring(args.code), tostring(args.description)
  if #code > 20000 then error("Scripts are limited to 20000 characters.", 0) end
  checkVisible(code, "script")
  checkVisible(description, "description")
  app.fs.makeAllDirectories(M.folder())
  local path = app.fs.joinPath(M.folder(), name .. ".lua")
  if app.fs.isFile(path) and args.replace ~= true then
    error("A script called '" .. name .. "' already exists. Save it with replace = true to overwrite it.", 0)
  end
  local text = "-- " .. description:gsub("\n", " ") .. "\n"
    .. "-- Written by Claude in Agent Chat on " .. os.date("%Y-%m-%d") .. "; approved by the artist.\n\n"
    .. code .. (code:sub(-1) ~= "\n" and "\n" or "")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
  local approvals = loadApprovals()
  approvals[name] = fingerprint(text)
  saveApprovals(approvals)
  return { name = name, path = path }
end

function M.run_script(args)
  local name = checkName(args.name)
  local path = app.fs.joinPath(M.folder(), name .. ".lua")
  local text = readAll(path)
  if not text then error("There is no saved script called '" .. name .. "'.", 0) end
  if loadApprovals()[name] ~= fingerprint(text) then
    error("The script '" .. name .. "' changed since it was approved (or wasn't saved through the chat). Save it again with write_script so the artist can review the code.", 0)
  end
  local out = {}
  -- Scripts get their own globals (reads fall through to Aseprite's), so they can't clobber the extension.
  local env = setmetatable({
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
      out[#out + 1] = table.concat(parts, "\t")
    end,
  }, { __index = _G })
  local chunk, syntaxErr = load(text, "=" .. name .. ".lua", "t", env)
  if not chunk then error("Script has a syntax error at " .. withLine(syntaxErr), 0) end
  local ok, err = pcall(function()
    if app.sprite then app.transaction("Script: " .. name, chunk) else chunk() end
  end)
  if not ok then error("Script error at " .. withLine(err), 0) end
  app.refresh()
  local output = table.concat(out, "\n")
  if #output > 4000 then output = output:sub(1, 4000) .. "\n[...truncated]" end
  return { name = name, output = output }
end

return M
