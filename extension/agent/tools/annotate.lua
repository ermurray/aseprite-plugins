local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local G = require("agent.tools.geometry")

local M = { DEFAULT_COLOR = "#ff3b30" }

local function shapePoints(sh)
  local t, x, y = sh.type, edit.int(sh.x), edit.int(sh.y)
  if t == "dot" then return G.dot(x, y) end
  if t == "line" or t == "arrow" then
    if sh.x2 == nil or sh.y2 == nil then error("A " .. t .. " needs x2 and y2.", 0) end
    return G[t](x, y, edit.int(sh.x2), edit.int(sh.y2))
  end
  if t == "rect" then
    if sh.w == nil or sh.h == nil then error("A rect needs w and h.", 0) end
    return G.rect(x, y, edit.int(sh.w), edit.int(sh.h))
  end
  if t == "circle" then
    if sh.r == nil then error("A circle needs r.", 0) end
    return G.circle(x, y, edit.int(sh.r))
  end
  error("Unknown shape type '" .. tostring(t) .. "'.", 0)
end

function M.annotate(args)
  local s = edit.editableSprite(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local value = edit.pixelValue(s, args.color or M.DEFAULT_COLOR)
  local all = {}
  for i = 1, #args.shapes do
    for _, p in ipairs(shapePoints(args.shapes[i])) do all[#all + 1] = p end
  end
  edit.transaction(s, "notes", function()
    local layer
    for _, l in ipairs(s.layers) do
      if l.name == edit.NOTES_LAYER then layer = l end
    end
    if not layer then
      layer = s:newLayer()
      layer.name = edit.NOTES_LAYER
    end
    local img, o
    if args.clear then
      img, o = Image(s.spec), Point(0, 0)
      img:clear(edit.transparentValue(s))
    else
      img, o = edit.canvasImage(s, layer, frame)
    end
    for _, p in ipairs(all) do
      if p.x >= 0 and p.y >= 0 and p.x < s.width and p.y < s.height then img:drawPixel(p.x - o.x, p.y - o.y, value) end
    end
    edit.commit(s, layer, frame, img, o)
  end)
  return { sprite = sprites.name(s), layer = edit.NOTES_LAYER, frame = frame.frameNumber, marks = #args.shapes }
end

return M
