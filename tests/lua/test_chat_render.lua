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

T.test("layout adds a thinking line after the history while busy", function()
  local items = { { kind = "user", text = "hi" } }
  local lay = R.layout(items, { width = 40, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude", thinking = 0 })
  T.deepEq(lay.lines[#lay.lines], { text = "Claude is thinking", kind = "thinking", y = 25 })
  T.eq(lay.height, 35)
  local idle = R.layout(items, { width = 40, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude" })
  T.eq(idle.lines[#idle.lines].kind, "user")
end)

T.test("thinking text animates its dots with the tick", function()
  T.eq(R.thinkingText("Claude", 0), "Claude is thinking")
  T.eq(R.thinkingText("Claude", 1), "Claude is thinking.")
  T.eq(R.thinkingText("Claude", 3), "Claude is thinking...")
  T.eq(R.thinkingText("Claude", 4), "Claude is thinking")
end)

T.test("an empty history while thinking shows only the thinking line", function()
  local lay = R.layout({}, { width = 40, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude", thinking = 2 })
  T.deepEq(lay.lines, { { text = "Claude is thinking..", kind = "thinking", y = 0 } })
end)

T.test("approval cards show a label, the summary and the state", function()
  local items = { { kind = "approval", id = "a1", text = "Set 2 pixels on hero", state = "pending" } }
  local lay = R.layout(items, { width = 40, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude" })
  T.deepEq(lay.lines, {
    { text = "Claude wants to:", kind = "approval_label", y = 0 },
    { text = "Set 2 pixels on hero", kind = "approval", y = 10 },
    { text = "Apply or Deny below", kind = "approval_state", y = 20 },
  })
  items[1].state = "denied"
  T.eq(R.layout(items, { width = 40, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude" }).lines[3].text, "Denied")
end)
