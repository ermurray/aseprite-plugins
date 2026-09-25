local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local paste = require("agent.tools.paste")
local clips = require("agent.clips")

local M = {}

local function framesArg(s, args)
  if args.frames then
    local out = {}
    for n = sprites.frame(s, args.frames.from).frameNumber, sprites.frame(s, args.frames.to).frameNumber do out[#out + 1] = n end
    return out
  end
  return { sprites.frame(s, args.frame).frameNumber }
end

function M.list_clips(args)
  local out = {}
  for _, c in ipairs(clips.list(sprites.projectRoot, args.filter)) do
    out[#out + 1] = { name = c.name, tags = c.tags, width = c.width, height = c.height, frames = c.frames, pinned = c.pinned, source = c.source }
  end
  return { clips = out }
end

function M.save_clip(args)
  local root = sprites.projectRoot
  clips.dir(root)
  local s = sprites.resolve(args.sprite)
  if args.layer then sprites.layer(s, args.layer) end
  local region
  if args.region then
    region = { x = edit.int(args.region.x), y = edit.int(args.region.y), w = edit.int(args.region.w), h = edit.int(args.region.h) }
  elseif not s.selection.isEmpty then
    local b = s.selection.bounds
    region = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  local tags = {}
  if args.tags then for i = 1, #args.tags do tags[i] = tostring(args.tags[i]) end end
  local entry, evicted = clips.save(root, s, {
    name = tostring(args.name), tags = tags, layer = args.layer, region = region,
    frames = framesArg(s, args), replace = args.replace == true,
  })
  return { name = entry.name, width = entry.width, height = entry.height, frames = entry.frames, evicted = evicted }
end

function M.insert_clip(args)
  local root = sprites.projectRoot
  clips.dir(root)
  local dest = edit.editableSprite(args.sprite)
  local frames, c = clips.frames(root, tostring(args.name))
  if args.flip then
    for _, fr in ipairs(frames) do
      local src, img = fr.image, Image(fr.image.spec)
      img:clear(0)
      for y = 0, src.height - 1 do
        for x = 0, src.width - 1 do
          local dx = args.flip == "horizontal" and (src.width - 1 - x) or x
          local dy = args.flip == "vertical" and (src.height - 1 - y) or y
          img:drawPixel(dx, dy, src:getPixel(x, y))
        end
      end
      fr.image = img
    end
  end
  local at
  if args.at then at = { x = edit.int(args.at.x), y = edit.int(args.at.y) }
  elseif not dest.selection.isEmpty then at = { x = dest.selection.bounds.x, y = dest.selection.bounds.y }
  else at = { x = 0, y = 0 } end
  local startFrame = (app.sprite == dest and app.frame) and app.frame.frameNumber or 1
  local layer, info
  edit.transaction(dest, "insert clip " .. c.name, function()
    layer, info = paste.pasteLayer(dest, "Clip: " .. c.name, frames, startFrame, at, args.paletteMode)
  end)
  return { sprite = sprites.name(dest), layer = layer.name, frames = #frames, colorsAdded = info.colorsAdded }
end

function M.delete_clip(args)
  clips.delete(sprites.projectRoot, tostring(args.name))
  return { deleted = args.name }
end

function M.pin_clip(args)
  clips.pin(sprites.projectRoot, tostring(args.name), args.pinned == true)
  return { name = args.name, pinned = args.pinned == true }
end

return M
