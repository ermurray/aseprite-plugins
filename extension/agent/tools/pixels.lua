local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local function ensureDraftLayer(s)
  for _, l in ipairs(s.layers) do
    if l.name == edit.DRAFT_LAYER then return l end
  end
  local l
  edit.transaction(s, "create AI Draft layer", function()
    l = s:newLayer()
    l.name = edit.DRAFT_LAYER
    l.opacity = edit.DRAFT_OPACITY
  end)
  return l
end
M.ensureDraftLayer = ensureDraftLayer

function M.set_pixels(args)
  local s = edit.editableSprite(args.sprite)
  local layerName = tostring(args.layer)
  if layerName:lower() == edit.DRAFT_LAYER:lower() then
    ensureDraftLayer(s)
    layerName = edit.DRAFT_LAYER
  end
  local layer = edit.drawableLayer(s, layerName)
  local frame = sprites.frame(s, args.frame)
  local pts = {}
  for i = 1, #args.pixels do
    local p = args.pixels[i]
    local x, y = edit.int(p.x), edit.int(p.y)
    if x < 0 or y < 0 or x >= s.width or y >= s.height then
      error(("Pixel (%d,%d) is outside the sprite (%dx%d)."):format(x, y, s.width, s.height), 0)
    end
    pts[#pts + 1] = { x = x, y = y, v = edit.pixelValue(s, p.color) }
  end
  edit.transaction(s, ("set %d pixels"):format(#pts), function()
    local img = edit.canvasImage(s, layer, frame)
    for _, p in ipairs(pts) do img:drawPixel(p.x, p.y, p.v) end
    edit.commit(s, layer, frame, img)
  end)
  return { sprite = sprites.name(s), layer = layer.name, frame = frame.frameNumber, changed = #pts }
end

local function editableLayers(layers, out)
  for _, l in ipairs(layers) do
    if l.isGroup then
      editableLayers(l.layers, out)
    elseif l.isEditable and not l.isTilemap and not l.isReference then
      out[#out + 1] = l
    end
  end
  return out
end

function M.replace_color(args)
  local s = edit.editableSprite(args.sprite)
  local layers = args.layer and { edit.drawableLayer(s, args.layer) } or editableLayers(s.layers, {})
  local fr, fg, fb, fa = color.parseHex(args.from)
  local toValue = edit.pixelValue(s, args.to)
  local tol = args.tolerance and edit.int(args.tolerance) or 0
  local first, last = 1, #s.frames
  if args.frames then
    first, last = edit.int(args.frames.from), math.min(edit.int(args.frames.to), #s.frames)
  end
  local rx, ry, rw, rh = 0, 0, s.width, s.height
  if args.region then
    rx, ry, rw, rh = edit.int(args.region.x), edit.int(args.region.y), edit.int(args.region.w), edit.int(args.region.h)
  end
  local pal = s.palettes[1]
  local function matches(v)
    local r, g, b, a = color.rgbaOf(v, s.colorMode, pal)
    return math.abs(r - fr) <= tol and math.abs(g - fg) <= tol and math.abs(b - fb) <= tol and math.abs(a - fa) <= tol
  end
  local replaced, cels = 0, 0
  edit.transaction(s, ("replace %s with %s"):format(args.from, args.to), function()
    for _, layer in ipairs(layers) do
      for f = first, last do
        local cel = layer:cel(f)
        if cel then
          local img, pos, changed = cel.image:clone(), cel.position, 0
          for y = 0, img.height - 1 do
            local sy = pos.y + y
            if sy >= ry and sy < ry + rh then
              for x = 0, img.width - 1 do
                local sx = pos.x + x
                if sx >= rx and sx < rx + rw and matches(img:getPixel(x, y)) then
                  img:drawPixel(x, y, toValue)
                  changed = changed + 1
                end
              end
            end
          end
          if changed > 0 then
            cel.image = img
            replaced, cels = replaced + changed, cels + 1
          end
        end
      end
    end
  end)
  return { sprite = sprites.name(s), replaced = replaced, cels = cels }
end

return M
