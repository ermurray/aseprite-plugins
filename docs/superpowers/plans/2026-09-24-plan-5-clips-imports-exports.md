# Aseprite Agent Chat — Plan 5: Clips, Imports and Exports

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse and output:
- Claude (and the artist) can import parts of any project sprite into the current one.
- A per-project clip library: save, insert, pin, rename, delete and clear, keeping the 20 most recently used clips, with a Clips dialog and an Edit menu command.
- Exports as PNG, per-frame PNGs, GIF, or sprite sheet + JSON, placed by the project's export rules (next to the source by default), optionally with the normal map exported as `_n`.

**Architecture:**
- **Lua:**
  - `projectconfig.lua` reads `project.json` (defaults: exports alongside, 20 clips);
  - `tools/paste.lua` builds RGBA frame images from any sprite and pastes them as a new layer, with palette handling for indexed destinations;
  - `clips.lua` is the store (`.artproject/clips/<file>.aseprite` + `clips.json`);
  - `tools/clips.lua`, `tools/importer.lua` and `tools/export.lua` hold the tool handlers.
- **Bridge:** 7 tool definitions. `export_sprite` and `delete_clip` always ask, even with auto-approve (spec §5).
- **Window:** a **Clips** header button (dialog) and a **Save Selection as Clip** command.

**Tech Stack:** Same as Plans 1–4.

**Spec:** `docs/superpowers/specs/2026-09-24-aseprite-agent-chat-design.md` §5 (`import_from_sprite`, clip tools, `export_sprite`), §8 (clips), §9 (exports).

## Global Constraints

- Everything from Plans 1–4 applies. Layer names are ASCII: `Import: <source> / <layer>` and `Clip: <name>` (the spec's `⤵` glyph can't be drawn by the UI font).
- **Verified headless:**
  - `app.command.SaveFileCopyAs{ui=false, filename=…gif, tag=, scale=}` writes GIFs, and `scale` works.
  - `app.command.ExportSpriteSheet{ui=false, type=SpriteSheetType.X, textureFilename, dataFilename, dataFormat=SpriteSheetDataFormat.JSON_HASH|JSON_ARRAY, tag=, layer=, askOverwrite=false}` writes the sheet and Aseprite JSON. Its `scale` is ignored, so scaled sheets export from a temporary resized copy (`Sprite(s)` then `:resize`).
  - `SaveFileCopyAs` to `.png` always writes a numbered sequence, so single PNG and per-frame PNG exports are rendered by us (`drawSprite`, nearest `resize`, `saveAs`).
- **Clips need a project.** The error text is exactly `Clips are kept in a project. Press Set up project first.`. The limit comes from `project.json` `clips.max` (default 20). When a save goes over the limit, the least recently used unpinned clip is evicted. If every clip is pinned and the library is full, the save is refused.
- **Export folder:** `project.json` `exports.location`:
  - `"alongside"` (the default, and also used without a project) means the source's folder;
  - `"folder"` means `<root>/<path>`, mirroring the source's sub-folder when `mirrorTree` is true.
  - An explicit `destination` wins: project-relative, or absolute.
- **File names:**
  - `png` → `<base>.png`
  - `frames` → `<base>_<frame>.png` (frame numbers are 1-based)
  - `gif` → `<base>.gif`
  - `sheet` → `<base>_sheet.png` + `<base>_sheet.json`
  - normal map exports add `_n` to the base.

## Review Focus

1. **Importing from an unopened project sprite:** it opens in the background and is closed afterwards, and the destination tab stays active, even when the import fails.
2. **Indexed destinations:** "nearest" maps every color, while "add" grows the palette and refuses to go past 256. Transparent source pixels stay transparent.
3. **The clip LRU:** evicts only unpinned clips, the most recently used survive, inserting a clip counts as using it, and a full, all-pinned library refuses to save.
4. **Export locations:** alongside versus a folder with a mirrored tree, a sprite at the project root, an explicit absolute destination, and an unsaved sprite (only allowed with an absolute destination).
5. **Multi-frame imports and clips inserted at a late frame** add frames to the destination as needed, in one undo step.

---

### Task 1: Tool definitions (bridge)

**Files:**
- Modify: `bridge/src/tools/definitions.ts`, `bridge/src/prompt.ts`
- Test: `bridge/test/definitions.test.ts`

- [ ] **Step 1: Write the failing test**

Add these names to the expected list in `definitions.test.ts`: `"delete_clip", "export_sprite", "import_from_sprite", "insert_clip", "list_clips", "pin_clip", "save_clip"`. Then add:
```ts
  it("exports and clip deletion always ask; summaries name the files' fate", () => {
    expect(toolDef("export_sprite")!.alwaysAsk).toBe(true);
    expect(toolDef("delete_clip")!.alwaysAsk).toBe(true);
    expect(toolDef("export_sprite")!.summarize!({ sprite: "knight.aseprite", format: "sheet", scale: 2, includeNormal: true })).toBe(
      "Export knight.aseprite as a sprite sheet + JSON at 2x, plus its normal map (_n), next to the sprite (or per project settings)",
    );
    expect(toolDef("export_sprite")!.summarize!({ format: "gif", destination: "../game/assets" })).toBe(
      "Export the active sprite as a GIF to ../game/assets",
    );
    expect(toolDef("import_from_sprite")!.summarize!({ from: "knight.aseprite", layer: "Head", flip: "horizontal" })).toBe(
      'Import knight.aseprite > "Head" into the active sprite as a new layer (flipped horizontally)',
    );
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npx vitest run test/definitions.test.ts`
Expected: FAIL (the tools are missing).

- [ ] **Step 3: Implement**

Append to `TOOL_DEFS`:
```ts
  {
    name: "import_from_sprite",
    kind: "edit",
    description:
      "Copy part of another sprite (any project sprite, open or not) into this one as a new layer 'Import: <source> / <layer>', with the pasted pixels selected so the artist can move them. from: source sprite; layer (default: flattened); frame or frames {from,to} (multi-frame imports line up from the current frame, adding frames if needed); region; flip; at {x,y} (default: same position); paletteMode for indexed sprites: nearest (default) or add. Reuses the artist's own art, so it is fine to use freely.",
    shape: {
      sprite: spriteArg,
      from: z.string(),
      layer: z.string().optional(),
      frame: frameArg,
      frames: frameRange.optional(),
      region: rect().optional(),
      flip: z.enum(["horizontal", "vertical"]).optional(),
      at: z.object({ x: z.number().int(), y: z.number().int() }).optional(),
      paletteMode: z.enum(["nearest", "add"]).optional(),
    },
    activity: (a) => `Imported from ${a.from}`,
    summarize: (a) =>
      `Import ${a.from}${typeof a.layer === "string" ? ` > "${a.layer}"` : ""} into ${spriteName(a)} as a new layer${a.flip ? ` (flipped ${a.flip === "horizontal" ? "horizontally" : "vertically"})` : ""}`,
  },
  {
    name: "list_clips",
    kind: "read",
    description: "List the project's saved clips (name, tags, size, frames, pinned, last used). filter matches name or tags.",
    shape: { filter: z.string().optional() },
    activity: () => "Listed the project's clips",
  },
  {
    name: "save_clip",
    kind: "edit",
    description: "Save part of a sprite as a reusable clip in the project (selection, or region, or the whole canvas; one layer or flattened; one frame or a range). The library keeps the most recently used clips (default 20); pinned clips are never evicted.",
    shape: {
      sprite: spriteArg,
      layer: z.string().optional(),
      region: rect().optional(),
      frame: frameArg,
      frames: frameRange.optional(),
      name: z.string().regex(/^[A-Za-z0-9 _-]{1,40}$/),
      tags: z.array(z.string().max(20)).max(8).optional(),
      replace: z.boolean().optional(),
    },
    activity: (a) => `Saved the clip "${a.name}"`,
    summarize: (a) => `${a.replace ? "Replace" : "Save"} clip "${a.name}" from ${spriteName(a)}${typeof a.layer === "string" ? ` > "${a.layer}"` : ""}`,
  },
  {
    name: "insert_clip",
    kind: "edit",
    description: "Insert a saved clip into a sprite as a new layer 'Clip: <name>' with its pixels selected; at {x,y} (default top-left of the selection or 0,0); flip; paletteMode for indexed sprites.",
    shape: {
      sprite: spriteArg,
      name: z.string(),
      at: z.object({ x: z.number().int(), y: z.number().int() }).optional(),
      flip: z.enum(["horizontal", "vertical"]).optional(),
      paletteMode: z.enum(["nearest", "add"]).optional(),
    },
    activity: (a) => `Inserted the clip "${a.name}"`,
    summarize: (a) => `Insert clip "${a.name}" into ${spriteName(a)} as a new layer`,
  },
  {
    name: "delete_clip",
    kind: "edit",
    alwaysAsk: true,
    description: "Delete a saved clip from the project library.",
    shape: { name: z.string() },
    activity: (a) => `Deleted the clip "${a.name}"`,
    summarize: (a) => `Delete clip "${a.name}" from the project library`,
  },
  {
    name: "pin_clip",
    kind: "edit",
    description: "Pin (keep forever) or unpin a clip.",
    shape: { name: z.string(), pinned: z.boolean() },
    activity: (a) => `${a.pinned ? "Pinned" : "Unpinned"} the clip "${a.name}"`,
    summarize: (a) => `${a.pinned ? "Pin" : "Unpin"} clip "${a.name}"`,
  },
  {
    name: "export_sprite",
    kind: "edit",
    alwaysAsk: true,
    description:
      "Export for games or sharing: png (one frame), frames (one PNG per frame), gif, or sheet (sprite sheet + Aseprite JSON, which Godot/Unity/most engines can import). Optional tag, layer, scale 1-10, sheetType, data hash/array/none, includeNormal (also export the <name>_normal companion as _n). Goes where the project's export settings say (next to the sprite by default) unless destination (a folder) is given.",
    shape: {
      sprite: spriteArg,
      format: z.enum(["png", "frames", "gif", "sheet"]),
      frame: frameArg,
      tag: z.string().optional(),
      layer: z.string().optional(),
      scale: z.number().int().min(1).max(10).optional(),
      sheetType: z.enum(["horizontal", "vertical", "rows", "columns", "packed"]).optional(),
      data: z.enum(["hash", "array", "none"]).optional(),
      includeNormal: z.boolean().optional(),
      destination: z.string().min(1).optional(),
      name: z.string().regex(/^[A-Za-z0-9 _.-]{1,60}$/).optional(),
    },
    activity: (a) => `Exported ${spriteName(a)} (${a.format})`,
    summarize: (a) => {
      const what = { png: "a PNG", frames: "one PNG per frame", gif: "a GIF", sheet: "a sprite sheet + JSON" }[String(a.format)];
      const scale = typeof a.scale === "number" && a.scale > 1 ? ` at ${a.scale}x` : "";
      const tag = typeof a.tag === "string" ? ` (tag "${a.tag}")` : "";
      const normal = a.includeNormal ? ", plus its normal map (_n)" : "";
      const dest = typeof a.destination === "string" ? `to ${a.destination}` : "next to the sprite (or per project settings)";
      return `Export ${spriteName(a)} as ${what}${tag}${scale}${normal}${a.includeNormal ? ", " : " "}${dest}`;
    },
  },
```

In `prompt.ts`, add this line to the "Effects, tools, extensions and scripts" section:
```
- Reuse and output: import_from_sprite copies parts of any project sprite into this one as a new layer; the clip library (save_clip, insert_clip, list_clips, pin_clip, delete_clip) keeps reusable pieces per project; export_sprite writes PNG, per-frame PNGs, GIF or sprite sheet + JSON where the project's export settings say (next to the sprite by default), optionally with the normal map as _n.
```

- [ ] **Step 4: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bridge && git commit -m "feat(bridge): import, clip library and export tool definitions"
```

---

### Task 2: Project config and export folders (Lua)

**Files:**
- Create: `extension/agent/projectconfig.lua`
- Test: `tests/lua/test_projectconfig.lua` (add it to the suite list)

**Interfaces:** `projectconfig.read(root|nil) -> {exports = {location, path, mirrorTree}, clips = {max}}`, `projectconfig.exportDir(root|nil, spritePath, cfg) -> dir`, `projectconfig.resolveDestination(root|nil, spritePath, destination) -> dir`

- [ ] **Step 1: Write the failing test**

`tests/lua/test_projectconfig.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local project = require("agent.project")
local cfg = require("agent.projectconfig")

local root = F.unique("cfg proj")
app.fs.makeAllDirectories(app.fs.joinPath(root, "chars"))
project.create(root, {})

local function writeConfig(text)
  local f = io.open(app.fs.joinPath(root, ".artproject", "project.json"), "w"); f:write(text); f:close()
end

T.test("defaults without a project or with a broken project.json", function()
  local c = cfg.read(nil)
  T.eq(c.exports.location, "alongside")
  T.eq(c.clips.max, 20)
  writeConfig("{broken")
  T.eq(cfg.read(root).clips.max, 20)
end)

T.test("reads exports and clips settings", function()
  writeConfig('{"version":1,"exports":{"location":"folder","path":"out","mirrorTree":true},"clips":{"max":5}}')
  local c = cfg.read(root)
  T.eq(c.exports.location, "folder")
  T.eq(c.clips.max, 5)
end)

T.test("export folders: alongside, mirrored folder, root-level sprite, destination override", function()
  local sprite = app.fs.joinPath(root, "chars", "knight.aseprite")
  T.eq(cfg.exportDir(root, sprite, cfg.DEFAULTS), app.fs.joinPath(root, "chars"))
  local folder = { exports = { location = "folder", path = "out", mirrorTree = true }, clips = { max = 20 } }
  T.eq(cfg.exportDir(root, sprite, folder), app.fs.normalizePath(app.fs.joinPath(root, "out", "chars")))
  T.eq(cfg.exportDir(root, app.fs.joinPath(root, "hero.aseprite"), folder), app.fs.normalizePath(app.fs.joinPath(root, "out")))
  folder.exports.mirrorTree = false
  T.eq(cfg.exportDir(root, sprite, folder), app.fs.normalizePath(app.fs.joinPath(root, "out")))
  T.eq(cfg.resolveDestination(root, sprite, "build/art"), app.fs.normalizePath(app.fs.joinPath(root, "build", "art")))
  T.eq(cfg.resolveDestination(nil, sprite, "sub"), app.fs.normalizePath(app.fs.joinPath(root, "chars", "sub")))
  T.eq(cfg.resolveDestination(root, sprite, "/abs/place"), "/abs/place")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh projectconfig`
Expected: `module 'agent.projectconfig' not found`.

- [ ] **Step 3: Implement**

`extension/agent/projectconfig.lua`:
```lua
local project = require("agent.project")

local M = {}
M.DEFAULTS = { exports = { location = "alongside", path = "exports", mirrorTree = true }, clips = { max = 20 } }

local function copyDefaults()
  return {
    exports = { location = M.DEFAULTS.exports.location, path = M.DEFAULTS.exports.path, mirrorTree = M.DEFAULTS.exports.mirrorTree },
    clips = { max = M.DEFAULTS.clips.max },
  }
end

function M.read(root)
  local c = copyDefaults()
  if not root then return c end
  local f = io.open(app.fs.joinPath(root, project.DIR, "project.json"), "r")
  if not f then return c end
  local ok, data = pcall(json.decode, f:read("a"))
  f:close()
  if not ok or not data then return c end
  local e = data.exports
  if e then
    if e.location == "alongside" or e.location == "folder" then c.exports.location = tostring(e.location) end
    if type(e.path) == "string" and e.path ~= "" then c.exports.path = e.path end
    if e.mirrorTree ~= nil then c.exports.mirrorTree = e.mirrorTree == true end
  end
  local cl = data.clips
  if cl and tonumber(cl.max) and tonumber(cl.max) >= 1 then c.clips.max = math.floor(tonumber(cl.max)) end
  return c
end

function M.exportDir(root, spritePath, c)
  local srcDir = app.fs.filePath(spritePath)
  if not root or c.exports.location ~= "folder" then return srcDir end
  local base = project.absolute(root, c.exports.path)
  if not c.exports.mirrorTree then return base end
  local rel = project.relative(root, spritePath)
  local sub = rel and rel:match("^(.*)/[^/]*$")
  return sub and project.absolute(base, sub) or base
end

function M.resolveDestination(root, spritePath, destination)
  if destination:sub(1, 1) == "/" or destination:match("^%a:[/\\]") then return destination end
  return project.absolute(root or app.fs.filePath(spritePath), destination)
end

return M
```

- [ ] **Step 4: Run the tests, then commit**

Run: `scripts/test-lua.sh`. Expected: all pass.
```bash
git add extension/agent/projectconfig.lua tests/lua && git commit -m "feat(extension): project.json settings and export folder rules"
```

---

### Task 3: Paste helper and import_from_sprite (Lua)

**Files:**
- Create: `extension/agent/tools/paste.lua`, `extension/agent/tools/importer.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_import.lua` (add it to the suite list)

**Interfaces:**
- `paste.frameImages(sprite, layerName|nil, frameNumbers, region|nil, flip|nil) -> {{image = Image(RGB), x, y}...}`
- `paste.pasteLayer(dest, name, frameImages, startFrame, at|nil, paletteMode) -> layer, info{colorsAdded}` (call it inside a transaction)
- `paste.uniqueLayerName(sprite, name)`
- handler `import_from_sprite`

- [ ] **Step 1: Write the failing test**

`tests/lua/test_import.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
local root = F.unique("import proj")
app.fs.makeAllDirectories(root)
project.create(root, {})

local function source()
  local s = Sprite(4, 3)
  local img = s.cels[1].image:clone()
  img:drawPixel(0, 0, pc.rgba(255, 0, 0, 255))
  img:drawPixel(1, 0, pc.rgba(0, 255, 0, 255))
  s.cels[1].image = img
  s.layers[1].name = "Head"
  s:newFrame(1)
  s:saveAs(project.absolute(root, "knight.aseprite"))
  s:close()
end

T.test("imports a layer region from an unopened project sprite, flipped, as a selected new layer", function()
  F.closeAll()
  source()
  sprites.projectRoot = root
  local dest = Sprite(6, 6)
  dest:saveAs(project.absolute(root, "dest.aseprite"))
  app.sprite = dest
  local r = call("import_from_sprite", { from = "knight.aseprite", layer = "Head", region = { x = 0, y = 0, w = 2, h = 1 }, flip = "horizontal", at = { x = 3, y = 2 } })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.layer, "Import: knight.aseprite / Head")
  T.eq(#app.sprites, 1, "source closed again")
  T.eq(app.sprite == dest, true)
  T.eq(F.px(dest, 3, 2, "Import: knight.aseprite / Head"), pc.rgba(0, 255, 0, 255), "flipped: green first")
  T.eq(F.px(dest, 4, 2, "Import: knight.aseprite / Head"), pc.rgba(255, 0, 0, 255))
  T.deepEq({ dest.selection.bounds.x, dest.selection.bounds.y, dest.selection.bounds.width }, { 3, 2, 2 })
  app.undo()
  T.eq(#dest.layers, 1, "one undo removes the import")
  sprites.projectRoot = nil
end)

T.test("multi-frame imports add frames to the destination", function()
  F.closeAll()
  source()
  sprites.projectRoot = root
  local dest = Sprite(4, 3)
  dest:saveAs(project.absolute(root, "dest2.aseprite"))
  app.sprite = dest
  local r = call("import_from_sprite", { from = "knight.aseprite", frames = { from = 1, to = 2 } })
  T.eq(r.ok, true, r.error)
  T.eq(#dest.frames, 2)
  T.eq(r.data.frames, 2)
  sprites.projectRoot = nil
end)

T.test("indexed destinations map to the nearest color, or add colors, and keep transparency", function()
  F.closeAll()
  source()
  sprites.projectRoot = root
  local dest = Sprite(4, 3, ColorMode.INDEXED)
  local pal = dest.palettes[1]
  pal:resize(3)
  pal:setColor(1, Color{ r = 250, g = 0, b = 0 })
  pal:setColor(2, Color{ r = 0, g = 0, b = 250 })
  app.sprite = dest
  local near = call("import_from_sprite", { from = "knight.aseprite", layer = "Head" })
  T.eq(near.ok, true, near.error)
  local cel = dest.layers[2]:cel(1)
  T.eq(cel.image:getPixel(0 - cel.position.x, 0 - cel.position.y), 1)
  T.eq(cel.image:getPixel(3 - cel.position.x, 2 - cel.position.y), dest.transparentColor)
  local add = call("import_from_sprite", { from = "knight.aseprite", layer = "Head", paletteMode = "add" })
  T.eq(add.ok, true, add.error)
  T.eq(add.data.colorsAdded, 2)
  sprites.projectRoot = nil
end)

T.test("a missing source is a plain error and leaves no stray tab", function()
  F.closeAll()
  local dest = Sprite(2, 2)
  app.sprite = dest
  T.eq(call("import_from_sprite", { from = "ghost.aseprite" }).ok, false)
  T.eq(#app.sprites, 1)
end)

F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh test_import`
Expected: `Unknown tool: import_from_sprite`.

- [ ] **Step 3: Implement paste**

`extension/agent/tools/paste.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local fxm = require("agent.fx.math")

local M = {}
local pc = app.pixelColor

-- An RGB image of one frame of `sprite` (a layer, or flattened), whatever its color mode.
local function rgbaFrame(sprite, layerName, frame)
  local out = Image(sprite.width, sprite.height, ColorMode.RGB)
  out:clear(0)
  if not layerName then
    out:drawSprite(sprite, frame)
    return out
  end
  local cel = sprites.layer(sprite, layerName):cel(frame)
  if not cel then return out end
  local img, p, pal = cel.image, cel.position, sprite.palettes[1]
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local v = img:getPixel(x, y)
      local r, g, b, a
      if sprite.colorMode == ColorMode.INDEXED and v == sprite.transparentColor then
        a = 0
      else
        r, g, b, a = color.rgbaOf(v, sprite.colorMode, pal)
      end
      local sx, sy = x + p.x, y + p.y
      if a > 0 and sx >= 0 and sy >= 0 and sx < sprite.width and sy < sprite.height then
        out:drawPixel(sx, sy, pc.rgba(r, g, b, a))
      end
    end
  end
  return out
end

function M.frameImages(sprite, layerName, frameNumbers, region, flip)
  local r = region or { x = 0, y = 0, w = sprite.width, h = sprite.height }
  local out = {}
  for _, n in ipairs(frameNumbers) do
    local full = rgbaFrame(sprite, layerName, sprite.frames[n])
    local img = Image(r.w, r.h, ColorMode.RGB)
    img:clear(0)
    for y = 0, r.h - 1 do
      for x = 0, r.w - 1 do
        local sx, sy = r.x + x, r.y + y
        if sx >= 0 and sy >= 0 and sx < sprite.width and sy < sprite.height then
          local dx = flip == "horizontal" and (r.w - 1 - x) or x
          local dy = flip == "vertical" and (r.h - 1 - y) or y
          img:drawPixel(dx, dy, full:getPixel(sx, sy))
        end
      end
    end
    out[#out + 1] = { image = img, x = r.x, y = r.y }
  end
  return out
end

function M.uniqueLayerName(sprite, name)
  local taken = {}
  local function walk(layers)
    for _, l in ipairs(layers) do
      taken[l.name] = true
      if l.isGroup then walk(l.layers) end
    end
  end
  walk(sprite.layers)
  if not taken[name] then return name end
  local i = 2
  while taken[name .. " " .. i] do i = i + 1 end
  return name .. " " .. i
end

-- Converts an RGB image to `dest`'s color mode; "add" grows an indexed palette with missing colors.
local function convert(dest, img, paletteMode, added)
  if dest.colorMode == ColorMode.RGB then return img end
  local out = Image(img.width, img.height, dest.colorMode)
  if dest.colorMode == ColorMode.GRAYSCALE then
    out:clear(0)
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local v = img:getPixel(x, y)
        local a = pc.rgbaA(v)
        if a > 0 then
          out:drawPixel(x, y, pc.graya(math.floor(fxm.luminance(pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v)) + 0.5), a))
        end
      end
    end
    return out
  end
  local pal = dest.palettes[1]
  out:clear(dest.transparentColor)
  local index = {}
  local function paletteList()
    local list = {}
    for i = 0, #pal - 1 do
      if i ~= dest.transparentColor then
        local c = pal:getColor(i)
        list[#list + 1] = { r = c.red, g = c.green, b = c.blue, i = i }
        index[c.red * 65536 + c.green * 256 + c.blue] = index[c.red * 65536 + c.green * 256 + c.blue] or i
      end
    end
    return list
  end
  local list = paletteList()
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local v = img:getPixel(x, y)
      if pc.rgbaA(v) > 0 then
        local r, g, b = pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v)
        local key = r * 65536 + g * 256 + b
        local i = index[key]
        if not i and paletteMode == "add" then
          if #pal >= 256 then error("The palette would exceed 256 colors (indexed mode). Use paletteMode = nearest.", 0) end
          pal:resize(#pal + 1)
          i = #pal - 1
          pal:setColor(i, Color{ r = r, g = g, b = b })
          index[key] = i
          list[#list + 1] = { r = r, g = g, b = b, i = i }
          added.count = added.count + 1
        end
        if not i then i = list[fxm.nearest(r, g, b, list)].i end
        out:drawPixel(x, y, i)
      end
    end
  end
  return out
end

function M.pasteLayer(dest, name, frames, startFrame, at, paletteMode)
  local layer = dest:newLayer()
  layer.name = M.uniqueLayerName(dest, name)
  local added = { count = 0 }
  local first
  for i, fr in ipairs(frames) do
    local n = startFrame + i - 1
    while #dest.frames < n do dest:newEmptyFrame(#dest.frames + 1) end
    local x, y = at and at.x or fr.x, at and at.y or fr.y
    dest:newCel(layer, n, convert(dest, fr.image, paletteMode or "nearest", added), Point(x, y))
    first = first or Rectangle(x, y, fr.image.width, fr.image.height)
  end
  if first then dest.selection = Selection(first) end
  return layer, { colorsAdded = added.count }
end

return M
```

- [ ] **Step 4: Implement the importer**

`extension/agent/tools/importer.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local paste = require("agent.tools.paste")

local M = {}

-- Frame numbers in `s` for args.frame / args.frames (default: frame 1).
local function frameNumbers(s, args)
  if args.frames then
    local a, b = edit.int(args.frames.from), edit.int(args.frames.to)
    sprites.frame(s, a)
    sprites.frame(s, b)
    local out = {}
    for n = a, b do out[#out + 1] = n end
    return out
  end
  return { sprites.frame(s, args.frame or 1).frameNumber }
end

local function region(args)
  if not args.region then return nil end
  return { x = edit.int(args.region.x), y = edit.int(args.region.y), w = edit.int(args.region.w), h = edit.int(args.region.h) }
end

function M.import_from_sprite(args)
  local dest = edit.editableSprite(args.sprite)
  local startFrame = (app.sprite == dest and app.frame) and app.frame.frameNumber or 1
  local handle = sprites.openIfNeeded(args.from, "read")
  local ok, result = pcall(function()
    local src = sprites.resolve(args.from)
    if args.layer then sprites.layer(src, args.layer) end
    local frames = paste.frameImages(src, args.layer, frameNumbers(src, args), region(args), args.flip)
    local name = "Import: " .. sprites.name(src) .. " / " .. (args.layer or "all layers")
    local at = args.at and { x = edit.int(args.at.x), y = edit.int(args.at.y) } or nil
    local layer, info
    edit.transaction(dest, "import", function()
      layer, info = paste.pasteLayer(dest, name, frames, startFrame, at, args.paletteMode)
    end)
    return { sprite = sprites.name(dest), layer = layer.name, frames = #frames, colorsAdded = info.colorsAdded }
  end)
  if handle and handle.close then handle.close() end
  if app.sprite ~= dest then pcall(function() app.sprite = dest end) end
  if not ok then error(result, 0) end
  return result
end

return M
```
Register `import_from_sprite = importer.import_from_sprite` as `"edit"` in `init.lua`.

> The registry's `openIfNeeded` only handles `args.sprite` (the destination); the importer opens `args.from` itself. For the "missing source" test, `sprites.resolve("ghost.aseprite")` raises the usual "not open" error.

- [ ] **Step 5: Run the tests, then commit**

Run: `scripts/test-lua.sh`. Expected: all pass.
```bash
git add extension/agent/tools/paste.lua extension/agent/tools/importer.lua extension/agent/tools/init.lua tests/lua
git commit -m "feat(extension): import_from_sprite with flips, frames and indexed palette handling"
```

---

### Task 4: The clip library (Lua)

**Files:**
- Create: `extension/agent/clips.lua` (store), `extension/agent/tools/clips.lua` (handlers)
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_clips.lua` (add it to the suite list)

**Interfaces:**
- **Store:**
  - `clips.dir(root)`, `clips.list(root, filter) -> entries` (most recently used first)
  - `clips.save(root, sprite, opts{layer, region, frames, name, tags, replace}) -> entry, evictedName|nil`
  - `clips.frames(root, name) -> frameImages` (marks the clip as used)
  - `clips.delete`, `clips.pin`, `clips.rename`, `clips.clear(root, includePinned) -> count`
  - `clips.label(entry) -> string` (for the UI)
- **Handlers:** `list_clips` (read); `save_clip`, `insert_clip`, `delete_clip`, `pin_clip` (edit)

- [ ] **Step 1: Write the failing test**

`tests/lua/test_clips.lua`:
```lua
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
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh test_clips`
Expected: failures (`Unknown tool: save_clip`).

- [ ] **Step 3: Implement the store**

`extension/agent/clips.lua`:
```lua
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

local function fileFor(name) return (name:gsub("[^%w_%-]", "_")) .. ".aseprite" end

function M.save(root, sprite, opts)
  local list = load(root)
  local max = projectconfig.read(root).clips.max
  local existing = find(list, opts.name)
  if existing and not opts.replace then
    error("A clip called '" .. opts.name .. "' already exists. Save with replace = true to overwrite it.", 0)
  end
  local evicted
  if not existing and #list >= max then
    local victim
    for _, c in ipairs(list) do
      if not c.pinned and (not victim or c.lastUsedAt < victim.lastUsedAt) then victim = c end
    end
    if not victim then
      error(("All %d clips are pinned and the library is full (max %d). Unpin or delete one first."):format(#list, max), 0)
    end
    M.delete(root, victim.name)
    list = load(root)
    evicted = victim.name
  end
  local frames = paste.frameImages(sprite, opts.layer, opts.frames, opts.region, nil)
  local w, h = frames[1].image.width, frames[1].image.height
  local prev = app.sprite
  local clip = Sprite(w, h, ColorMode.RGB)
  for i = 2, #frames do clip:newEmptyFrame(i) end
  for i, fr in ipairs(frames) do
    local cel = clip.layers[1]:cel(i)
    if cel then cel.image = fr.image else clip:newCel(clip.layers[1], i, fr.image, Point(0, 0)) end
  end
  clip.layers[1].name = "Clip"
  app.fs.makeAllDirectories(M.dir(root))
  local file = fileFor(opts.name)
  clip:saveAs(app.fs.joinPath(M.dir(root), file))
  clip:close()
  if prev then pcall(function() app.sprite = prev end) end
  local t = now()
  local entry = {
    name = opts.name, file = file, tags = opts.tags or {}, source = sprites.name(sprite),
    width = w, height = h, frames = #frames, createdAt = t, lastUsedAt = t, pinned = existing and existing.pinned or false,
  }
  if existing then
    local _, i = find(list, opts.name)
    list[i] = entry
  else
    list[#list + 1] = entry
  end
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
```

- [ ] **Step 4: Implement the handlers**

`extension/agent/tools/clips.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local paste = require("agent.tools.paste")
local clips = require("agent.clips")

local M = {}

local function framesArg(s, args)
  if args.frames then
    local out = {}
    for n = sprites.frame(s, args.frames.from).frameNumber, sprites.frame(s, args.frames.to).frameNumber do out[#out + 1] = n end
    return out
  end
  return { sprites.frame(s, args.frame).frameNumber }
end

function M.list_clips(args)
  local out = {}
  for _, c in ipairs(clips.list(sprites.projectRoot, args.filter)) do
    out[#out + 1] = { name = c.name, tags = c.tags, width = c.width, height = c.height, frames = c.frames, pinned = c.pinned, source = c.source }
  end
  return { clips = out }
end

function M.save_clip(args)
  local root = sprites.projectRoot
  clips.dir(root)
  local s = sprites.resolve(args.sprite)
  if args.layer then sprites.layer(s, args.layer) end
  local region
  if args.region then
    region = { x = edit.int(args.region.x), y = edit.int(args.region.y), w = edit.int(args.region.w), h = edit.int(args.region.h) }
  elseif not s.selection.isEmpty then
    local b = s.selection.bounds
    region = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  local tags = {}
  if args.tags then for i = 1, #args.tags do tags[i] = tostring(args.tags[i]) end end
  local entry, evicted = clips.save(root, s, {
    name = tostring(args.name), tags = tags, layer = args.layer, region = region,
    frames = framesArg(s, args), replace = args.replace == true,
  })
  return { name = entry.name, width = entry.width, height = entry.height, frames = entry.frames, evicted = evicted }
end

function M.insert_clip(args)
  local root = sprites.projectRoot
  clips.dir(root)
  local dest = edit.editableSprite(args.sprite)
  local frames, c = clips.frames(root, tostring(args.name))
  if args.flip then
    for _, fr in ipairs(frames) do
      local src, img = fr.image, Image(fr.image.spec)
      img:clear(0)
      for y = 0, src.height - 1 do
        for x = 0, src.width - 1 do
          local dx = args.flip == "horizontal" and (src.width - 1 - x) or x
          local dy = args.flip == "vertical" and (src.height - 1 - y) or y
          img:drawPixel(dx, dy, src:getPixel(x, y))
        end
      end
      fr.image = img
    end
  end
  local at
  if args.at then at = { x = edit.int(args.at.x), y = edit.int(args.at.y) }
  elseif not dest.selection.isEmpty then at = { x = dest.selection.bounds.x, y = dest.selection.bounds.y }
  else at = { x = 0, y = 0 } end
  local startFrame = (app.sprite == dest and app.frame) and app.frame.frameNumber or 1
  local layer, info
  edit.transaction(dest, "insert clip " .. c.name, function()
    layer, info = paste.pasteLayer(dest, "Clip: " .. c.name, frames, startFrame, at, args.paletteMode)
  end)
  return { sprite = sprites.name(dest), layer = layer.name, frames = #frames, colorsAdded = info.colorsAdded }
end

function M.delete_clip(args)
  clips.delete(sprites.projectRoot, tostring(args.name))
  return { deleted = args.name }
end

function M.pin_clip(args)
  clips.pin(sprites.projectRoot, tostring(args.name), args.pinned == true)
  return { name = args.name, pinned = args.pinned == true }
end

return M
```
Register `list_clips` as `"read"`; `save_clip`, `insert_clip`, `delete_clip` and `pin_clip` as `"edit"`. (`save_clip` doesn't change the sprite, but writes files, so it stays an edit with a card.)

- [ ] **Step 5: Run the tests, then commit**

Run: `scripts/test-lua.sh`. Expected: all pass.
```bash
git add extension/agent/clips.lua extension/agent/tools/clips.lua extension/agent/tools/init.lua tests/lua
git commit -m "feat(extension): per-project clip library with LRU, pins, insert and tools"
```

---

### Task 5: Exports (Lua)

**Files:**
- Create: `extension/agent/tools/export.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_export.lua` (add it to the suite list)

**Interfaces:** handler `export_sprite -> {files = {paths...}, folder}`. Paths are project-relative inside a project, and absolute otherwise.

- [ ] **Step 1: Write the failing test**

`tests/lua/test_export.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
local root = F.unique("export proj")
app.fs.makeAllDirectories(app.fs.joinPath(root, "chars"))
project.create(root, {})

local function knight()
  F.closeAll()
  sprites.projectRoot = root
  local s = Sprite(4, 4)
  local img = s.cels[1].image:clone(); img:clear(pc.rgba(255, 0, 0, 255)); s.cels[1].image = img
  s:newFrame(1)
  s:newTag(1, 2).name = "idle"
  s:saveAs(project.absolute(root, "chars/knight.aseprite"))
  app.sprite = s
  return s
end

local function exists(rel) return app.fs.isFile(project.absolute(root, rel)) end
local function size(rel) local i = Image{ fromFile = project.absolute(root, rel) } return i.width, i.height end

T.test("png next to the sprite, scaled", function()
  knight()
  local r = call("export_sprite", { format = "png", scale = 3 })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.files, { "chars/knight.png" })
  T.deepEq({ size("chars/knight.png") }, { 12, 12 })
end)

T.test("frames as numbered PNGs, and a tag as a GIF", function()
  knight()
  T.deepEq(call("export_sprite", { format = "frames" }).data.files, { "chars/knight_1.png", "chars/knight_2.png" })
  T.deepEq(call("export_sprite", { format = "gif", tag = "idle", name = "knight_idle" }).data.files, { "chars/knight_idle.gif" })
  T.eq(exists("chars/knight_idle.gif"), true)
end)

T.test("sprite sheet + JSON, scaled from a temporary copy", function()
  local s = knight()
  local r = call("export_sprite", { format = "sheet", scale = 2, data = "array" })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.files, { "chars/knight_sheet.png", "chars/knight_sheet.json" })
  T.deepEq({ size("chars/knight_sheet.png") }, { 16, 8 })
  T.eq(#app.sprites, 1, "the temporary copy is closed")
  T.eq(app.sprite == s, true)
end)

T.test("project folder rules and destination overrides", function()
  knight()
  local f = io.open(app.fs.joinPath(root, ".artproject", "project.json"), "w")
  f:write('{"version":1,"exports":{"location":"folder","path":"out","mirrorTree":true}}'); f:close()
  T.deepEq(call("export_sprite", { format = "png" }).data.files, { "out/chars/knight.png" })
  T.deepEq(call("export_sprite", { format = "png", destination = "build" }).data.files, { "build/knight.png" })
  f = io.open(app.fs.joinPath(root, ".artproject", "project.json"), "w"); f:write('{"version":1}'); f:close()
end)

T.test("includeNormal also exports the normal companion as _n", function()
  knight()
  T.eq(call("make_normal_map", { layer = "Layer 1", saveHeight = false }).ok, true)
  local r = call("export_sprite", { format = "png", includeNormal = true })
  T.eq(r.ok, true, r.error)
  T.deepEq(r.data.files, { "chars/knight.png", "chars/knight_n.png" })
  T.eq(call("export_sprite", { format = "gif", layer = "Layer 1" }).error, "GIF export uses the whole sprite; drop layer or export frames/png instead.")
end)

T.test("unsaved sprites need an absolute destination", function()
  F.closeAll()
  sprites.projectRoot = nil
  app.sprite = Sprite(2, 2)
  T.eq(call("export_sprite", { format = "png" }).error, "Save the sprite first, or give an absolute destination folder.")
  local dir = F.unique("abs export")
  T.eq(call("export_sprite", { format = "png", destination = dir, name = "loose" }).ok, true)
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "loose.png")), true)
end)

sprites.projectRoot = nil
F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh test_export`
Expected: `Unknown tool: export_sprite`.

- [ ] **Step 3: Implement**

`extension/agent/tools/export.lua`:
```lua
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
```
Register `export_sprite = export.export_sprite` as `"edit"`.

> For `includeNormal` with `format = "png"`, the companion's own active frame isn't meaningful. `exportOne` falls back to frame 1 for a sprite that isn't active, and uses `args.frame` when given.

- [ ] **Step 4: Run the tests, then commit**

Run: `scripts/test-lua.sh`. Expected: all pass. Also update the Lua handler-coverage list with `"import_from_sprite", "list_clips", "save_clip", "insert_clip", "delete_clip", "pin_clip", "export_sprite"`.
```bash
git add extension/agent/tools/export.lua extension/agent/tools/init.lua tests/lua
git commit -m "feat(extension): exports (png, frames, gif, sheet+json) with project folder rules and _n normals"
```

---

### Task 6: Clips in the window and the Edit menu

**Files:**
- Modify: `extension/agent/chat_window.lua`, `extension/plugin.lua`
- Test: `tests/lua/test_chat_window.lua` (add a case)

**Interfaces:**
- `ChatWindow:showClips()` shows a dialog: a filter, a combobox of `clips.label` entries, a preview canvas, and the buttons **Insert**, **Rename…**, **Pin/Unpin**, **Delete**, **Clear all…** and **Close**.
- `ChatWindow.saveSelectionAsClip()` is a static function that asks for a name and tags, then saves.
- The **Clips** header button and a plugin command **Save Selection as Clip** (`group = "edit_insert"`).

- [ ] **Step 1: Write the failing test**

Add to `tests/lua/test_chat_window.lua`:
```lua
T.test("the Clips button explains that clips need a project", function()
  local tips = {}
  local real = ChatWindow.showTip
  ChatWindow.showTip = function(t) tips[#tips + 1] = t end
  local w = stubbed({})
  w.projectRoot = nil
  w:showClips()
  T.eq(tips[1], "Clips are kept in a project. Press Set up project first.")
  ChatWindow.showTip = real
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh chat_window`
Expected: failure (`showClips` is nil).

- [ ] **Step 3: Implement**

In `chat_window.lua`:
- Add `local clips = require("agent.clips")` and `local paste = require("agent.tools.paste")`.
- In `build()`'s header row, after History:
```lua
  dlg:button{ id = "clips", text = "Clips", onclick = function() self:showClips() end }
```
- Add:
```lua
function ChatWindow:showClips()
  local root = self.projectRoot
  if not root then
    ChatWindow.showTip("Clips are kept in a project. Press Set up project first.")
    return
  end
  local filter = ""
  while true do
    local list = clips.list(root, filter)
    local labels, byLabel = {}, {}
    for _, c in ipairs(list) do
      local l = clips.label(c)
      labels[#labels + 1] = l
      byLabel[l] = c
    end
    local d = Dialog{ title = "Clips in " .. self.projectName }
    d:entry{ id = "filter", label = "Filter", text = filter }
    d:button{ id = "apply", text = "Filter" }
    d:newrow()
    if #labels == 0 then
      d:label{ text = "No clips yet. Select an area and use Edit > Save Selection as Clip." }
    else
      d:combobox{ id = "clip", options = labels, option = labels[1], onchange = function() d:repaint() end }
      d:canvas{
        id = "preview", width = 160, height = 120,
        onpaint = function(ev)
          local c = byLabel[d.data.clip]
          if not c then return end
          local ok, frames = pcall(function()
            local spr = Sprite{ fromFile = app.fs.joinPath(clips.dir(root), c.file) }
            local img = Image(spr.cels[1].image)
            spr:close()
            return img
          end)
          if ok and frames then
            local scale = math.max(1, math.floor(math.min(160 / frames.width, 120 / frames.height)))
            ev.context:drawImage(frames, Rectangle(0, 0, frames.width, frames.height), Rectangle(0, 0, frames.width * scale, frames.height * scale))
          end
        end,
      }
      d:newrow()
      d:button{ id = "insert", text = "Insert" }
      d:button{ id = "rename", text = "Rename..." }
      d:button{ id = "pin", text = "Pin / Unpin" }
      d:button{ id = "delete", text = "Delete" }
      d:button{ id = "clear", text = "Clear all..." }
    end
    d:button{ id = "close", text = "Close" }
    d:show()
    local data = d.data
    local c = data.clip and byLabel[data.clip]
    if data.apply then
      filter = data.filter or ""
    elseif data.insert and c then
      local r = require("agent.tools").dispatch("insert_clip", { name = c.name })
      ChatWindow.showTip(r.ok and ("Inserted clip " .. c.name) or tostring(r.error))
      self:repaint()
      return
    elseif data.rename and c then
      local r = Dialog{ title = "Rename clip" }
      r:entry{ id = "name", label = "New name", text = c.name }
      r:button{ id = "ok", text = "Rename", focus = true }
      r:button{ id = "cancel", text = "Cancel" }
      r:show()
      if r.data.ok then
        local ok, err = pcall(clips.rename, root, c.name, r.data.name)
        if not ok then ChatWindow.showTip(tostring(err)) end
      end
    elseif data.pin and c then
      clips.pin(root, c.name, not c.pinned)
    elseif data.delete and c then
      clips.delete(root, c.name)
    elseif data.clear then
      local answer = app.alert{ title = "Clear clips", text = "Delete every clip in this project?", buttons = { "Unpinned only", "Including pinned", "Cancel" } }
      if answer == 1 then clips.clear(root, false) elseif answer == 2 then clips.clear(root, true) end
    else
      return
    end
  end
end

-- Edit > Save Selection as Clip (works without the chat window open).
function ChatWindow.saveSelectionAsClip()
  local s = app.sprite
  local root = s and project.findRoot(s.filename)
  if not root then
    ChatWindow.showTip("Clips are kept in a project. Press Set up project first.")
    return
  end
  local d = Dialog{ title = "Save Selection as Clip" }
  d:entry{ id = "name", label = "Name", text = "" }
  d:entry{ id = "tags", label = "Tags (comma separated)", text = "" }
  d:check{ id = "layerOnly", text = "Only the active layer", selected = false }
  d:button{ id = "ok", text = "Save", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()
  if not d.data.ok then return end
  local tags = {}
  for t in (d.data.tags or ""):gmatch("[^,]+") do tags[#tags + 1] = t:match("^%s*(.-)%s*$") end
  local region
  if not s.selection.isEmpty then
    local b = s.selection.bounds
    region = { x = b.x, y = b.y, w = b.width, h = b.height }
  end
  local ok, entry, evicted = pcall(clips.save, root, s, {
    name = d.data.name, tags = tags, region = region,
    layer = d.data.layerOnly and app.layer and app.layer.name or nil,
    frames = { app.frame and app.frame.frameNumber or 1 },
  })
  if not ok then
    ChatWindow.showTip(tostring(entry))
  else
    ChatWindow.showTip("Saved clip " .. entry.name .. (evicted and (" (removed " .. evicted .. ", limit reached)") or ""))
  end
end
```
> The Insert button calls the same `tools.dispatch("insert_clip", …)` path Claude uses. Also, `showClips`'s preview relies on `GraphicsContext:drawImage(image, srcRect, dstRect)`; verify this in the final manual test.

In `plugin.lua`, inside `init`, after the Agent Chat command:
```lua
  plugin:newCommand{
    id = "AgentSaveClip",
    title = "Save Selection as Clip",
    group = "edit_insert",
    onclick = function() ChatWindow.saveSelectionAsClip() end,
  }
```
Also add `"AgentSaveClip"` to the refused-commands list in `extensions.lua`.

- [ ] **Step 4: Run the tests, load check, install and commit**

Run `scripts/test-lua.sh` (all pass) and the headless load check. Then:
```bash
scripts/dev-install.sh
git add extension tests && git commit -m "feat(extension): Clips dialog and Edit > Save Selection as Clip"
```
Rebuild and restart the bridge, updating the running-process record.

- [ ] **Step 5: Manual checks (added to the final big test)**
1. Select part of a sprite, then **Edit → Save Selection as Clip**; name and tag it. The **Clips** dialog shows it with a preview, and **Insert** adds a "Clip: …" layer with the pixels selected.
2. Ask Claude to "bring the knight's helmet into this sprite, mirrored". Claude uses `import_from_sprite` from the unopened knight file.
3. Save 21 clips (or set `clips.max` to 3 in `project.json`). The oldest unpinned one is removed, and pinned ones stay.
4. Ask "export the knight as a sprite sheet for Godot at 2x, with its normal map". Files appear next to the sprite (`knight_sheet.png/json`, `knight_n_sheet.png/json`). Change `project.json` to use an `exports/` folder and export again.

---

## Self-Review Notes

- **Spec coverage:** §5 (`import_from_sprite`, clip tools, `export_sprite`, with auto-approve exceptions for `export_sprite` and `delete_clip`), §8 (clip store, LRU, pinning, the Clips UI and the Edit menu command), §9 (export locations and formats, `_n` normals).
- **Deviations:**
  - ASCII layer names instead of `⤵`.
  - The clip browser is a dialog with a single preview rather than a thumbnail grid, because the Lua `Dialog` has no scrolling grid.
  - PNG and per-frame exports are rendered by us, because `SaveFileCopyAs` always writes sequences.
  - Scaled sheets export from a temporary copy, because ExportSpriteSheet ignores `scale`.
