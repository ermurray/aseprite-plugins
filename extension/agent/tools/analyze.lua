local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local inspect = require("agent.tools.inspect")
local edit = require("agent.tools.edit")
local project = require("agent.project")

local M = { NEAR = 24, TOP = 16 }

-- "Redmean" weighted RGB distance: cheap and closer to perception than plain RGB.
function M.distance(a, b)
  local r1, g1, b1 = color.parseHex(a)
  local r2, g2, b2 = color.parseHex(b)
  local rm = (r1 + r2) / 2
  local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
  return math.sqrt((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db)
end

function M.analyze_colors(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local img = inspect.render(s, frame)
  local pal = s.palettes[1]
  local counts, list = {}, {}
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local hex = color.pixelToHex(img:getPixel(x, y), s.colorMode, pal, s.transparentColor)
      if hex ~= "." then
        if not counts[hex] then list[#list + 1] = hex end
        counts[hex] = (counts[hex] or 0) + 1
      end
    end
  end
  table.sort(list, function(a, b) return counts[a] > counts[b] or (counts[a] == counts[b] and a < b) end)
  local top = {}
  for i = 1, math.min(M.TOP, #list) do top[i] = { color = list[i], count = counts[list[i]] } end
  local near = {}
  for i = 1, math.min(64, #list) do
    for j = i + 1, math.min(64, #list) do
      local d = M.distance(list[i], list[j])
      if d < M.NEAR and #near < 10 then near[#near + 1] = { a = list[i], b = list[j], distance = math.floor(d + 0.5) } end
    end
  end
  local unused = 0
  for i = 0, #pal - 1 do
    if not counts[color.fromColor(pal:getColor(i))] then unused = unused + 1 end
  end
  return {
    sprite = sprites.name(s),
    frame = frame.frameNumber,
    uniqueColors = #list,
    topColors = top,
    nearDuplicates = near,
    unusedPaletteEntries = unused,
  }
end

function M.list_open_sprites()
  local tabs = {}
  for _, s in ipairs(app.sprites) do
    tabs[#tabs + 1] = {
      name = sprites.name(s),
      path = s.filename,
      active = app.sprite == s,
      kind = edit.isReference(s) and "reference" or "sprite",
      width = s.width,
      height = s.height,
      frames = #s.frames,
    }
  end
  return { tabs = tabs }
end

function M.list_project_sprites()
  local root = sprites.projectRoot
  if not root then error("No project is open. The artist can create one with Make project in the chat window.", 0) end
  local open = {}
  for _, s in ipairs(app.sprites) do open[sprites.name(s)] = true end
  local list = {}
  for _, rel in ipairs(project.listSprites(root)) do list[#list + 1] = { path = rel, open = open[rel] == true } end
  return { project = app.fs.fileName(root), sprites = list }
end

return M
