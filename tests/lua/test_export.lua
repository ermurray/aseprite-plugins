local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
local root = F.unique("export proj")
app.fs.makeAllDirectories(app.fs.joinPath(root, "chars"))
project.create(root, {})

local function knight()
  F.closeAll()
  sprites.projectRoot = root
  local s = Sprite(4, 4)
  local img = s.cels[1].image:clone(); img:clear(pc.rgba(255, 0, 0, 255)); s.cels[1].image = img
  s:newFrame(1)
  s:newTag(1, 2).name = "idle"
  s:saveAs(project.absolute(root, "chars/knight.aseprite"))
  app.sprite = s
  return s
end

local function exists(rel) return app.fs.isFile(project.absolute(root, rel)) end
local function size(rel) local i = Image{ fromFile = project.absolute(root, rel) } return i.width, i.height end

T.test("png next to the sprite, scaled", function()
  knight()
  local r = call("export_sprite", { format = "png", scale = 3 })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.files, { "chars/knight.png" })
  T.deepEq({ size("chars/knight.png") }, { 12, 12 })
end)

T.test("frames as numbered PNGs, and a tag as a GIF", function()
  knight()
  T.deepEq(call("export_sprite", { format = "frames" }).data.files, { "chars/knight_1.png", "chars/knight_2.png" })
  T.deepEq(call("export_sprite", { format = "gif", tag = "idle", name = "knight_idle" }).data.files, { "chars/knight_idle.gif" })
  T.eq(exists("chars/knight_idle.gif"), true)
end)

T.test("sprite sheet + JSON, scaled from a temporary copy", function()
  local s = knight()
  local r = call("export_sprite", { format = "sheet", scale = 2, data = "array" })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.files, { "chars/knight_sheet.png", "chars/knight_sheet.json" })
  T.deepEq({ size("chars/knight_sheet.png") }, { 16, 8 })
  T.eq(#app.sprites, 1, "the temporary copy is closed")
  T.eq(app.sprite == s, true)
end)

T.test("project folder rules and destination overrides", function()
  knight()
  local f = io.open(app.fs.joinPath(root, ".artproject", "project.json"), "w")
  f:write('{"version":1,"exports":{"location":"folder","path":"out","mirrorTree":true}}'); f:close()
  T.deepEq(call("export_sprite", { format = "png" }).data.files, { "out/chars/knight.png" })
  T.deepEq(call("export_sprite", { format = "png", destination = "build" }).data.files, { "build/knight.png" })
  f = io.open(app.fs.joinPath(root, ".artproject", "project.json"), "w"); f:write('{"version":1}'); f:close()
end)

T.test("includeNormal also exports the normal companion as _n", function()
  knight()
  T.eq(call("make_normal_map", { layer = "Layer 1", saveHeight = false }).ok, true)
  local r = call("export_sprite", { format = "png", includeNormal = true })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.files, { "chars/knight.png", "chars/knight_n.png" })
  T.eq(call("export_sprite", { format = "gif", layer = "Layer 1" }).error, "GIF export uses the whole sprite; drop layer or export frames/png instead.")
end)

T.test("unsaved sprites need an absolute destination", function()
  F.closeAll()
  sprites.projectRoot = nil
  app.sprite = Sprite(2, 2)
  T.eq(call("export_sprite", { format = "png" }).error, "Save the sprite first, or give an absolute destination folder.")
  local dir = F.unique("abs export")
  T.eq(call("export_sprite", { format = "png", destination = dir, name = "loose" }).ok, true)
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "loose.png")), true)
end)

sprites.projectRoot = nil
F.closeAll()

T.test("preview_export names the absolute folder, the files, and what gets replaced", function()
  knight()
  call("export_sprite", { format = "png" })
  local p = call("preview_export", { format = "png" })
  T.eq(p.ok, true, p.error)
  T.eq(p.data.note:find("Writes to " .. app.fs.joinPath(root, "chars"), 1, true) ~= nil, true, p.data.note)
  T.eq(p.data.note:find("knight.png", 1, true) ~= nil, true)
  T.eq(p.data.note:find("replaces existing knight.png", 1, true) ~= nil, true, p.data.note)
end)

T.test("an export never overwrites the sprite's own file", function()
  F.closeAll()
  sprites.projectRoot = root
  local s = Sprite(2, 2)
  s:saveAs(project.absolute(root, "hero.png"))
  app.sprite = s
  local msg = "That would overwrite hero.png itself. Pick another name or destination."
  T.eq(call("preview_export", { format = "png" }).error, msg)
  T.eq(call("export_sprite", { format = "png", scale = 4 }).error, msg)
  local i = Image{ fromFile = project.absolute(root, "hero.png") }
  T.eq(i.width, 2, "original untouched")
end)

T.test("includeNormal exports the same frame of the normal map", function()
  local s = knight()
  local img = s.layers[1]:cel(2).image:clone(); img:clear(pc.rgba(0, 0, 0, 0)); s.layers[1]:cel(2).image = img
  T.eq(call("make_normal_map", { layer = "Layer 1", saveHeight = false }).ok, true)
  app.sprite = s
  app.frame = s.frames[2]
  T.eq(call("export_sprite", { format = "png", includeNormal = true }).ok, true)
  local n = Image{ fromFile = project.absolute(root, "chars/knight_n.png") }
  T.eq(pc.rgbaA(n:getPixel(1, 1)), 0, "frame 2 of the normal map is empty like frame 2 of the art")
end)
