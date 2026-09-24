local M = {}
local pc = app.pixelColor

function M.hex(r, g, b, a)
  if a == nil or a == 255 then return string.format("#%02x%02x%02x", r, g, b) end
  return string.format("#%02x%02x%02x%02x", r, g, b, a)
end

function M.fromColor(c)
  return M.hex(c.red, c.green, c.blue, c.alpha)
end

-- Converts a raw pixel value to "#rrggbb[aa]", or "." when fully transparent.
function M.pixelToHex(value, colorMode, palette, transparentIndex)
  if colorMode == ColorMode.RGB then
    local a = pc.rgbaA(value)
    if a == 0 then return "." end
    return M.hex(pc.rgbaR(value), pc.rgbaG(value), pc.rgbaB(value), a)
  elseif colorMode == ColorMode.GRAYSCALE then
    local a = pc.grayaA(value)
    if a == 0 then return "." end
    local v = pc.grayaV(value)
    return M.hex(v, v, v, a)
  end
  if value == transparentIndex then return "." end
  if value >= #palette then return "?" end
  local c = palette:getColor(value)
  if c.alpha == 0 then return "." end
  return M.fromColor(c)
end

M.COLOR_MODES = {
  [ColorMode.RGB] = "rgb",
  [ColorMode.GRAYSCALE] = "grayscale",
  [ColorMode.INDEXED] = "indexed",
}

return M
