local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local analyze = require("agent.tools.analyze")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end

T.test("distance is zero for equal colors and grows with difference", function()
  T.eq(analyze.distance("#102030", "#102030"), 0)
  T.eq(analyze.distance("#000000", "#010101") < analyze.distance("#000000", "#808080"), true)
end)

T.test("analyze_colors counts colors and finds near duplicates", function()
  F.closeAll()
  local s = F.rgbSprite()
  local img = s.cels[1].image:clone()
  img:drawPixel(2, 0, pc.rgba(254, 1, 1, 255)) -- near-duplicate of red
  img:drawPixel(3, 0, pc.rgba(255, 0, 0, 255))
  s.cels[1].image = img
  local r = call("analyze_colors")
  T.eq(r.ok, true, r.error)
  T.eq(r.data.uniqueColors, 3)
  T.deepEq(r.data.topColors[1], { color = "#ff0000", count = 2 })
  T.eq(#r.data.nearDuplicates, 1)
  T.eq(r.data.nearDuplicates[1].a == "#ff0000" or r.data.nearDuplicates[1].b == "#ff0000", true)
end)

T.test("analyze_colors works on reference tabs", function()
  F.closeAll()
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(F.tmp, "ref3.png"))
  app.sprite = ref
  T.eq(call("analyze_colors").ok, true)
end)

T.test("list_open_sprites marks the active tab and references", function()
  F.closeAll()
  F.rgbSprite("hero.aseprite")
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(F.tmp, "ref4.png"))
  app.sprite = ref
  local r = call("list_open_sprites")
  T.eq(r.ok, true, r.error)
  local byName = {}
  for _, t in ipairs(r.data.tabs) do byName[t.name] = t end
  T.eq(byName["hero.aseprite"].kind, "sprite")
  T.eq(byName["hero.aseprite"].active, false)
  T.eq(byName["ref4.png"].kind, "reference")
  T.eq(byName["ref4.png"].active, true)
  T.eq(byName["hero.aseprite"].width, 4)
end)

F.closeAll()

T.test("every tool name the bridge forwards has a Lua handler", function()
  local registry = require("agent.tools")
  for _, name in ipairs{ "get_sprite_info", "get_snapshot", "get_pixels", "get_palette", "list_open_sprites",
    "analyze_colors", "set_palette", "add_palette_colors", "replace_color", "layer_ops", "frame_ops",
    "set_pixels", "annotate", "transform", "ensure_draft_layer", "list_project_sprites", "get_tool_state", "set_tool", "list_installed_extensions", "run_extension_command", "check_readability", "light_preview", "dither", "gradient_fill", "pixel_perfect", "snap_to_palette", "selout", "layer_style", "builtin_fx", "make_normal_map", "write_script", "run_script", "import_from_sprite", "list_clips", "save_clip", "insert_clip", "delete_clip", "pin_clip", "export_sprite" } do
    T.eq(type(registry.handlers[name]), "function", name)
  end
end)
