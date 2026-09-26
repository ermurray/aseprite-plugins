local T = require("testlib")
local TI = require("agent.textinput")

local function chars(s) return utf8.len(s) or #s end
local function key(code, keyText, mods)
  local ev = { code = code, key = keyText or "" }
  for k, v in pairs(mods or {}) do ev[k] = v end
  return ev
end
local function typeText(t, s)
  for _, c in utf8.codes(s) do t:handleKey(key("Key", utf8.char(c))) end
end

T.test("typing, backspace and delete work on UTF-8 characters", function()
  local t = TI.new()
  typeText(t, "héllo")
  T.eq(t.text, "héllo")
  t:handleKey(key("ArrowLeft"))
  t:handleKey(key("ArrowLeft"))
  t:handleKey(key("ArrowLeft"))
  t:handleKey(key("Backspace"))
  T.eq(t.text, "hllo")
  t:handleKey(key("Delete"))
  T.eq(t.text, "hlo")
  T.eq(t.cursor, 1)
end)

T.test("Enter sends, Shift+Enter adds a new line", function()
  local t = TI.new()
  typeText(t, "a")
  T.eq(t:handleKey(key("Enter", "", { shiftKey = true })), "handled")
  typeText(t, "b")
  T.eq(t.text, "a\nb")
  T.eq(t:handleKey(key("Enter")), "send")
  T.eq(t.text, "a\nb", "sending is the window's job; the text stays until cleared")
end)

T.test("Cmd/Ctrl+V pastes, Cmd/Ctrl+A then Backspace clears, and pasted text is made drawable", function()
  local t = TI.new()
  T.eq(t:handleKey(key("KeyV", "v", { metaKey = true }), function() return "3\u{2013}4\r\nnext" end), "handled")
  T.eq(t.text, "3-4\nnext")
  t:handleKey(key("KeyA", "a", { ctrlKey = true }))
  t:handleKey(key("Backspace"))
  T.eq(t.text, "")
  typeText(t, "x")
  t:handleKey(key("KeyA", "a", { metaKey = true }))
  typeText(t, "y")
  T.eq(t.text, "y", "typing replaces a select-all")
end)

T.test("other shortcuts pass through to Aseprite; unknown keys are ignored", function()
  local t = TI.new()
  T.eq(t:handleKey(key("KeyZ", "z", { metaKey = true })), nil)
  T.eq(t:handleKey(key("Escape")), nil)
  T.eq(t.text, "")
end)

T.test("layout wraps long lines at spaces, keeps every character, and honours new lines", function()
  local t = TI.new()
  t:setText("hello world again\nx")
  local lines = t:layout(8, chars)
  local texts = {}
  for i, l in ipairs(lines) do texts[i] = l.text end
  T.deepEq(texts, { "hello ", "world ", "again", "x" })
  T.eq(lines[4].start, #"hello world again\n")
end)

T.test("layout hard-breaks words longer than the box", function()
  local t = TI.new()
  t:setText("abcdefghij")
  local texts = {}
  for i, l in ipairs(t:layout(4, chars)) do texts[i] = l.text end
  T.deepEq(texts, { "abcd", "efgh", "ij" })
end)

T.test("up and down move between visual lines, Home and End stay on the line", function()
  local t = TI.new()
  t:setText("hello world again")
  t:layout(8, chars)
  t.cursor = #"hello wo"
  t:handleKey(key("ArrowUp"))
  T.eq(t.cursor, 2, "same column on the line above")
  t:handleKey(key("ArrowDown"))
  t:handleKey(key("ArrowDown"))
  T.eq(t.cursor, #"hello world ag")
  t:handleKey(key("Home"))
  T.eq(t.cursor, #"hello world ")
  t:handleKey(key("End"))
  T.eq(t.cursor, #"hello world again")
end)

T.test("caret position and scrolling keep the cursor in view", function()
  local t = TI.new()
  t:setText("1\n2\n3\n4\n5\n6")
  local lines = t:layout(10, chars)
  local line, x = t:caret(lines, chars)
  T.eq(line, 6)
  T.eq(x, 1)
  t:ensureVisible(lines, 10, 40, chars)
  T.eq(t.scroll, 20, "last line visible in a 4-line box")
  t.cursor = 0
  t:ensureVisible(lines, 10, 40, chars)
  T.eq(t.scroll, 0)
end)
