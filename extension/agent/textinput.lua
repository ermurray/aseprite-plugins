-- A multi-line text box model (Aseprite dialogs have no multi-line entry): text, cursor,
-- soft wrapping that keeps every character, scrolling and key handling. Pure; the window draws it.
--
-- The text is kept exactly as typed or pasted (only line endings are normalised), so Claude
-- receives what the artist wrote. Widths are measured per character on the text as the UI font
-- will draw it (chat_render.displayText), cached, so layout is cheap and the caret stays exact.
local render = require("agent.chat_render")

local TI = {}
TI.__index = TI

function TI.new()
  return setmetatable({
    text = "", cursor = 0, scroll = 0, selectAll = false, followCursor = true,
    lines = nil, layoutKey = nil, lastWidth = math.huge, widths = {}, widthsFor = nil,
  }, TI)
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

local function snap(s, pos)
  pos = math.max(0, math.min(pos, #s))
  while pos > 0 and pos < #s and isCont(s, pos + 1) do pos = pos - 1 end
  return pos
end

local function normalise(s)
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "  ")
  -- Drop other control characters (keep newlines).
  return (s:gsub("[%z\1-\9\11-\31\127]", ""))
end

function TI:changed()
  self.lines, self.layoutKey = nil, nil
  self.cursor = snap(self.text, self.cursor)
  self.followCursor = true
end

function TI:setText(s)
  self.text = normalise(s or "")
  self.cursor = #self.text
  self.selectAll = false
  self:changed()
end

function TI:clear()
  self.text, self.cursor, self.scroll, self.selectAll = "", 0, 0, false
  self:changed()
end

function TI:insert(s)
  if self.selectAll then self:clear() end
  s = normalise(s)
  self.text = self.text:sub(1, self.cursor) .. s .. self.text:sub(self.cursor + 1)
  self.cursor = self.cursor + #s
  self:changed()
end

function TI:charWidth(c, measure)
  if self.widthsFor ~= measure then self.widths, self.widthsFor = {}, measure end
  local w = self.widths[c]
  if not w then
    w = measure(render.displayText(c, true))
    self.widths[c] = w
  end
  return w
end

-- Soft-wrapped visual lines: {start = byte offset, text = string, widths = {per char}}.
-- Breaks after a space when possible, else between characters; "\n" belongs to no line.
-- Cached per (text, width).
function TI:layout(width, measure)
  self.lastWidth = width
  local key = width .. "\0" .. self.text
  if self.lines and self.layoutKey == key and self.widthsFor == measure then return self.lines end
  local lines, pos = {}, 0
  for para in (self.text .. "\n"):gmatch("(.-)\n") do
    local chars = {}
    for p, c in utf8.codes(para) do
      local ch = utf8.char(c)
      chars[#chars + 1] = { p = p, c = ch, w = self:charWidth(ch, measure) }
    end
    if #chars == 0 then
      lines[#lines + 1] = { start = pos, text = "", widths = {} }
    else
      local lineStart, lineWidth, lastSpace = 1, 0, nil
      local j = 1
      while j <= #chars do
        if lineWidth + chars[j].w > width and j > lineStart then
          local breakAt = (lastSpace and lastSpace >= lineStart) and lastSpace or (j - 1)
          local ws = {}
          for k = lineStart, breakAt do ws[#ws + 1] = chars[k].w end
          lines[#lines + 1] = {
            start = pos + chars[lineStart].p - 1,
            text = para:sub(chars[lineStart].p, chars[breakAt].p + #chars[breakAt].c - 1),
            widths = ws,
          }
          lineStart, lineWidth, lastSpace = breakAt + 1, 0, nil
          for k = lineStart, j - 1 do lineWidth = lineWidth + chars[k].w end
        else
          if chars[j].c == " " then lastSpace = j end
          lineWidth = lineWidth + chars[j].w
          j = j + 1
        end
      end
      if lineStart <= #chars then
        local ws = {}
        for k = lineStart, #chars do ws[#ws + 1] = chars[k].w end
        lines[#lines + 1] = { start = pos + chars[lineStart].p - 1, text = para:sub(chars[lineStart].p), widths = ws }
      end
    end
    pos = pos + #para + 1
  end
  self.lines, self.layoutKey = lines, key
  return lines
end

-- x offset of byte column `col` within a laid-out line.
local function xAt(line, col)
  local x, i = 0, 1
  for p in utf8.codes(line.text) do
    if p - 1 >= col then break end
    x = x + (line.widths[i] or 0)
    i = i + 1
  end
  return x
end

-- Which visual line the cursor is on (1-based) and its x offset in pixels.
function TI:caret(lines)
  local idx = 1
  for i, l in ipairs(lines) do
    if self.cursor >= l.start then idx = i end
  end
  local l = lines[idx]
  return idx, xAt(l, math.max(0, math.min(#l.text, self.cursor - l.start)))
end

-- Byte offset on `line` whose left edge is closest to x.
local function offsetAt(line, x)
  local best, bestD, cx, i = line.start, math.abs(x), 0, 1
  for p, c in utf8.codes(line.text) do
    cx = cx + (line.widths[i] or 0)
    i = i + 1
    local col = p - 1 + #utf8.char(c)
    local d = math.abs(cx - x)
    if d < bestD then best, bestD = line.start + col, d end
  end
  return best
end

function TI:ensureVisible(lines, lineHeight, viewHeight)
  local idx = self:caret(lines)
  local top = (idx - 1) * lineHeight
  if top < self.scroll then self.scroll = top end
  if top + lineHeight > self.scroll + viewHeight then self.scroll = top + lineHeight - viewHeight end
  self.scroll = math.max(0, math.min(self.scroll, math.max(0, #lines * lineHeight - viewHeight)))
end

-- Mouse-wheel scrolling: clamped, and it stops following the cursor until the next edit.
function TI:scrollBy(dy, lines, lineHeight, viewHeight)
  self.scroll = math.max(0, math.min(self.scroll + dy, math.max(0, #lines * lineHeight - viewHeight)))
  self.followCursor = false
end

local measureChars = function(s) return utf8.len(s) or #s end

local function currentLines(self, measure)
  return self.lines or self:layout(self.lastWidth, measure)
end

local function deletePrevWord(self)
  local p = self.cursor
  while p > 0 and self.text:sub(p, p) == " " do p = p - 1 end
  while p > 0 and self.text:sub(p, p) ~= " " and self.text:sub(p, p) ~= "\n" do p = p - 1 end
  self.text = self.text:sub(1, p) .. self.text:sub(self.cursor + 1)
  self.cursor = p
  self:changed()
end

-- Returns "send", "handled", or nil (not ours: let Aseprite handle it).
-- getClipboard() is only called for paste; setClipboard(text) only for copy/cut.
function TI:handleKey(ev, getClipboard, measure, setClipboard)
  measure = measure or self.measure or measureChars
  local code = ev.code or ""
  local key = ev.key or ""
  local printable = key ~= "" and key:byte(1) >= 32 and key ~= "\127"
  -- AltGr arrives as Ctrl+Alt on Windows/Linux: those keys type characters, they aren't shortcuts.
  local cmd = (ev.metaKey or ev.ctrlKey) and not (ev.ctrlKey and ev.altKey and printable)
  local selected = self.selectAll
  if cmd then
    if code == "KeyV" then
      local s = getClipboard and getClipboard()
      if s and s ~= "" then self:insert(s) end
      return "handled"
    elseif code == "KeyA" then
      self.selectAll = true
      self.cursor = #self.text
      return "handled"
    elseif code == "KeyC" or code == "KeyX" then
      if selected and setClipboard then
        setClipboard(self.text)
        if code == "KeyX" then self:clear() end
      end
      return "handled"
    elseif code == "ArrowLeft" or code == "ArrowRight" then
      self.selectAll = false
      local lines = currentLines(self, measure)
      local idx = self:caret(lines)
      self.cursor = code == "ArrowLeft" and lines[idx].start or (lines[idx].start + #lines[idx].text)
      self.followCursor = true
      return "handled"
    elseif code == "Backspace" then
      if selected then self:clear() else deletePrevWord(self) end
      return "handled"
    end
    return nil
  end
  if not printable then self.selectAll = false end
  if code == "Enter" or code == "NumpadEnter" then
    if ev.shiftKey then self:insert("\n") return "handled" end
    return "send"
  elseif code == "Backspace" or code == "Delete" then
    if selected then self:clear() return "handled" end
    if code == "Backspace" and ev.altKey then deletePrevWord(self) return "handled" end
    if code == "Backspace" and self.cursor > 0 then
      local p = prevBoundary(self.text, self.cursor)
      self.text = self.text:sub(1, p) .. self.text:sub(self.cursor + 1)
      self.cursor = p
    elseif code == "Delete" and self.cursor < #self.text then
      local n = nextBoundary(self.text, self.cursor)
      self.text = self.text:sub(1, self.cursor) .. self.text:sub(n + 1)
    end
    self:changed()
    return "handled"
  elseif code == "ArrowLeft" then
    self.cursor = prevBoundary(self.text, self.cursor)
    self.followCursor = true
    return "handled"
  elseif code == "ArrowRight" then
    self.cursor = nextBoundary(self.text, self.cursor)
    self.followCursor = true
    return "handled"
  elseif code == "ArrowUp" or code == "ArrowDown" or code == "Home" or code == "End" then
    local lines = currentLines(self, measure)
    local idx, x = self:caret(lines)
    if code == "Home" then
      self.cursor = lines[idx].start
    elseif code == "End" then
      self.cursor = lines[idx].start + #lines[idx].text
    else
      local target = lines[idx + (code == "ArrowUp" and -1 or 1)]
      if target then self.cursor = offsetAt(target, x) end
    end
    self.cursor = snap(self.text, self.cursor)
    self.followCursor = true
    return "handled"
  elseif code == "Tab" or code == "PageUp" or code == "PageDown" then
    return "handled" -- keep Aseprite's frame navigation and focus changes away while typing
  end
  if printable then
    self:insert(key)
    return "handled"
  end
  return nil
end

return TI
