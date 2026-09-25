local F = {}
local pc = app.pixelColor

F.tmp = app.fs.joinPath(app.fs.tempPath, "aseagent-tests")
app.fs.makeAllDirectories(F.tmp)

-- A folder name no earlier test run has used (os.time() alone collides between quick runs).
local runId = tostring(os.time()) .. "-" .. tostring(math.floor(os.clock() * 1e6)) .. "-" .. tostring(math.random(1e9))
local counter = 0
function F.unique(prefix)
  counter = counter + 1
  return app.fs.joinPath(F.tmp, prefix .. " " .. runId .. "-" .. counter)
end

function F.closeAll()
  while #app.sprites > 0 do app.sprites[1]:close() end
end

-- 4x3 RGB sprite, layer "Body": (0,0) red, (1,0) green, rest transparent. Saved as <name> when given.
function F.rgbSprite(name)
  local s = Sprite(4, 3)
  local cel = s.cels[1]
  local img = cel.image:clone()
  img:drawPixel(0, 0, pc.rgba(255, 0, 0, 255))
  img:drawPixel(1, 0, pc.rgba(0, 255, 0, 255))
  cel.image = img
  s.layers[1].name = "Body"
  if name then s:saveAs(app.fs.joinPath(F.tmp, name)) end
  app.sprite = s
  return s
end

-- Same args as the extension receives them: Aseprite json userdata with float numbers.
function F.decode(tbl)
  return json.decode(json.encode(tbl))
end

function F.px(sprite, x, y, layerName, frame)
  local layer = layerName and sprite.layers[1] or sprite.layers[1]
  for _, l in ipairs(sprite.layers) do if l.name == layerName then layer = l end end
  local cel = layer:cel(frame or 1)
  if not cel then return nil end
  local p = cel.position
  if x < p.x or y < p.y or x >= p.x + cel.image.width or y >= p.y + cel.image.height then return 0 end
  return cel.image:getPixel(x - p.x, y - p.y)
end

return F
