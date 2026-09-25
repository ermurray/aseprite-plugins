-- The palettes an artist can pick for a project: the sprite's own, none, Aseprite's
-- built-in palette packs (contributed by extensions), and the user's palettes folder.
local M = {}

local PALETTE_FILES = { gpl = true, pal = true, hex = true, ase = true, aseprite = true, png = true }

-- Aseprite's data folder differs per install (DMG, Steam, Windows/Linux).
local function dataDirs()
  local bin = app.fs.filePath(app.fs.appPath)
  local out = {}
  for _, c in ipairs{
    app.fs.joinPath(bin, "data"),
    app.fs.joinPath(bin, "..", "Resources", "data"),
    app.fs.joinPath(bin, "..", "..", "..", "data"),
  } do
    local dir = app.fs.normalizePath(c)
    if app.fs.isDirectory(app.fs.joinPath(dir, "extensions")) then out[#out + 1] = dir end
  end
  return out
end

local function extensionDirs()
  local dirs = {}
  for _, data in ipairs(dataDirs()) do dirs[#dirs + 1] = app.fs.joinPath(data, "extensions") end
  dirs[#dirs + 1] = app.fs.joinPath(app.fs.userConfigPath, "extensions")
  return dirs
end

local function builtIns()
  local seen, out = {}, {}
  for _, extDir in ipairs(extensionDirs()) do
    if app.fs.isDirectory(extDir) then
      for _, name in ipairs(app.fs.listFiles(extDir)) do
        local f = io.open(app.fs.joinPath(extDir, name, "package.json"), "r")
        if f then
          local ok, pkg = pcall(json.decode, f:read("a"))
          f:close()
          local list = ok and pkg and pkg.contributes and pkg.contributes.palettes
          if list then
            for i = 1, #list do
              local id = list[i].id and tostring(list[i].id)
              if id and not seen[id] then
                seen[id] = true
                out[#out + 1] = { label = id, id = id }
              end
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
  return out
end

local function userPalettes()
  local out = {}
  local dir = app.fs.joinPath(app.fs.userConfigPath, "palettes")
  if not app.fs.isDirectory(dir) then return out end
  for _, name in ipairs(app.fs.listFiles(dir)) do
    if name:sub(1, 1) ~= "." and PALETTE_FILES[app.fs.fileExtension(name):lower()] then
      out[#out + 1] = { label = "My palettes: " .. app.fs.fileTitle(name), path = app.fs.joinPath(dir, name) }
    end
  end
  table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
  return out
end

function M.list(sprite)
  local out = {}
  if sprite then
    out[#out + 1] = { label = "Current sprite palette (" .. #sprite.palettes[1] .. " colors)", current = true }
  end
  out[#out + 1] = { label = "None", none = true }
  for _, e in ipairs(builtIns()) do out[#out + 1] = e end
  for _, e in ipairs(userPalettes()) do out[#out + 1] = e end
  return out
end

-- The Palette for an entry, or nil for "None".
function M.load(entry, sprite)
  if entry.none then return nil end
  if entry.current then return Palette(sprite.palettes[1]) end
  if entry.id then return Palette{ fromResource = entry.id } end
  return Palette{ fromFile = entry.path }
end

-- How the brief describes a chosen palette ("" for none).
function M.describe(entry, palette, sprite)
  if entry.none or not palette then return "" end
  local n = #palette .. " colors"
  if entry.current then return "From " .. app.fs.fileName(sprite.filename) .. " (" .. n .. ")" end
  return entry.label .. " (" .. n .. ")"
end

return M
