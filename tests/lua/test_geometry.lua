local T = require("testlib")
local G = require("agent.tools.geometry")

local function key(pts)
  local t = {}
  for _, p in ipairs(pts) do t[#t + 1] = p.x .. "," .. p.y end
  table.sort(t)
  return table.concat(t, " ")
end

T.test("line is a Bresenham line including both ends", function()
  T.eq(key(G.line(0, 0, 3, 0)), "0,0 1,0 2,0 3,0")
  T.eq(key(G.line(0, 0, 2, 2)), "0,0 1,1 2,2")
  T.eq(#G.line(0, 0, 5, 2), 6)
end)

T.test("rect is the outline only", function()
  T.eq(key(G.rect(0, 0, 3, 3)), "0,0 0,1 0,2 1,0 1,2 2,0 2,1 2,2")
  T.eq(#G.rect(0, 0, 1, 1), 1)
end)

T.test("circle is symmetric and r=0 is a dot", function()
  T.eq(key(G.circle(5, 5, 0)), "5,5")
  local pts = G.circle(0, 0, 3)
  local set = {}
  for _, p in ipairs(pts) do set[p.x .. "," .. p.y] = true end
  for _, p in ipairs(pts) do
    T.eq(set[(-p.x) .. "," .. p.y], true)
    T.eq(set[p.x .. "," .. (-p.y)], true)
  end
  T.eq(set["3,0"], true)
  T.eq(set["0,0"], nil, "outline, not filled")
end)

T.test("arrow is the shaft plus a head at the tip", function()
  local shaft = G.line(0, 0, 10, 0)
  local arrow = G.arrow(0, 0, 10, 0)
  T.eq(#arrow > #shaft, true)
  local set = {}
  for _, p in ipairs(arrow) do set[p.x .. "," .. p.y] = true end
  T.eq(set["10,0"], true)
  T.eq(set["8,2"] or set["8,-2"] or set["7,2"] or set["7,-2"], true, "head wings behind the tip")
end)

T.test("points are de-duplicated", function()
  T.eq(#G.line(2, 2, 2, 2), 1)
end)
