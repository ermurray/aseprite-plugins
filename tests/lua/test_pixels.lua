local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args)) end

T.test("set_pixels paints and erases in one undo step", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("set_pixels", { layer = "Body", pixels = { { x = 3, y = 2, color = "#0000ff" }, { x = 0, y = 0, color = "." } } })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.changed, 2)
  T.eq(F.px(s, 3, 2, "Body"), pc.rgba(0, 0, 255, 255))
  T.eq(F.px(s, 0, 0, "Body"), 0)
  app.undo()
  T.eq(F.px(s, 3, 2, "Body"), 0)
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(255, 0, 0, 255))
end)

T.test("set_pixels rejects out-of-canvas pixels without changing anything", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("set_pixels", { layer = "Body", pixels = { { x = 1, y = 1, color = "#0000ff" }, { x = 9, y = 0, color = "#0000ff" } } })
  T.eq(r.error, "Pixel (9,0) is outside the sprite (4x3).")
  T.eq(F.px(s, 1, 1, "Body"), 0)
end)

T.test("set_pixels refuses reference tabs", function()
  F.closeAll()
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(F.tmp, "ref2.png"))
  app.sprite = ref
  T.eq(call("set_pixels", { layer = "Layer 1", pixels = { { x = 0, y = 0, color = "#000000" } } }).error,
    "'ref2.png' is a reference image tab; it is read-only.")
end)

T.test("set_pixels on AI Draft creates the layer at 40% opacity", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("set_pixels", { layer = "AI Draft", pixels = { { x = 0, y = 1, color = "#ffffff" } } })
  T.eq(r.ok, true, r.error)
  local top = s.layers[#s.layers]
  T.eq(top.name, "AI Draft")
  T.eq(top.opacity, 102)
end)

T.test("replace_color swaps colors across frames, with tolerance and region", function()
  F.closeAll()
  local s = F.rgbSprite()
  s:newFrame(1)
  local r = call("replace_color", { from = "#ff0000", to = "#00ffff" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.replaced, 2)
  T.eq(F.px(s, 0, 0, "Body", 1), pc.rgba(0, 255, 255, 255))
  T.eq(F.px(s, 0, 0, "Body", 2), pc.rgba(0, 255, 255, 255))
  app.undo()
  T.eq(F.px(s, 0, 0, "Body", 2), pc.rgba(255, 0, 0, 255))
  T.eq(call("replace_color", { from = "#fe0101", to = "#000000", tolerance = 0 }).data.replaced, 0)
  T.eq(call("replace_color", { from = "#fe0101", to = "#000000", tolerance = 2, frames = { from = 1, to = 1 } }).data.replaced, 1)
  T.eq(call("replace_color", { from = "#00ff00", to = "#000000", region = { x = 2, y = 0, w = 2, h = 3 } }).data.replaced, 0)
end)

T.test("replace_color in indexed mode remaps indices", function()
  F.closeAll()
  local s = Sprite(2, 1, ColorMode.INDEXED)
  local pal = s.palettes[1]
  pal:resize(3)
  pal:setColor(1, Color{ r = 10, g = 20, b = 30 })
  pal:setColor(2, Color{ r = 40, g = 50, b = 60 })
  local img = s.cels[1].image:clone()
  img:drawPixel(0, 0, 1)
  s.cels[1].image = img
  app.sprite = s
  local r = call("replace_color", { from = "#0a141e", to = "#28323c" })
  T.eq(r.data.replaced, 1)
  T.eq(s.cels[1].image:getPixel(0, 0), 2)
end)
