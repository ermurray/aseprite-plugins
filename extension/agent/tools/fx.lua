local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")
local target = require("agent.tools.fxtarget")
local project = require("agent.project")
local fxm = require("agent.fx.math")

local M = {}
local pc = app.pixelColor
local rgba = target.rgba

local function hexValue(hex)
  local r, g, b, a = color.parseHex(hex)
  return pc.rgba(r, g, b, a)
end

local function result(s, layers, changed, extra)
  local out = { sprite = sprites.name(s), layer = #layers == 1 and layers[1].name or nil, changed = changed }
  for k, v in pairs(extra or {}) do out[k] = v end
  return out
end

-- Iterates the target rectangle in sprite coordinates, giving image coordinates too.
local function each(r, o, fn)
  for y = r.y, r.y + r.h - 1 do
    for x = r.x, r.x + r.w - 1 do fn(x, y, x - o.x, y - o.y) end
  end
end

function M.dither(args)
  local s, layers, frames, r = target.resolve(args)
  local va, vb = hexValue(args.colorA), hexValue(args.colorB)
  local pattern, amount, onlyOpaque = args.pattern or "bayer4", args.amount, args.onlyOpaque ~= false
  local n = target.apply(s, layers, frames, "dither", function(img, o)
    local c = 0
    each(r, o, function(x, y, ix, iy)
      if not onlyOpaque or pc.rgbaA(img:getPixel(ix, iy)) > 0 then
        img:drawPixel(ix, iy, fxm.ditherPick(pattern, x, y, amount) and vb or va)
        c = c + 1
      end
    end)
    return c
  end)
  return result(s, layers, n)
end

function M.gradient_fill(args)
  local s, layers, frames, r = target.resolve(args)
  local values = {}
  for i = 1, #args.colors do values[i] = hexValue(args.colors[i]) end
  local radial = args.type == "radial"
  local cx, cy = r.x + (r.w - 1) / 2, r.y + (r.h - 1) / 2
  local radius = math.sqrt((r.w / 2) ^ 2 + (r.h / 2) ^ 2)
  local onlyOpaque = args.onlyOpaque == true
  local n = target.apply(s, layers, frames, "gradient", function(img, o)
    local c = 0
    each(r, o, function(x, y, ix, iy)
      if not onlyOpaque or pc.rgbaA(img:getPixel(ix, iy)) > 0 then
        local t = radial and fxm.radialT(x, y, cx, cy, radius) or fxm.linearT(x, y, r, args.angle or 0)
        img:drawPixel(ix, iy, values[fxm.gradientIndex(t, #values, args.dither, x, y)])
        c = c + 1
      end
    end)
    return c
  end)
  return result(s, layers, n)
end

function M.pixel_perfect(args)
  local s, layers, frames, r = target.resolve(args)
  local n = target.apply(s, layers, frames, "pixel-perfect", function(img, o)
    local opaque = {}
    for yy = 0, r.h - 1 do
      for xx = 0, r.w - 1 do
        opaque[yy * r.w + xx + 1] = pc.rgbaA(img:getPixel(r.x + xx - o.x, r.y + yy - o.y)) > 0
      end
    end
    local removed = fxm.pixelPerfectRemovals(opaque, r.w, r.h)
    for _, p in ipairs(removed) do img:drawPixel(r.x + p.x - o.x, r.y + p.y - o.y, 0) end
    return #removed
  end)
  return result(s, layers, n)
end

local function paletteColors(s, which)
  local pal
  if which == "sprite" then
    pal = s.palettes[1]
  else
    local root = sprites.projectRoot
    local path = root and app.fs.joinPath(root, project.DIR, "palette.gpl")
    if not path or not app.fs.isFile(path) then
      error('This project has no palette. Pick one in Project settings, or use palette = "sprite".', 0)
    end
    pal = Palette{ fromFile = path }
  end
  local list, set = {}, {}
  for i = 0, #pal - 1 do
    local c = pal:getColor(i)
    if c.alpha > 0 then
      list[#list + 1] = { r = c.red, g = c.green, b = c.blue }
      set[c.red * 65536 + c.green * 256 + c.blue] = true
    end
  end
  return list, set
end

function M.snap_to_palette(args)
  local s, layers, frames = target.resolve(args, { layerOptional = true })
  local list, set = paletteColors(s, args.palette or "project")
  local n = target.apply(s, layers, frames, "snap to palette", function(img)
    local c = 0
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local r, g, b, a = rgba(img:getPixel(x, y))
        if a > 0 and not set[r * 65536 + g * 256 + b] then
          local p = list[fxm.nearest(r, g, b, list)]
          img:drawPixel(x, y, pc.rgba(p.r, p.g, p.b, a))
          c = c + 1
        end
      end
    end
    return c
  end)
  return result(s, layers, n)
end

local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local N8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }

function M.selout(args)
  local s, layers, frames, r = target.resolve(args)
  local darken = args.darken or 0.35
  local n = target.apply(s, layers, frames, "selout", function(img, o)
    local w, h = img.width, img.height
    local function A(x, y) return x >= 0 and y >= 0 and x < w and y < h and pc.rgbaA(img:getPixel(x, y)) > 0 end
    local function isEdge(x, y)
      if not A(x, y) then return false end
      for _, d in ipairs(N4) do if not A(x + d[1], y + d[2]) then return true end end
      return false
    end
    local edges, counts = {}, {}
    each(r, o, function(_, _, ix, iy)
      if isEdge(ix, iy) then
        local v = img:getPixel(ix, iy)
        edges[#edges + 1] = { ix, iy, v }
        counts[v] = (counts[v] or 0) + 1
      end
    end)
    local outline = args.outlineColor and hexValue(args.outlineColor)
    if not outline then
      local best = 0
      for v, k in pairs(counts) do if k > best then outline, best = v, k end end
    end
    local src = img:clone()
    local c = 0
    for _, e in ipairs(edges) do
      local ix, iy, v = e[1], e[2], e[3]
      if v == outline then
        local fill
        for _, d in ipairs(N4) do
          local nx, ny = ix + d[1], iy + d[2]
          if A(nx, ny) and not isEdge(nx, ny) then fill = src:getPixel(nx, ny) break end
        end
        if not fill then
          for _, d in ipairs(N8) do
            local nx, ny = ix + d[1], iy + d[2]
            if A(nx, ny) and src:getPixel(nx, ny) ~= outline then fill = src:getPixel(nx, ny) break end
          end
        end
        if fill then
          local fr, fg, fb = rgba(fill)
          local dr, dg, db = fxm.darken(fr, fg, fb, darken)
          img:drawPixel(ix, iy, pc.rgba(dr, dg, db, pc.rgbaA(v)))
          c = c + 1
        end
      end
    end
    return c
  end)
  return result(s, layers, n)
end

local function newLayerBelow(s, source, name)
  local l = s:newLayer()
  l.name = name
  l.stackIndex = source.stackIndex
  return l
end

function M.layer_style(args)
  local s, layers, frames, r = target.resolve(args)
  local source = layers[1]
  local value = hexValue(args.color)
  if args.style == "overlay" then
    local cr, cg, cb = color.parseHex(args.color)
    local amount = args.amount or 0.5
    local n = target.apply(s, layers, frames, "color overlay", function(img, o)
      local c = 0
      each(r, o, function(_, _, ix, iy)
        local pr, pg, pb, pa = rgba(img:getPixel(ix, iy))
        if pa > 0 then
          local mr, mg, mb = fxm.mix(pr, pg, pb, cr, cg, cb, amount)
          img:drawPixel(ix, iy, pc.rgba(mr, mg, mb, pa))
          c = c + 1
        end
      end)
      return c
    end)
    return result(s, layers, n)
  end

  local name = source.name .. (args.style == "stroke" and " stroke" or " shadow")
  local total = 0
  edit.transaction(s, args.style, function()
    local dest = newLayerBelow(s, source, name)
    for _, f in ipairs(frames) do
      local img, o = edit.canvasImage(s, source, f)
      local w, h = img.width, img.height
      local out = Image(img.spec)
      out:clear(0)
      local opaque = {}
      for y = 0, h - 1 do for x = 0, w - 1 do opaque[y * w + x + 1] = pc.rgbaA(img:getPixel(x, y)) > 0 end end
      if args.style == "stroke" then
        for _, p in ipairs(fxm.dilate(opaque, w, h, args.width or 1)) do
          local sx, sy = p.x + o.x, p.y + o.y
          if sx >= r.x - (args.width or 1) and sy >= r.y - (args.width or 1) and sx < r.x + r.w + (args.width or 1) and sy < r.y + r.h + (args.width or 1) then
            out:drawPixel(p.x, p.y, value)
            total = total + 1
          end
        end
      else
        local dx, dy = args.offsetX or 1, args.offsetY or 1
        for y = 0, h - 1 do
          for x = 0, w - 1 do
            if opaque[y * w + x + 1] and x + dx >= 0 and y + dy >= 0 and x + dx < w and y + dy < h then
              out:drawPixel(x + dx, y + dy, value)
              total = total + 1
            end
          end
        end
      end
      edit.commit(s, dest, f, out, o)
    end
  end)
  return result(s, layers, total, { newLayer = name })
end

return M
