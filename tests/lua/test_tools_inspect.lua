local T = require("testlib")
local tools = require("agent.tools")
local inspect = require("agent.tools.inspect")
local color = require("agent.tools.color")

local pc = app.pixelColor
local tmp = app.fs.joinPath(app.fs.tempPath, "aseagent-tests")
app.fs.makeAllDirectories(tmp)

local function closeAll()
  while #app.sprites > 0 do app.sprites[1]:close() end
end

-- 4x3 RGB sprite, layer "Body": (0,0) red, (1,0) green, rest transparent.
local function rgbSprite(name)
  local s = Sprite(4, 3)
  local cel = s.cels[1]
  local img = cel.image:clone()
  img:drawPixel(0, 0, pc.rgba(255, 0, 0, 255))
  img:drawPixel(1, 0, pc.rgba(0, 255, 0, 255))
  cel.image = img
  s.layers[1].name = "Body"
  if name then s:saveAs(app.fs.joinPath(tmp, name)) end
  app.sprite = s
  return s
end

local function call(name, args)
  return tools.dispatch(name, args or {})
end

T.test("get_sprite_info describes the active sprite", function()
  closeAll()
  rgbSprite()
  local r = call("get_sprite_info")
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 4)
  T.eq(r.data.height, 3)
  T.eq(r.data.colorMode, "rgb")
  T.eq(r.data.frameCount, 1)
  T.eq(r.data.layers[1].name, "Body")
  T.eq(r.data.layers[1].blendMode, "normal")
  T.eq(r.data.activeFrame, 1)
end)

T.test("no open sprite gives a plain error", function()
  closeAll()
  local r = call("get_sprite_info")
  T.eq(r.ok, false)
  T.eq(r.error, "No sprite is open in Aseprite.")
end)

T.test("sprites resolve by file name, and unknown names list open sprites", function()
  closeAll()
  rgbSprite("first.aseprite")
  local other = Sprite(2, 2)
  app.sprite = other
  local r = call("get_sprite_info", { sprite = "first.aseprite" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 4)
  T.eq(r.data.activeFrame, nil, "not the active sprite")
  local bad = call("get_sprite_info", { sprite = "nope.aseprite" })
  T.eq(bad.ok, false)
  T.eq(bad.error:find("Sprite 'nope.aseprite' is not open", 1, true) ~= nil, true, bad.error)
end)

T.test("get_pixels returns hex rows with '.' for transparent", function()
  closeAll()
  rgbSprite()
  local r = call("get_pixels", { region = { x = 0, y = 0, w = 4, h = 1 } })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.rows, { "#ff0000 #00ff00 . ." })
  T.eq(r.data.frame, 1)
end)

T.test("get_pixels clips to the sprite and rejects oversized or outside regions", function()
  closeAll()
  rgbSprite()
  local r = call("get_pixels", { region = { x = 2, y = 0, w = 10, h = 1 } })
  T.eq(r.data.w, 2)
  T.eq(call("get_pixels", { region = { x = 0, y = 0, w = 65, h = 1 } }).error,
    "Region is limited to 64x64 pixels; use get_snapshot for larger areas.")
  T.eq(call("get_pixels", { region = { x = 10, y = 10, w = 2, h = 2 } }).error, "Region is outside the sprite.")
end)

T.test("get_pixels reads a single layer", function()
  closeAll()
  local s = rgbSprite()
  s:newLayer().name = "Empty"
  local r = call("get_pixels", { layer = "Empty", region = { x = 0, y = 0, w = 2, h = 1 } })
  T.deepEq(r.data.rows, { ". ." })
  T.eq(call("get_pixels", { layer = "Ghost", region = { x = 0, y = 0, w = 1, h = 1 } }).error, "Layer 'Ghost' not found.")
end)

T.test("accepts JSON numbers decoded as floats", function()
  closeAll()
  rgbSprite()
  local r = call("get_pixels", { frame = 1.0, region = { x = 0.0, y = 0.0, w = 2.0, h = 1.0 } })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.rows, { "#ff0000 #00ff00" })
end)

T.test("frames are 1-based and validated", function()
  closeAll()
  rgbSprite()
  T.eq(call("get_pixels", { frame = 5, region = { x = 0, y = 0, w = 1, h = 1 } }).error,
    "Frame 5 does not exist (sprite has 1 frames).")
end)

T.test("indexed sprites report palette colors", function()
  closeAll()
  local s = Sprite(2, 1, ColorMode.INDEXED)
  local pal = s.palettes[1]
  pal:resize(3)
  pal:setColor(1, Color{ r = 10, g = 20, b = 30, a = 255 })
  local cel = s.cels[1]
  local img = cel.image:clone()
  img:drawPixel(0, 0, s.transparentColor)
  img:drawPixel(1, 0, 1)
  cel.image = img
  app.sprite = s
  local px = call("get_pixels", { region = { x = 0, y = 0, w = 2, h = 1 } })
  T.deepEq(px.data.rows, { ". #0a141e" })
  local p = call("get_palette")
  T.eq(p.data.size, 3)
  T.eq(p.data.colors[2], "#0a141e")
  T.eq(p.data.transparentIndex, 0)
  T.eq(call("get_sprite_info").data.colorMode, "indexed")
end)

T.test("pixelToHex handles translucency and grayscale", function()
  T.eq(color.pixelToHex(pc.rgba(1, 2, 3, 128), ColorMode.RGB), "#01020380")
  T.eq(color.pixelToHex(pc.rgba(1, 2, 3, 0), ColorMode.RGB), ".")
  T.eq(color.pixelToHex(pc.graya(200, 255), ColorMode.GRAYSCALE), "#c8c8c8")
end)

T.test("snapshotScale upscales small sprites and caps big ones", function()
  T.eq(inspect.snapshotScale(16, 16, 512), 32)
  T.eq(inspect.snapshotScale(1000, 10, 512), 1)
  T.eq(inspect.snapshotScale(3000, 10, 512), 2048 / 3000)
end)

T.test("get_snapshot writes an upscaled PNG into the snapshot dir", function()
  closeAll()
  inspect.snapshotDir = tmp
  local s = Sprite(16, 16)
  app.sprite = s
  local r = call("get_snapshot")
  T.eq(r.ok, true, r.error)
  T.eq(r.data.scale, 32)
  T.eq(app.fs.filePath(r.data.pngPath), app.fs.filePath(app.fs.joinPath(tmp, "x.png")))
  T.eq(app.fs.fileName(r.data.pngPath):match("^aseagent%-[%w%-]+%.png$") ~= nil, true, r.data.pngPath)
  local img = Image{ fromFile = r.data.pngPath }
  T.eq(img.width, 512)
  os.remove(r.data.pngPath)
end)

T.test("get_snapshot crops regions and rejects regions outside the sprite", function()
  closeAll()
  inspect.snapshotDir = tmp
  rgbSprite()
  local r = call("get_snapshot", { region = { x = 0, y = 0, w = 2, h = 2 }, maxSize = 64 })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 64)
  T.deepEq(r.data.region, { x = 0, y = 0, w = 2, h = 2 })
  os.remove(r.data.pngPath)
  T.eq(call("get_snapshot", { region = { x = 50, y = 50, w = 2, h = 2 } }).error, "Region is outside the sprite.")
end)

T.test("get_snapshot without a bridge connection explains itself", function()
  closeAll()
  rgbSprite()
  inspect.snapshotDir = nil
  T.eq(call("get_snapshot").error, "Snapshot directory unknown (bridge not connected).")
end)

T.test("unknown tools and internal errors are reported, not thrown", function()
  T.eq(call("launch_missiles").error, "Unknown tool: launch_missiles")
end)

closeAll()
