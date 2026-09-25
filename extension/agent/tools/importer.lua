local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local paste = require("agent.tools.paste")

local M = {}

-- Frame numbers in `s` for args.frame / args.frames (default: frame 1).
local function frameNumbers(s, args)
  if args.frames then
    local a, b = edit.int(args.frames.from), edit.int(args.frames.to)
    sprites.frame(s, a)
    sprites.frame(s, b)
    local out = {}
    for n = a, b do out[#out + 1] = n end
    return out
  end
  return { sprites.frame(s, args.frame or 1).frameNumber }
end

local function region(args)
  if not args.region then return nil end
  return { x = edit.int(args.region.x), y = edit.int(args.region.y), w = edit.int(args.region.w), h = edit.int(args.region.h) }
end

function M.import_from_sprite(args)
  local dest = edit.editableSprite(args.sprite)
  local startFrame = (app.sprite == dest and app.frame) and app.frame.frameNumber or 1
  local handle = sprites.openIfNeeded(args.from, "read")
  local ok, result = pcall(function()
    local src = sprites.resolve(args.from)
    if args.layer then sprites.layer(src, args.layer) end
    local frames = paste.frameImages(src, args.layer, frameNumbers(src, args), region(args), args.flip)
    local name = "Import: " .. sprites.name(src) .. " / " .. (args.layer or "all layers")
    local at = args.at and { x = edit.int(args.at.x), y = edit.int(args.at.y) } or nil
    local layer, info
    edit.transaction(dest, "import", function()
      layer, info = paste.pasteLayer(dest, name, frames, startFrame, at, args.paletteMode)
    end)
    return { sprite = sprites.name(dest), layer = layer.name, frames = #frames, colorsAdded = info.colorsAdded }
  end)
  if handle and handle.close then handle.close() end
  if app.sprite ~= dest then pcall(function() app.sprite = dest end) end
  if not ok then error(result, 0) end
  return result
end

return M
