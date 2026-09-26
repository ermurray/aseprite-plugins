-- A multi-line text box model (Aseprite dialogs have no multi-line entry): text, cursor,
-- soft wrapping that keeps every character, and key handling. Pure; the window draws it.
local render = require("agent.chat_render")

local TI = {}
TI.__index = TI

function TI.new()
  return setmetatable({ text = "", cursor = 0, scroll = 0, selectAll = false, lines = nil }, TI)
end

-- Byte offsets are "number of bytes before the cursor", always on a UTF-8 character boundary.
local function isCont(s, i) local b = s:byte(i) return b and (b & 0xC0) == 0x80 end

local function prevBoundary(s, pos)
  if pos <= 0 then return 0 end
  local j = pos - 1
  while j > 0 and isCont(s, j + 1) do j = j - 1 end
  return j
end

local function nextBoundary(s, pos)
  if pos >= #s then return #s end
  local j = pos + 1
  while j < #s and isCont(s, j + 1) do j = j + 1 end
  return j
end

-- Only text the UI font can draw goes into the box (so measuring and the caret stay exact).
local function clean(s)
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "  ")
  local parts = {}
  for piece in (s .. "\n"):gmatch("(.-)\n") do parts[#parts + 1] = render.displayText(piece, true) end
  return table.concat(parts, "\n")
end

function TI:setText(s)
  self.text = clean(s or "")
  self.cursor = #self.text
  self.selectAll = false
end

function TI:clear()
  self.text, self.cursor, self.scroll, self.selectAll = "", 0, 0, false
end

function TI:insert(s)
  if self.selectAll then self:clear() end
  s = clean(s)
  self.text = self.text:sub(1, self.cursor) .. s .. self.text:sub(self.cursor + 1)
  self.cursor = self.cursor + #s
end

-- Soft-wrapped visual lines: {start = byte offset, text = string}. Breaks after a space when
-- possible, else between characters; the "\n" itself belongs to no line.
function TI:layout(width, measure)
  local lines = {}
  local pos = 0
  for para in (self.text .. "\n"):gmatch("(.-)\n") do
    if para == "" then
      lines[#lines + 1] = { start = pos, text = "" }
    else
      local lineStart = 1
      local lastSpace
      local chars = {}
      for p, c in utf8.codes(para) do chars[#chars + 1] = { p = p, c = utf8.char(c) } end
      local idx = 1
      while idx <= #chars do
        local startByte = chars[lineStart].p
        local j = idx
        local text = para:sub(startByte, chars[j].p + #chars[j].c - 1)
        if measure(text) > width and j > lineStart then
          local breakAt = lastSpace and lastSpace >= lineStart and lastSpace or (j - 1)
          local endByte = chars[breakAt].p + #chars[breakAt].c - 1
          lines[#lines + 1] = { start = pos + startByte - 1, text = para:sub(startByte, endByte) }
          lineStart = breakAt + 1
          idx = lineStart
          lastSpace = nil
        else
          if chars[j].c == " " then lastSpace = j end
          idx = idx + 1
        end
      end
      if lineStart <= #chars then
        local startByte = chars[lineStart].p
        lines[#lines + 1] = { start = pos + startByte - 1, text = para:sub(startByte) }
      end
    end
    pos = pos + #para + 1
  end
  self.lines = lines
  return lines
end

-- Which visual line the cursor is on (1-based) and its x offset in pixels.
function TI:caret(lines, measure)
  local idx = 1
  for i, l in ipairs(lines) do
    if self.cursor >= l.start then idx = i end
  end
  local l = lines[idx]
  local col = math.max(0, math.min(#l.text, self.cursor - l.start))
  return idx, measure(l.text:sub(1, col))
end

-- Byte offset on `line` whose left edge is closest to x.
local function offsetAt(line, x, measure)
  local best, bestD = line.start, math.huge
  local positions = { 0 }
  for p in utf8.codes(line.text) do if p > 1 then positions[#positions + 1] = p - 1 end end
  positions[#positions + 1] = #line.text
  for _, col in ipairs(positions) do
    local d = math.abs(measure(line.text:sub(1, col)) - x)
    if d < bestD then best, bestD = line.start + col, d end
  end
  return best
end

function TI:ensureVisible(lines, lineHeight, viewHeight, measure)
  local idx = self:caret(lines, measure)
  local top = (idx - 1) * lineHeight
  if top < self.scroll then self.scroll = top end
  if top + lineHeight > self.scroll + viewHeight then self.scroll = top + lineHeight - viewHeight end
  local maxScroll = math.max(0, #lines * lineHeight - viewHeight)
  self.scroll = math.max(0, math.min(self.scroll, maxScroll))
end

local measureChars = function(s) return utf8.len(s) or #s end

-- Returns "send", "handled", or nil (not ours: let Aseprite handle it). getClipboard is only
-- called for paste.
function TI:handleKey(ev, getClipboard, measure)
  measure = measure or self.measure or measureChars
  local code = ev.code or ""
  local cmd = ev.metaKey or ev.ctrlKey
  if cmd then
    if code == "KeyV" then
      local s = getClipboard and getClipboard()
      if s and s ~= "" then self:insert(s) end
      return "handled"
    elseif code == "KeyA" then
      self.selectAll = true
      self.cursor = #self.text
      return "handled"
    end
    return nil
  end
  -- Select-all lasts until the next key: typing replaces everything, Backspace/Delete clear it,
  -- anything else just drops the selection.
  local selected = self.selectAll
  local printable = ev.key and ev.key ~= "" and ev.key:byte(1) >= 32 and ev.key ~= "\127"
  if not printable then self.selectAll = false end
  if code == "Enter" or code == "NumpadEnter" then
    if ev.shiftKey then self:insert("\n") return "handled" end
    return "send"
  elseif code == "Backspace" or code == "Delete" then
    if selected then self:clear() return "handled" end
    if code == "Backspace" and self.cursor > 0 then
      local p = prevBoundary(self.text, self.cursor)
      self.text = self.text:sub(1, p) .. self.text:sub(self.cursor + 1)
      self.cursor = p
    elseif code == "Delete" and self.cursor < #self.text then
      local n = nextBoundary(self.text, self.cursor)
      self.text = self.text:sub(1, self.cursor) .. self.text:sub(n + 1)
    end
    return "handled"
  elseif code == "ArrowLeft" then
    self.cursor = prevBoundary(self.text, self.cursor)
    return "handled"
  elseif code == "ArrowRight" then
    self.cursor = nextBoundary(self.text, self.cursor)
    return "handled"
  elseif code == "ArrowUp" or code == "ArrowDown" or code == "Home" or code == "End" then
    local lines = self.lines or self:layout(math.huge, measure)
    local idx, x = self:caret(lines, measure)
    if code == "Home" then
      self.cursor = lines[idx].start
    elseif code == "End" then
      self.cursor = lines[idx].start + #lines[idx].text
    else
      local target = lines[idx + (code == "ArrowUp" and -1 or 1)]
      if target then self.cursor = offsetAt(target, x, measure) end
    end
    return "handled"
  end
  if printable then
    self:insert(ev.key)
    return "handled"
  end
  return nil
end

return TI
