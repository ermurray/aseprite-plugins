local root = app.params.root
package.path = app.fs.joinPath(root, "extension", "?.lua") .. ";"
  .. app.fs.joinPath(root, "extension", "?", "init.lua") .. ";"
  .. app.fs.joinPath(root, "tests", "lua", "?.lua") .. ";" .. package.path

math.randomseed(os.time() + math.floor(os.clock() * 1e6))
local T = require("testlib")
local only = app.params.only or ""
local suites = {
  "test_chat_model", "test_chat_render", "test_tools_inspect", "test_connection",
  "test_edit", "test_pixels", "test_palette", "test_layers_frames", "test_geometry",
  "test_annotate_transform", "test_analyze", "test_chat_window", "test_project", "test_prefs_context", "test_open_sprites", "test_palettes", "test_fx_math", "test_fx", "test_maps", "test_builtin_toolstate", "test_scripts", "test_projectconfig", "test_import", "test_clips", "test_export", "test_launcher", "test_textinput",
}

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
