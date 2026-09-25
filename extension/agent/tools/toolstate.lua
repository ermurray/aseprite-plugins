local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local INKS = { simple = "SIMPLE", alpha_compositing = "ALPHA_COMPOSITING", copy_color = "COPY_COLOR", lock_alpha = "LOCK_ALPHA", shading = "SHADING" }
local SHAPES = { circle = "CIRCLE", square = "SQUARE", line = "LINE" }
local SYMMETRY = { none = 0, horizontal = 1, vertical = 2, both = 3 }
local TILED = { none = 0, x = 1, y = 2, both = 3 }

local function reverse(map, enum)
  local out = {}
  for name, key in pairs(map) do
    local v = enum and enum[key] or key
    if v ~= nil then out[v] = name end
  end
  return out
end

function M.get_tool_state()
  local id = app.tool and app.tool.id or "pencil"
  local tp = app.preferences.tool(id)
  local state = {
    tool = id,
    brush = { size = tp.brush.size, shape = reverse(SHAPES, BrushType)[tp.brush.type] or tostring(tp.brush.type), angle = tp.brush.angle },
    ink = reverse(INKS, Ink)[tp.ink] or tostring(tp.ink),
    foreground = color.fromColor(app.fgColor),
    background = color.fromColor(app.bgColor),
  }
  if app.sprite then
    local dp = app.preferences.document(app.sprite)
    state.symmetry = reverse(SYMMETRY)[dp.symmetry.mode] or tostring(dp.symmetry.mode)
    state.tiled = reverse(TILED)[dp.tiled.mode] or tostring(dp.tiled.mode)
  end
  return state
end

local function colorOf(hex)
  local r, g, b, a = color.parseHex(hex)
  return Color{ r = r, g = g, b = b, a = a }
end

function M.set_tool(args)
  if args.tool then
    local ok = pcall(function() app.tool = args.tool end)
    if not ok or not app.tool or app.tool.id ~= args.tool then error("Unknown tool '" .. args.tool .. "'.", 0) end
  end
  local tp = app.preferences.tool(app.tool and app.tool.id or "pencil")
  if args.brushSize then tp.brush.size = edit.int(args.brushSize) end
  if args.brushShape then tp.brush.type = BrushType[SHAPES[args.brushShape]] end
  if args.brushAngle then tp.brush.angle = edit.int(args.brushAngle) end
  if args.ink then tp.ink = Ink[INKS[args.ink]] end
  if args.foreground then app.fgColor = colorOf(args.foreground) end
  if args.background then app.bgColor = colorOf(args.background) end
  local skipped = {}
  if args.symmetry or args.tiled then
    if app.sprite then
      local dp = app.preferences.document(app.sprite)
      if args.symmetry then
        dp.symmetry.mode = SYMMETRY[args.symmetry]
        app.preferences.symmetry_mode.enabled = args.symmetry ~= "none"
      end
      if args.tiled then dp.tiled.mode = TILED[args.tiled] end
    else
      if args.symmetry then skipped[#skipped + 1] = "symmetry (no sprite open)" end
      if args.tiled then skipped[#skipped + 1] = "tiled mode (no sprite open)" end
    end
  end
  app.refresh()
  local state = M.get_tool_state()
  if #skipped > 0 then state.skipped = skipped end
  return state
end

return M
