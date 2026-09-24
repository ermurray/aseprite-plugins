local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local function toColor(hex)
  local r, g, b, a = color.parseHex(hex)
  return Color{ r = r, g = g, b = b, a = a }
end

function M.set_palette(args)
  local s = edit.editableSprite(args.sprite)
  local n = #args.colors
  local colors = {}
  for i = 1, n do colors[i] = toColor(args.colors[i]) end
  edit.transaction(s, ("set palette (%d colors)"):format(n), function()
    local pal = Palette(n)
    for i = 1, n do pal:setColor(i - 1, colors[i]) end
    s:setPalette(pal)
  end)
  return { sprite = sprites.name(s), size = #s.palettes[1] }
end

function M.add_palette_colors(args)
  local s = edit.editableSprite(args.sprite)
  local pal = s.palettes[1]
  local existing = {}
  for i = 0, #pal - 1 do existing[color.fromColor(pal:getColor(i))] = true end
  local new = {}
  for i = 1, #args.colors do
    local c = toColor(args.colors[i])
    local key = color.fromColor(c)
    if not existing[key] then
      existing[key] = true
      new[#new + 1] = c
    end
  end
  if #new == 0 then return { sprite = sprites.name(s), added = 0, size = #pal } end
  if s.colorMode == ColorMode.INDEXED and #pal + #new > 256 then
    error("The palette would exceed 256 colors (indexed mode). Replace or merge colors first.", 0)
  end
  edit.transaction(s, ("add %d palette colors"):format(#new), function()
    local base = #pal
    pal:resize(base + #new)
    for i, c in ipairs(new) do pal:setColor(base + i - 1, c) end
  end)
  return { sprite = sprites.name(s), added = #new, size = #s.palettes[1] }
end

return M
