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

T.test("set_pixels never creates the AI Draft layer; it must come from ensure_draft_layer", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("set_pixels", { layer = "AI Draft", pixels = { { x = 0, y = 1, color = "#ffffff" } } })
  T.eq(r.error, "This sprite has no AI Draft layer. Draft mode must be approved for it first (request_draft_mode).")
  T.eq(#s.layers, 1, "no stray layer")
  T.eq(call("ensure_draft_layer", {}).ok, true)
  local ok = call("set_pixels", { layer = " ai draft ", pixels = { { x = 0, y = 1, color = "#ffffff" } } })
  T.eq(ok.ok, true, ok.error)
  T.eq(F.px(s, 0, 1, "AI Draft"), pc.rgba(255, 255, 255, 255))
end)

T.test("edits keep the parts of a cel that hang off the canvas", function()
  F.closeAll()
  local s = F.rgbSprite()
  local cel = s.cels[1]
  local img = Image(4, 3, ColorMode.RGB)
  img:clear(0)
  img:drawPixel(3, 0, pc.rgba(9, 9, 9, 255)) -- lands at sprite x=5, off the 4-wide canvas
  cel.image = img
  cel.position = Point(2, 0)
  T.eq(call("set_pixels", { layer = "Body", pixels = { { x = 0, y = 0, color = "#0000ff" } } }).ok, true)
  T.eq(F.px(s, 5, 0, "Body"), pc.rgba(9, 9, 9, 255), "off-canvas pixel survives set_pixels")
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(0, 0, 255, 255))
  T.eq(call("transform", { layer = "Body", action = "outline", color = "#000000" }).ok, true)
  T.eq(F.px(s, 5, 0, "Body"), pc.rgba(9, 9, 9, 255), "off-canvas pixel survives transform")
  T.eq(call("annotate", { shapes = { { type = "dot", x = 0, y = 2 } } }).ok, true)
end)

T.test("indexed: the transparent index never stands in for an opaque color", function()
  F.closeAll()
  local s = Sprite(3, 1, ColorMode.INDEXED)
  local pal = s.palettes[1]
  pal:resize(4)
  pal:setColor(0, Color{ r = 0, g = 0, b = 0, a = 255 }) -- transparent index, stored as opaque black
  pal:setColor(1, Color{ r = 50, g = 50, b = 50, a = 255 })
  pal:setColor(2, Color{ r = 0, g = 0, b = 0, a = 255 }) -- the real black
  pal:setColor(3, Color{ r = 255, g = 0, b = 0, a = 255 })
  local img = s.cels[1].image:clone()
  img:clear(0)
  img:drawPixel(1, 0, 2)
  s.cels[1].image = img
  app.sprite = s
  local sp = call("set_pixels", { layer = "Layer 1", pixels = { { x = 2, y = 0, color = "#000000" } } })
  T.eq(sp.ok, true, sp.error)
  T.eq(s.cels[1].image:getPixel(2, 0), 2, "painted with the real black, not the transparent index")
  app.undo()
  local r = call("replace_color", { from = "#000000", to = "#ff0000" })
  T.eq(r.data.replaced, 1, "transparent background is not 'black'")
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
