local project = require("agent.project")

local M = {}
M.DEFAULTS = { exports = { location = "alongside", path = "exports", mirrorTree = true }, clips = { max = 20 } }

local function copyDefaults()
  return {
    exports = { location = M.DEFAULTS.exports.location, path = M.DEFAULTS.exports.path, mirrorTree = M.DEFAULTS.exports.mirrorTree },
    clips = { max = M.DEFAULTS.clips.max },
  }
end

function M.read(root)
  local c = copyDefaults()
  if not root then return c end
  local f = io.open(app.fs.joinPath(root, project.DIR, "project.json"), "r")
  if not f then return c end
  local ok, data = pcall(json.decode, f:read("a"))
  f:close()
  if not ok or not data then return c end
  local e = data.exports
  if e then
    if e.location == "alongside" or e.location == "folder" then c.exports.location = tostring(e.location) end
    if type(e.path) == "string" and e.path ~= "" then c.exports.path = e.path end
    if e.mirrorTree ~= nil then c.exports.mirrorTree = e.mirrorTree == true end
  end
  local cl = data.clips
  if cl and tonumber(cl.max) and tonumber(cl.max) >= 1 then c.clips.max = math.floor(tonumber(cl.max)) end
  return c
end

function M.exportDir(root, spritePath, c)
  local srcDir = app.fs.filePath(spritePath)
  if not root or c.exports.location ~= "folder" then return srcDir end
  local base = project.absolute(root, c.exports.path)
  if not c.exports.mirrorTree then return base end
  local rel = project.relative(root, spritePath)
  local sub = rel and rel:match("^(.*)/[^/]*$")
  return sub and project.absolute(base, sub) or base
end

function M.resolveDestination(root, spritePath, destination)
  if destination:sub(1, 1) == "/" or destination:match("^%a:[/\\]") then return destination end
  return project.absolute(root or app.fs.filePath(spritePath), destination)
end

return M
