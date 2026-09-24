local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")

local M = {}

local function need(args, action, key)
  if args[key] == nil then error(("frame_ops %s needs '%s'."):format(action, key), 0) end
  return args[key]
end

function M.frame_ops(args)
  local s = edit.editableSprite(args.sprite)
  local action = args.action
  local result = { sprite = sprites.name(s) }
  if action == "add_empty" then
    local after = args.frame and sprites.frame(s, args.frame).frameNumber or #s.frames
    edit.transaction(s, "add empty frame", function() s:newEmptyFrame(after + 1) end)
    result.frame = after + 1
  elseif action == "duplicate" then
    local n = sprites.frame(s, need(args, "duplicate", "frame")).frameNumber
    edit.transaction(s, "duplicate frame " .. n, function() s:newFrame(n) end)
    result.frame = n + 1
  elseif action == "set_duration" then
    local from = sprites.frame(s, need(args, "set_duration", "frame")).frameNumber
    local to = args.toFrame and sprites.frame(s, args.toFrame).frameNumber or from
    local seconds = edit.int(need(args, "set_duration", "durationMs")) / 1000
    edit.transaction(s, "set frame durations", function()
      for f = from, to do s.frames[f].duration = seconds end
    end)
  elseif action == "add_tag" then
    local name = need(args, "add_tag", "name")
    local from = sprites.frame(s, need(args, "add_tag", "frame")).frameNumber
    local to = args.toFrame and sprites.frame(s, args.toFrame).frameNumber or from
    edit.transaction(s, "add tag " .. name, function() s:newTag(from, to).name = name end)
  else
    error("Unknown frame action '" .. tostring(action) .. "'.", 0)
  end
  result.frameCount = #s.frames
  return result
end

return M
