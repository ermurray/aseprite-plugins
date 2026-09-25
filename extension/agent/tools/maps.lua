local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local inspect = require("agent.tools.inspect")
local fxm = require("agent.fx.math")

local M = {}
local pc = app.pixelColor

-- Luminance and opacity grids for an RGB image.
local function grids(img)
  local w, h = img.width, img.height
  local lum, opaque = {}, {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local v = img:getPixel(x, y)
      local i = y * w + x + 1
      opaque[i] = pc.rgbaA(v) > 0
      lum[i] = fxm.luminance(pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v))
    end
  end
  return lum, opaque, w, h
end

local function layerImage(s, layerName, frame)
  local img = Image(s.width, s.height, ColorMode.RGB)
  img:clear(0)
  if layerName then
    local cel = sprites.layer(s, layerName):cel(frame)
    if cel then img:drawImage(cel.image, cel.position) end
  else
    img:drawSprite(s, frame)
  end
  return img
end

local function companionPath(s, suffix)
  return app.fs.joinPath(app.fs.filePath(s.filename), app.fs.fileTitle(s.filename) .. suffix .. ".aseprite")
end

local function ensureClosed(path)
  for _, o in ipairs(app.sprites) do
    if o.filename == path then error("Close " .. app.fs.fileName(path) .. " first: it will be replaced.", 0) end
  end
end

local function writeCompanion(s, path, layerName, render)
  local prev = app.sprite
  local out = Sprite(s.width, s.height, ColorMode.RGB)
  for i = 2, #s.frames do out:newEmptyFrame(i) end
  for i, f in ipairs(s.frames) do out.frames[i].duration = f.duration end
  out.layers[1].name = layerName
  for i, f in ipairs(s.frames) do
    local img = render(f)
    local cel = out.layers[1]:cel(i)
    if cel then cel.image = img; cel.position = Point(0, 0) else out:newCel(out.layers[1], i, img, Point(0, 0)) end
  end
  out:saveAs(path)
  out:close()
  if prev then app.sprite = prev end
end

function M.make_normal_map(args)
  local s = edit.editableSprite(args.sprite)
  if app.fs.filePath(s.filename) == "" then error("Save the sprite first: maps are saved next to it.", 0) end
  sprites.layer(s, args.layer)
  local normalPath, heightPath = companionPath(s, "_normal"), companionPath(s, "_height")
  ensureClosed(normalPath)
  if args.saveHeight ~= false then ensureClosed(heightPath) end
  local source, bevel = args.source or "both", edit.int(args.bevel or 3)
  local strength, convention, quantize = args.strength or 2, args.convention or "opengl", args.quantize or "off"
  local function heightsFor(f)
    local lum, opaque, w, h = grids(layerImage(s, args.layer, f))
    return fxm.heights(lum, opaque, w, h, source, bevel), opaque, w, h
  end
  writeCompanion(s, normalPath, "Normal", function(f)
    local hts, opaque, w, h = heightsFor(f)
    local normals = fxm.normals(hts, opaque, w, h, strength, convention, quantize)
    local img = Image(w, h, ColorMode.RGB)
    img:clear(0)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local n = normals[y * w + x + 1]
        if n then
          local r, g, b = fxm.encodeNormal(n[1], n[2], n[3])
          img:drawPixel(x, y, pc.rgba(r, g, b, 255))
        end
      end
    end
    return img
  end)
  local result = { normal = sprites.name({ filename = normalPath }), frames = #s.frames }
  if args.saveHeight ~= false then
    writeCompanion(s, heightPath, "Height", function(f)
      local hts, opaque, w, h = heightsFor(f)
      local img = Image(w, h, ColorMode.RGB)
      img:clear(0)
      for i = 1, w * h do
        if opaque[i] then
          local v = math.floor(hts[i] * 255 + 0.5)
          img:drawPixel((i - 1) % w, (i - 1) // w, pc.rgba(v, v, v, 255))
        end
      end
      return img
    end)
    result.height = sprites.name({ filename = heightPath })
  end
  return result
end

function M.check_readability(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local src = layerImage(s, nil, frame)
  local mode = args.mode or "both"
  local function view(kind)
    local img = Image(src.width, src.height, ColorMode.RGB)
    img:clear(0)
    for y = 0, src.height - 1 do
      for x = 0, src.width - 1 do
        local v = src:getPixel(x, y)
        local a = pc.rgbaA(v)
        if a > 0 then
          if kind == "values" then
            local l = math.floor(fxm.luminance(pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v)) + 0.5)
            img:drawPixel(x, y, pc.rgba(l, l, l, a))
          else
            img:drawPixel(x, y, pc.rgba(40, 40, 40, 255))
          end
        end
      end
    end
    return img
  end
  local out
  if mode == "both" then
    local a, b = view("values"), view("silhouette")
    out = Image(a.width * 2 + 2, a.height, ColorMode.RGB)
    out:clear(0)
    out:drawImage(a, Point(0, 0))
    out:drawImage(b, Point(a.width + 2, 0))
  else
    out = view(mode)
  end
  return inspect.saveSnapshot(out, s, { frame = frame.frameNumber, mode = mode })
end

function M.light_preview(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local base = layerImage(s, args.layer, frame)
  local lum, opaque, w, h = grids(base)
  local hts = fxm.heights(lum, opaque, w, h, args.source or "both", edit.int(args.bevel or 3))
  local normals = fxm.normals(hts, opaque, w, h, args.strength or 2, "opengl", "off")
  local lz, ambient = args.lightZ or 0.6, args.ambient or 0.25
  local out = Image(w, h, ColorMode.RGB)
  out:clear(0)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local n = normals[y * w + x + 1]
      if n then
        local k = fxm.shade(n, args.lightX, args.lightY, lz, ambient)
        local v = base:getPixel(x, y)
        out:drawPixel(x, y, pc.rgba(
          math.min(255, math.floor(pc.rgbaR(v) * k + 0.5)),
          math.min(255, math.floor(pc.rgbaG(v) * k + 0.5)),
          math.min(255, math.floor(pc.rgbaB(v) * k + 0.5)),
          pc.rgbaA(v)))
      end
    end
  end
  return inspect.saveSnapshot(out, s, { frame = frame.frameNumber, light = { args.lightX, args.lightY, lz } })
end

return M
