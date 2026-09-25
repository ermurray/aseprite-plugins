local T = require("testlib")
local F = require("fixtures")
local project = require("agent.project")
local cfg = require("agent.projectconfig")

local root = F.unique("cfg proj")
app.fs.makeAllDirectories(app.fs.joinPath(root, "chars"))
project.create(root, {})

local function writeConfig(text)
  local f = io.open(app.fs.joinPath(root, ".artproject", "project.json"), "w"); f:write(text); f:close()
end

T.test("defaults without a project or with a broken project.json", function()
  local c = cfg.read(nil)
  T.eq(c.exports.location, "alongside")
  T.eq(c.clips.max, 20)
  writeConfig("{broken")
  T.eq(cfg.read(root).clips.max, 20)
end)

T.test("reads exports and clips settings", function()
  writeConfig('{"version":1,"exports":{"location":"folder","path":"out","mirrorTree":true},"clips":{"max":5}}')
  local c = cfg.read(root)
  T.eq(c.exports.location, "folder")
  T.eq(c.clips.max, 5)
end)

T.test("export folders: alongside, mirrored folder, root-level sprite, destination override", function()
  local sprite = app.fs.joinPath(root, "chars", "knight.aseprite")
  T.eq(cfg.exportDir(root, sprite, cfg.DEFAULTS), app.fs.joinPath(root, "chars"))
  local folder = { exports = { location = "folder", path = "out", mirrorTree = true }, clips = { max = 20 } }
  T.eq(cfg.exportDir(root, sprite, folder), app.fs.normalizePath(app.fs.joinPath(root, "out", "chars")))
  T.eq(cfg.exportDir(root, app.fs.joinPath(root, "hero.aseprite"), folder), app.fs.normalizePath(app.fs.joinPath(root, "out")))
  folder.exports.mirrorTree = false
  T.eq(cfg.exportDir(root, sprite, folder), app.fs.normalizePath(app.fs.joinPath(root, "out")))
  T.eq(cfg.resolveDestination(root, sprite, "build/art"), app.fs.normalizePath(app.fs.joinPath(root, "build", "art")))
  T.eq(cfg.resolveDestination(nil, sprite, "sub"), app.fs.normalizePath(app.fs.joinPath(root, "chars", "sub")))
  T.eq(cfg.resolveDestination(root, sprite, "/abs/place"), "/abs/place")
end)
