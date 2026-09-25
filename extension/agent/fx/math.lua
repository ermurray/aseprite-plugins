-- Pure pixel-art algorithms on plain tables; no Aseprite objects, so they are easy to test.
local M = {}

M.BAYER = {
  bayer2 = { { 0, 2 }, { 3, 1 } },
  bayer4 = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } },
}

function M.threshold(pattern, x, y)
  if pattern == "checker" then return ((x + y) % 2 == 0) and 0.25 or 0.75 end
  local m = M.BAYER[pattern] or M.BAYER.bayer4
  local n = #m
  return (m[y % n + 1][x % n + 1] + 0.5) / (n * n)
end

function M.ditherPick(pattern, x, y, amount)
  return amount > M.threshold(pattern, x, y)
end

function M.linearT(x, y, rect, angleDeg)
  local a = math.rad(angleDeg or 0)
  local dx, dy = math.cos(a), math.sin(a)
  local lo, hi = math.huge, -math.huge
  for _, c in ipairs{ { rect.x, rect.y }, { rect.x + rect.w - 1, rect.y }, { rect.x, rect.y + rect.h - 1 }, { rect.x + rect.w - 1, rect.y + rect.h - 1 } } do
    local p = c[1] * dx + c[2] * dy
    lo, hi = math.min(lo, p), math.max(hi, p)
  end
  if hi - lo < 1e-9 then return 0 end
  return math.max(0, math.min(1, ((x * dx + y * dy) - lo) / (hi - lo)))
end

function M.radialT(x, y, cx, cy, radius)
  if radius <= 0 then return 0 end
  return math.min(1, math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2) / radius)
end

function M.gradientIndex(t, count, pattern, x, y)
  if count <= 1 then return 1 end
  local seg = t * (count - 1)
  local i = math.floor(seg)
  if i >= count - 1 then return count end
  local u = seg - i
  local nextOne
  if pattern and pattern ~= "none" then nextOne = M.ditherPick(pattern, x, y, u) else nextOne = u >= 0.5 end
  return i + (nextOne and 2 or 1)
end

-- Removes L-corner pixels from 1px strokes, scanning in order so staircases thin to diagonals.
function M.pixelPerfectRemovals(opaque, w, h)
  local function at(x, y) return x >= 0 and y >= 0 and x < w and y < h and opaque[y * w + x + 1] == true end
  local removed = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      if at(x, y) then
        local e, wv, n, s = at(x + 1, y), at(x - 1, y), at(x, y - 1), at(x, y + 1)
        local horiz = (e and 1 or 0) + (wv and 1 or 0)
        local vert = (n and 1 or 0) + (s and 1 or 0)
        if horiz == 1 and vert == 1 then
          local hx, vy = e and 1 or -1, s and 1 or -1
          if not at(x + hx, y + vy) then
            local ok, count = true, 0
            for dy = -1, 1 do
              for dx = -1, 1 do
                if (dx ~= 0 or dy ~= 0) and at(x + dx, y + dy) then
                  count = count + 1
                  local isArm = (dx == hx and dy == 0) or (dx == 0 and dy == vy)
                  local touchesArm = (math.abs(dx - hx) <= 1 and math.abs(dy) <= 1) or (math.abs(dx) <= 1 and math.abs(dy - vy) <= 1)
                  if not isArm and not touchesArm then ok = false end
                end
              end
            end
            if ok and count <= 3 then
              opaque[y * w + x + 1] = false
              removed[#removed + 1] = { x = x, y = y }
            end
          end
        end
      end
    end
  end
  return removed
end

function M.redmean(r1, g1, b1, r2, g2, b2)
  local rm = (r1 + r2) / 2
  local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
  return math.sqrt((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db)
end

function M.nearest(r, g, b, palette)
  local best, bestD = 1, math.huge
  for i, c in ipairs(palette) do
    local d = M.redmean(r, g, b, c.r, c.g, c.b)
    if d < bestD then best, bestD = i, d end
  end
  return best
end

function M.luminance(r, g, b)
  return 0.299 * r + 0.587 * g + 0.114 * b
end

local function round(v) return math.floor(v + 0.5) end

function M.darken(r, g, b, amount)
  local k = 1 - amount
  return round(r * k), round(g * k), round(b * k)
end

function M.mix(r1, g1, b1, r2, g2, b2, t)
  return round(r1 + (r2 - r1) * t), round(g1 + (g2 - g1) * t), round(b1 + (b2 - b1) * t)
end

local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

function M.distance(opaque, w, h)
  local dist, queue, head = {}, {}, 1
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x + 1
      if not opaque[i] then
        dist[i] = 0
        queue[#queue + 1] = i
      elseif x == 0 or y == 0 or x == w - 1 or y == h - 1 then
        dist[i] = 1
        queue[#queue + 1] = i
      end
    end
  end
  while head <= #queue do
    local i = queue[head]
    head = head + 1
    local x, y = (i - 1) % w, (i - 1) // w
    for _, d in ipairs(N4) do
      local nx, ny = x + d[1], y + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local j = ny * w + nx + 1
        if dist[j] == nil then
          dist[j] = dist[i] + 1
          queue[#queue + 1] = j
        end
      end
    end
  end
  return dist
end

function M.dilate(opaque, w, h, width)
  local cur, added = {}, {}
  for i = 1, w * h do cur[i] = opaque[i] == true end
  for _ = 1, width do
    local grow = {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local i = y * w + x + 1
        if not cur[i] then
          for _, d in ipairs(N4) do
            local nx, ny = x + d[1], y + d[2]
            if nx >= 0 and ny >= 0 and nx < w and ny < h and cur[ny * w + nx + 1] then
              grow[#grow + 1] = i
              break
            end
          end
        end
      end
    end
    for _, i in ipairs(grow) do
      cur[i] = true
      added[#added + 1] = { x = (i - 1) % w, y = (i - 1) // w }
    end
  end
  return added
end

-- Heights 0..1 per pixel: brightness (lum 0..255 per pixel), edge distance ("pillow"), or both.
function M.heights(lum, opaque, w, h, source, bevel)
  local dist = (source ~= "brightness") and M.distance(opaque, w, h) or nil
  local out = {}
  for i = 1, w * h do
    if not opaque[i] then
      out[i] = 0
    else
      local e = dist and math.min(dist[i], bevel) / bevel or 0
      local b = lum and lum[i] / 255 or 0
      if source == "brightness" then out[i] = b
      elseif source == "edges" then out[i] = e
      else out[i] = (b + e) / 2 end
    end
  end
  return out
end

local function quantizeComponent(v, levels)
  local steps = (levels - 1) / 2
  return math.floor(v * steps + 0.5) / steps
end

function M.normals(h, opaque, w, hgt, strength, convention, quantize)
  local function H(x, y)
    if x < 0 or y < 0 or x >= w or y >= hgt then return 0 end
    return h[y * w + x + 1]
  end
  local levels = tonumber(quantize)
  local out = {}
  for y = 0, hgt - 1 do
    for x = 0, w - 1 do
      local i = y * w + x + 1
      if not opaque[i] then
        out[i] = false
      else
        local dx = (H(x + 1, y - 1) + 2 * H(x + 1, y) + H(x + 1, y + 1)) - (H(x - 1, y - 1) + 2 * H(x - 1, y) + H(x - 1, y + 1))
        local dy = (H(x - 1, y + 1) + 2 * H(x, y + 1) + H(x + 1, y + 1)) - (H(x - 1, y - 1) + 2 * H(x, y - 1) + H(x + 1, y - 1))
        local nx, ny, nz = -dx * strength, dy * strength, 1
        if convention == "directx" then ny = -ny end
        local len = math.sqrt(nx * nx + ny * ny + nz * nz)
        nx, ny, nz = nx / len, ny / len, nz / len
        if levels then
          nx, ny = quantizeComponent(nx, levels), quantizeComponent(ny, levels)
          nz = math.sqrt(math.max(0.05, 1 - nx * nx - ny * ny))
          len = math.sqrt(nx * nx + ny * ny + nz * nz)
          nx, ny, nz = nx / len, ny / len, nz / len
        end
        out[i] = { nx, ny, nz }
      end
    end
  end
  return out
end

function M.encodeNormal(nx, ny, nz)
  local function enc(v) return math.max(0, math.min(255, math.floor((v * 0.5 + 0.5) * 255 + 0.5))) end
  return enc(nx), enc(ny), enc(nz)
end

function M.shade(n, lx, ly, lz, ambient)
  local len = math.sqrt(lx * lx + ly * ly + lz * lz)
  if len == 0 then return 1 end
  local d = (n[1] * lx + n[2] * ly + n[3] * lz) / len
  return ambient + (1 - ambient) * math.max(0, d)
end

return M
