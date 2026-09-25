local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")

local M = {}
local pc = app.pixelColor

function M.rgba(v)
  return pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v), pc.rgbaA(v)
end

local function editableLayers(layers, out)
  for _, l in ipairs(layers) do
    if l.isGroup then editableLayers(l.layers, out)
    elseif l.isEditable and not l.isTilemap and not l.isReference then out[#out + 1] = l end
  end
  return out
end

function M.resolve(args, opts)
  local s = edit.editableSprite(args.sprite)
  if s.colorMode ~= ColorMode.RGB then
    error("Effects work on RGB sprites. Convert with Sprite > Color Mode > RGB first.", 0)
  end
  local layers
  if args.layer then layers = { edit.drawableLayer(s, args.layer) }
  elseif opts and opts.layerOptional then layers = editableLayers(s.layers, {})
  else error("Name the layer to work on.", 0) end
  local frames = {}
  if args.allFrames then
    for _, f in ipairs(s.frames) do frames[#frames + 1] = f end
  else
    frames[1] = sprites.frame(s, args.frame)
  end
  local r
  if args.region then
    r = { x = edit.int(args.region.x), y = edit.int(args.region.y), w = edit.int(args.region.w), h = edit.int(args.region.h) }
  elseif not s.selection.isEmpty then
    local b = s.selection.bounds
    r = { x = b.x, y = b.y, w = b.width, h = b.height }
  else
    r = { x = 0, y = 0, w = s.width, h = s.height }
  end
  local x1, y1 = math.max(0, r.x), math.max(0, r.y)
  local x2, y2 = math.min(s.width, r.x + r.w), math.min(s.height, r.y + r.h)
  if x2 <= x1 or y2 <= y1 then error("Region is outside the sprite.", 0) end
  return s, layers, frames, { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Runs fn(img, origin, frame, layer) on every layer x frame inside ONE transaction; commits changed images.
function M.apply(s, layers, frames, label, fn)
  local total = 0
  edit.transaction(s, label, function()
    for _, layer in ipairs(layers) do
      for _, f in ipairs(frames) do
        local img, o = edit.canvasImage(s, layer, f)
        local n = fn(img, o, f, layer) or 0
        if n > 0 then
          edit.commit(s, layer, f, img, o)
          total = total + n
        end
      end
    end
  end)
  return total
end

return M
