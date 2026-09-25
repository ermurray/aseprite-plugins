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

M.MAX_DEPTH, M.MAX_FILES = 6, 2000

-- Sprites under root, bounded in depth and count so a huge folder or a symlink loop can't
-- freeze Aseprite (the Lua fs API can't tell symlinks apart).
function M.listSprites(root)
  local out = {}
  local function walk(dir, rel, depth)
    if depth > M.MAX_DEPTH or #out >= M.MAX_FILES then return end
    for _, name in ipairs(app.fs.listFiles(dir)) do
      local full = app.fs.joinPath(dir, name)
      local r = rel == "" and name or (rel .. "/" .. name)
      if app.fs.isDirectory(full) then
        if name:sub(1, 1) ~= "." then walk(full, r, depth + 1) end
      else
        local ext = app.fs.fileExtension(name):lower()
        if ext == "aseprite" or ext == "ase" then out[#out + 1] = r end
      end
    end
  end
  walk(root, "", 1)
  table.sort(out)
  return out
end

-- Candidate project folders for a sprite: its folder, then parents, but never the home
-- folder or the filesystem root (too big to be one project).
function M.ancestors(path, max)
  local out = {}
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  local dir = app.fs.filePath(path)
  while dir ~= "" and #out < (max or 5) do
    local parent = app.fs.filePath(trimSep(dir))
    if dir == home or parent == "" or parent == dir then break end
    out[#out + 1] = dir
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

function M.savePalette(root, palette)
  palette:saveAs(app.fs.joinPath(root, M.DIR, "palette.gpl"))
end

local FIELDS = {
  { key = "resolution", label = "Sprite size" },
  { key = "palette", label = "Palette" },
  { key = "outline", label = "Outline style" },
  { key = "light", label = "Light direction" },
}

local function unset(v)
  return (v == nil or v == "(not set)") and "" or v
end

-- The brief's template fields. handEdited is true when the file has anything beyond the
-- template, so the settings dialog must not overwrite it.
function M.readBrief(root)
  local f = io.open(app.fs.joinPath(root, M.DIR, "brief.md"), "r")
  local text = f and f:read("a") or ""
  if f then f:close() end
  local b = {}
  for _, fd in ipairs(FIELDS) do
    b[fd.key] = unset(text:match("\n%- " .. fd.label:gsub("%s", "%%s") .. ": ([^\n]*)"))
  end
  b.notes = unset((text:match("## Notes%s*\n(.*)$") or ""):match("^%s*(.-)%s*$"))
  -- Multi-line notes count too: the dialog's single-line Notes field would flatten them.
  b.handEdited = b.notes:find("\n") ~= nil or M.briefMarkdown(b):match("^(.-)%s*$") ~= text:match("^(.-)%s*$")
  return b
end

function M.writeBrief(root, b)
  write(app.fs.joinPath(root, M.DIR, "brief.md"), M.briefMarkdown(b))
end

-- Shell command that opens a file or folder with the system's default app.
function M.openCommand(path, osName)
  if osName == "Windows" then return 'start "" "' .. path .. '"' end
  return (osName == "Darwin" and "open" or "xdg-open") .. ' "' .. path .. '"'
end

function M.osName()
  if app.fs.pathSeparator == "\\" then return "Windows" end
  local p = io.popen("uname")
  local name = p and p:read("l") or "Linux"
  if p then p:close() end
  return name
end

function M.clearMemory(root)
  write(app.fs.joinPath(root, M.DIR, "memory.md"), MEMORY)
end

return M
