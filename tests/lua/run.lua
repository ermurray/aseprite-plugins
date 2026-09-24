local root = app.params.root
package.path = app.fs.joinPath(root, "extension", "?.lua") .. ";"
  .. app.fs.joinPath(root, "extension", "?", "init.lua") .. ";"
  .. app.fs.joinPath(root, "tests", "lua", "?.lua") .. ";" .. package.path

local T = require("testlib")
local only = app.params.only or ""
local suites = { "test_chat_model", "test_chat_render", "test_tools_inspect", "test_connection" }

for _, name in ipairs(suites) do
  if only == "" or name:find(only, 1, true) then
    local path = app.fs.joinPath(root, "tests", "lua", name .. ".lua")
    if app.fs.isFile(path) then
      print(name)
      require(name)
    end
  end
end
T.finish()
