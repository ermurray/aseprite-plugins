local registry = require("agent.tools.registry")
local inspect = require("agent.tools.inspect")
local pixels = require("agent.tools.pixels")
local palette = require("agent.tools.palette")
local layers = require("agent.tools.layers")
local frames = require("agent.tools.frames")
local annotate = require("agent.tools.annotate")
local transform = require("agent.tools.transform")
local analyze = require("agent.tools.analyze")

registry.register({
  get_sprite_info = inspect.get_sprite_info,
  get_snapshot = inspect.get_snapshot,
  get_pixels = inspect.get_pixels,
  get_palette = inspect.get_palette,
  analyze_colors = analyze.analyze_colors,
  list_open_sprites = analyze.list_open_sprites,
  list_project_sprites = analyze.list_project_sprites,
}, "read")

registry.register({
  set_pixels = pixels.set_pixels,
  replace_color = pixels.replace_color,
  set_palette = palette.set_palette,
  add_palette_colors = palette.add_palette_colors,
  layer_ops = layers.layer_ops,
  ensure_draft_layer = layers.ensure_draft_layer,
  frame_ops = frames.frame_ops,
  annotate = annotate.annotate,
  transform = transform.transform,
}, "edit")

return registry
