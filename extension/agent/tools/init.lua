local registry = require("agent.tools.registry")
local inspect = require("agent.tools.inspect")

registry.register{
  get_sprite_info = inspect.get_sprite_info,
  get_snapshot = inspect.get_snapshot,
  get_pixels = inspect.get_pixels,
  get_palette = inspect.get_palette,
}

return registry
