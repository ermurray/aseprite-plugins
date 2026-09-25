local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")

local root = F.unique("open tests ")
app.fs.makeAllDirectories(app.fs.joinPath(root, "chars"))
project.create(root, {})

local function saveSprite(rel, w)
  local s = Sprite(w, w)
  s:saveAs(project.absolute(root, rel))
  s:close()
end
saveSprite("chars/knight.aseprite", 8)
saveSprite("chars/slime.aseprite", 6)

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end

local function setup()
  F.closeAll()
  sprites.projectRoot = root
  local active = Sprite(2, 2)
  active:saveAs(app.fs.joinPath(root, "active.aseprite"))
  app.sprite = active
  return active
end

T.test("names are project-relative inside a project", function()
  local active = setup()
  T.eq(sprites.name(active), "active.aseprite")
  T.eq(call("get_sprite_info").data.sprite, "active.aseprite")
end)

T.test("reading an unopened project sprite opens it in the background and closes it again", function()
  local active = setup()
  local r = call("get_sprite_info", { sprite = "chars/knight.aseprite" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 8)
  T.eq(#app.sprites, 1, "closed again")
  T.eq(app.sprite == active, true, "the artist's tab is active again")
end)

T.test("a failing read still closes the background sprite", function()
  local active = setup()
  local r = call("get_pixels", { sprite = "chars/knight.aseprite", region = { x = 50, y = 50, w = 1, h = 1 } })
  T.eq(r.ok, false)
  T.eq(#app.sprites, 1)
  T.eq(app.sprite == active, true)
end)

T.test("editing an unopened project sprite opens it as a tab and keeps it open", function()
  local active = setup()
  local r = call("layer_ops", { sprite = "chars/slime.aseprite", action = "add", name = "Shade" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.openedAsTab, "chars/slime.aseprite")
  T.eq(#app.sprites, 2)
  T.eq(app.sprite == active, true, "the artist stays on their tab")
end)

T.test("unknown sprites still give the plain error", function()
  setup()
  T.eq(call("get_sprite_info", { sprite = "chars/ghost.aseprite" }).error:find("is not open", 1, true) ~= nil, true)
end)

T.test("list_project_sprites lists project files and which are open", function()
  setup()
  local r = call("list_project_sprites")
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.sprites, {
    { path = "active.aseprite", open = true },
    { path = "chars/knight.aseprite", open = false },
    { path = "chars/slime.aseprite", open = false },
  })
  sprites.projectRoot = nil
  T.eq(call("list_project_sprites").error, "No project is open. The artist can set one up with Set up project in the chat window.")
end)

sprites.projectRoot = nil
F.closeAll()

T.test("an exact project path wins over a same-named open sprite in another folder", function()
  setup()
  local sub = Sprite(3, 3)
  app.fs.makeAllDirectories(app.fs.joinPath(root, "sub"))
  sub:saveAs(project.absolute(root, "sub/knight.aseprite"))
  saveSprite("knight.aseprite", 5)
  local r = call("get_sprite_info", { sprite = "knight.aseprite" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.width, 5, "read the unopened root-level knight, not the open sub/knight")
  sprites.projectRoot = nil
end)
