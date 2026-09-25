local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
local root = F.unique("import proj")
app.fs.makeAllDirectories(root)
project.create(root, {})

local function source()
  local s = Sprite(4, 3)
  local img = s.cels[1].image:clone()
  img:drawPixel(0, 0, pc.rgba(255, 0, 0, 255))
  img:drawPixel(1, 0, pc.rgba(0, 255, 0, 255))
  s.cels[1].image = img
  s.layers[1].name = "Head"
  s:newFrame(1)
  s:saveAs(project.absolute(root, "knight.aseprite"))
  s:close()
end

T.test("imports a layer region from an unopened project sprite, flipped, as a selected new layer", function()
  F.closeAll()
  source()
  sprites.projectRoot = root
  local dest = Sprite(6, 6)
  dest:saveAs(project.absolute(root, "dest.aseprite"))
  app.sprite = dest
  local r = call("import_from_sprite", { from = "knight.aseprite", layer = "Head", region = { x = 0, y = 0, w = 2, h = 1 }, flip = "horizontal", at = { x = 3, y = 2 } })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.layer, "Import: knight.aseprite / Head")
  T.eq(#app.sprites, 1, "source closed again")
  T.eq(app.sprite == dest, true)
  T.eq(F.px(dest, 3, 2, "Import: knight.aseprite / Head"), pc.rgba(0, 255, 0, 255), "flipped: green first")
  T.eq(F.px(dest, 4, 2, "Import: knight.aseprite / Head"), pc.rgba(255, 0, 0, 255))
  T.deepEq({ dest.selection.bounds.x, dest.selection.bounds.y, dest.selection.bounds.width }, { 3, 2, 2 })
  app.undo()
  T.eq(#dest.layers, 1, "one undo removes the import")
  sprites.projectRoot = nil
end)

T.test("multi-frame imports add frames to the destination", function()
  F.closeAll()
  source()
  sprites.projectRoot = root
  local dest = Sprite(4, 3)
  dest:saveAs(project.absolute(root, "dest2.aseprite"))
  app.sprite = dest
  local r = call("import_from_sprite", { from = "knight.aseprite", frames = { from = 1, to = 2 } })
  T.eq(r.ok, true, r.error)
  T.eq(#dest.frames, 2)
  T.eq(r.data.frames, 2)
  sprites.projectRoot = nil
end)

T.test("indexed destinations map to the nearest color, or add colors, and keep transparency", function()
  F.closeAll()
  source()
  sprites.projectRoot = root
  local dest = Sprite(4, 3, ColorMode.INDEXED)
  local pal = dest.palettes[1]
  pal:resize(3)
  pal:setColor(1, Color{ r = 250, g = 0, b = 0 })
  pal:setColor(2, Color{ r = 0, g = 0, b = 250 })
  app.sprite = dest
  local near = call("import_from_sprite", { from = "knight.aseprite", layer = "Head" })
  T.eq(near.ok, true, near.error)
  local cel = dest.layers[2]:cel(1)
  T.eq(cel.image:getPixel(0 - cel.position.x, 0 - cel.position.y), 1)
  T.eq(cel.image:getPixel(3 - cel.position.x, 2 - cel.position.y), dest.transparentColor)
  local add = call("import_from_sprite", { from = "knight.aseprite", layer = "Head", paletteMode = "add" })
  T.eq(add.ok, true, add.error)
  T.eq(add.data.colorsAdded, 2)
  sprites.projectRoot = nil
end)

T.test("a missing source is a plain error and leaves no stray tab", function()
  F.closeAll()
  local dest = Sprite(2, 2)
  app.sprite = dest
  T.eq(call("import_from_sprite", { from = "ghost.aseprite" }).ok, false)
  T.eq(#app.sprites, 1)
end)

F.closeAll()
