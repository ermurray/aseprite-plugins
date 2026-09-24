local registry = require("agent.tools.registry")
local inspect = require("agent.tools.inspect")
local pixels = require("agent.tools.pixels")
local palette = require("agent.tools.palette")

registry.register{
  get_sprite_info = inspect.get_sprite_info,
  get_snapshot = inspect.get_snapshot,
  get_pixels = inspect.get_pixels,
  get_palette = inspect.get_palette,
  set_pixels = pixels.set_pixels,
  replace_color = pixels.replace_color,
  set_palette = palette.set_palette,
  add_palette_colors = palette.add_palette_colors,
}

return registry
