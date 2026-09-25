local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local fxm = require("agent.fx.math")

local M = {}
local pc = app.pixelColor

-- An RGB image of one frame of `sprite` (a layer, or flattened), whatever its color mode.
local function rgbaFrame(sprite, layerName, frame)
  local out = Image(sprite.width, sprite.height, ColorMode.RGB)
  out:clear(0)
  if not layerName then
    out:drawSprite(sprite, frame)
    return out
  end
  local cel = sprites.layer(sprite, layerName):cel(frame)
  if not cel then return out end
  local img, p, pal = cel.image, cel.position, sprite.palettes[1]
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local v = img:getPixel(x, y)
      local r, g, b, a
      if sprite.colorMode == ColorMode.INDEXED and v == sprite.transparentColor then
        a = 0
      else
        r, g, b, a = color.rgbaOf(v, sprite.colorMode, pal)
      end
      local sx, sy = x + p.x, y + p.y
      if a > 0 and sx >= 0 and sy >= 0 and sx < sprite.width and sy < sprite.height then
        out:drawPixel(sx, sy, pc.rgba(r, g, b, a))
      end
    end
  end
  return out
end

function M.frameImages(sprite, layerName, frameNumbers, region, flip)
  local r = region or { x = 0, y = 0, w = sprite.width, h = sprite.height }
  local out = {}
  for _, n in ipairs(frameNumbers) do
    local full = rgbaFrame(sprite, layerName, sprite.frames[n])
    local img = Image(r.w, r.h, ColorMode.RGB)
    img:clear(0)
    for y = 0, r.h - 1 do
      for x = 0, r.w - 1 do
        local sx, sy = r.x + x, r.y + y
        if sx >= 0 and sy >= 0 and sx < sprite.width and sy < sprite.height then
          local dx = flip == "horizontal" and (r.w - 1 - x) or x
          local dy = flip == "vertical" and (r.h - 1 - y) or y
          img:drawPixel(dx, dy, full:getPixel(sx, sy))
        end
      end
    end
    out[#out + 1] = { image = img, x = r.x, y = r.y }
  end
  return out
end

function M.uniqueLayerName(sprite, name)
  local taken = {}
  local function walk(layers)
    for _, l in ipairs(layers) do
      taken[l.name] = true
      if l.isGroup then walk(l.layers) end
    end
  end
  walk(sprite.layers)
  if not taken[name] then return name end
  local i = 2
  while taken[name .. " " .. i] do i = i + 1 end
  return name .. " " .. i
end

-- Converts an RGB image to `dest`'s color mode; "add" grows an indexed palette with missing colors.
local function convert(dest, img, paletteMode, added)
  if dest.colorMode == ColorMode.RGB then return img end
  local out = Image(img.width, img.height, dest.colorMode)
  if dest.colorMode == ColorMode.GRAYSCALE then
    out:clear(0)
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local v = img:getPixel(x, y)
        local a = pc.rgbaA(v)
        if a > 0 then
          out:drawPixel(x, y, pc.graya(math.floor(fxm.luminance(pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v)) + 0.5), a))
        end
      end
    end
    return out
  end
  local pal = dest.palettes[1]
  out:clear(dest.transparentColor)
  local index = {}
  local function paletteList()
    local list = {}
    for i = 0, #pal - 1 do
      if i ~= dest.transparentColor then
        local c = pal:getColor(i)
        list[#list + 1] = { r = c.red, g = c.green, b = c.blue, i = i }
        index[c.red * 65536 + c.green * 256 + c.blue] = index[c.red * 65536 + c.green * 256 + c.blue] or i
      end
    end
    return list
  end
  local list = paletteList()
  if #list == 0 and paletteMode ~= "add" then error("This sprite's palette has no colors to map to. Use paletteMode = add.", 0) end
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local v = img:getPixel(x, y)
      if pc.rgbaA(v) > 0 then
        local r, g, b = pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v)
        local key = r * 65536 + g * 256 + b
        local i = index[key]
        if not i and paletteMode == "add" then
          if #pal >= 256 then error("The palette would exceed 256 colors (indexed mode). Use paletteMode = nearest.", 0) end
          pal:resize(#pal + 1)
          i = #pal - 1
          pal:setColor(i, Color{ r = r, g = g, b = b })
          index[key] = i
          list[#list + 1] = { r = r, g = g, b = b, i = i }
          added.count = added.count + 1
        end
        if not i then i = list[fxm.nearest(r, g, b, list)].i end
        out:drawPixel(x, y, i)
      end
    end
  end
  return out
end

function M.pasteLayer(dest, name, frames, startFrame, at, paletteMode)
  local layer = dest:newLayer()
  layer.name = M.uniqueLayerName(dest, name)
  local added = { count = 0 }
  local first
  for i, fr in ipairs(frames) do
    local n = startFrame + i - 1
    while #dest.frames < n do dest:newEmptyFrame(#dest.frames + 1) end
    local x, y = at and at.x or fr.x, at and at.y or fr.y
    dest:newCel(layer, n, convert(dest, fr.image, paletteMode or "nearest", added), Point(x, y))
    first = first or Rectangle(x, y, fr.image.width, fr.image.height)
  end
  if first then dest.selection = Selection(first) end
  return layer, { colorsAdded = added.count }
end

return M
