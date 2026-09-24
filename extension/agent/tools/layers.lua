local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local pixels = require("agent.tools.pixels")

local M = {}

local function need(args, action, key)
  if args[key] == nil then error(("layer_ops %s needs '%s'."):format(action, key), 0) end
  return args[key]
end

local function exists(s, name)
  local ok = pcall(sprites.layer, s, name)
  return ok
end

function M.layer_ops(args)
  local s = edit.editableSprite(args.sprite)
  local action = args.action
  if action == "add" then
    local name = need(args, "add", "name")
    if exists(s, name) then error("A layer named '" .. name .. "' already exists.", 0) end
    local l
    edit.transaction(s, "add layer " .. name, function()
      l = s:newLayer()
      l.name = name
      if args.toIndex then l.stackIndex = edit.int(args.toIndex) end
    end)
    return { sprite = sprites.name(s), layer = l.name, index = l.stackIndex }
  end

  local layer = sprites.layer(s, need(args, action, "layer"))
  if not layer.isEditable then error("Layer '" .. layer.name .. "' is locked.", 0) end
  if action == "rename" then
    local name = need(args, "rename", "name")
    if exists(s, name) then error("A layer named '" .. name .. "' already exists.", 0) end
    edit.transaction(s, "rename layer", function() layer.name = name end)
  elseif action == "set" then
    local mode
    if args.blendMode then
      mode = BlendMode[tostring(args.blendMode):upper()]
      if mode == nil then error("Unknown blend mode '" .. tostring(args.blendMode) .. "'.", 0) end
    end
    edit.transaction(s, "set layer " .. layer.name, function()
      if args.visible ~= nil then layer.isVisible = args.visible end
      if args.opacity then layer.opacity = edit.int(args.opacity) end
      if mode then layer.blendMode = mode end
    end)
  elseif action == "move" then
    local to = edit.int(need(args, "move", "toIndex"))
    edit.transaction(s, "move layer " .. layer.name, function() layer.stackIndex = to end)
  else
    error("Unknown layer action '" .. tostring(action) .. "'.", 0)
  end
  return { sprite = sprites.name(s), layer = layer.name, index = layer.stackIndex }
end

function M.ensure_draft_layer(args)
  local s = edit.editableSprite(args.sprite)
  local created = not exists(s, edit.DRAFT_LAYER)
  pixels.ensureDraftLayer(s)
  return { sprite = sprites.name(s), layer = edit.DRAFT_LAYER, opacity = edit.DRAFT_OPACITY, created = created }
end

return M
