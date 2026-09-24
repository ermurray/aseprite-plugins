local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")

local M = { snapshotDir = nil }

local BLEND_NAMES = {}
for _, n in ipairs{ "NORMAL", "MULTIPLY", "SCREEN", "OVERLAY", "DARKEN", "LIGHTEN", "COLOR_DODGE", "COLOR_BURN",
  "HARD_LIGHT", "SOFT_LIGHT", "DIFFERENCE", "EXCLUSION", "HUE", "SATURATION", "COLOR", "LUMINOSITY",
  "ADDITION", "SUBTRACT", "DIVIDE" } do
  if BlendMode[n] ~= nil then BLEND_NAMES[BlendMode[n]] = n:lower() end
end

local function layerTree(layers)
  local out = {}
  for _, l in ipairs(layers) do
    local e = { name = l.name, visible = l.isVisible, isGroup = l.isGroup, opacity = l.opacity }
    if l.isGroup then
      e.layers = layerTree(l.layers)
    else
      e.blendMode = BLEND_NAMES[l.blendMode] or tostring(l.blendMode)
    end
    out[#out + 1] = e
  end
  return out
end

-- Flattened visible image of a frame, or one layer's cel placed at its position.
local function render(sprite, frame, layerName)
  local img = Image(sprite.spec)
  img:clear()
  if layerName then
    local cel = sprites.layer(sprite, layerName):cel(frame)
    if cel then img:drawImage(cel.image, cel.position) end
  else
    img:drawSprite(sprite, frame)
  end
  return img
end

-- Intersects a {x,y,w,h} region with the sprite bounds; errors when empty.
local function clip(sprite, r)
  local x, y, w, h = math.floor(r.x), math.floor(r.y), math.floor(r.w), math.floor(r.h)
  local x1, y1 = math.max(0, x), math.max(0, y)
  local x2, y2 = math.min(sprite.width, x + w), math.min(sprite.height, y + h)
  if x2 <= x1 or y2 <= y1 then error("Region is outside the sprite.", 0) end
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

function M.get_sprite_info(args)
  local s = sprites.resolve(args.sprite)
  local durations = {}
  for i, f in ipairs(s.frames) do durations[i] = math.floor(f.duration * 1000 + 0.5) end
  local tags = {}
  for _, t in ipairs(s.tags) do
    tags[#tags + 1] = { name = t.name, from = t.fromFrame.frameNumber, to = t.toFrame.frameNumber }
  end
  local info = {
    sprite = sprites.name(s),
    path = s.filename,
    width = s.width,
    height = s.height,
    colorMode = color.COLOR_MODES[s.colorMode] or "other",
    frameCount = #s.frames,
    frameDurationsMs = durations,
    layers = layerTree(s.layers),
    tags = tags,
    paletteSize = #s.palettes[1],
  }
  if app.sprite == s then
    info.activeFrame = app.frame and app.frame.frameNumber
    info.activeLayer = app.layer and app.layer.name
  end
  if not s.selection.isEmpty then
    local b = s.selection.bounds
    info.selection = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  return info
end

function M.snapshotScale(w, h, maxSize)
  local long = math.max(w, h)
  if long > 2048 then return 2048 / long end
  return math.max(1, math.floor(maxSize / long))
end

local counter = 0

function M.get_snapshot(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local img = render(s, frame, args.layer)
  local region
  if args.region then
    region = clip(s, args.region)
    img = Image(img, Rectangle(region.x, region.y, region.w, region.h))
  end
  if not M.snapshotDir then error("Snapshot directory unknown (bridge not connected).", 0) end
  local scale = M.snapshotScale(img.width, img.height, args.maxSize or 512)
  if scale ~= 1 then
    img:resize(math.max(1, math.floor(img.width * scale + 0.5)), math.max(1, math.floor(img.height * scale + 0.5)))
  end
  counter = counter + 1
  local path = app.fs.joinPath(M.snapshotDir, ("aseagent-%d-%d.png"):format(os.time(), counter))
  img:saveAs{ filename = path, palette = s.palettes[1] }
  return {
    pngPath = path,
    sprite = sprites.name(s),
    frame = frame.frameNumber,
    layer = args.layer,
    region = region,
    width = img.width,
    height = img.height,
    scale = scale,
  }
end

function M.get_pixels(args)
  local s = sprites.resolve(args.sprite)
  local r = args.region
  if not r then error("region is required.", 0) end
  if r.w > 64 or r.h > 64 then error("Region is limited to 64x64 pixels; use get_snapshot for larger areas.", 0) end
  local frame = sprites.frame(s, args.frame)
  r = clip(s, r)
  local img = render(s, frame, args.layer)
  local pal = s.palettes[1]
  local rows = {}
  for y = r.y, r.y + r.h - 1 do
    local row = {}
    for x = r.x, r.x + r.w - 1 do
      row[#row + 1] = color.pixelToHex(img:getPixel(x, y), s.colorMode, pal, s.transparentColor)
    end
    rows[#rows + 1] = table.concat(row, " ")
  end
  return {
    sprite = sprites.name(s),
    frame = frame.frameNumber,
    x = r.x, y = r.y, w = r.w, h = r.h,
    legend = "'.' = transparent; colors are #rrggbb or #rrggbbaa",
    rows = rows,
  }
end

function M.get_palette(args)
  local s = sprites.resolve(args.sprite)
  local pal = s.palettes[1]
  local colors = {}
  for i = 0, #pal - 1 do colors[#colors + 1] = color.fromColor(pal:getColor(i)) end
  return {
    sprite = sprites.name(s),
    size = #pal,
    colors = colors,
    transparentIndex = (s.colorMode == ColorMode.INDEXED) and s.transparentColor or nil,
  }
end

return M
