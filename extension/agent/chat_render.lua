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

local LABELS = { user = "You" }
local PREFIX = { activity = "- ", error = "! " }

function R.layout(items, opts)
  local lines, y = {}, 0
  for i, item in ipairs(items) do
    if i > 1 then y = y + opts.gap end
    local label = LABELS[item.kind] or (item.kind == "agent" and (opts.agentLabel or "Agent")) or nil
    if label then
      lines[#lines + 1] = { text = label, kind = item.kind .. "_label", y = y }
      y = y + opts.lineHeight
    end
    for _, l in ipairs(R.wrap((PREFIX[item.kind] or "") .. item.text, opts.width, opts.measure)) do
      lines[#lines + 1] = { text = l, kind = item.kind, y = y }
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
