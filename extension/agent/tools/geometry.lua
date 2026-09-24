local G = {}

local function collector()
  local pts, seen = {}, {}
  local function add(x, y)
    local k = x .. "," .. y
    if not seen[k] then
      seen[k] = true
      pts[#pts + 1] = { x = x, y = y }
    end
  end
  return pts, add
end

local function bresenham(add, x1, y1, x2, y2)
  local dx, dy = math.abs(x2 - x1), -math.abs(y2 - y1)
  local sx, sy = x1 < x2 and 1 or -1, y1 < y2 and 1 or -1
  local err = dx + dy
  while true do
    add(x1, y1)
    if x1 == x2 and y1 == y2 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x1 = x1 + sx end
    if e2 <= dx then err = err + dx; y1 = y1 + sy end
  end
end

function G.dot(x, y)
  return { { x = x, y = y } }
end

function G.line(x1, y1, x2, y2)
  local pts, add = collector()
  bresenham(add, x1, y1, x2, y2)
  return pts
end

function G.rect(x, y, w, h)
  local pts, add = collector()
  local x2, y2 = x + w - 1, y + h - 1
  bresenham(add, x, y, x2, y)
  bresenham(add, x, y2, x2, y2)
  bresenham(add, x, y, x, y2)
  bresenham(add, x2, y, x2, y2)
  return pts
end

function G.circle(cx, cy, r)
  local pts, add = collector()
  local x, y, err = r, 0, 1 - r
  while x >= y do
    for _, p in ipairs{ { x, y }, { y, x }, { -y, x }, { -x, y }, { -x, -y }, { -y, -x }, { y, -x }, { x, -y } } do
      add(cx + p[1], cy + p[2])
    end
    y = y + 1
    if err < 0 then
      err = err + 2 * y + 1
    else
      x = x - 1
      err = err + 2 * (y - x) + 1
    end
  end
  return pts
end

function G.arrow(x1, y1, x2, y2)
  local pts, add = collector()
  bresenham(add, x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 0 then
    local head = math.max(2, math.min(4, len / 3))
    local ux, uy = dx / len, dy / len
    for _, sign in ipairs{ 1, -1 } do
      -- rotate the reversed direction by +/-35 degrees
      local a = math.rad(35) * sign
      local rx = -ux * math.cos(a) + uy * math.sin(a)
      local ry = -ux * math.sin(a) - uy * math.cos(a)
      bresenham(add, x2, y2, math.floor(x2 + rx * head + 0.5), math.floor(y2 + ry * head + 0.5))
    end
  end
  return pts
end

return G
