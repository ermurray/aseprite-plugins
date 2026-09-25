local T = require("testlib")
local F = require("fixtures")
local project = require("agent.project")

local base = F.unique("proj tests ")
local game = app.fs.joinPath(base, "My Gäme")
app.fs.makeAllDirectories(app.fs.joinPath(game, "chars", "enemies"))
app.fs.makeAllDirectories(app.fs.joinPath(game, ".hidden"))

local function touch(path)
  local f = io.open(path, "w"); f:write("x"); f:close()
end
touch(app.fs.joinPath(game, "chars", "hero.aseprite"))
touch(app.fs.joinPath(game, "chars", "enemies", "slime.ase"))
touch(app.fs.joinPath(game, "chars", "notes.txt"))
touch(app.fs.joinPath(game, ".hidden", "secret.aseprite"))

T.test("create writes the project files and refuses to run twice", function()
  local dir = project.create(game, { resolution = "32x32", palette = "", outline = "1px dark", light = "top-left", notes = "Cozy village" })
  T.eq(app.fs.isDirectory(app.fs.joinPath(dir, "chats")), true)
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "project.json")), true)
  local f = io.open(app.fs.joinPath(dir, "brief.md")); local brief = f:read("a"); f:close()
  T.eq(brief:find("Sprite size: 32x32", 1, true) ~= nil, true, brief)
  T.eq(brief:find("Palette: (not set)", 1, true) ~= nil, true, brief)
  T.eq(brief:find("Cozy village", 1, true) ~= nil, true, brief)
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "memory.md")), true)
  T.errors(function() project.create(game, {}) end, "This folder is already a project.")
  T.errors(function() project.create(app.fs.joinPath(base, "nope"), {}) end, "Folder not found")
end)

T.test("findRoot walks up from a file or folder, and returns nil outside projects", function()
  T.eq(project.findRoot(app.fs.joinPath(game, "chars", "enemies", "slime.ase")), game)
  T.eq(project.findRoot(app.fs.joinPath(game, "chars")), game)
  T.eq(project.findRoot(base), nil)
  T.eq(project.findRoot(""), nil)
  T.eq(project.findRoot(nil), nil)
  T.eq(project.findRoot("/"), nil, "terminates at the filesystem root")
end)

T.test("relative and absolute paths round-trip with / separators", function()
  local abs = app.fs.joinPath(game, "chars", "hero.aseprite")
  T.eq(project.relative(game, abs), "chars/hero.aseprite")
  T.eq(project.absolute(game, "chars/hero.aseprite"), abs)
  T.eq(project.relative(game, app.fs.joinPath(base, "other.aseprite")), nil)
  T.eq(project.relative(game .. "x", abs), nil, "a sibling folder with a shared prefix is not inside")
end)

T.test("listSprites finds sprites recursively and skips hidden folders", function()
  T.deepEq(project.listSprites(game), { "chars/enemies/slime.ase", "chars/hero.aseprite" })
end)

T.test("ancestors lists the file's folder first", function()
  local list = project.ancestors(app.fs.joinPath(game, "chars", "hero.aseprite"), 3)
  T.deepEq(list, { app.fs.joinPath(game, "chars"), game, base })
end)

T.test("listSprites stops at a depth limit (no runaway walks)", function()
  local deep = app.fs.joinPath(base, "deep")
  local dir = deep
  for i = 1, 10 do dir = app.fs.joinPath(dir, "d" .. i) end
  app.fs.makeAllDirectories(dir)
  touch(app.fs.joinPath(dir, "too-deep.aseprite"))
  touch(app.fs.joinPath(deep, "d1", "shallow.aseprite"))
  local list = project.listSprites(deep)
  T.deepEq(list, { "d1/shallow.aseprite" })
end)

T.test("ancestors never offer the home folder or the filesystem root", function()
  local home = os.getenv("HOME")
  for _, dir in ipairs(project.ancestors(app.fs.joinPath(home, "a", "b", "c.aseprite"), 10)) do
    T.eq(dir ~= home and dir ~= "/" and dir ~= "", true, dir)
  end
end)
