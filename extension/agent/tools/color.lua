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

function M.parseHex(hex)
  local s = type(hex) == "string" and hex:match("^#(%x+)$")
  if not s or (#s ~= 6 and #s ~= 8) then
    error("Invalid color '" .. tostring(hex) .. "'; use #rrggbb or #rrggbbaa.", 0)
  end
  local a = #s == 8 and tonumber(s:sub(7, 8), 16) or 255
  return tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16), a
end

-- r, g, b, a of a raw pixel value in the given color mode.
function M.rgbaOf(value, colorMode, palette)
  if colorMode == ColorMode.RGB then
    return pc.rgbaR(value), pc.rgbaG(value), pc.rgbaB(value), pc.rgbaA(value)
  elseif colorMode == ColorMode.GRAYSCALE then
    local v = pc.grayaV(value)
    return v, v, v, pc.grayaA(value)
  end
  if value >= #palette then return 0, 0, 0, 0 end
  local c = palette:getColor(value)
  return c.red, c.green, c.blue, c.alpha
end

return M
