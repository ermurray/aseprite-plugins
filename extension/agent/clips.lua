local project = require("agent.project")
local projectconfig = require("agent.projectconfig")
local paste = require("agent.tools.paste")
local sprites = require("agent.tools.sprites")

local M = {}

function M.dir(root)
  if not root then error("Clips are kept in a project. Press Set up project first.", 0) end
  return app.fs.joinPath(root, project.DIR, "clips")
end

local function indexPath(root) return app.fs.joinPath(M.dir(root), "clips.json") end

local function load(root)
  local f = io.open(indexPath(root), "r")
  if not f then return {} end
  local ok, data = pcall(json.decode, f:read("a"))
  f:close()
  local out = {}
  if ok and data and data.clips then
    for i = 1, #data.clips do
      local c = data.clips[i]
      local tags = {}
      if c.tags then for j = 1, #c.tags do tags[j] = tostring(c.tags[j]) end end
      out[#out + 1] = {
        name = tostring(c.name), file = tostring(c.file), tags = tags, source = c.source and tostring(c.source) or nil,
        width = math.floor(tonumber(c.width) or 0), height = math.floor(tonumber(c.height) or 0),
        frames = math.floor(tonumber(c.frames) or 1), createdAt = tonumber(c.createdAt) or 0,
        lastUsedAt = tonumber(c.lastUsedAt) or 0, pinned = c.pinned == true,
      }
    end
  end
  return out
end

local function save(root, list)
  app.fs.makeAllDirectories(M.dir(root))
  local f = assert(io.open(indexPath(root), "w"))
  f:write(json.encode({ clips = list }))
  f:close()
end

local function find(list, name)
  for i, c in ipairs(list) do if c.name == name then return c, i end end
end

local clock = 0
local function now()
  -- Strictly increasing, so clips saved in the same second still have an order.
  clock = math.max(clock + 1, os.time() * 1000)
  return clock
end

function M.list(root, filter)
  local list = load(root)
  local q = filter and filter:lower() or ""
  local out = {}
  for _, c in ipairs(list) do
    local hit = q == "" or c.name:lower():find(q, 1, true)
    for _, t in ipairs(c.tags) do if t:lower():find(q, 1, true) then hit = true end end
    if hit then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.lastUsedAt > b.lastUsedAt end)
  return out
end

function M.label(c)
  local tags = #c.tags > 0 and (" [" .. table.concat(c.tags, ", ") .. "]") or ""
  return ("%s%s  %dx%d%s%s"):format(c.name, tags, c.width, c.height, c.frames > 1 and (", " .. c.frames .. " frames") or "", c.pinned and "  (pinned)" or "")
end

-- A file name for a clip that no other clip uses (names like "a b" and "a_b", or "Hero" and
-- "hero" on case-insensitive disks, must not share a file).
local function fileFor(name, list, except)
  local stem = (name:gsub("[^%w_%-]", "_"))
  local used = {}
  for _, c in ipairs(list) do if c ~= except then used[c.file:lower()] = true end end
  local file, i = stem .. ".aseprite", 2
  while used[file:lower()] do
    file = stem .. "_" .. i .. ".aseprite"
    i = i + 1
  end
  return file
end

-- The clip a save would evict (nil when there's room or the name already exists).
function M.victim(root, name)
  local list = load(root)
  if find(list, name) or #list < projectconfig.read(root).clips.max then return nil end
  local victim
  for _, c in ipairs(list) do
    if not c.pinned and (not victim or c.lastUsedAt < victim.lastUsedAt) then victim = c end
  end
  if not victim then
    error(("All %d clips are pinned and the library is full (max %d). Unpin or delete one first."):format(#list, projectconfig.read(root).clips.max), 0)
  end
  return victim
end

function M.save(root, sprite, opts)
  local list = load(root)
  local existing = find(list, opts.name)
  if existing and not opts.replace then
    error("A clip called '" .. opts.name .. "' already exists. Save with replace = true to overwrite it.", 0)
  end
  local victim = M.victim(root, opts.name)
  -- Write the new clip first; only then evict, so a failed save never costs the artist a clip.
  local frames = paste.frameImages(sprite, opts.layer, opts.frames, opts.region, nil)
  local w, h = frames[1].image.width, frames[1].image.height
  if w < 1 or h < 1 then error("The clip area is empty.", 0) end
  app.fs.makeAllDirectories(M.dir(root))
  local file = existing and existing.file or fileFor(opts.name, list)
  local prev = app.sprite
  local clip = Sprite(w, h, ColorMode.RGB)
  local ok, err = pcall(function()
    for i = 2, #frames do clip:newEmptyFrame(i) end
    for i, fr in ipairs(frames) do
      local cel = clip.layers[1]:cel(i)
      if cel then cel.image = fr.image else clip:newCel(clip.layers[1], i, fr.image, Point(0, 0)) end
    end
    clip.layers[1].name = "Clip"
    clip:saveAs(app.fs.joinPath(M.dir(root), file))
  end)
  pcall(function() clip:close() end)
  if prev then pcall(function() app.sprite = prev end) end
  if not ok then error(err, 0) end
  if not app.fs.isFile(app.fs.joinPath(M.dir(root), file)) then error("Couldn't save the clip file.", 0) end
  local evicted
  if victim then
    os.remove(app.fs.joinPath(M.dir(root), victim.file))
    local _, vi = find(list, victim.name)
    table.remove(list, vi)
    evicted = victim.name
  end
  local t = now()
  local entry = {
    name = opts.name, file = file, tags = opts.tags or {}, source = sprites.name(sprite),
    width = w, height = h, frames = #frames, createdAt = t, lastUsedAt = t, pinned = existing and existing.pinned or false,
  }
  local _, i = find(list, opts.name)
  if i then list[i] = entry else list[#list + 1] = entry end
  save(root, list)
  return entry, evicted
end

function M.frames(root, name)
  local list = load(root)
  local c = find(list, name)
  if not c then error("There is no clip called '" .. name .. "'.", 0) end
  local prev = app.sprite
  local clip = Sprite{ fromFile = app.fs.joinPath(M.dir(root), c.file) }
  local ok, frames = pcall(function()
    local nums = {}
    for i = 1, #clip.frames do nums[i] = i end
    return paste.frameImages(clip, nil, nums, nil, nil)
  end)
  clip:close()
  if prev then pcall(function() app.sprite = prev end) end
  if not ok then error(frames, 0) end
  c.lastUsedAt = now()
  save(root, list)
  return frames, c
end

function M.delete(root, name)
  local list = load(root)
  local c, i = find(list, name)
  if not c then error("There is no clip called '" .. name .. "'.", 0) end
  os.remove(app.fs.joinPath(M.dir(root), c.file))
  table.remove(list, i)
  save(root, list)
end

function M.pin(root, name, pinned)
  local list = load(root)
  local c = find(list, name)
  if not c then error("There is no clip called '" .. name .. "'.", 0) end
  c.pinned = pinned == true
  save(root, list)
end

function M.rename(root, old, new)
  local list = load(root)
  local c = find(list, old)
  if not c then error("There is no clip called '" .. old .. "'.", 0) end
  if find(list, new) then error("A clip called '" .. new .. "' already exists.", 0) end
  c.name = new
  save(root, list)
end

function M.clear(root, includePinned)
  local n = 0
  for _, c in ipairs(load(root)) do
    if includePinned or not c.pinned then
      M.delete(root, c.name)
      n = n + 1
    end
  end
  return n
end

return M
