local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")

local M = {
  DRAFT_LAYER = "AI Draft",
  NOTES_LAYER = "Agent Notes",
  DRAFT_OPACITY = 102,
}

function M.int(v)
  return math.tointeger(v) or math.floor(v)
end

function M.isReference(sprite)
  local ext = app.fs.fileExtension(sprite.filename):lower()
  return ext ~= "" and ext ~= "aseprite" and ext ~= "ase"
end

function M.editableSprite(ref)
  local s = sprites.resolve(ref)
  if M.isReference(s) then
    error("'" .. sprites.name(s) .. "' is a reference image tab; it is read-only.", 0)
  end
  return s
end

function M.drawableLayer(sprite, name)
  local l = sprites.layer(sprite, name)
  if l.isGroup then error("Layer '" .. name .. "' is a group; name one of its layers.", 0) end
  if l.isTilemap or l.isReference then error("Layer '" .. name .. "' is a tilemap or reference layer; it can't be edited.", 0) end
  if not l.isEditable then error("Layer '" .. name .. "' is locked.", 0) end
  return l
end

-- Runs fn as one undoable step on `sprite` (temporarily active). Errors roll back and re-raise.
function M.transaction(sprite, label, fn)
  local prev = app.sprite
  if prev ~= sprite then app.sprite = sprite end
  local out
  local ok, err = pcall(function()
    app.transaction("Agent: " .. label, function() out = fn() end)
  end)
  if prev and prev ~= sprite then app.sprite = prev end
  if not ok then error(err, 0) end
  return out
end

function M.transparentValue(sprite)
  if sprite.colorMode == ColorMode.INDEXED then return sprite.transparentColor end
  return 0
end

function M.pixelValue(sprite, hex)
  if hex == "." then return M.transparentValue(sprite) end
  local r, g, b, a = color.parseHex(hex)
  local pc = app.pixelColor
  if sprite.colorMode == ColorMode.RGB then return pc.rgba(r, g, b, a) end
  if sprite.colorMode == ColorMode.GRAYSCALE then
    return pc.graya(math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5), a)
  end
  local pal = sprite.palettes[1]
  for i = 0, #pal - 1 do
    local c = i ~= sprite.transparentColor and pal:getColor(i)
    if c and c.red == r and c.green == g and c.blue == b and c.alpha == a then return i end
  end
  error(hex .. " is not in the palette of " .. sprites.name(sprite) .. " (indexed mode). Add it with add_palette_colors first.", 0)
end

-- A copy of the layer's image in `frame` covering the canvas plus any part of the cel that
-- hangs off it (Aseprite keeps off-canvas pixels). Returns the image and its origin in
-- sprite coordinates: sprite (x, y) is image (x - origin.x, y - origin.y).
function M.canvasImage(sprite, layer, frame)
  local x1, y1, x2, y2 = 0, 0, sprite.width, sprite.height
  local cel = layer:cel(frame)
  if cel then
    local b = cel.bounds
    x1, y1 = math.min(x1, b.x), math.min(y1, b.y)
    x2, y2 = math.max(x2, b.x + b.width), math.max(y2, b.y + b.height)
  end
  local spec = sprite.spec
  spec.width, spec.height = x2 - x1, y2 - y1
  local img = Image(spec)
  img:clear(M.transparentValue(sprite))
  if cel then img:drawImage(cel.image, Point(cel.position.x - x1, cel.position.y - y1), 255, BlendMode.SRC) end
  return img, Point(x1, y1)
end

-- Writes an image from canvasImage back as the layer's cel. Call inside M.transaction.
function M.commit(sprite, layer, frame, img, origin)
  origin = origin or Point(0, 0)
  local cel = layer:cel(frame)
  if cel then
    cel.image = img
    cel.position = origin
  else
    sprite:newCel(layer, frame, img, origin)
  end
end

function M.isDraftName(name)
  return type(name) == "string" and name:match("^%s*(.-)%s*$"):lower() == M.DRAFT_LAYER:lower()
end

return M
