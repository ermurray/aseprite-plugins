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

-- Writes one format for sprite `s` into `dir` with base name `base`; returns the absolute paths.
local function exportOne(s, args, dir, base, scale)
  local files = {}
  local fmt = args.format
  if fmt == "png" then
    local n = args.frame and sprites.frame(s, args.frame).frameNumber or ((app.sprite == s and app.frame) and app.frame.frameNumber or 1)
    local path = app.fs.joinPath(dir, base .. ".png")
    render(s, args.layer, n, scale):saveAs(path)
    files[1] = path
  elseif fmt == "frames" then
    for _, n in ipairs(frameRange(s, args.tag)) do
      local path = app.fs.joinPath(dir, ("%s_%d.png"):format(base, n))
      render(s, args.layer, n, scale):saveAs(path)
      files[#files + 1] = path
    end
  elseif fmt == "gif" then
    if args.layer then error("GIF export uses the whole sprite; drop layer or export frames/png instead.", 0) end
    local path = app.fs.joinPath(dir, base .. ".gif")
    local prev = app.sprite
    app.sprite = s
    local params = { ui = false, filename = path, scale = scale }
    if args.tag then params.tag = args.tag end
    app.command.SaveFileCopyAs(params)
    if prev then app.sprite = prev end
    files[1] = path
  else
    local prev = app.sprite
    local src = s
    if scale > 1 then
      src = Sprite(s)
      src:resize(s.width * scale, s.height * scale)
    end
    local png = app.fs.joinPath(dir, base .. "_sheet.png")
    local jsonPath = args.data ~= "none" and app.fs.joinPath(dir, base .. "_sheet.json") or nil
    local ok, err = pcall(function()
      app.sprite = src
      local params = {
        ui = false,
        askOverwrite = false,
        type = SpriteSheetType[SHEET_TYPES[args.sheetType or "horizontal"]],
        textureFilename = png,
        dataFilename = jsonPath or "",
        dataFormat = args.data == "array" and SpriteSheetDataFormat.JSON_ARRAY or SpriteSheetDataFormat.JSON_HASH,
      }
      if args.tag then params.tag = args.tag end
      if args.layer then params.layer = args.layer end
      app.command.ExportSpriteSheet(params)
    end)
    if src ~= s then pcall(function() src:close() end) end
    if prev then pcall(function() app.sprite = prev end) end
    if not ok then error(err, 0) end
    files[1] = png
    if jsonPath then files[2] = jsonPath end
  end
  for _, f in ipairs(files) do
    if not app.fs.isFile(f) then error("Couldn't write " .. app.fs.fileName(f) .. " (is the folder writable?).", 0) end
  end
  return files
end

function M.export_sprite(args)
  local s = sprites.resolve(args.sprite)
  local root = sprites.projectRoot
  local saved = app.fs.filePath(s.filename) ~= ""
  local dir
  if args.destination then
    local dest = tostring(args.destination)
    local absolute = dest:sub(1, 1) == "/" or dest:match("^%a:[/\\]")
    if not saved and not absolute then error("Save the sprite first, or give an absolute destination folder.", 0) end
    dir = projectconfig.resolveDestination(root, s.filename, dest)
  else
    if not saved then error("Save the sprite first, or give an absolute destination folder.", 0) end
    dir = projectconfig.exportDir(root, s.filename, projectconfig.read(root))
  end
  app.fs.makeAllDirectories(dir)
  local scale = math.floor(tonumber(args.scale) or 1)
  local base = args.name and tostring(args.name) or app.fs.fileTitle(s.filename)
  if base == "" then base = "sprite" end
  local files = exportOne(s, args, dir, base, scale)

  if args.includeNormal then
    local normalPath = app.fs.joinPath(app.fs.filePath(s.filename), app.fs.fileTitle(s.filename) .. "_normal.aseprite")
    if not app.fs.isFile(normalPath) then error("There is no normal map yet; make it first with make_normal_map.", 0) end
    local prev = app.sprite
    local n = Sprite{ fromFile = normalPath }
    local ok, more = pcall(exportOne, n, { format = args.format, frame = args.frame, tag = args.tag, sheetType = args.sheetType, data = args.data }, dir, base .. "_n", scale)
    n:close()
    if prev then pcall(function() app.sprite = prev end) end
    if not ok then error(more, 0) end
    for _, f in ipairs(more) do files[#files + 1] = f end
  end

  local shown = {}
  for i, f in ipairs(files) do shown[i] = (root and project.relative(root, f)) or f end
  return { files = shown, folder = dir }
end

return M
