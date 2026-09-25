local sprites = require("agent.tools.sprites")
local project = require("agent.project")
local projectconfig = require("agent.projectconfig")

local M = {}

local SHEET_TYPES = { horizontal = "HORIZONTAL", vertical = "VERTICAL", rows = "ROWS", columns = "COLUMNS", packed = "PACKED" }

local function frameRange(s, tagName)
  if not tagName then
    local out = {}
    for i = 1, #s.frames do out[i] = i end
    return out
  end
  for _, t in ipairs(s.tags) do
    if t.name == tagName then
      local out = {}
      for n = t.fromFrame.frameNumber, t.toFrame.frameNumber do out[#out + 1] = n end
      return out
    end
  end
  error("Tag '" .. tagName .. "' not found.", 0)
end

local function render(s, layerName, frameNumber, scale)
  local img = Image(s.width, s.height, ColorMode.RGB)
  img:clear(0)
  if layerName then
    local cel = sprites.layer(s, layerName):cel(frameNumber)
    if cel then img:drawImage(cel.image, cel.position) end
  else
    img:drawSprite(s, frameNumber)
  end
  if scale > 1 then img:resize(s.width * scale, s.height * scale) end
  return img
end

-- The files one format produces for `base` in `dir`.
local function targets(s, args, dir, base, frameNumber)
  local fmt = args.format
  if fmt == "png" then return { app.fs.joinPath(dir, base .. ".png") } end
  if fmt == "gif" then return { app.fs.joinPath(dir, base .. ".gif") } end
  if fmt == "frames" then
    local out = {}
    for _, n in ipairs(frameRange(s, args.tag)) do out[#out + 1] = app.fs.joinPath(dir, ("%s_%d.png"):format(base, n)) end
    return out
  end
  local out = { app.fs.joinPath(dir, base .. "_sheet.png") }
  if args.data ~= "none" then out[2] = app.fs.joinPath(dir, base .. "_sheet.json") end
  return out
end

local function same(a, b)
  return app.fs.normalizePath(a):lower() == app.fs.normalizePath(b):lower()
end

-- Works out everything an export will do, without writing anything.
function M.plan(args)
  local s = sprites.resolve(args.sprite)
  local root = sprites.projectRoot
  local saved = app.fs.filePath(s.filename) ~= ""
  local dir
  if args.destination then
    local dest = tostring(args.destination)
    local absolute = dest:sub(1, 1) == "/" or dest:match("^%a:[/\\]")
    if not saved and not absolute then error("Save the sprite first, or give an absolute destination folder.", 0) end
    dir = app.fs.normalizePath(projectconfig.resolveDestination(root, s.filename, dest))
  else
    if not saved then error("Save the sprite first, or give an absolute destination folder.", 0) end
    dir = projectconfig.exportDir(root, s.filename, projectconfig.read(root))
  end
  if args.format == "gif" and args.layer then
    error("GIF export uses the whole sprite; drop layer or export frames/png instead.", 0)
  end
  local base = args.name and tostring(args.name) or app.fs.fileTitle(s.filename)
  if base == "" then base = "sprite" end
  local frameNumber = args.frame and sprites.frame(s, args.frame).frameNumber
    or ((app.sprite == s and app.frame) and app.frame.frameNumber or 1)
  local plan = { sprite = s, dir = dir, base = base, frameNumber = frameNumber, scale = math.floor(tonumber(args.scale) or 1) }
  plan.files = targets(s, args, dir, base, frameNumber)
  if args.includeNormal then
    plan.normalPath = saved and app.fs.joinPath(app.fs.filePath(s.filename), app.fs.fileTitle(s.filename) .. "_normal.aseprite") or nil
    if not plan.normalPath or not app.fs.isFile(plan.normalPath) then
      error("There is no normal map yet; make it first with make_normal_map.", 0)
    end
    plan.normalFiles = targets(s, args, dir, base .. "_n", frameNumber)
  end
  plan.overwrites = {}
  local all = {}
  for _, f in ipairs(plan.files) do all[#all + 1] = f end
  for _, f in ipairs(plan.normalFiles or {}) do all[#all + 1] = f end
  for _, f in ipairs(all) do
    if saved and same(f, s.filename) then
      error("That would overwrite " .. app.fs.fileName(s.filename) .. " itself. Pick another name or destination.", 0)
    end
    if app.fs.isFile(f) then plan.overwrites[#plan.overwrites + 1] = app.fs.fileName(f) end
  end
  plan.all = all
  return plan
end

function M.preview_export(args)
  local p = M.plan(args)
  local names = {}
  for _, f in ipairs(p.all) do names[#names + 1] = app.fs.fileName(f) end
  local note = "Writes to " .. p.dir .. ": " .. table.concat(names, ", ")
  if #p.overwrites > 0 then note = note .. " (replaces existing " .. table.concat(p.overwrites, ", ") .. ")" end
  return { note = note }
end

local function writeFormat(s, args, dir, base, scale, frameNumber)
  local fmt = args.format
  local prev = app.sprite
  local ok, err = pcall(function()
    if fmt == "png" then
      render(s, args.layer, frameNumber, scale):saveAs(app.fs.joinPath(dir, base .. ".png"))
    elseif fmt == "frames" then
      for _, n in ipairs(frameRange(s, args.tag)) do
        render(s, args.layer, n, scale):saveAs(app.fs.joinPath(dir, ("%s_%d.png"):format(base, n)))
      end
    elseif fmt == "gif" then
      app.sprite = s
      local params = { ui = false, filename = app.fs.joinPath(dir, base .. ".gif"), scale = scale }
      if args.tag then params.tag = args.tag end
      app.command.SaveFileCopyAs(params)
    else
      local src = s
      if scale > 1 then
        src = Sprite(s)
        src:resize(s.width * scale, s.height * scale)
      end
      local sheetOk, sheetErr = pcall(function()
        app.sprite = src
        local params = {
          ui = false,
          askOverwrite = false,
          type = SpriteSheetType[SHEET_TYPES[args.sheetType or "horizontal"]],
          textureFilename = app.fs.joinPath(dir, base .. "_sheet.png"),
          dataFilename = args.data ~= "none" and app.fs.joinPath(dir, base .. "_sheet.json") or "",
          dataFormat = args.data == "array" and SpriteSheetDataFormat.JSON_ARRAY or SpriteSheetDataFormat.JSON_HASH,
        }
        if args.tag then params.tag = args.tag end
        if args.layer then params.layer = args.layer end
        app.command.ExportSpriteSheet(params)
      end)
      if src ~= s then pcall(function() src:close() end) end
      if not sheetOk then error(sheetErr, 0) end
    end
  end)
  if prev then pcall(function() app.sprite = prev end) end
  if not ok then error(err, 0) end
end

function M.export_sprite(args)
  local p = M.plan(args)
  local s, root = p.sprite, sprites.projectRoot
  app.fs.makeAllDirectories(p.dir)
  writeFormat(s, args, p.dir, p.base, p.scale, p.frameNumber)
  if p.normalPath then
    local prev = app.sprite
    local n = Sprite{ fromFile = p.normalPath }
    local ok, err = pcall(writeFormat, n,
      { format = args.format, tag = args.tag, sheetType = args.sheetType, data = args.data },
      p.dir, p.base .. "_n", p.scale, math.min(p.frameNumber, #n.frames))
    n:close()
    if prev then pcall(function() app.sprite = prev end) end
    if not ok then error(err, 0) end
  end
  local shown = {}
  for i, f in ipairs(p.all) do
    if not app.fs.isFile(f) then error("Couldn't write " .. app.fs.fileName(f) .. " (is the folder writable?).", 0) end
    shown[i] = (root and project.relative(root, f)) or f
  end
  return { files = shown, folder = p.dir, replaced = p.overwrites }
end

return M
