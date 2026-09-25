local R = {}

local function splitChars(s)
  local out = {}
  local ok = pcall(function()
    for _, code in utf8.codes(s) do out[#out + 1] = utf8.char(code) end
  end)
  if not ok then
    out = {}
    for i = 1, #s do out[#out + 1] = s:sub(i, i) end
  end
  return out
end

function R.wrap(text, maxWidth, measure)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local candidate = (line == "") and word or (line .. " " .. word)
      if measure(candidate) <= maxWidth then
        line = candidate
      else
        if line ~= "" then
          lines[#lines + 1] = line
          line = ""
        end
        if measure(word) <= maxWidth then
          line = word
        else
          for _, ch in ipairs(splitChars(word)) do
            if line ~= "" and measure(line .. ch) > maxWidth then
              lines[#lines + 1] = line
              line = ch
            else
              line = line .. ch
            end
          end
        end
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- Aseprite's UI font lacks most non-Latin glyphs, and an unknown glyph breaks both
-- measureText and fillText (text overlaps itself). Map common punctuation to ASCII,
-- keep Latin letters (U+00A0..U+024F), and replace anything else with "?".
local PUNCT = {
  [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-", [0x2014] = "-", [0x2015] = "-", [0x2212] = "-",
  [0x2018] = "'", [0x2019] = "'", [0x201A] = "'", [0x201B] = "'", [0x2032] = "'",
  [0x201C] = '"', [0x201D] = '"', [0x201E] = '"', [0x2033] = '"',
  [0x2026] = "...", [0x2022] = "-", [0x00B7] = "-", [0x2023] = "-", [0x25CF] = "-",
  [0x2192] = "->", [0x2190] = "<-", [0x2194] = "<->", [0x21D2] = "=>",
  [0x00D7] = "x", [0x2248] = "~", [0x2264] = "<=", [0x2265] = ">=", [0x2260] = "!=",
  [0x00A0] = " ", [0x2009] = " ", [0x200A] = " ", [0x202F] = " ", [0x200B] = "",
}

function R.displayText(s, keepMarkdown)
  if not keepMarkdown then s = s:gsub("%*%*", "") end
  s = s:gsub("[\t\r\f\v]", " "):gsub("[%z\1-\8\14-\31\127]", "")
  local ok, out = pcall(function()
    local parts = {}
    for _, code in utf8.codes(s) do
      local mapped = PUNCT[code]
      if mapped then
        parts[#parts + 1] = mapped
      elseif code < 0x80 or (code >= 0xA0 and code <= 0x24F) then
        parts[#parts + 1] = utf8.char(code)
      else
        parts[#parts + 1] = "?"
      end
    end
    return table.concat(parts)
  end)
  return ok and out or (s:gsub("[\128-\255]", "?"))
end

local LABELS = { user = "You" }
local PREFIX = { activity = "- ", error = "! ", setup = "Tip: " }

-- Normalized text per item, recomputed only when the item's text changes: layout runs on
-- every paint (8x a second while Claude works) and saved chats can be long.
local displayCache = setmetatable({}, { __mode = "k" })

local function displayFor(item)
  local raw = (PREFIX[item.kind] or "") .. item.text
  local hit = displayCache[item]
  if hit and hit.raw == raw then return hit.text end
  local text = R.displayText(raw, item.kind == "user") -- the artist's own text is shown as typed
  displayCache[item] = { raw = raw, text = text }
  return text
end
local APPROVAL_STATE = {
  pending = "Apply or Deny below",
  applied = "Approved",
  denied = "Denied",
  cancelled = "Cancelled",
}

function R.layout(items, opts)
  local lines, y = {}, 0
  for i, item in ipairs(items) do
    if i > 1 then y = y + opts.gap end
    local label = LABELS[item.kind] or (item.kind == "agent" and (opts.agentLabel or "Agent")) or nil
    if item.kind == "approval" then label = (opts.agentLabel or "Agent") .. " wants to:" end
    if label then
      lines[#lines + 1] = { text = label, kind = item.kind .. "_label", y = y }
      y = y + opts.lineHeight
    end
    for _, l in ipairs(R.wrap(displayFor(item), opts.width, opts.measure)) do
      lines[#lines + 1] = { text = l, kind = item.kind, y = y }
      y = y + opts.lineHeight
    end
    if item.kind == "approval" then
      lines[#lines + 1] = { text = APPROVAL_STATE[item.state] or item.state, kind = "approval_state", y = y }
      y = y + opts.lineHeight
    end
  end
  -- opts.thinking is the animation tick while a turn is running, nil when idle.
  if opts.thinking then
    if #items > 0 then y = y + opts.gap end
    lines[#lines + 1] = { text = R.thinkingText(opts.agentLabel or "Agent", opts.thinking), kind = "thinking", y = y }
    y = y + opts.lineHeight
  end
  return { lines = lines, height = y }
end

function R.thinkingText(label, tick)
  return label .. " is thinking" .. string.rep(".", tick % 4)
end

function R.clampScroll(scroll, contentHeight, viewHeight)
  return math.max(0, math.min(scroll, math.max(0, contentHeight - viewHeight)))
end

return R
