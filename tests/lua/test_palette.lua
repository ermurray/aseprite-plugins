local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")

local function call(name, args) return tools.dispatch(name, F.decode(args)) end

T.test("set_palette replaces the palette in one undo step", function()
  F.closeAll()
  local s = F.rgbSprite()
  local before = #s.palettes[1]
  local r = call("set_palette", { colors = { "#000000", "#ffffff", "#ff000080" } })
  T.eq(r.ok, true, r.error)
  T.eq(#s.palettes[1], 3)
  T.eq(s.palettes[1]:getColor(2).alpha, 128)
  app.undo()
  T.eq(#s.palettes[1], before)
end)

T.test("add_palette_colors appends new colors and skips existing ones", function()
  F.closeAll()
  local s = F.rgbSprite()
  call("set_palette", { colors = { "#000000" } })
  local r = call("add_palette_colors", { colors = { "#000000", "#123456", "#abcdef" } })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.added, 2)
  T.eq(#s.palettes[1], 3)
  T.eq(s.palettes[1]:getColor(1).red, 0x12)
end)

T.test("indexed palettes are limited to 256 colors", function()
  F.closeAll()
  local s = Sprite(2, 2, ColorMode.INDEXED)
  app.sprite = s
  local pal = s.palettes[1]
  pal:resize(256)
  for i = 0, 255 do pal:setColor(i, Color{ r = i, g = 0, b = 0 }) end
  T.eq(call("add_palette_colors", { colors = { "#123457" } }).error,
    "The palette would exceed 256 colors (indexed mode). Replace or merge colors first.")
end)
