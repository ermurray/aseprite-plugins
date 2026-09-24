local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")

local M = {}

local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function outline(src, s, value, place)
  local clear = edit.transparentValue(s)
  local out = src:clone()
  local w, h, changed = src.width, src.height, 0
  local function opaque(x, y)
    return x >= 0 and y >= 0 and x < w and y < h and src:getPixel(x, y) ~= clear
  end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local here = opaque(x, y)
      if here == (place == "inside") then
        for _, d in ipairs(N4) do
          if opaque(x + d[1], y + d[2]) ~= here then
            out:drawPixel(x, y, value)
            changed = changed + 1
            break
          end
        end
      end
    end
  end
  return out, changed
end

local function flip(src, horizontal, rx, ry, rw, rh)
  local out = src:clone()
  for y = ry, ry + rh - 1 do
    for x = rx, rx + rw - 1 do
      local sx = horizontal and (rx + rw - 1 - (x - rx)) or x
      local sy = horizontal and y or (ry + rh - 1 - (y - ry))
      out:drawPixel(x, y, src:getPixel(sx, sy))
    end
  end
  return out, rw * rh
end

function M.transform(args)
  local s = edit.editableSprite(args.sprite)
  local layer = edit.drawableLayer(s, args.layer)
  local frame = sprites.frame(s, args.frame)
  local action = args.action
  local value = action == "outline" and edit.pixelValue(s, args.color or "#000000") or nil
  local rx, ry, rw, rh = 0, 0, s.width, s.height
  if args.region then
    rx, ry = math.max(0, edit.int(args.region.x)), math.max(0, edit.int(args.region.y))
    rw = math.min(s.width, edit.int(args.region.x) + edit.int(args.region.w)) - rx
    rh = math.min(s.height, edit.int(args.region.y) + edit.int(args.region.h)) - ry
    if rw <= 0 or rh <= 0 then error("Region is outside the sprite.", 0) end
  end
  local changed = 0
  edit.transaction(s, action .. " " .. layer.name, function()
    local img = edit.canvasImage(s, layer, frame)
    local out
    if action == "outline" then
      out, changed = outline(img, s, value, args.place or "outside")
    elseif action == "flip_horizontal" or action == "flip_vertical" then
      out, changed = flip(img, action == "flip_horizontal", rx, ry, rw, rh)
    else
      error("Unknown transform '" .. tostring(action) .. "'.", 0)
    end
    edit.commit(s, layer, frame, out)
  end)
  return { sprite = sprites.name(s), layer = layer.name, frame = frame.frameNumber, changed = changed }
end

return M
