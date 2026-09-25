local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local scripts = require("agent.tools.scripts")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
scripts.dir = F.unique("scripts")

T.test("write_script saves a commented script into the Agent folder", function()
  local r = call("write_script", { name = "Say hi", description = "Prints a greeting", code = "print('hi')" })
  T.eq(r.ok, true, r.error)
  local f = io.open(r.data.path, "r"); local text = f:read("a"); f:close()
  T.eq(text:find("-- Prints a greeting", 1, true) ~= nil, true)
  T.eq(text:find("print('hi')", 1, true) ~= nil, true)
end)

T.test("run_script runs once, returns printed output and restores print", function()
  local realPrint = print
  local r = call("run_script", { name = "Say hi" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.output, "hi")
  T.eq(print, realPrint)
end)

T.test("script edits are one undo step, and a failing script rolls back", function()
  F.closeAll()
  local s = F.rgbSprite()
  call("write_script", { name = "Paint", description = "Paints one pixel", code = [[
local s = app.sprite
local cel = s.cels[1]
local img = cel.image:clone()
img:drawPixel(3, 2, app.pixelColor.rgba(0, 0, 255, 255))
cel.image = img
]] })
  T.eq(call("run_script", { name = "Paint" }).ok, true)
  T.eq(F.px(s, 3, 2, "Body"), pc.rgba(0, 0, 255, 255))
  app.undo()
  T.eq(F.px(s, 3, 2, "Body"), 0)
  call("write_script", { name = "Broken", description = "Fails halfway", code = [[
local cel = app.sprite.cels[1]
local img = cel.image:clone()
img:drawPixel(2, 2, app.pixelColor.rgba(1, 1, 1, 255))
cel.image = img
error("boom")
]] })
  local bad = call("run_script", { name = "Broken" })
  T.eq(bad.ok, false)
  T.eq(bad.error:find("boom", 1, true) ~= nil, true, bad.error)
  T.eq(F.px(s, 2, 2, "Body"), 0, "rolled back")
end)

T.test("syntax errors and missing scripts are reported", function()
  call("write_script", { name = "Syntax", description = "Bad", code = "local = 1" })
  local r = call("run_script", { name = "Syntax" })
  T.eq(r.ok, false)
  T.eq(r.error:find("Script has a syntax error", 1, true) ~= nil, true, r.error)
  T.eq(call("run_script", { name = "Nope" }).error, "There is no saved script called 'Nope'.")
  T.eq(call("write_script", { name = "../x", description = "d", code = "x" }).ok, false)
end)

F.closeAll()

T.test("script errors name the line, not the file path", function()
  call("write_script", { name = "Syntax2", description = "Bad", code = "local = 1" })
  local r = call("run_script", { name = "Syntax2" })
  T.eq(r.error:find("Script has a syntax error at line 4", 1, true) ~= nil, true, r.error)
  T.eq(r.error:find(".lua", 1, true), nil, r.error)
end)

T.test("write_script refuses hidden control characters and won't overwrite without replace", function()
  T.eq(call("write_script", { name = "Hidden", description = "d", code = "-- tidy\ros.execute('x')" }).ok, false)
  T.eq(call("write_script", { name = "Keep", description = "first", code = "print('one')" }).ok, true)
  T.eq(call("write_script", { name = "Keep", description = "second", code = "print('two')" }).error,
    "A script called 'Keep' already exists. Save it with replace = true to overwrite it.")
  T.eq(call("write_script", { name = "Keep", description = "second", code = "print('two')", replace = true }).ok, true)
  T.eq(call("run_script", { name = "Keep" }).data.output, "two")
end)

T.test("run_script refuses scripts changed since they were approved", function()
  call("write_script", { name = "Tamper", description = "d", code = "print('safe')" })
  local path = app.fs.joinPath(scripts.folder(), "Tamper.lua")
  local f = io.open(path, "a"); f:write("print('sneaky')\n"); f:close()
  T.eq(call("run_script", { name = "Tamper" }).error,
    "The script 'Tamper' changed since it was approved (or wasn't saved through the chat). Save it again with write_script so the artist can review the code.")
end)

T.test("scripts get their own globals", function()
  call("write_script", { name = "Globals", description = "d", code = "LEAKED_GLOBAL_FROM_SCRIPT = 1\nprint = nil" })
  T.eq(call("run_script", { name = "Globals" }).ok, true)
  T.eq(rawget(_G, "LEAKED_GLOBAL_FROM_SCRIPT"), nil)
  T.eq(type(print), "function")
end)
