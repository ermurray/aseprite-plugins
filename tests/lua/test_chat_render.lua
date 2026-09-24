local T = require("testlib")
local R = require("agent.chat_render")

local function chars(s) return utf8.len(s) or #s end

T.test("wraps on word boundaries", function()
  T.deepEq(R.wrap("hello world", 5, chars), { "hello", "world" })
  T.deepEq(R.wrap("a b c", 100, chars), { "a b c" })
end)

T.test("hard-breaks words longer than the width", function()
  T.deepEq(R.wrap("abcdefghij", 4, chars), { "abcd", "efgh", "ij" })
  T.deepEq(R.wrap("see https://example.com/very/long", 10, chars),
    { "see", "https://ex", "ample.com/", "very/long" })
end)

T.test("keeps paragraphs and blank lines", function()
  T.deepEq(R.wrap("one\n\ntwo", 10, chars), { "one", "", "two" })
  T.deepEq(R.wrap("", 10, chars), { "" })
end)

T.test("splits on UTF-8 characters, not bytes", function()
  T.deepEq(R.wrap("héllo wörld", 5, chars), { "héllo", "wörld" })
  T.deepEq(R.wrap("ééééé", 2, chars), { "éé", "éé", "é" })
end)

T.test("survives invalid UTF-8", function()
  local lines = R.wrap("ab\255\254cd", 2, function(s) return #s end)
  T.eq(#lines > 0, true)
end)

T.test("lays out labels, text, activity and gaps", function()
  local items = {
    { kind = "user", text = "hi" },
    { kind = "agent", text = "yo" },
    { kind = "activity", text = "Looked at a" },
  }
  local lay = R.layout(items, { width = 20, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude" })
  T.deepEq(lay.lines, {
    { text = "You", kind = "user_label", y = 0 },
    { text = "hi", kind = "user", y = 10 },
    { text = "Claude", kind = "agent_label", y = 25 },
    { text = "yo", kind = "agent", y = 35 },
    { text = "- Looked at a", kind = "activity", y = 50 },
  })
  T.eq(lay.height, 60)
end)

T.test("clampScroll keeps the view inside the content", function()
  T.eq(R.clampScroll(-5, 100, 40), 0)
  T.eq(R.clampScroll(500, 100, 40), 60)
  T.eq(R.clampScroll(10, 30, 40), 0)
end)
