local M = { DIR = ".artproject" }

local function trimSep(p)
  return (p:gsub("[/\\]+$", ""))
end

function M.findRoot(path)
  if type(path) ~= "string" or path == "" then return nil end
  local dir = app.fs.isDirectory(path) and path or app.fs.filePath(path)
  while dir and dir ~= "" do
    if app.fs.isDirectory(app.fs.joinPath(dir, M.DIR)) then return dir end
    local parent = app.fs.filePath(trimSep(dir))
    if parent == "" or parent == dir then break end
    dir = parent
  end
  return nil
end

function M.relative(root, path)
  if type(root) ~= "string" or type(path) ~= "string" then return nil end
  local prefix = trimSep(root) .. app.fs.pathSeparator
  if path:sub(1, #prefix) ~= prefix then return nil end
  return (path:sub(#prefix + 1):gsub("\\", "/"))
end

function M.absolute(root, rel)
  local parts = { root }
  for piece in tostring(rel):gmatch("[^/\\]+") do parts[#parts + 1] = piece end
  return app.fs.normalizePath(app.fs.joinPath(table.unpack(parts)))
end

function M.listSprites(root)
  local out = {}
  local function walk(dir, rel)
    for _, name in ipairs(app.fs.listFiles(dir)) do
      local full = app.fs.joinPath(dir, name)
      local r = rel == "" and name or (rel .. "/" .. name)
      if app.fs.isDirectory(full) then
        if name:sub(1, 1) ~= "." then walk(full, r) end
      else
        local ext = app.fs.fileExtension(name):lower()
        if ext == "aseprite" or ext == "ase" then out[#out + 1] = r end
      end
    end
  end
  walk(root, "")
  table.sort(out)
  return out
end

function M.ancestors(path, max)
  local out = {}
  local dir = app.fs.filePath(path)
  while dir ~= "" and #out < (max or 5) do
    out[#out + 1] = dir
    local parent = app.fs.filePath(trimSep(dir))
    if parent == dir then break end
    dir = parent
  end
  return out
end

local function field(v)
  v = v and tostring(v):match("^%s*(.-)%s*$") or ""
  return v ~= "" and v or "(not set)"
end

function M.briefMarkdown(b)
  b = b or {}
  return table.concat({
    "# Project brief",
    "",
    "- Sprite size: " .. field(b.resolution),
    "- Palette: " .. field(b.palette),
    "- Outline style: " .. field(b.outline),
    "- Light direction: " .. field(b.light),
    "",
    "## Notes",
    "",
    field(b.notes),
    "",
  }, "\n")
end

local CONFIG = '{\n  "version": 1,\n  "exports": { "location": "alongside" },\n  "clips": { "max": 20 }\n}\n'
local MEMORY = "# Project memory\n\nLasting decisions Claude proposed and you approved.\n\n"

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

function M.create(root, brief)
  if not app.fs.isDirectory(root) then error("Folder not found: " .. tostring(root), 0) end
  local dir = app.fs.joinPath(root, M.DIR)
  if app.fs.isDirectory(dir) then error("This folder is already a project.", 0) end
  app.fs.makeAllDirectories(app.fs.joinPath(dir, "chats"))
  write(app.fs.joinPath(dir, "project.json"), CONFIG)
  write(app.fs.joinPath(dir, "brief.md"), M.briefMarkdown(brief))
  write(app.fs.joinPath(dir, "memory.md"), MEMORY)
  return dir
end

return M
