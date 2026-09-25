local project = require("agent.project")

local M = {}

local function nameOf(sprite, root)
  return project.relative(root, sprite.filename) or app.fs.fileName(sprite.filename)
end

function M.build(root)
  local ctx = { openSprites = {} }
  for _, s in ipairs(app.sprites) do ctx.openSprites[#ctx.openSprites + 1] = nameOf(s, root) end
  local s = app.sprite
  if not s then return ctx end
  ctx.activeSprite = nameOf(s, root)
  ctx.frameCount = #s.frames
  if app.frame then ctx.frame = app.frame.frameNumber end
  if app.layer then ctx.layer = app.layer.name end
  if not s.selection.isEmpty then
    local b = s.selection.bounds
    ctx.selection = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  return ctx
end

return M
