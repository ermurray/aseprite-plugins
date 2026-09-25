local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local function col(hex)
  local r, g, b, a = color.parseHex(hex)
  return Color{ r = r, g = g, b = b, a = a }
end

local function kernel(kind, size, allowed)
  size = size and edit.int(size) or allowed[1]
  for _, v in ipairs(allowed) do
    if v == size then return ("%s-%dx%d"):format(kind, size, size) end
  end
  local list = {}
  for i, v in ipairs(allowed) do list[i] = tostring(v) end
  error(("%s supports sizes %s and %s."):format(kind, table.concat(list, ", ", 1, #list - 1), list[#list]), 0)
end

local EFFECTS = {
  brightness_contrast = function(a) return "BrightnessContrast", { ui = false, brightness = a.brightness or 0, contrast = a.contrast or 0 } end,
  hue_saturation = function(a) return "HueSaturation", { ui = false, hue = a.hue or 0, saturation = a.saturation or 0, lightness = a.lightness or 0, mode = "hsl" } end,
  invert = function() return "InvertColor", { ui = false } end,
  despeckle = function(a) local n = edit.int(a.size or 3) return "Despeckle", { ui = false, width = n, height = n } end,
  blur = function(a) return "ConvolutionMatrix", { ui = false, fromResource = kernel("blur", a.size, { 3, 5, 7, 9 }) } end,
  sharpen = function(a) return "ConvolutionMatrix", { ui = false, fromResource = kernel("sharpen", a.size, { 3, 5, 7 }) } end,
  find_edges = function() return "ConvolutionMatrix", { ui = false, fromResource = "edges-find" } end,
  replace_color = function(a)
    if not a.from or not a.to then error("replace_color needs from and to.", 0) end
    return "ReplaceColor", { ui = false, from = col(a.from), to = col(a.to), tolerance = a.tolerance and edit.int(a.tolerance) or 0 }
  end,
}

function M.builtin_fx(args)
  local build = EFFECTS[args.effect]
  if not build then error("Unknown effect '" .. tostring(args.effect) .. "'.", 0) end
  local s = edit.editableSprite(args.sprite)
  local layer = edit.drawableLayer(s, args.layer)
  local frame = sprites.frame(s, args.frame)
  local command, params = build(args)
  edit.transaction(s, (tostring(args.effect):gsub("_", " ")), function()
    local saved = Selection()
    saved:add(s.selection)
    app.layer = layer
    app.frame = frame
    if args.region then
      s.selection = Selection(Rectangle(edit.int(args.region.x), edit.int(args.region.y), edit.int(args.region.w), edit.int(args.region.h)))
    end
    app.command[command](params)
    if args.region then s.selection = saved end
  end)
  return { sprite = sprites.name(s), layer = layer.name, frame = frame.frameNumber, effect = args.effect }
end

return M
