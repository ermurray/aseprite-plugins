local T = require("testlib")
local M = require("agent.fx.math")

T.test("dither thresholds: amount 0 never, 1 always, 0.5 is half of each tile", function()
  for _, p in ipairs{ "bayer2", "bayer4", "checker" } do
    local picks, cells = 0, 0
    for y = 0, 3 do for x = 0, 3 do
      T.eq(M.ditherPick(p, x, y, 0), false)
      T.eq(M.ditherPick(p, x, y, 1), true)
      cells = cells + 1
      if M.ditherPick(p, x, y, 0.5) then picks = picks + 1 end
    end end
    T.eq(picks, cells / 2, p)
  end
  T.eq(M.ditherPick("checker", 0, 0, 0.5), true)
  T.eq(M.ditherPick("checker", 1, 0, 0.5), false)
end)

T.test("gradient positions and color steps", function()
  local r = { x = 0, y = 0, w = 4, h = 1 }
  T.eq(M.linearT(0, 0, r, 0), 0)
  T.eq(M.linearT(3, 0, r, 0), 1)
  T.eq(M.linearT(3, 0, r, 180), 0)
  T.eq(M.radialT(2, 2, 2, 2, 5), 0)
  T.eq(M.radialT(7, 2, 2, 2, 5), 1)
  T.eq(M.gradientIndex(0, 3, "none", 0, 0), 1)
  T.eq(M.gradientIndex(1, 3, "none", 0, 0), 3)
  T.eq(M.gradientIndex(0.49 / 2, 3, "none", 0, 0), 1)
  T.eq(M.gradientIndex(0.51 / 2, 3, "none", 0, 0), 2)
end)

local function grid(rows)
  local w, h, g = #rows[1], #rows, {}
  for y = 1, h do for x = 1, w do g[(y - 1) * w + x] = rows[y]:sub(x, x) == "#" end end
  return g, w, h
end
local function key(list)
  local t = {}
  for _, p in ipairs(list) do t[#t + 1] = p.x .. "," .. p.y end
  table.sort(t)
  return table.concat(t, " ")
end

T.test("pixel-perfect removes L corners, keeps lines, junctions and blocks", function()
  T.eq(key(M.pixelPerfectRemovals(grid{ "##.", ".#." })), "1,0")
  T.eq(key(M.pixelPerfectRemovals(grid{ "####" })), "")
  T.eq(key(M.pixelPerfectRemovals(grid{ "##..", ".##.", "..##" })), "1,0 2,1")
  T.eq(key(M.pixelPerfectRemovals(grid{ "###", ".#.", ".#." })), "")
  T.eq(key(M.pixelPerfectRemovals(grid{ "##", "##" })), "")
end)

T.test("color helpers", function()
  T.eq(M.redmean(1, 2, 3, 1, 2, 3), 0)
  T.eq(M.nearest(250, 250, 250, { { r = 0, g = 0, b = 0 }, { r = 255, g = 255, b = 255 } }), 2)
  T.eq(M.luminance(255, 255, 255), 255)
  T.deepEq({ M.darken(200, 100, 50, 0.5) }, { 100, 50, 25 })
  T.deepEq({ M.mix(0, 0, 0, 255, 255, 255, 0.5) }, { 128, 128, 128 })
end)

T.test("distance transform and dilation", function()
  local g, w, h = grid{ "#####", "#####", "#####", "#####", "#####" }
  local d = M.distance(g, w, h)
  T.eq(d[1], 1)
  T.eq(d[2 * w + 2 + 1], 3)
  local g2, w2, h2 = grid{ "#..", "...", "..." }
  T.eq(key(M.dilate(g2, w2, h2, 1)), "0,1 1,0")
  T.eq(#M.dilate(g2, w2, h2, 2), 5)
end)

T.test("normals: flat in the middle of a dome, facing out at the sides, conventions flip Y", function()
  local g, w, h = grid{ "#####", "#####", "#####", "#####", "#####" }
  local heights = M.heights(nil, g, w, h, "edges", 3)
  local n = M.normals(heights, g, w, h, 2, "opengl", "off")
  local c = n[2 * w + 2 + 1]
  T.deepEq({ M.encodeNormal(c[1], c[2], c[3]) }, { 128, 128, 255 })
  local left = n[2 * w + 1 + 1]
  T.eq(left[1] < 0, true, "left side faces left")
  local top = n[1 * w + 2 + 1]
  T.eq(top[2] > 0, true, "top faces up in opengl")
  local dx = M.normals(heights, g, w, h, 2, "directx", "off")
  T.eq(dx[1 * w + 2 + 1][2] < 0, true, "directx flips green")
  local q = M.normals(heights, g, w, h, 2, "opengl", "3")
  local qc = q[1 * w + 1 + 1]
  for _, v in ipairs(qc) do T.eq(v == v, true) end
  T.eq(n[0 + 1] ~= nil, true)
  local empty, ew, eh = grid{ "#.", ".." }
  T.eq(M.normals(M.heights(nil, empty, ew, eh, "edges", 2), empty, ew, eh, 1, "opengl", "off")[2], false)
end)

T.test("shade lights faces that point at the light", function()
  T.eq(M.shade({ 0, 0, 1 }, 0, 0, 1, 0), 1)
  T.eq(M.shade({ 1, 0, 0 }, -1, 0, 0, 0.2), 0.2)
end)
