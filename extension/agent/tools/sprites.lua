local project = require("agent.project")

local M = { projectRoot = nil }


function M.openList()
  local names = {}
  for _, s in ipairs(app.sprites) do names[#names + 1] = M.name(s) end
  return #names > 0 and table.concat(names, ", ") or "(none)"
end

function M.name(sprite)
  return project.relative(M.projectRoot, sprite.filename) or app.fs.fileName(sprite.filename)
end

function M.resolve(ref)
  if ref == nil or ref == "" then
    local s = app.sprite
    if not s then error("No sprite is open in Aseprite.", 0) end
    return s
  end
  for _, s in ipairs(app.sprites) do
    if s.filename == ref or app.fs.fileName(s.filename) == ref or M.name(s) == ref then return s end
  end
  error("Sprite '" .. ref .. "' is not open. Open sprites: " .. M.openList(), 0)
end

-- An unopened project sprite named by `ref` is opened for the duration of a tool call:
-- in the background (and closed afterwards) for reads, as a tab (left open) for edits.
function M.openIfNeeded(ref, mode)
  if type(ref) ~= "string" or ref == "" or not M.projectRoot then return nil end
  if pcall(M.resolve, ref) then return nil end
  local abs = project.absolute(M.projectRoot, ref)
  if not app.fs.isFile(abs) or not project.relative(M.projectRoot, abs) then return nil end
  local prev = app.sprite
  if mode == "edit" then
    local opened = app.open(abs)
    if not opened then error("Couldn't open " .. ref .. ".", 0) end
    if prev then app.sprite = prev end
    return { openedAsTab = M.name(opened) }
  end
  local bg = Sprite{ fromFile = abs }
  if prev then app.sprite = prev end
  return {
    close = function()
      bg:close()
      if prev then pcall(function() app.sprite = prev end) end
    end,
  }
end

function M.frame(sprite, n)
  n = n and (math.tointeger(n) or n)
  if n == nil then
    if app.sprite == sprite and app.frame then return app.frame end
    return sprite.frames[1]
  end
  local ok, f = pcall(function() return sprite.frames[n] end)
  if not ok or not f then
    error(("Frame %d does not exist (sprite has %d frames)."):format(n, #sprite.frames), 0)
  end
  return f
end

function M.layer(sprite, name)
  local function find(layers)
    for _, l in ipairs(layers) do
      if l.name == name then return l end
      if l.isGroup then
        local hit = find(l.layers)
        if hit then return hit end
      end
    end
  end
  local l = find(sprite.layers)
  if not l then error("Layer '" .. name .. "' not found.", 0) end
  return l
end

return M
