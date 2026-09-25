local registry = require("agent.tools.registry")
local inspect = require("agent.tools.inspect")
local pixels = require("agent.tools.pixels")
local palette = require("agent.tools.palette")
local layers = require("agent.tools.layers")
local frames = require("agent.tools.frames")
local annotate = require("agent.tools.annotate")
local transform = require("agent.tools.transform")
local analyze = require("agent.tools.analyze")
local fx = require("agent.tools.fx")
local maps = require("agent.tools.maps")
local builtin = require("agent.tools.builtin")
local toolstate = require("agent.tools.toolstate")
local extensions = require("agent.tools.extensions")
local scripts = require("agent.tools.scripts")
local importer = require("agent.tools.importer")
local cliptools = require("agent.tools.clips")

registry.register({
  get_sprite_info = inspect.get_sprite_info,
  get_snapshot = inspect.get_snapshot,
  get_pixels = inspect.get_pixels,
  get_palette = inspect.get_palette,
  analyze_colors = analyze.analyze_colors,
  list_open_sprites = analyze.list_open_sprites,
  list_project_sprites = analyze.list_project_sprites,
  check_readability = maps.check_readability,
  light_preview = maps.light_preview,
  get_tool_state = toolstate.get_tool_state,
  list_installed_extensions = extensions.list_installed_extensions,
  list_clips = cliptools.list_clips,
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
  dither = fx.dither,
  gradient_fill = fx.gradient_fill,
  pixel_perfect = fx.pixel_perfect,
  snap_to_palette = fx.snap_to_palette,
  selout = fx.selout,
  layer_style = fx.layer_style,
  make_normal_map = maps.make_normal_map,
  builtin_fx = builtin.builtin_fx,
  run_extension_command = extensions.run_extension_command,
  write_script = scripts.write_script,
  run_script = scripts.run_script,
  import_from_sprite = importer.import_from_sprite,
  save_clip = cliptools.save_clip,
  insert_clip = cliptools.insert_clip,
  delete_clip = cliptools.delete_clip,
  pin_clip = cliptools.pin_clip,
}, "edit")

registry.register({ set_tool = toolstate.set_tool }, "setting")

return registry
