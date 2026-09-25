local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")
local clips = require("agent.clips")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
local root = F.unique("clip proj")
app.fs.makeAllDirectories(root)
project.create(root, {})
local function setMax(n)
  local f = io.open(app.fs.joinPath(root, ".artproject", "project.json"), "w")
  f:write('{"version":1,"clips":{"max":' .. n .. '}}')
  f:close()
end

local function art()
  F.closeAll()
  sprites.projectRoot = root
  local s = F.rgbSprite()
  s:saveAs(project.absolute(root, "art.aseprite"))
  app.sprite = s
  return s
end

T.test("clips need a project", function()
  F.closeAll()
  sprites.projectRoot = nil
  F.rgbSprite()
  T.eq(call("save_clip", { name = "x" }).error, "Clips are kept in a project. Press Set up project first.")
end)

T.test("save, list and insert a clip", function()
  local s = art()
  s.selection = Selection(Rectangle(0, 0, 2, 1))
  local r = call("save_clip", { name = "gem", tags = { "ui" } })
  T.eq(r.ok, true, r.error)
  local list = call("list_clips").data.clips
  T.eq(list[1].name, "gem")
  T.eq(list[1].width, 2)
  T.deepEq(list[1].tags, { "ui" })
  local ins = call("insert_clip", { name = "gem", at = { x = 2, y = 2 } })
  T.eq(ins.ok, true, ins.error)
  T.eq(ins.data.layer, "Clip: gem")
  T.eq(F.px(s, 2, 2, "Clip: gem"), pc.rgba(255, 0, 0, 255))
  T.eq(F.px(s, 3, 2, "Clip: gem"), pc.rgba(0, 255, 0, 255))
  T.eq(call("save_clip", { name = "gem" }).error, "A clip called 'gem' already exists. Save with replace = true to overwrite it.")
end)

T.test("the library keeps the most recently used clips and never evicts pinned ones", function()
  art()
  clips.clear(root, true)
  setMax(2)
  call("save_clip", { name = "a" })
  call("save_clip", { name = "b" })
  call("pin_clip", { name = "a", pinned = true })
  local r = call("save_clip", { name = "c" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.evicted, "b")
  local names = {}
  for _, c in ipairs(call("list_clips").data.clips) do names[#names + 1] = c.name end
  table.sort(names)
  T.deepEq(names, { "a", "c" })
  call("pin_clip", { name = "c", pinned = true })
  T.eq(call("save_clip", { name = "d" }).error, "All 2 clips are pinned and the library is full (max 2). Unpin or delete one first.")
end)

T.test("inserting a clip counts as using it", function()
  art()
  clips.clear(root, true)
  setMax(2)
  call("save_clip", { name = "old" })
  call("save_clip", { name = "new" })
  call("insert_clip", { name = "old" })
  T.eq(call("save_clip", { name = "newest" }).data.evicted, "new")
end)

T.test("delete, rename, clear and the UI label", function()
  art()
  clips.clear(root, true)
  setMax(20)
  call("save_clip", { name = "one", tags = { "tile" } })
  call("save_clip", { name = "two" })
  clips.rename(root, "one", "uno")
  T.eq(clips.list(root, "uno")[1].name, "uno")
  T.eq(clips.list(root, "tile")[1].name, "uno", "filter matches tags")
  T.eq(clips.label(clips.list(root, "uno")[1]):find("uno", 1, true) ~= nil, true)
  T.eq(call("delete_clip", { name = "two" }).ok, true)
  clips.pin(root, "uno", true)
  T.eq(clips.clear(root, false), 0, "pinned clips survive clear unless asked")
  T.eq(clips.clear(root, true), 1)
  T.eq(#clips.list(root), 0)
  sprites.projectRoot = nil
end)

F.closeAll()

T.test("clip names that look alike get separate files", function()
  art()
  clips.clear(root, true)
  setMax(20)
  call("save_clip", { name = "a b", region = { x = 0, y = 0, w = 1, h = 1 } })
  call("save_clip", { name = "a_b", region = { x = 1, y = 0, w = 1, h = 1 } })
  local files = {}
  for _, c in ipairs(clips.list(root)) do files[#files + 1] = c.file:lower() end
  T.eq(files[1] ~= files[2], true)
  local dest = app.sprite
  call("insert_clip", { name = "a b", at = { x = 0, y = 2 } })
  T.eq(F.px(dest, 0, 2, "Clip: a b"), pc.rgba(255, 0, 0, 255))
end)

T.test("a failed save never evicts a clip, and the preview names the one that would go", function()
  art()
  clips.clear(root, true)
  setMax(1)
  call("save_clip", { name = "keep" })
  T.eq(call("preview_save_clip", { name = "next" }).data.note, "The library is full (max 1): this removes the clip 'keep'.")
  T.eq(call("save_clip", { name = "broken", layer = "Nope" }).ok, false)
  T.eq(#clips.list(root), 1)
  T.eq(clips.list(root)[1].name, "keep")
  T.eq(#app.sprites, 1, "no temporary clip sprite left open")
end)
