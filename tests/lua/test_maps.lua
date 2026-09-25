local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local inspect = require("agent.tools.inspect")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
local dir = F.unique("maps")
app.fs.makeAllDirectories(dir)
inspect.snapshotDir = F.tmp

local function square(name, frames)
  local s = Sprite(5, 5)
  local img = s.cels[1].image:clone()
  img:clear(pc.rgba(120, 120, 120, 255))
  s.cels[1].image = img
  for _ = 2, frames or 1 do s:newFrame(1) end
  s:saveAs(app.fs.joinPath(dir, name))
  app.sprite = s
  return s
end

T.test("make_normal_map saves companion height and normal sprites with every frame", function()
  F.closeAll()
  local s = square("knight.aseprite", 2)
  local r = call("make_normal_map", { layer = "Layer 1", source = "edges", bevel = 3 })
  T.eq(r.ok, true, r.error)
  T.eq(#app.sprites, 1, "companions are closed after saving")
  T.eq(app.sprite == s, true)
  local n = Sprite{ fromFile = app.fs.joinPath(dir, "knight_normal.aseprite") }
  T.eq(#n.frames, 2)
  local img = n.cels[1].image
  local c = img:getPixel(2 - n.cels[1].position.x, 2 - n.cels[1].position.y)
  T.deepEq({ pc.rgbaR(c), pc.rgbaG(c), pc.rgbaB(c) }, { 128, 128, 255 })
  local left = img:getPixel(1 - n.cels[1].position.x, 2 - n.cels[1].position.y)
  T.eq(pc.rgbaR(left) < 128, true)
  n:close()
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "knight_height.aseprite")), true)
  app.sprite = s -- closing the inspection sprite above leaves no active sprite headless
  local again = call("make_normal_map", { layer = "Layer 1" })
  T.eq(again.ok, true, "re-running replaces the companions: " .. tostring(again.error))
end)

T.test("make_normal_map needs a saved sprite and a closed companion", function()
  F.closeAll()
  app.sprite = Sprite(3, 3)
  T.eq(call("make_normal_map", { layer = "Layer 1" }).error, "Save the sprite first: maps are saved next to it.")
  F.closeAll()
  square("slime.aseprite")
  call("make_normal_map", { layer = "Layer 1" })
  local open = Sprite{ fromFile = app.fs.joinPath(dir, "slime_normal.aseprite") }
  app.sprite = app.sprites[1]
  T.eq(call("make_normal_map", { sprite = "slime.aseprite", layer = "Layer 1" }).error, "Close slime_normal.aseprite first: it will be replaced.")
  open:close()
end)

T.test("check_readability returns value, silhouette or both images without changing the sprite", function()
  F.closeAll()
  local s = F.rgbSprite()
  local before = F.px(s, 0, 0, "Body")
  local both = call("check_readability", { mode = "both" })
  T.eq(both.ok, true, both.error)
  T.eq(both.data.mode, "both")
  local single = call("check_readability", { mode = "values" })
  T.eq(both.data.width / both.data.scale > single.data.width / single.data.scale, true, "both views side by side")
  T.eq(F.px(s, 0, 0, "Body"), before)
  os.remove(both.data.pngPath)
  os.remove(single.data.pngPath)
end)

T.test("light_preview renders a lit image and leaves the sprite alone", function()
  F.closeAll()
  local s = square("lit.aseprite")
  local r = call("light_preview", { lightX = -1, lightY = 1, lightZ = 0.5 })
  T.eq(r.ok, true, r.error)
  T.eq(app.fs.isFile(r.data.pngPath), true)
  T.eq(#app.sprites, 1)
  os.remove(r.data.pngPath)
end)

F.closeAll()

T.test("a failed companion save closes the half-made sprite and restores the tab", function()
  F.closeAll()
  local ro = F.unique("readonly")
  app.fs.makeAllDirectories(ro)
  local s = Sprite(3, 3)
  local img = s.cels[1].image:clone(); img:clear(pc.rgba(9, 9, 9, 255)); s.cels[1].image = img
  s:saveAs(app.fs.joinPath(ro, "locked.aseprite"))
  app.sprite = s
  os.execute('chmod 500 "' .. ro .. '"')
  local r = call("make_normal_map", { layer = "Layer 1" })
  os.execute('chmod 700 "' .. ro .. '"')
  T.eq(r.ok, false)
  T.eq(#app.sprites, 1, "no stray unsaved companion tab")
  T.eq(app.sprite == s, true)
end)
