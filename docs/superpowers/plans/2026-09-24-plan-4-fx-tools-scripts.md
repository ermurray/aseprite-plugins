# Aseprite Agent Chat — Plan 4: FX, Tools and Scripts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude helps with effects, Aseprite's tools, extensions and scripts:
- It runs hand-built pixel-art FX and Aseprite's built-in adjustments (with approval, one undo each).
- It makes height and normal maps as companion sprites.
- It shows read-only value, silhouette and lighting previews for teaching.
- It sets up tools, brushes, inks, colors, symmetry and tiled mode (applied immediately).
- It recommends and runs extensions.
- It writes and runs custom Lua scripts, with the full code shown on an approval card.

**Architecture:** The bridge gains about 17 tool definitions, a new `setting` tool kind (no approval card), and a bridge-side extension catalog. On the Lua side:
- a pure `fx/math.lua` holds the algorithms, fully unit-tested on plain tables;
- `tools/fxtarget.lua` resolves the sprite, layers, frames and region, and runs one transaction across frames;
- one tool module per area (`fx`, `maps`, `builtin`, `toolstate`, `extensions`, `scripts`).

**Tech Stack:** Same as Plans 1–3.

**Spec:** `docs/superpowers/specs/2026-09-24-aseprite-agent-chat-design.md` §15 (plus earlier sections for the approval and undo rules).

## Global Constraints

- All earlier constraints still apply:
  - clone → assign inside `edit.transaction`, one undo per tool call;
  - `error(msg, 0)`;
  - json userdata args with float numbers (use `edit.int`);
  - no emoji;
  - frames are 1-based;
  - reference tabs are read-only;
  - run `scripts/dev-install.sh` after extension changes, and keep the running-process record for the bridge.
- **FX require RGB sprites.** The error text is exactly `Effects work on RGB sprites. Convert with Sprite > Color Mode > RGB first.` This doesn't apply to `builtin_fx`, `set_tool`, `get_tool_state`, `check_readability` or `light_preview`.
- **The FX target region** is `region`, else the selection's bounds, else the whole canvas, always clipped to the canvas. `allFrames: true` processes every frame in one transaction.
- **Verified in headless Aseprite:**
  - `BrightnessContrast`, `HueSaturation`, `InvertColor`, `Despeckle`, `ConvolutionMatrix` (`fromResource = "blur-3x3" | "blur-5x5" | "blur-7x7" | "blur-9x9" | "sharpen-3x3" | "sharpen-5x5" | "sharpen-7x7" | "edges-find"`) and `ReplaceColor` all work with `ui = false` inside a transaction, and undo in one step.
  - `ColorCurve` is excluded (no effect without points).
  - Brush size, shape and angle are set via `app.preferences.tool(toolId).brush.{size,type,angle}`; `app.brush = Brush(...)` does not apply in scripts.
  - `Ink.SIMPLE = 0` and `Ink.SHADING = 4`.
  - `app.preferences.document(sprite).symmetry.mode` and `.tiled.mode` are settable.
  - Unknown `app.command.X` raises `command 'X' not found`.
- **Companion maps** are saved next to the source as `<title>_normal.aseprite` and `<title>_height.aseprite`. The source must be saved first, and the companion must not be open as a tab. Error texts: `Save the sprite first: maps are saved next to it.` and `Close <file> first: it will be replaced.`
- **Scripts** live in `<app.fs.userConfigPath>/scripts/Agent/<name>.lua`. Names match `^[%w _%-]+$`, up to 60 characters. Code is at most 20000 characters. `run_script` captures `print` output (up to 4000 characters) and always restores `print`.
- **Commands `run_extension_command` refuses:** `Exit`, `CloseFile`, `CloseAllFiles`, `SaveFile`, `SaveFileAs`, `SaveFileCopyAs`, `ExportSpriteSheet`, `Options`, `KeyboardShortcuts`, `RunScript`, `DeveloperConsole`, `OpenScriptFolder`, `AgentChat`.

## Review Focus

1. **FX edge cases:** layers with partially transparent pixels, cels that hang off the canvas, frames with no cel when `allFrames` is set, and a selection versus a region versus neither. FX must not crash, must not crop cels, and must only touch the target region. Covered in Tasks 3 and 4.
2. **`snap_to_palette` with no project palette**, and `palette = "sprite"` on a sprite whose palette already contains every color. It gives clear errors and reports zero changes. Covered in Task 3.
3. **Normal maps:** an unsaved source, the companion file open as a tab, multi-frame sprites (every frame processed, durations copied), and repeated runs (the companion is replaced cleanly). Covered in Task 4.
4. **Scripts:** syntax errors, runtime errors halfway through an edit (the transaction rolls back), `print` always restored, and a script run with no sprite open. Covered in Task 6.
5. **`set_tool`** with an unknown tool or ink, or with no sprite open while setting symmetry. It gives plain errors or skips with a note, and never leaves a half-applied setup without saying so. Covered in Task 5.

---

## File Structure

```
bridge/src/
  tools/definitions.ts  + ToolKind "setting"; 17 tools (see Task 1)
  catalog.ts            NEW: curated extension/script catalog + search
  prompt.ts             + Effects, tools, extensions, scripts section
extension/agent/
  fx/math.lua           NEW: pure algorithms (dither, gradient, pixel-perfect, palette distance,
                             distance transform, heights, normals, shading)
  tools/fxtarget.lua    NEW: resolve sprite/layers/frames/region; one-transaction apply
  tools/fx.lua          NEW: dither, gradient_fill, pixel_perfect, snap_to_palette, selout, layer_style
  tools/maps.lua        NEW: make_normal_map, light_preview, check_readability
  tools/builtin.lua     NEW: builtin_fx
  tools/toolstate.lua   NEW: get_tool_state, set_tool
  tools/extensions.lua  NEW: list_installed_extensions, run_extension_command
  tools/scripts.lua     NEW: write_script, run_script
  tools/inspect.lua     + saveSnapshot (shared by get_snapshot and the previews)
  tools/init.lua        registers the new handlers (read / edit / setting)
tests/lua/test_fx_math.lua, test_fx.lua, test_maps.lua, test_builtin_toolstate.lua, test_scripts.lua  NEW
```

---

### Task 1: Tool definitions, the catalog and the prompt (bridge)

**Files:**
- Create: `bridge/src/catalog.ts`
- Modify: `bridge/src/tools/definitions.ts`, `bridge/src/prompt.ts`
- Test: `bridge/test/catalog.test.ts`, `bridge/test/definitions.test.ts`, `bridge/test/approval.test.ts`

**Interfaces:**
- `ToolKind = "read" | "edit" | "setting"`. Setting tools never show a card (the session only gates `edit`).
- New tools:
  - **read:** `get_tool_state`, `find_extensions` (runs in the bridge), `list_installed_extensions`, `check_readability`, `light_preview`
  - **setting:** `set_tool`
  - **edit:** `dither`, `gradient_fill`, `pixel_perfect`, `snap_to_palette`, `selout`, `layer_style`, `builtin_fx`, `make_normal_map`, `run_extension_command`, `write_script`, `run_script`
- `catalog.ts`: `interface CatalogEntry { name; by; kind: "extension" | "script collection"; purpose; tags: string[]; url; license }`, `CATALOG: CatalogEntry[]`, `searchCatalog(query?: string): CatalogEntry[]`

- [ ] **Step 1: Write the failing tests**

`bridge/test/catalog.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { CATALOG, searchCatalog } from "../src/catalog.js";

describe("extension catalog", () => {
  it("has well-formed entries with links and licenses", () => {
    expect(CATALOG.length).toBeGreaterThanOrEqual(15);
    for (const e of CATALOG) {
      expect(e.url).toMatch(/^https:\/\//);
      expect(e.license.length).toBeGreaterThan(0);
      expect(e.purpose).toMatch(/^[\x20-\x7E]+$/);
    }
  });

  it("finds entries by purpose or tag, case-insensitively", () => {
    const names = searchCatalog("Wave").map((e) => e.name);
    expect(names).toContain("Wave Warp");
    expect(searchCatalog("normal map").length).toBeGreaterThan(0);
    expect(searchCatalog("").length).toBe(CATALOG.length);
    expect(searchCatalog("zzzz-nothing")).toEqual([]);
  });
});
```

In `bridge/test/definitions.test.ts`, extend the expected name list with:
`"builtin_fx", "check_readability", "dither", "find_extensions", "get_tool_state", "gradient_fill", "layer_style", "light_preview", "list_installed_extensions", "make_normal_map", "pixel_perfect", "run_extension_command", "run_script", "selout", "set_tool", "snap_to_palette", "write_script"` (keep the list sorted; the test sorts it anyway). Then add:
```ts
  it("set_tool is a setting (no approval) and scripts show their full code on the card", () => {
    expect(toolDef("set_tool")!.kind).toBe("setting");
    const card = toolDef("write_script")!.summarize!({ name: "Export tags", description: "Exports each tag", code: "print('hi')\nprint('there')" });
    expect(card).toContain('Save script "Export tags" to File > Scripts > Agent');
    expect(card).toContain("print('hi')\nprint('there')");
    expect(toolDef("run_script")!.summarize!({ name: "Export tags" })).toBe('Run script "Export tags" once');
  });

  it("validates FX arguments", () => {
    const dither = z.object(toolDef("dither")!.shape);
    expect(dither.safeParse({ layer: "Body", colorA: "#000000", colorB: "#ffffff", amount: 0.5 }).success).toBe(true);
    expect(dither.safeParse({ layer: "Body", colorA: "#000000", colorB: "#ffffff", amount: 2 }).success).toBe(false);
    const script = z.object(toolDef("write_script")!.shape);
    expect(script.safeParse({ name: "../evil", description: "x", code: "x" }).success).toBe(false);
    const cmd = z.object(toolDef("run_extension_command")!.shape);
    expect(cmd.safeParse({ command: "os.exit()" }).success).toBe(false);
  });
```

In `bridge/test/approval.test.ts`, add:
```ts
  it("setting tools never show a card", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("set_tool", { tool: "pencil", brushSize: 2 });
    });
    c.send({ type: "user_message", text: "set me up" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "approval_request")).toBe(false);
    expect(c.received.filter((m) => m.type === "tool_call")).toHaveLength(1);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npx vitest run`
Expected: FAIL. `catalog.js` is missing, the new tools are unknown, and `set_tool` has no kind.

- [ ] **Step 3: Implement the catalog**

`bridge/src/catalog.ts`:
```ts
/** Well-known community extensions and scripts Claude can recommend. Nothing here is bundled. */
export interface CatalogEntry {
  name: string;
  by: string;
  kind: "extension" | "script collection";
  purpose: string;
  tags: string[];
  url: string;
  license: string;
}

const THKWZNK = "https://github.com/thkwznk/aseprite-scripts";
const COMMUNITY = "https://github.com/projectitis/aseprite-community-script-collection";
const BEHREAJJ = "https://github.com/behreajj/AsepriteAddons";

export const CATALOG: CatalogEntry[] = [
  { name: "Sprite Analyzer", by: "thkwznk", kind: "extension", purpose: "Live preview breakdown of values, silhouette, outline and blocked shapes while you draw.", tags: ["values", "silhouette", "readability", "preview"], url: THKWZNK, license: "not stated (ask the author before redistributing)" },
  { name: "FX", by: "thkwznk", kind: "extension", purpose: "A pack of visual effects for sprites.", tags: ["effects", "fx"], url: THKWZNK, license: "not stated" },
  { name: "Magic Pencil", by: "thkwznk", kind: "extension", purpose: "Extra pencil modes such as outline, colorize and hue shifting while drawing.", tags: ["pencil", "tool", "shading", "outline"], url: THKWZNK, license: "not stated" },
  { name: "NxPA Studio", by: "thkwznk", kind: "extension", purpose: "Pixel-art scaling algorithms, frame interpolation and color analysis.", tags: ["scaling", "upscale", "tween", "animation", "colors"], url: THKWZNK, license: "not stated" },
  { name: "Animation Suite", by: "thkwznk", kind: "extension", purpose: "Import animations with movement patterns and build loops from layered animation.", tags: ["animation", "loop"], url: THKWZNK, license: "not stated" },
  { name: "AsepriteAddons", by: "behreajj", kind: "script collection", purpose: "Gradients (linear, radial, sweep), dither filter, gradient map, color curves, normal maps and an LCh color picker.", tags: ["gradient", "dither", "normal map", "curves", "color picker"], url: BEHREAJJ, license: "GPL-3.0" },
  { name: "Gradients Extension", by: "community collection", kind: "extension", purpose: "Gradient tool with over 100 dither patterns.", tags: ["gradient", "dither"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Wave Warp", by: "community collection", kind: "extension", purpose: "Animated wave distortion effects.", tags: ["wave", "distortion", "effects", "animation"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Parallixel", by: "community collection", kind: "extension", purpose: "Automates seamless parallax scrolling backgrounds.", tags: ["parallax", "background", "animation"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Tweencel", by: "community collection", kind: "extension", purpose: "Advanced frame tweening between key poses.", tags: ["tween", "animation", "inbetween"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Multi Color Replacer", by: "community collection", kind: "script collection", purpose: "Replace several colors at once.", tags: ["colors", "replace", "palette swap"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Palettize", by: "community collection", kind: "script collection", purpose: "Preview and tune palette application with HSV sliders.", tags: ["palette", "colors"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Perlin Noise Generation", by: "community collection", kind: "script collection", purpose: "Procedural noise for textures.", tags: ["noise", "texture"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Isometric Guidelines and Box Generator", by: "community collection", kind: "script collection", purpose: "Isometric guide layers and customizable isometric boxes.", tags: ["isometric", "guides"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "1-Point Perspective Helper", by: "community collection", kind: "script collection", purpose: "Single-point perspective grids.", tags: ["perspective", "guides"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Reflecto", by: "community collection", kind: "script collection", purpose: "Automatic vertical sprite reflections.", tags: ["reflection", "water", "effects"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Normal Map Generator and Preview", by: "community collection", kind: "script collection", purpose: "Normal maps from sprites and an in-editor preview.", tags: ["normal map", "lighting"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Export Tags and Export Tooling", by: "community collection", kind: "script collection", purpose: "Export tags as strips and advanced sprite sheet or layer export for game engines.", tags: ["export", "sprite sheet", "tags"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Brush Manager Pro and Dithering Generator", by: "community forum", kind: "extension", purpose: "Brush library and packs, shading helpers and a dithering pattern generator.", tags: ["brush", "dither", "shading"], url: "https://community.aseprite.org/t/extension-brush-manager-pro-dithering-generator-shading-library-brush-packs/28193", license: "see forum post" },
];

export function searchCatalog(query?: string): CatalogEntry[] {
  const q = (query ?? "").trim().toLowerCase();
  if (!q) return CATALOG;
  return CATALOG.filter((e) => [e.name, e.purpose, ...e.tags].some((s) => s.toLowerCase().includes(q)));
}
```

- [ ] **Step 4: Implement the definitions**

In `definitions.ts`:
- Change `ToolKind` to `"read" | "edit" | "setting"`.
- Import `searchCatalog` from `../catalog.js`.
- Add these shared helpers after the existing ones:
```ts
const layerArg2 = z.string().describe("Layer to work on.");
const allFramesArg = z.boolean().optional().describe("Apply to every frame (default: the given or active frame only).");
const regionArg = rect().optional().describe("Limit to this rectangle (default: the selection if any, else the whole canvas).");
const fxTarget = { sprite: spriteArg, layer: layerArg2, frame: frameArg, allFrames: allFramesArg, region: regionArg };
const where = (a: Record<string, unknown>) => `${target(a)}${a.allFrames ? ", all frames" : typeof a.frame === "number" ? `, frame ${a.frame}` : ""}`;
```
Then append these entries to `TOOL_DEFS`:
```ts
  {
    name: "get_tool_state",
    kind: "read",
    description: "The artist's current tool, brush (size, shape, angle), ink, foreground/background colors, and the active sprite's symmetry and tiled mode.",
    shape: {},
    activity: () => "Checked your current tool",
  },
  {
    name: "set_tool",
    kind: "setting",
    description:
      "Set up Aseprite's tools for the artist immediately (no approval; it changes settings, not art): tool id (pencil, eraser, paint_bucket, spray, line, rectangle, filled_rectangle, ellipse, filled_ellipse, contour, polygon, blur, jumble, eyedropper, move, rectangular_marquee, lasso, magic_wand), brush size/shape/angle, ink (simple, alpha_compositing, copy_color, lock_alpha, shading), foreground/background colors, symmetry and tiled mode. Say what you set and why.",
    shape: {
      tool: z.string().regex(/^[a-z_]+$/).optional(),
      brushSize: z.number().int().min(1).max(64).optional(),
      brushShape: z.enum(["circle", "square", "line"]).optional(),
      brushAngle: z.number().int().min(-180).max(180).optional(),
      ink: z.enum(["simple", "alpha_compositing", "copy_color", "lock_alpha", "shading"]).optional(),
      foreground: hexColor.optional(),
      background: hexColor.optional(),
      symmetry: z.enum(["none", "horizontal", "vertical", "both"]).optional(),
      tiled: z.enum(["none", "x", "y", "both"]).optional(),
    },
    activity: (a) => `Set up ${[a.tool, a.ink && `${a.ink} ink`, a.brushSize && `brush ${a.brushSize}px`].filter(Boolean).join(", ") || "your tools"}`,
  },
  {
    name: "find_extensions",
    kind: "read",
    description: "Search a curated catalog of well-known Aseprite extensions and script collections (name, purpose, link, license) to recommend. Empty query lists all. Nothing is installed automatically.",
    shape: { query: z.string().optional() },
    activity: (a) => `Searched extensions${typeof a.query === "string" && a.query ? ` for "${a.query}"` : ""}`,
    runInBridge: async (a) => ({ ok: true, data: { matches: searchCatalog(typeof a.query === "string" ? a.query : "") } }),
  },
  {
    name: "list_installed_extensions",
    kind: "read",
    description: "Extensions the artist has installed in Aseprite (name, display name, version, description).",
    shape: {},
    activity: () => "Listed your installed extensions",
  },
  {
    name: "check_readability",
    kind: "read",
    description: "Read-only teaching view of a frame: 'values' (grayscale by luminance), 'silhouette' (flat shape), or 'both' side by side. Returns an image; the sprite is not changed.",
    shape: { sprite: spriteArg, frame: frameArg, mode: z.enum(["values", "silhouette", "both"]).optional() },
    activity: (a) => `Checked ${a.mode ?? "values and silhouette"} of ${spriteName(a)}`,
  },
  {
    name: "light_preview",
    kind: "read",
    description: "Read-only lit preview: shades a frame using normals computed from a layer (or the flattened image) with a light direction (lightX right, lightY up, lightZ toward the viewer). Use it to show how normal maps or shading read. The sprite is not changed.",
    shape: {
      sprite: spriteArg,
      layer: z.string().optional(),
      frame: frameArg,
      lightX: z.number().min(-1).max(1),
      lightY: z.number().min(-1).max(1),
      lightZ: z.number().min(0).max(1).optional(),
      ambient: z.number().min(0).max(1).optional(),
      source: z.enum(["brightness", "edges", "both"]).optional(),
      bevel: z.number().int().min(1).max(16).optional(),
      strength: z.number().min(0.5).max(8).optional(),
    },
    activity: (a) => `Previewed lighting on ${spriteName(a)}`,
  },
  {
    name: "dither",
    kind: "edit",
    description: "Dither two colors across the target: amount is the share of colorB (0-1); pattern bayer2, bayer4 (default) or checker. By default only paints over existing opaque pixels (onlyOpaque).",
    shape: { ...fxTarget, colorA: hexColor, colorB: hexColor, amount: z.number().min(0).max(1), pattern: z.enum(["bayer2", "bayer4", "checker"]).optional(), onlyOpaque: z.boolean().optional() },
    activity: (a) => `Dithered ${where(a)}`,
    summarize: (a) => `Dither ${a.colorA} and ${a.colorB} (${Math.round(Number(a.amount) * 100)}% ${a.colorB}, ${a.pattern ?? "bayer4"}) on ${where(a)}`,
  },
  {
    name: "gradient_fill",
    kind: "edit",
    description: "Fill the target with a gradient through 2-8 colors: linear (angle in degrees, 0 = left to right) or radial (from the center); optional dither between steps. Fills transparent pixels too unless onlyOpaque.",
    shape: {
      ...fxTarget,
      colors: z.array(hexColor).min(2).max(8),
      type: z.enum(["linear", "radial"]).optional(),
      angle: z.number().min(-360).max(360).optional(),
      dither: z.enum(["none", "bayer2", "bayer4", "checker"]).optional(),
      onlyOpaque: z.boolean().optional(),
    },
    activity: (a) => `Filled a gradient on ${where(a)}`,
    summarize: (a) => `Fill a ${a.type ?? "linear"} gradient ${(Array.isArray(a.colors) ? a.colors : []).join(" > ")}${a.dither && a.dither !== "none" ? ` with ${a.dither} dither` : ""} on ${where(a)}`,
  },
  {
    name: "pixel_perfect",
    kind: "edit",
    description: "Clean 1px lines: remove L-shaped corner pixels so strokes become clean diagonals (keeps line connectivity; leaves junctions and filled areas alone).",
    shape: fxTarget,
    activity: (a) => `Cleaned lines on ${where(a)}`,
    summarize: (a) => `Clean up 1px lines (pixel-perfect) on ${where(a)}`,
  },
  {
    name: "snap_to_palette",
    kind: "edit",
    description: "Recolor every off-palette pixel to the nearest palette color: palette 'project' (the project's palette.gpl, default) or 'sprite' (the sprite's palette). Layer optional: default all editable layers.",
    shape: { sprite: spriteArg, layer: z.string().optional(), frame: frameArg, allFrames: allFramesArg, palette: z.enum(["project", "sprite"]).optional() },
    activity: (a) => `Snapped ${spriteName(a)} to the ${a.palette ?? "project"} palette`,
    summarize: (a) => `Snap off-palette colors in ${where(a)} to the ${a.palette ?? "project"} palette`,
  },
  {
    name: "selout",
    kind: "edit",
    description: "Selective outline: recolor outline pixels (default: the most common edge color, or outlineColor) to a darker shade of the fill next to them. darken 0-0.9 (default 0.35).",
    shape: { ...fxTarget, darken: z.number().min(0).max(0.9).optional(), outlineColor: hexColor.optional() },
    activity: (a) => `Applied selout to ${where(a)}`,
    summarize: (a) => `Selective outline on ${where(a)} (darken ${a.darken ?? 0.35})`,
  },
  {
    name: "layer_style",
    kind: "edit",
    description: "Layer effects: 'overlay' tints the layer's pixels toward color by amount; 'stroke' adds an N-px outline on a new '<layer> stroke' layer below; 'shadow' adds a hard drop shadow on a new '<layer> shadow' layer below.",
    shape: {
      ...fxTarget,
      style: z.enum(["overlay", "stroke", "shadow"]),
      color: hexColor,
      amount: z.number().min(0).max(1).optional(),
      width: z.number().int().min(1).max(8).optional(),
      offsetX: z.number().int().min(-16).max(16).optional(),
      offsetY: z.number().int().min(-16).max(16).optional(),
    },
    activity: (a) => `Added a ${a.style} to ${where(a)}`,
    summarize: (a) =>
      a.style === "overlay"
        ? `Tint ${where(a)} toward ${a.color} (${Math.round(Number(a.amount ?? 0.5) * 100)}%)`
        : a.style === "stroke"
          ? `Add a ${a.width ?? 1}px ${a.color} stroke under ${where(a)} (new layer)`
          : `Add a ${a.color} drop shadow offset (${a.offsetX ?? 1},${a.offsetY ?? 1}) under ${where(a)} (new layer)`,
  },
  {
    name: "builtin_fx",
    kind: "edit",
    description:
      "Aseprite's own adjustments on a layer/frame (optionally a region): brightness_contrast (brightness, contrast -100..100), hue_saturation (hue -180..180, saturation, lightness -100..100), invert, despeckle (size 3-9), blur (size 3/5/7/9), sharpen (size 3/5/7), find_edges, replace_color (from, to, tolerance).",
    shape: {
      sprite: spriteArg,
      layer: layerArg2,
      frame: frameArg,
      region: regionArg,
      effect: z.enum(["brightness_contrast", "hue_saturation", "invert", "despeckle", "blur", "sharpen", "find_edges", "replace_color"]),
      brightness: z.number().min(-100).max(100).optional(),
      contrast: z.number().min(-100).max(100).optional(),
      hue: z.number().min(-180).max(180).optional(),
      saturation: z.number().min(-100).max(100).optional(),
      lightness: z.number().min(-100).max(100).optional(),
      size: z.number().int().min(3).max(9).optional(),
      from: hexColor.optional(),
      to: hexColor.optional(),
      tolerance: z.number().int().min(0).max(255).optional(),
    },
    activity: (a) => `Applied ${String(a.effect).replace(/_/g, " ")} to ${target(a)}`,
    summarize: (a) => `Apply Aseprite's ${String(a.effect).replace(/_/g, " ")} to ${target(a)}${typeof a.frame === "number" ? `, frame ${a.frame}` : ""}${a.region ? " (region only)" : ""}`,
  },
  {
    name: "make_normal_map",
    kind: "edit",
    description:
      "Make a height map and normal map from a layer for 2D lighting, every frame, saved as companion sprites next to the source (<name>_height.aseprite, <name>_normal.aseprite). source: brightness (lighter = higher), edges (pillow bevel from the shape's edge), both (default). convention: opengl (+Y, Godot/Unity default) or directx. quantize: off, 3 or 5 levels per axis for crisp pixel-art normals.",
    shape: {
      sprite: spriteArg,
      layer: layerArg2,
      source: z.enum(["brightness", "edges", "both"]).optional(),
      bevel: z.number().int().min(1).max(16).optional(),
      strength: z.number().min(0.5).max(8).optional(),
      convention: z.enum(["opengl", "directx"]).optional(),
      quantize: z.enum(["off", "3", "5"]).optional(),
      saveHeight: z.boolean().optional(),
    },
    activity: (a) => `Made normal maps for ${target(a)}`,
    summarize: (a) =>
      `Create or replace ${spriteName(a)}'s companion normal map${a.saveHeight === false ? "" : " and height map"} from ${target(a)} (${a.source ?? "both"}, ${a.convention ?? "opengl"}), saved next to it`,
  },
  {
    name: "run_extension_command",
    kind: "edit",
    description: "Run an Aseprite command by id, e.g. one added by an installed extension (its author names it). Some built-in commands (quit, save, close, options, scripts) are refused. Check list_installed_extensions first.",
    shape: { command: z.string().regex(/^[A-Za-z][A-Za-z0-9_]{0,63}$/) },
    activity: (a) => `Ran the ${a.command} command`,
    summarize: (a) => `Run the Aseprite command "${a.command}"`,
  },
  {
    name: "write_script",
    kind: "edit",
    description:
      "Save a Lua script for a repetitive job to the artist's File > Scripts > Agent menu. The artist sees the full code on the approval card. Keep it short and commented; wrap sprite edits in app.transaction. Run it with run_script (separate approval).",
    shape: {
      name: z.string().regex(/^[A-Za-z0-9 _-]{1,60}$/),
      description: z.string().min(1).max(200),
      code: z.string().min(1).max(20000),
    },
    activity: (a) => `Saved the script "${a.name}"`,
    summarize: (a) => `Save script "${a.name}" to File > Scripts > Agent: ${a.description}\n\n${a.code}`,
  },
  {
    name: "run_script",
    kind: "edit",
    description: "Run a script saved in File > Scripts > Agent once. Edits run as one undo step; printed output and errors come back to you.",
    shape: { name: z.string().regex(/^[A-Za-z0-9 _-]{1,60}$/) },
    activity: (a) => `Ran the script "${a.name}"`,
    summarize: (a) => `Run script "${a.name}" once`,
  },
```

- [ ] **Step 5: Update the prompt**

In `prompt.ts`, insert this section before the paragraph that starts `You are not an art generator`:
```
Effects, tools, extensions and scripts:
- Pixel-art effects (each asks for approval and is one undo): dither, gradient_fill, pixel_perfect (turns L-corners in 1px lines into clean diagonals), snap_to_palette, selout (outline pixels become darker shades of the fill), layer_style (overlay, stroke, drop shadow), and builtin_fx for Aseprite's own adjustments (brightness/contrast, hue/saturation, invert, despeckle, blur, sharpen, find edges, replace color). Effects need RGB sprites.
- make_normal_map writes <name>_height and <name>_normal companion sprites next to the source for 2D lighting in game engines. light_preview shows how a light direction reads, and check_readability shows value and silhouette views; both are read-only and great for teaching.
- Aseprite's tools: get_tool_state shows what the artist is using, and set_tool sets the tool, brush, ink (for example shading ink with a ramp), colors, symmetry and tiled mode immediately, without a card. Say what you set and why.
- Extensions: find_extensions searches a catalog of well-known community extensions and scripts (with links and licenses) for recommendations; list_installed_extensions shows what is installed; run_extension_command runs an installed extension's command by id after approval. Never claim something is installed without checking.
- Scripts: for repetitive jobs, write_script saves a Lua script to File > Scripts > Agent (the artist sees the full code first) and run_script runs it once after a separate approval. Keep scripts small and commented, and wrap sprite edits in app.transaction.
```

- [ ] **Step 6: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all pass. tsc is clean.

- [ ] **Step 7: Commit**

```bash
git add bridge/src bridge/test
git commit -m "feat(bridge): FX, tool setup, extension catalog and script tool definitions"
```

---

### Task 2: Pure FX math (Lua)

**Files:**
- Create: `extension/agent/fx/math.lua`
- Test: `tests/lua/test_fx_math.lua` (add it to the suite list)

**Interfaces** (grids are flat tables indexed `y * w + x + 1`, with 0-based `x` and `y`):
- `threshold(pattern, x, y) -> 0..1` and `ditherPick(pattern, x, y, amount) -> bool` (true means use the second color). Patterns: `bayer2`, `bayer4`, `checker`.
- `linearT(x, y, rect, angleDeg)`, `radialT(x, y, cx, cy, radius)`, `gradientIndex(t, count, pattern, x, y) -> 1..count`
- `pixelPerfectRemovals(opaque, w, h) -> {{x, y}...}` (mutates `opaque`)
- `redmean(r1, g1, b1, r2, g2, b2)`, `nearest(r, g, b, palette{{r, g, b}}) -> index`, `luminance(r, g, b)`, `darken(r, g, b, amount)`, `mix(r1, g1, b1, r2, g2, b2, t)`
- `distance(opaque, w, h) -> dist` (0 for transparent pixels; 1 at edges)
- `dilate(opaque, w, h, width) -> {{x, y}...}` (new pixels, 4-neighborhood)
- `heights(lum, opaque, w, h, source, bevel) -> h` (values 0..1)
- `normals(h, opaque, w, hgt, strength, convention, quantize) -> {{nx, ny, nz}|false ...}`. The vector is normalized. `ny` is image-up for `opengl` and image-down for `directx`.
- `encodeNormal(nx, ny, nz) -> r, g, b`, `shade(n, lx, ly, lz, ambient) -> 0..1` (`n` in the up-convention)

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_fx_math.lua`:
```lua
local T = require("testlib")
local M = require("agent.fx.math")

T.test("dither thresholds: amount 0 never, 1 always, 0.5 is half of each tile", function()
  for _, p in ipairs{ "bayer2", "bayer4", "checker" } do
    local picks, cells = 0, 0
    for y = 0, 3 do for x = 0, 3 do
      T.eq(M.ditherPick(p, x, y, 0), false)
      T.eq(M.ditherPick(p, x, y, 1), true)
      cells = cells + 1
      if M.ditherPick(p, x, y, 0.5) then picks = picks + 1 end
    end end
    T.eq(picks, cells / 2, p)
  end
  T.eq(M.ditherPick("checker", 0, 0, 0.5), true)
  T.eq(M.ditherPick("checker", 1, 0, 0.5), false)
end)

T.test("gradient positions and color steps", function()
  local r = { x = 0, y = 0, w = 4, h = 1 }
  T.eq(M.linearT(0, 0, r, 0), 0)
  T.eq(M.linearT(3, 0, r, 0), 1)
  T.eq(M.linearT(3, 0, r, 180), 0)
  T.eq(M.radialT(2, 2, 2, 2, 5), 0)
  T.eq(M.radialT(7, 2, 2, 2, 5), 1)
  T.eq(M.gradientIndex(0, 3, "none", 0, 0), 1)
  T.eq(M.gradientIndex(1, 3, "none", 0, 0), 3)
  T.eq(M.gradientIndex(0.49 / 2, 3, "none", 0, 0), 1)
  T.eq(M.gradientIndex(0.51 / 2, 3, "none", 0, 0), 2)
end)

local function grid(rows)
  local w, h, g = #rows[1], #rows, {}
  for y = 1, h do for x = 1, w do g[(y - 1) * w + x] = rows[y]:sub(x, x) == "#" end end
  return g, w, h
end
local function key(list)
  local t = {}
  for _, p in ipairs(list) do t[#t + 1] = p.x .. "," .. p.y end
  table.sort(t)
  return table.concat(t, " ")
end

T.test("pixel-perfect removes L corners, keeps lines, junctions and blocks", function()
  T.eq(key(M.pixelPerfectRemovals(grid{ "##.", ".#." })), "1,0")
  T.eq(key(M.pixelPerfectRemovals(grid{ "####" })), "")
  T.eq(key(M.pixelPerfectRemovals(grid{ "##..", ".##.", "..##" })), "1,0 2,1")
  T.eq(key(M.pixelPerfectRemovals(grid{ "###", ".#.", ".#." })), "")
  T.eq(key(M.pixelPerfectRemovals(grid{ "##", "##" })), "")
end)

T.test("color helpers", function()
  T.eq(M.redmean(1, 2, 3, 1, 2, 3), 0)
  T.eq(M.nearest(250, 250, 250, { { r = 0, g = 0, b = 0 }, { r = 255, g = 255, b = 255 } }), 2)
  T.eq(M.luminance(255, 255, 255), 255)
  T.deepEq({ M.darken(200, 100, 50, 0.5) }, { 100, 50, 25 })
  T.deepEq({ M.mix(0, 0, 0, 255, 255, 255, 0.5) }, { 128, 128, 128 })
end)

T.test("distance transform and dilation", function()
  local g, w, h = grid{ "#####", "#####", "#####", "#####", "#####" }
  local d = M.distance(g, w, h)
  T.eq(d[1], 1)
  T.eq(d[2 * w + 2 + 1], 3)
  local g2, w2, h2 = grid{ "#..", "...", "..." }
  T.eq(key(M.dilate(g2, w2, h2, 1)), "0,1 1,0")
  T.eq(#M.dilate(g2, w2, h2, 2), 5)
end)

T.test("normals: flat in the middle of a dome, facing out at the sides, conventions flip Y", function()
  local g, w, h = grid{ "#####", "#####", "#####", "#####", "#####" }
  local heights = M.heights(nil, g, w, h, "edges", 3)
  local n = M.normals(heights, g, w, h, 2, "opengl", "off")
  local c = n[2 * w + 2 + 1]
  T.deepEq({ M.encodeNormal(c[1], c[2], c[3]) }, { 128, 128, 255 })
  local left = n[2 * w + 1 + 1]
  T.eq(left[1] < 0, true, "left side faces left")
  local top = n[1 * w + 2 + 1]
  T.eq(top[2] > 0, true, "top faces up in opengl")
  local dx = M.normals(heights, g, w, h, 2, "directx", "off")
  T.eq(dx[1 * w + 2 + 1][2] < 0, true, "directx flips green")
  local q = M.normals(heights, g, w, h, 2, "opengl", "3")
  local qc = q[1 * w + 1 + 1]
  for _, v in ipairs(qc) do T.eq(v == v, true) end
  T.eq(n[0 + 1] ~= nil, true)
  local empty, ew, eh = grid{ "#.", ".." }
  T.eq(M.normals(M.heights(nil, empty, ew, eh, "edges", 2), empty, ew, eh, 1, "opengl", "off")[2], false)
end)

T.test("shade lights faces that point at the light", function()
  T.eq(M.shade({ 0, 0, 1 }, 0, 0, 1, 0), 1)
  T.eq(M.shade({ 1, 0, 0 }, -1, 0, 0, 0.2), 0.2)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh fx_math`
Expected: `module 'agent.fx.math' not found`.

- [ ] **Step 3: Implement**

`extension/agent/fx/math.lua`:
```lua
-- Pure pixel-art algorithms on plain tables; no Aseprite objects, so they are easy to test.
local M = {}

M.BAYER = {
  bayer2 = { { 0, 2 }, { 3, 1 } },
  bayer4 = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } },
}

function M.threshold(pattern, x, y)
  if pattern == "checker" then return ((x + y) % 2 == 0) and 0.25 or 0.75 end
  local m = M.BAYER[pattern] or M.BAYER.bayer4
  local n = #m
  return (m[y % n + 1][x % n + 1] + 0.5) / (n * n)
end

function M.ditherPick(pattern, x, y, amount)
  return amount > M.threshold(pattern, x, y)
end

function M.linearT(x, y, rect, angleDeg)
  local a = math.rad(angleDeg or 0)
  local dx, dy = math.cos(a), math.sin(a)
  local lo, hi = math.huge, -math.huge
  for _, c in ipairs{ { rect.x, rect.y }, { rect.x + rect.w - 1, rect.y }, { rect.x, rect.y + rect.h - 1 }, { rect.x + rect.w - 1, rect.y + rect.h - 1 } } do
    local p = c[1] * dx + c[2] * dy
    lo, hi = math.min(lo, p), math.max(hi, p)
  end
  if hi - lo < 1e-9 then return 0 end
  return math.max(0, math.min(1, ((x * dx + y * dy) - lo) / (hi - lo)))
end

function M.radialT(x, y, cx, cy, radius)
  if radius <= 0 then return 0 end
  return math.min(1, math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2) / radius)
end

function M.gradientIndex(t, count, pattern, x, y)
  if count <= 1 then return 1 end
  local seg = t * (count - 1)
  local i = math.floor(seg)
  if i >= count - 1 then return count end
  local u = seg - i
  local nextOne
  if pattern and pattern ~= "none" then nextOne = M.ditherPick(pattern, x, y, u) else nextOne = u >= 0.5 end
  return i + (nextOne and 2 or 1)
end

-- Removes L-corner pixels from 1px strokes, scanning in order so staircases thin to diagonals.
function M.pixelPerfectRemovals(opaque, w, h)
  local function at(x, y) return x >= 0 and y >= 0 and x < w and y < h and opaque[y * w + x + 1] == true end
  local removed = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      if at(x, y) then
        local e, wv, n, s = at(x + 1, y), at(x - 1, y), at(x, y - 1), at(x, y + 1)
        local horiz = (e and 1 or 0) + (wv and 1 or 0)
        local vert = (n and 1 or 0) + (s and 1 or 0)
        if horiz == 1 and vert == 1 then
          local hx, vy = e and 1 or -1, s and 1 or -1
          if not at(x + hx, y + vy) then
            local ok, count = true, 0
            for dy = -1, 1 do
              for dx = -1, 1 do
                if (dx ~= 0 or dy ~= 0) and at(x + dx, y + dy) then
                  count = count + 1
                  local isArm = (dx == hx and dy == 0) or (dx == 0 and dy == vy)
                  local touchesArm = (math.abs(dx - hx) <= 1 and math.abs(dy) <= 1) or (math.abs(dx) <= 1 and math.abs(dy - vy) <= 1)
                  if not isArm and not touchesArm then ok = false end
                end
              end
            end
            if ok and count <= 3 then
              opaque[y * w + x + 1] = false
              removed[#removed + 1] = { x = x, y = y }
            end
          end
        end
      end
    end
  end
  return removed
end

function M.redmean(r1, g1, b1, r2, g2, b2)
  local rm = (r1 + r2) / 2
  local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
  return math.sqrt((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db)
end

function M.nearest(r, g, b, palette)
  local best, bestD = 1, math.huge
  for i, c in ipairs(palette) do
    local d = M.redmean(r, g, b, c.r, c.g, c.b)
    if d < bestD then best, bestD = i, d end
  end
  return best
end

function M.luminance(r, g, b)
  return 0.299 * r + 0.587 * g + 0.114 * b
end

local function round(v) return math.floor(v + 0.5) end

function M.darken(r, g, b, amount)
  local k = 1 - amount
  return round(r * k), round(g * k), round(b * k)
end

function M.mix(r1, g1, b1, r2, g2, b2, t)
  return round(r1 + (r2 - r1) * t), round(g1 + (g2 - g1) * t), round(b1 + (b2 - b1) * t)
end

local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

function M.distance(opaque, w, h)
  local dist, queue, head = {}, {}, 1
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x + 1
      if not opaque[i] then
        dist[i] = 0
        queue[#queue + 1] = i
      elseif x == 0 or y == 0 or x == w - 1 or y == h - 1 then
        dist[i] = 1
        queue[#queue + 1] = i
      end
    end
  end
  while head <= #queue do
    local i = queue[head]
    head = head + 1
    local x, y = (i - 1) % w, (i - 1) // w
    for _, d in ipairs(N4) do
      local nx, ny = x + d[1], y + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local j = ny * w + nx + 1
        if dist[j] == nil then
          dist[j] = dist[i] + 1
          queue[#queue + 1] = j
        end
      end
    end
  end
  return dist
end

function M.dilate(opaque, w, h, width)
  local cur, added = {}, {}
  for i = 1, w * h do cur[i] = opaque[i] == true end
  for _ = 1, width do
    local grow = {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local i = y * w + x + 1
        if not cur[i] then
          for _, d in ipairs(N4) do
            local nx, ny = x + d[1], y + d[2]
            if nx >= 0 and ny >= 0 and nx < w and ny < h and cur[ny * w + nx + 1] then
              grow[#grow + 1] = i
              break
            end
          end
        end
      end
    end
    for _, i in ipairs(grow) do
      cur[i] = true
      added[#added + 1] = { x = (i - 1) % w, y = (i - 1) // w }
    end
  end
  return added
end

-- Heights 0..1 per pixel: brightness (lum 0..255 per pixel), edge distance ("pillow"), or both.
function M.heights(lum, opaque, w, h, source, bevel)
  local dist = (source ~= "brightness") and M.distance(opaque, w, h) or nil
  local out = {}
  for i = 1, w * h do
    if not opaque[i] then
      out[i] = 0
    else
      local e = dist and math.min(dist[i], bevel) / bevel or 0
      local b = lum and lum[i] / 255 or 0
      if source == "brightness" then out[i] = b
      elseif source == "edges" then out[i] = e
      else out[i] = (b + e) / 2 end
    end
  end
  return out
end

local function quantizeComponent(v, levels)
  local steps = (levels - 1) / 2
  return math.floor(v * steps + 0.5) / steps
end

function M.normals(h, opaque, w, hgt, strength, convention, quantize)
  local function H(x, y)
    if x < 0 or y < 0 or x >= w or y >= hgt then return 0 end
    return h[y * w + x + 1]
  end
  local levels = tonumber(quantize)
  local out = {}
  for y = 0, hgt - 1 do
    for x = 0, w - 1 do
      local i = y * w + x + 1
      if not opaque[i] then
        out[i] = false
      else
        local dx = (H(x + 1, y - 1) + 2 * H(x + 1, y) + H(x + 1, y + 1)) - (H(x - 1, y - 1) + 2 * H(x - 1, y) + H(x - 1, y + 1))
        local dy = (H(x - 1, y + 1) + 2 * H(x, y + 1) + H(x + 1, y + 1)) - (H(x - 1, y - 1) + 2 * H(x, y - 1) + H(x + 1, y - 1))
        local nx, ny, nz = -dx * strength, dy * strength, 1
        if convention == "directx" then ny = -ny end
        local len = math.sqrt(nx * nx + ny * ny + nz * nz)
        nx, ny, nz = nx / len, ny / len, nz / len
        if levels then
          nx, ny = quantizeComponent(nx, levels), quantizeComponent(ny, levels)
          nz = math.sqrt(math.max(0.05, 1 - nx * nx - ny * ny))
          len = math.sqrt(nx * nx + ny * ny + nz * nz)
          nx, ny, nz = nx / len, ny / len, nz / len
        end
        out[i] = { nx, ny, nz }
      end
    end
  end
  return out
end

function M.encodeNormal(nx, ny, nz)
  local function enc(v) return math.max(0, math.min(255, math.floor((v * 0.5 + 0.5) * 255 + 0.5))) end
  return enc(nx), enc(ny), enc(nz)
end

function M.shade(n, lx, ly, lz, ambient)
  local len = math.sqrt(lx * lx + ly * ly + lz * lz)
  if len == 0 then return 1 end
  local d = (n[1] * lx + n[2] * ly + n[3] * lz) / len
  return ambient + (1 - ambient) * math.max(0, d)
end

return M
```
> `encodeNormal(0, 0, 1)` gives `(128, 128, 255)`: `(0 * 0.5 + 0.5) * 255 + 0.5 = 128.0`, and the floor is 128.

Add `"test_fx_math"` to the suite list in `tests/lua/run.lua`.

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add extension/agent/fx/math.lua tests/lua/test_fx_math.lua tests/lua/run.lua
git commit -m "feat(extension): pure pixel-art FX math (dither, gradients, pixel-perfect, palettes, heights, normals)"
```

---

### Task 3: FX tools (Lua)

**Files:**
- Create: `extension/agent/tools/fxtarget.lua`, `extension/agent/tools/fx.lua`
- Modify: `extension/agent/tools/init.lua` (register the handlers as `"edit"`)
- Test: `tests/lua/test_fx.lua` (add it to the suite list)

**Interfaces:**
- `fxtarget.resolve(args, { layerOptional = bool }) -> sprite, layers{...}, frames{...}, rect{x, y, w, h}`
- `fxtarget.apply(sprite, layers, frames, label, fn(img, origin, frame, layer) -> changedCount) -> totalChanged` (one transaction)
- Handlers: `dither`, `gradient_fill`, `pixel_perfect`, `snap_to_palette`, `selout`, `layer_style`. Each returns `{sprite, layer?, changed}`; `layer_style` stroke/shadow also return `newLayer`.

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_fx.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local sprites = require("agent.tools.sprites")
local project = require("agent.project")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args)) end
local RED, GREEN, BLUE = pc.rgba(255, 0, 0, 255), pc.rgba(0, 255, 0, 255), pc.rgba(0, 0, 255, 255)

T.test("dither paints only opaque pixels by default, with the checker pattern", function()
  F.closeAll()
  local s = F.rgbSprite() -- red (0,0), green (1,0)
  local r = call("dither", { layer = "Body", colorA = "#ff0000", colorB = "#0000ff", amount = 0.5, pattern = "checker" })
  T.eq(r.ok, true, r.error)
  T.eq(F.px(s, 0, 0, "Body"), BLUE)
  T.eq(F.px(s, 1, 0, "Body"), RED)
  T.eq(F.px(s, 2, 0, "Body"), 0, "transparent pixels untouched")
  app.undo()
  T.eq(F.px(s, 0, 0, "Body"), RED)
end)

T.test("FX refuse non-RGB sprites", function()
  F.closeAll()
  app.sprite = Sprite(2, 2, ColorMode.INDEXED)
  T.eq(call("pixel_perfect", { layer = "Layer 1" }).error, "Effects work on RGB sprites. Convert with Sprite > Color Mode > RGB first.")
end)

T.test("gradient_fill fills the region, linear, without dither", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("gradient_fill", { layer = "Body", colors = { "#000000", "#ffffff" }, region = { x = 0, y = 1, w = 4, h = 1 } })
  T.eq(r.ok, true, r.error)
  T.eq(F.px(s, 0, 1, "Body"), pc.rgba(0, 0, 0, 255))
  T.eq(F.px(s, 3, 1, "Body"), pc.rgba(255, 255, 255, 255))
  T.eq(F.px(s, 0, 0, "Body"), RED, "outside the region untouched")
end)

T.test("pixel_perfect turns an L into a diagonal across all frames", function()
  F.closeAll()
  local s = Sprite(3, 2)
  app.sprite = s
  local img = s.cels[1].image:clone()
  img:drawPixel(0, 0, RED); img:drawPixel(1, 0, RED); img:drawPixel(1, 1, RED)
  s.cels[1].image = img
  s:newFrame(1)
  local r = call("pixel_perfect", { layer = "Layer 1", allFrames = true })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.changed, 2)
  T.eq(F.px(s, 1, 0, "Layer 1", 1), 0)
  T.eq(F.px(s, 1, 0, "Layer 1", 2), 0)
  app.undo()
  T.eq(F.px(s, 1, 0, "Layer 1", 2), RED, "one undo for all frames")
end)

T.test("snap_to_palette uses the sprite palette, or explains a missing project palette", function()
  F.closeAll()
  local s = F.rgbSprite()
  local pal = Palette(2)
  pal:setColor(0, Color{ r = 0, g = 0, b = 0 })
  pal:setColor(1, Color{ r = 250, g = 10, b = 10 })
  s:setPalette(pal)
  local r = call("snap_to_palette", { palette = "sprite" })
  T.eq(r.ok, true, r.error)
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(250, 10, 10, 255))
  T.eq(r.data.changed, 2)
  sprites.projectRoot = nil
  T.eq(call("snap_to_palette", {}).error, "This project has no palette. Pick one in Project settings, or use palette = \"sprite\".")
end)

T.test("snap_to_palette reads the project's palette.gpl", function()
  F.closeAll()
  local root = app.fs.joinPath(F.tmp, "fx proj " .. os.time())
  app.fs.makeAllDirectories(root)
  project.create(root, {})
  local pal = Palette(1)
  pal:setColor(0, Color{ r = 0, g = 0, b = 255 })
  project.savePalette(root, pal)
  sprites.projectRoot = root
  local s = F.rgbSprite()
  local r = call("snap_to_palette", { layer = "Body" })
  T.eq(r.ok, true, r.error)
  T.eq(F.px(s, 0, 0, "Body"), BLUE)
  sprites.projectRoot = nil
end)

T.test("selout darkens the outline toward the fill it borders", function()
  F.closeAll()
  local s = Sprite(5, 5)
  app.sprite = s
  local img = s.cels[1].image:clone()
  img:clear(pc.rgba(0, 0, 0, 255))
  for y = 1, 3 do for x = 1, 3 do img:drawPixel(x, y, pc.rgba(200, 100, 50, 255)) end end
  s.cels[1].image = img
  local r = call("selout", { layer = "Layer 1", darken = 0.5 })
  T.eq(r.ok, true, r.error)
  T.eq(F.px(s, 0, 2, "Layer 1"), pc.rgba(100, 50, 25, 255))
  T.eq(F.px(s, 0, 0, "Layer 1"), pc.rgba(100, 50, 25, 255), "corners use the diagonal fill")
  T.eq(F.px(s, 2, 2, "Layer 1"), pc.rgba(200, 100, 50, 255), "fill untouched")
end)

T.test("layer_style overlay, stroke and shadow", function()
  F.closeAll()
  local s = F.rgbSprite()
  T.eq(call("layer_style", { layer = "Body", style = "overlay", color = "#0000ff", amount = 1 }).ok, true)
  T.eq(F.px(s, 0, 0, "Body"), BLUE)
  app.undo()
  local st = call("layer_style", { layer = "Body", style = "stroke", color = "#0000ff", width = 1 })
  T.eq(st.ok, true, st.error)
  T.eq(st.data.newLayer, "Body stroke")
  T.eq(s.layers[1].name, "Body stroke", "stroke sits below the layer")
  T.eq(F.px(s, 2, 0, "Body stroke"), BLUE)
  T.eq(F.px(s, 0, 1, "Body stroke"), BLUE)
  T.eq(F.px(s, 2, 1, "Body stroke"), 0, "4-neighbour stroke, no diagonal corner")
  T.eq(F.px(s, 0, 0, "Body stroke"), 0, "not under the art")
  app.undo()
  T.eq(#s.layers, 1, "one undo removes the stroke layer")
  local sh = call("layer_style", { layer = "Body", style = "shadow", color = "#000000", offsetX = 1, offsetY = 1 })
  T.eq(sh.ok, true, sh.error)
  T.eq(F.px(s, 1, 1, "Body shadow"), pc.rgba(0, 0, 0, 255))
  T.eq(F.px(s, 2, 1, "Body shadow"), pc.rgba(0, 0, 0, 255))
end)

F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh test_fx`
Expected: failures (`Unknown tool: dither`, and so on). Add `"test_fx"` to the suite list first.

- [ ] **Step 3: Implement the target helper**

`extension/agent/tools/fxtarget.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")

local M = {}
local pc = app.pixelColor

function M.rgba(v)
  return pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v), pc.rgbaA(v)
end

local function editableLayers(layers, out)
  for _, l in ipairs(layers) do
    if l.isGroup then editableLayers(l.layers, out)
    elseif l.isEditable and not l.isTilemap and not l.isReference then out[#out + 1] = l end
  end
  return out
end

function M.resolve(args, opts)
  local s = edit.editableSprite(args.sprite)
  if s.colorMode ~= ColorMode.RGB then
    error("Effects work on RGB sprites. Convert with Sprite > Color Mode > RGB first.", 0)
  end
  local layers
  if args.layer then layers = { edit.drawableLayer(s, args.layer) }
  elseif opts and opts.layerOptional then layers = editableLayers(s.layers, {})
  else error("Name the layer to work on.", 0) end
  local frames = {}
  if args.allFrames then
    for _, f in ipairs(s.frames) do frames[#frames + 1] = f end
  else
    frames[1] = sprites.frame(s, args.frame)
  end
  local r
  if args.region then
    r = { x = edit.int(args.region.x), y = edit.int(args.region.y), w = edit.int(args.region.w), h = edit.int(args.region.h) }
  elseif not s.selection.isEmpty then
    local b = s.selection.bounds
    r = { x = b.x, y = b.y, w = b.width, h = b.height }
  else
    r = { x = 0, y = 0, w = s.width, h = s.height }
  end
  local x1, y1 = math.max(0, r.x), math.max(0, r.y)
  local x2, y2 = math.min(s.width, r.x + r.w), math.min(s.height, r.y + r.h)
  if x2 <= x1 or y2 <= y1 then error("Region is outside the sprite.", 0) end
  return s, layers, frames, { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Runs fn(img, origin, frame, layer) on every layer x frame inside ONE transaction; commits changed images.
function M.apply(s, layers, frames, label, fn)
  local total = 0
  edit.transaction(s, label, function()
    for _, layer in ipairs(layers) do
      for _, f in ipairs(frames) do
        local img, o = edit.canvasImage(s, layer, f)
        local n = fn(img, o, f, layer) or 0
        if n > 0 then
          edit.commit(s, layer, f, img, o)
          total = total + n
        end
      end
    end
  end)
  return total
end

return M
```

- [ ] **Step 4: Implement the FX**

`extension/agent/tools/fx.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")
local target = require("agent.tools.fxtarget")
local project = require("agent.project")
local fxm = require("agent.fx.math")

local M = {}
local pc = app.pixelColor
local rgba = target.rgba

local function hexValue(hex)
  local r, g, b, a = color.parseHex(hex)
  return pc.rgba(r, g, b, a)
end

local function result(s, layers, changed, extra)
  local out = { sprite = sprites.name(s), layer = #layers == 1 and layers[1].name or nil, changed = changed }
  for k, v in pairs(extra or {}) do out[k] = v end
  return out
end

-- Iterates the target rectangle in sprite coordinates, giving image coordinates too.
local function each(r, o, fn)
  for y = r.y, r.y + r.h - 1 do
    for x = r.x, r.x + r.w - 1 do fn(x, y, x - o.x, y - o.y) end
  end
end

function M.dither(args)
  local s, layers, frames, r = target.resolve(args)
  local va, vb = hexValue(args.colorA), hexValue(args.colorB)
  local pattern, amount, onlyOpaque = args.pattern or "bayer4", args.amount, args.onlyOpaque ~= false
  local n = target.apply(s, layers, frames, "dither", function(img, o)
    local c = 0
    each(r, o, function(x, y, ix, iy)
      if not onlyOpaque or pc.rgbaA(img:getPixel(ix, iy)) > 0 then
        img:drawPixel(ix, iy, fxm.ditherPick(pattern, x, y, amount) and vb or va)
        c = c + 1
      end
    end)
    return c
  end)
  return result(s, layers, n)
end

function M.gradient_fill(args)
  local s, layers, frames, r = target.resolve(args)
  local values = {}
  for i = 1, #args.colors do values[i] = hexValue(args.colors[i]) end
  local radial = args.type == "radial"
  local cx, cy = r.x + (r.w - 1) / 2, r.y + (r.h - 1) / 2
  local radius = math.sqrt((r.w / 2) ^ 2 + (r.h / 2) ^ 2)
  local onlyOpaque = args.onlyOpaque == true
  local n = target.apply(s, layers, frames, "gradient", function(img, o)
    local c = 0
    each(r, o, function(x, y, ix, iy)
      if not onlyOpaque or pc.rgbaA(img:getPixel(ix, iy)) > 0 then
        local t = radial and fxm.radialT(x, y, cx, cy, radius) or fxm.linearT(x, y, r, args.angle or 0)
        img:drawPixel(ix, iy, values[fxm.gradientIndex(t, #values, args.dither, x, y)])
        c = c + 1
      end
    end)
    return c
  end)
  return result(s, layers, n)
end

function M.pixel_perfect(args)
  local s, layers, frames, r = target.resolve(args)
  local n = target.apply(s, layers, frames, "pixel-perfect", function(img, o)
    local opaque = {}
    for yy = 0, r.h - 1 do
      for xx = 0, r.w - 1 do
        opaque[yy * r.w + xx + 1] = pc.rgbaA(img:getPixel(r.x + xx - o.x, r.y + yy - o.y)) > 0
      end
    end
    local removed = fxm.pixelPerfectRemovals(opaque, r.w, r.h)
    for _, p in ipairs(removed) do img:drawPixel(r.x + p.x - o.x, r.y + p.y - o.y, 0) end
    return #removed
  end)
  return result(s, layers, n)
end

local function paletteColors(s, which)
  local pal
  if which == "sprite" then
    pal = s.palettes[1]
  else
    local root = sprites.projectRoot
    local path = root and app.fs.joinPath(root, project.DIR, "palette.gpl")
    if not path or not app.fs.isFile(path) then
      error('This project has no palette. Pick one in Project settings, or use palette = "sprite".', 0)
    end
    pal = Palette{ fromFile = path }
  end
  local list, set = {}, {}
  for i = 0, #pal - 1 do
    local c = pal:getColor(i)
    if c.alpha > 0 then
      list[#list + 1] = { r = c.red, g = c.green, b = c.blue }
      set[c.red * 65536 + c.green * 256 + c.blue] = true
    end
  end
  return list, set
end

function M.snap_to_palette(args)
  local s, layers, frames = target.resolve(args, { layerOptional = true })
  local list, set = paletteColors(s, args.palette or "project")
  local n = target.apply(s, layers, frames, "snap to palette", function(img)
    local c = 0
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local r, g, b, a = rgba(img:getPixel(x, y))
        if a > 0 and not set[r * 65536 + g * 256 + b] then
          local p = list[fxm.nearest(r, g, b, list)]
          img:drawPixel(x, y, pc.rgba(p.r, p.g, p.b, a))
          c = c + 1
        end
      end
    end
    return c
  end)
  return result(s, layers, n)
end

local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local N8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }

function M.selout(args)
  local s, layers, frames, r = target.resolve(args)
  local darken = args.darken or 0.35
  local n = target.apply(s, layers, frames, "selout", function(img, o)
    local w, h = img.width, img.height
    local function A(x, y) return x >= 0 and y >= 0 and x < w and y < h and pc.rgbaA(img:getPixel(x, y)) > 0 end
    local function isEdge(x, y)
      if not A(x, y) then return false end
      for _, d in ipairs(N4) do if not A(x + d[1], y + d[2]) then return true end end
      return false
    end
    local edges, counts = {}, {}
    each(r, o, function(_, _, ix, iy)
      if isEdge(ix, iy) then
        local v = img:getPixel(ix, iy)
        edges[#edges + 1] = { ix, iy, v }
        counts[v] = (counts[v] or 0) + 1
      end
    end)
    local outline = args.outlineColor and hexValue(args.outlineColor)
    if not outline then
      local best = 0
      for v, k in pairs(counts) do if k > best then outline, best = v, k end end
    end
    local src = img:clone()
    local c = 0
    for _, e in ipairs(edges) do
      local ix, iy, v = e[1], e[2], e[3]
      if v == outline then
        local fill
        for _, d in ipairs(N4) do
          local nx, ny = ix + d[1], iy + d[2]
          if A(nx, ny) and not isEdge(nx, ny) then fill = src:getPixel(nx, ny) break end
        end
        if not fill then
          for _, d in ipairs(N8) do
            local nx, ny = ix + d[1], iy + d[2]
            if A(nx, ny) and src:getPixel(nx, ny) ~= outline then fill = src:getPixel(nx, ny) break end
          end
        end
        if fill then
          local fr, fg, fb = rgba(fill)
          local dr, dg, db = fxm.darken(fr, fg, fb, darken)
          img:drawPixel(ix, iy, pc.rgba(dr, dg, db, pc.rgbaA(v)))
          c = c + 1
        end
      end
    end
    return c
  end)
  return result(s, layers, n)
end

local function newLayerBelow(s, source, name)
  local l = s:newLayer()
  l.name = name
  l.stackIndex = source.stackIndex
  return l
end

function M.layer_style(args)
  local s, layers, frames, r = target.resolve(args)
  local source = layers[1]
  local value = hexValue(args.color)
  if args.style == "overlay" then
    local cr, cg, cb = color.parseHex(args.color)
    local amount = args.amount or 0.5
    local n = target.apply(s, layers, frames, "color overlay", function(img, o)
      local c = 0
      each(r, o, function(_, _, ix, iy)
        local pr, pg, pb, pa = rgba(img:getPixel(ix, iy))
        if pa > 0 then
          local mr, mg, mb = fxm.mix(pr, pg, pb, cr, cg, cb, amount)
          img:drawPixel(ix, iy, pc.rgba(mr, mg, mb, pa))
          c = c + 1
        end
      end)
      return c
    end)
    return result(s, layers, n)
  end

  local name = source.name .. (args.style == "stroke" and " stroke" or " shadow")
  local total = 0
  edit.transaction(s, args.style, function()
    local dest = newLayerBelow(s, source, name)
    for _, f in ipairs(frames) do
      local img, o = edit.canvasImage(s, source, f)
      local w, h = img.width, img.height
      local out = Image(img.spec)
      out:clear(0)
      local opaque = {}
      for y = 0, h - 1 do for x = 0, w - 1 do opaque[y * w + x + 1] = pc.rgbaA(img:getPixel(x, y)) > 0 end end
      if args.style == "stroke" then
        for _, p in ipairs(fxm.dilate(opaque, w, h, args.width or 1)) do
          local sx, sy = p.x + o.x, p.y + o.y
          if sx >= r.x - (args.width or 1) and sy >= r.y - (args.width or 1) and sx < r.x + r.w + (args.width or 1) and sy < r.y + r.h + (args.width or 1) then
            out:drawPixel(p.x, p.y, value)
            total = total + 1
          end
        end
      else
        local dx, dy = args.offsetX or 1, args.offsetY or 1
        for y = 0, h - 1 do
          for x = 0, w - 1 do
            if opaque[y * w + x + 1] and x + dx >= 0 and y + dy >= 0 and x + dx < w and y + dy < h then
              out:drawPixel(x + dx, y + dy, value)
              total = total + 1
            end
          end
        end
      end
      edit.commit(s, dest, f, out, o)
    end
  end)
  return result(s, layers, total, { newLayer = name })
end

return M
```

In `init.lua`, add `local fx = require("agent.tools.fx")`, and to the `"edit"` register call add:
```lua
  dither = fx.dither,
  gradient_fill = fx.gradient_fill,
  pixel_perfect = fx.pixel_perfect,
  snap_to_palette = fx.snap_to_palette,
  selout = fx.selout,
  layer_style = fx.layer_style,
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add extension/agent/tools/fxtarget.lua extension/agent/tools/fx.lua extension/agent/tools/init.lua tests/lua
git commit -m "feat(extension): dither, gradient fill, pixel-perfect, snap to palette, selout, layer styles"
```

---

### Task 4: Normal maps and read-only previews (Lua)

**Files:**
- Create: `extension/agent/tools/maps.lua`
- Modify: `extension/agent/tools/inspect.lua` (extract `saveSnapshot`), `extension/agent/tools/init.lua`
- Test: `tests/lua/test_maps.lua` (add it to the suite list)

**Interfaces:**
- `inspect.saveSnapshot(img, sprite, info, maxSize) -> {pngPath, width, height, scale, ...info}`. `get_snapshot` uses it too.
- Handlers:
  - `make_normal_map` (edit) `-> {normal, height?, frames}`, with paths relative to the project when there is one;
  - `light_preview` (read) and `check_readability` (read), both returning snapshot results.

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_maps.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local inspect = require("agent.tools.inspect")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
local dir = app.fs.joinPath(F.tmp, "maps " .. os.time())
app.fs.makeAllDirectories(dir)
inspect.snapshotDir = F.tmp

local function square(name, frames)
  local s = Sprite(5, 5)
  local img = s.cels[1].image:clone()
  img:clear(pc.rgba(120, 120, 120, 255))
  s.cels[1].image = img
  for _ = 2, frames or 1 do s:newFrame(1) end
  s:saveAs(app.fs.joinPath(dir, name))
  app.sprite = s
  return s
end

T.test("make_normal_map saves companion height and normal sprites with every frame", function()
  F.closeAll()
  local s = square("knight.aseprite", 2)
  local r = call("make_normal_map", { layer = "Layer 1", source = "edges", bevel = 3 })
  T.eq(r.ok, true, r.error)
  T.eq(#app.sprites, 1, "companions are closed after saving")
  T.eq(app.sprite == s, true)
  local n = Sprite{ fromFile = app.fs.joinPath(dir, "knight_normal.aseprite") }
  T.eq(#n.frames, 2)
  local img = n.cels[1].image
  local c = img:getPixel(2 - n.cels[1].position.x, 2 - n.cels[1].position.y)
  T.deepEq({ pc.rgbaR(c), pc.rgbaG(c), pc.rgbaB(c) }, { 128, 128, 255 })
  local left = img:getPixel(1 - n.cels[1].position.x, 2 - n.cels[1].position.y)
  T.eq(pc.rgbaR(left) < 128, true)
  n:close()
  T.eq(app.fs.isFile(app.fs.joinPath(dir, "knight_height.aseprite")), true)
  T.eq(call("make_normal_map", { layer = "Layer 1" }).ok, true, "re-running replaces the companions")
end)

T.test("make_normal_map needs a saved sprite and a closed companion", function()
  F.closeAll()
  app.sprite = Sprite(3, 3)
  T.eq(call("make_normal_map", { layer = "Layer 1" }).error, "Save the sprite first: maps are saved next to it.")
  F.closeAll()
  square("slime.aseprite")
  call("make_normal_map", { layer = "Layer 1" })
  local open = Sprite{ fromFile = app.fs.joinPath(dir, "slime_normal.aseprite") }
  app.sprite = app.sprites[1]
  T.eq(call("make_normal_map", { sprite = "slime.aseprite", layer = "Layer 1" }).error, "Close slime_normal.aseprite first: it will be replaced.")
  open:close()
end)

T.test("check_readability returns value, silhouette or both images without changing the sprite", function()
  F.closeAll()
  local s = F.rgbSprite()
  local before = F.px(s, 0, 0, "Body")
  local both = call("check_readability", { mode = "both" })
  T.eq(both.ok, true, both.error)
  T.eq(both.data.mode, "both")
  local single = call("check_readability", { mode = "values" })
  T.eq(both.data.width / both.data.scale > single.data.width / single.data.scale, true, "both views side by side")
  T.eq(F.px(s, 0, 0, "Body"), before)
  os.remove(both.data.pngPath)
  os.remove(single.data.pngPath)
end)

T.test("light_preview renders a lit image and leaves the sprite alone", function()
  F.closeAll()
  local s = square("lit.aseprite")
  local r = call("light_preview", { lightX = -1, lightY = 1, lightZ = 0.5 })
  T.eq(r.ok, true, r.error)
  T.eq(app.fs.isFile(r.data.pngPath), true)
  T.eq(#app.sprites, 1)
  os.remove(r.data.pngPath)
end)

F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh test_maps` (after adding it to the suite list)
Expected: `Unknown tool: make_normal_map`.

- [ ] **Step 3: Extract saveSnapshot**

In `inspect.lua`, split the save part of `get_snapshot` into:
```lua
-- Scales an image for Claude and saves it as a snapshot PNG in the bridge's folder.
function M.saveSnapshot(img, sprite, info, maxSize)
  if not M.snapshotDir then error("Snapshot directory unknown (bridge not connected).", 0) end
  local scale = M.snapshotScale(img.width, img.height, maxSize or 512)
  if scale ~= 1 then
    img:resize(math.max(1, math.floor(img.width * scale + 0.5)), math.max(1, math.floor(img.height * scale + 0.5)))
  end
  counter = counter + 1
  local path = app.fs.joinPath(M.snapshotDir, ("aseagent-%d-%d.png"):format(os.time(), counter))
  img:saveAs{ filename = path, palette = sprite.palettes[1] }
  local out = { pngPath = path, sprite = sprites.name(sprite), width = img.width, height = img.height, scale = scale }
  for k, v in pairs(info or {}) do out[k] = v end
  return out
end
```
(move `local counter = 0` above it). `get_snapshot` then ends with:
```lua
  return M.saveSnapshot(img, s, { frame = frame.frameNumber, layer = args.layer, region = region }, args.maxSize)
```
and loses its own save and scale code. (The "snapshot directory unknown" check now happens in `saveSnapshot`, and the existing test for it still passes.)

- [ ] **Step 4: Implement maps**

`extension/agent/tools/maps.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local inspect = require("agent.tools.inspect")
local fxm = require("agent.fx.math")

local M = {}
local pc = app.pixelColor

-- Luminance and opacity grids for an RGB image.
local function grids(img)
  local w, h = img.width, img.height
  local lum, opaque = {}, {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local v = img:getPixel(x, y)
      local i = y * w + x + 1
      opaque[i] = pc.rgbaA(v) > 0
      lum[i] = fxm.luminance(pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v))
    end
  end
  return lum, opaque, w, h
end

local function layerImage(s, layerName, frame)
  local img = Image(s.width, s.height, ColorMode.RGB)
  img:clear(0)
  if layerName then
    local cel = sprites.layer(s, layerName):cel(frame)
    if cel then img:drawImage(cel.image, cel.position) end
  else
    img:drawSprite(s, frame)
  end
  return img
end

local function companionPath(s, suffix)
  return app.fs.joinPath(app.fs.filePath(s.filename), app.fs.fileTitle(s.filename) .. suffix .. ".aseprite")
end

local function ensureClosed(path)
  for _, o in ipairs(app.sprites) do
    if o.filename == path then error("Close " .. app.fs.fileName(path) .. " first: it will be replaced.", 0) end
  end
end

local function writeCompanion(s, path, layerName, render)
  local prev = app.sprite
  local out = Sprite(s.width, s.height, ColorMode.RGB)
  for i = 2, #s.frames do out:newEmptyFrame(i) end
  for i, f in ipairs(s.frames) do out.frames[i].duration = f.duration end
  out.layers[1].name = layerName
  for i, f in ipairs(s.frames) do
    local img = render(f)
    local cel = out.layers[1]:cel(i)
    if cel then cel.image = img; cel.position = Point(0, 0) else out:newCel(out.layers[1], i, img, Point(0, 0)) end
  end
  out:saveAs(path)
  out:close()
  if prev then app.sprite = prev end
end

function M.make_normal_map(args)
  local s = edit.editableSprite(args.sprite)
  if app.fs.filePath(s.filename) == "" then error("Save the sprite first: maps are saved next to it.", 0) end
  sprites.layer(s, args.layer)
  local normalPath, heightPath = companionPath(s, "_normal"), companionPath(s, "_height")
  ensureClosed(normalPath)
  if args.saveHeight ~= false then ensureClosed(heightPath) end
  local source, bevel = args.source or "both", edit.int(args.bevel or 3)
  local strength, convention, quantize = args.strength or 2, args.convention or "opengl", args.quantize or "off"
  local function heightsFor(f)
    local lum, opaque, w, h = grids(layerImage(s, args.layer, f))
    return fxm.heights(lum, opaque, w, h, source, bevel), opaque, w, h
  end
  writeCompanion(s, normalPath, "Normal", function(f)
    local hts, opaque, w, h = heightsFor(f)
    local normals = fxm.normals(hts, opaque, w, h, strength, convention, quantize)
    local img = Image(w, h, ColorMode.RGB)
    img:clear(0)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local n = normals[y * w + x + 1]
        if n then
          local r, g, b = fxm.encodeNormal(n[1], n[2], n[3])
          img:drawPixel(x, y, pc.rgba(r, g, b, 255))
        end
      end
    end
    return img
  end)
  local result = { normal = sprites.name({ filename = normalPath }), frames = #s.frames }
  if args.saveHeight ~= false then
    writeCompanion(s, heightPath, "Height", function(f)
      local hts, opaque, w, h = heightsFor(f)
      local img = Image(w, h, ColorMode.RGB)
      img:clear(0)
      for i = 1, w * h do
        if opaque[i] then
          local v = math.floor(hts[i] * 255 + 0.5)
          img:drawPixel((i - 1) % w, (i - 1) // w, pc.rgba(v, v, v, 255))
        end
      end
      return img
    end)
    result.height = sprites.name({ filename = heightPath })
  end
  return result
end

function M.check_readability(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local src = layerImage(s, nil, frame)
  local mode = args.mode or "both"
  local function view(kind)
    local img = Image(src.width, src.height, ColorMode.RGB)
    img:clear(0)
    for y = 0, src.height - 1 do
      for x = 0, src.width - 1 do
        local v = src:getPixel(x, y)
        local a = pc.rgbaA(v)
        if a > 0 then
          if kind == "values" then
            local l = math.floor(fxm.luminance(pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v)) + 0.5)
            img:drawPixel(x, y, pc.rgba(l, l, l, a))
          else
            img:drawPixel(x, y, pc.rgba(40, 40, 40, 255))
          end
        end
      end
    end
    return img
  end
  local out
  if mode == "both" then
    local a, b = view("values"), view("silhouette")
    out = Image(a.width * 2 + 2, a.height, ColorMode.RGB)
    out:clear(0)
    out:drawImage(a, Point(0, 0))
    out:drawImage(b, Point(a.width + 2, 0))
  else
    out = view(mode)
  end
  return inspect.saveSnapshot(out, s, { frame = frame.frameNumber, mode = mode })
end

function M.light_preview(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local base = layerImage(s, args.layer, frame)
  local lum, opaque, w, h = grids(base)
  local hts = fxm.heights(lum, opaque, w, h, args.source or "both", edit.int(args.bevel or 3))
  local normals = fxm.normals(hts, opaque, w, h, args.strength or 2, "opengl", "off")
  local lz, ambient = args.lightZ or 0.6, args.ambient or 0.25
  local out = Image(w, h, ColorMode.RGB)
  out:clear(0)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local n = normals[y * w + x + 1]
      if n then
        local k = fxm.shade(n, args.lightX, args.lightY, lz, ambient)
        local v = base:getPixel(x, y)
        out:drawPixel(x, y, pc.rgba(
          math.min(255, math.floor(pc.rgbaR(v) * k + 0.5)),
          math.min(255, math.floor(pc.rgbaG(v) * k + 0.5)),
          math.min(255, math.floor(pc.rgbaB(v) * k + 0.5)),
          pc.rgbaA(v)))
      end
    end
  end
  return inspect.saveSnapshot(out, s, { frame = frame.frameNumber, light = { args.lightX, args.lightY, lz } })
end

return M
```
> `sprites.name({ filename = path })` works because `sprites.name` only reads `.filename`.

In `init.lua`, add `local maps = require("agent.tools.maps")`. Register `make_normal_map` as `"edit"`, and `check_readability` and `light_preview` as `"read"`.

- [ ] **Step 5: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add extension/agent/tools/maps.lua extension/agent/tools/inspect.lua extension/agent/tools/init.lua tests/lua
git commit -m "feat(extension): height/normal map companions, readability and lighting previews"
```

---

### Task 5: Built-in FX, tool setup, and extensions (Lua)

**Files:**
- Create: `extension/agent/tools/builtin.lua`, `extension/agent/tools/toolstate.lua`, `extension/agent/tools/extensions.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_builtin_toolstate.lua` (add it to the suite list)

**Interfaces:**
- Handlers:
  - `builtin_fx` (edit)
  - `get_tool_state` (read), `set_tool` (registered as kind `"setting"`)
  - `list_installed_extensions` (read), `run_extension_command` (edit)
- `extensions.DENY` is the set of refused command ids.

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_builtin_toolstate.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local extensions = require("agent.tools.extensions")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end

T.test("builtin invert changes the layer in one undo and respects a region", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("builtin_fx", { layer = "Body", effect = "invert", region = { x = 0, y = 0, w = 1, h = 1 } })
  T.eq(r.ok, true, r.error)
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(0, 255, 255, 255))
  T.eq(F.px(s, 1, 0, "Body"), pc.rgba(0, 255, 0, 255), "outside the region untouched")
  T.eq(s.selection.isEmpty, true, "the artist's (empty) selection is restored")
  app.undo()
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(255, 0, 0, 255))
end)

T.test("builtin blur and replace_color map to Aseprite's commands", function()
  F.closeAll()
  local s = F.rgbSprite()
  T.eq(call("builtin_fx", { layer = "Body", effect = "replace_color", from = "#ff0000", to = "#0000ff" }).ok, true)
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(0, 0, 255, 255))
  T.eq(call("builtin_fx", { layer = "Body", effect = "blur", size = 3 }).ok, true)
  T.eq(call("builtin_fx", { layer = "Body", effect = "sharpen", size = 9 }).error, "sharpen supports sizes 3, 5 and 7.")
end)

T.test("set_tool applies tool, brush, ink, colors and symmetry; get_tool_state reports them", function()
  F.closeAll()
  F.rgbSprite()
  local r = call("set_tool", { tool = "pencil", brushSize = 3, brushShape = "square", ink = "shading", foreground = "#102030", symmetry = "horizontal" })
  T.eq(r.ok, true, r.error)
  local st = call("get_tool_state").data
  T.eq(st.tool, "pencil")
  T.eq(st.brush.size, 3)
  T.eq(st.brush.shape, "square")
  T.eq(st.ink, "shading")
  T.eq(st.foreground, "#102030")
  T.eq(st.symmetry, "horizontal")
end)

T.test("set_tool reports bad values plainly and notes symmetry needs a sprite", function()
  F.closeAll()
  T.eq(call("set_tool", { tool = "lightsaber" }).error, "Unknown tool 'lightsaber'.")
  local r = call("set_tool", { symmetry = "both", brushSize = 2 })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.skipped[1], "symmetry (no sprite open)")
end)

T.test("extension commands: dangerous ones are refused, unknown ones explained", function()
  T.eq(extensions.DENY.Exit, true)
  T.eq(call("run_extension_command", { command = "Exit" }).error, "The command 'Exit' can't be run from the chat.")
  T.eq(call("run_extension_command", { command = "NoSuchCommandXyz" }).error,
    "Aseprite has no command 'NoSuchCommandXyz'. Check the extension's menu or docs for its command id.")
  local list = call("list_installed_extensions")
  T.eq(list.ok, true, list.error)
  T.eq(type(list.data.extensions), "table")
end)

F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh builtin_toolstate` (after adding it to the suite list)
Expected: failures (unknown tools).

- [ ] **Step 3: Implement**

`extension/agent/tools/builtin.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local function col(hex)
  local r, g, b, a = color.parseHex(hex)
  return Color{ r = r, g = g, b = b, a = a }
end

local function kernel(kind, size, allowed)
  size = size and edit.int(size) or allowed[1]
  for _, v in ipairs(allowed) do
    if v == size then return ("%s-%dx%d"):format(kind, size, size) end
  end
  local list = {}
  for i, v in ipairs(allowed) do list[i] = tostring(v) end
  error(("%s supports sizes %s and %s."):format(kind, table.concat(list, ", ", 1, #list - 1), list[#list]), 0)
end

local EFFECTS = {
  brightness_contrast = function(a) return "BrightnessContrast", { ui = false, brightness = a.brightness or 0, contrast = a.contrast or 0 } end,
  hue_saturation = function(a) return "HueSaturation", { ui = false, hue = a.hue or 0, saturation = a.saturation or 0, lightness = a.lightness or 0, mode = "hsl" } end,
  invert = function() return "InvertColor", { ui = false } end,
  despeckle = function(a) local n = edit.int(a.size or 3) return "Despeckle", { ui = false, width = n, height = n } end,
  blur = function(a) return "ConvolutionMatrix", { ui = false, fromResource = kernel("blur", a.size, { 3, 5, 7, 9 }) } end,
  sharpen = function(a) return "ConvolutionMatrix", { ui = false, fromResource = kernel("sharpen", a.size, { 3, 5, 7 }) } end,
  find_edges = function() return "ConvolutionMatrix", { ui = false, fromResource = "edges-find" } end,
  replace_color = function(a)
    if not a.from or not a.to then error("replace_color needs from and to.", 0) end
    return "ReplaceColor", { ui = false, from = col(a.from), to = col(a.to), tolerance = a.tolerance and edit.int(a.tolerance) or 0 }
  end,
}

function M.builtin_fx(args)
  local build = EFFECTS[args.effect]
  if not build then error("Unknown effect '" .. tostring(args.effect) .. "'.", 0) end
  local s = edit.editableSprite(args.sprite)
  local layer = edit.drawableLayer(s, args.layer)
  local frame = sprites.frame(s, args.frame)
  local command, params = build(args)
  edit.transaction(s, (tostring(args.effect):gsub("_", " ")), function()
    local saved = Selection()
    saved:add(s.selection)
    app.layer = layer
    app.frame = frame
    if args.region then
      s.selection = Selection(Rectangle(edit.int(args.region.x), edit.int(args.region.y), edit.int(args.region.w), edit.int(args.region.h)))
    end
    app.command[command](params)
    if args.region then s.selection = saved end
  end)
  return { sprite = sprites.name(s), layer = layer.name, frame = frame.frameNumber, effect = args.effect }
end

return M
```

`extension/agent/tools/toolstate.lua`:
```lua
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local INKS = { simple = "SIMPLE", alpha_compositing = "ALPHA_COMPOSITING", copy_color = "COPY_COLOR", lock_alpha = "LOCK_ALPHA", shading = "SHADING" }
local SHAPES = { circle = "CIRCLE", square = "SQUARE", line = "LINE" }
local SYMMETRY = { none = 0, horizontal = 1, vertical = 2, both = 3 }
local TILED = { none = 0, x = 1, y = 2, both = 3 }

local function reverse(map, enum)
  local out = {}
  for name, key in pairs(map) do
    local v = enum and enum[key] or key
    if v ~= nil then out[v] = name end
  end
  return out
end

function M.get_tool_state()
  local id = app.tool and app.tool.id or "pencil"
  local tp = app.preferences.tool(id)
  local state = {
    tool = id,
    brush = { size = tp.brush.size, shape = reverse(SHAPES, BrushType)[tp.brush.type] or tostring(tp.brush.type), angle = tp.brush.angle },
    ink = reverse(INKS, Ink)[tp.ink] or tostring(tp.ink),
    foreground = color.fromColor(app.fgColor),
    background = color.fromColor(app.bgColor),
  }
  if app.sprite then
    local dp = app.preferences.document(app.sprite)
    state.symmetry = reverse(SYMMETRY)[dp.symmetry.mode] or tostring(dp.symmetry.mode)
    state.tiled = reverse(TILED)[dp.tiled.mode] or tostring(dp.tiled.mode)
  end
  return state
end

local function colorOf(hex)
  local r, g, b, a = color.parseHex(hex)
  return Color{ r = r, g = g, b = b, a = a }
end

function M.set_tool(args)
  if args.tool then
    local ok = pcall(function() app.tool = args.tool end)
    if not ok or not app.tool or app.tool.id ~= args.tool then error("Unknown tool '" .. args.tool .. "'.", 0) end
  end
  local tp = app.preferences.tool(app.tool and app.tool.id or "pencil")
  if args.brushSize then tp.brush.size = edit.int(args.brushSize) end
  if args.brushShape then tp.brush.type = BrushType[SHAPES[args.brushShape]] end
  if args.brushAngle then tp.brush.angle = edit.int(args.brushAngle) end
  if args.ink then tp.ink = Ink[INKS[args.ink]] end
  if args.foreground then app.fgColor = colorOf(args.foreground) end
  if args.background then app.bgColor = colorOf(args.background) end
  local skipped = {}
  if args.symmetry or args.tiled then
    if app.sprite then
      local dp = app.preferences.document(app.sprite)
      if args.symmetry then dp.symmetry.mode = SYMMETRY[args.symmetry] end
      if args.tiled then dp.tiled.mode = TILED[args.tiled] end
    else
      if args.symmetry then skipped[#skipped + 1] = "symmetry (no sprite open)" end
      if args.tiled then skipped[#skipped + 1] = "tiled mode (no sprite open)" end
    end
  end
  app.refresh()
  local state = M.get_tool_state()
  if #skipped > 0 then state.skipped = skipped end
  return state
end

return M
```

`extension/agent/tools/extensions.lua`:
```lua
local M = {}

M.DENY = {}
for _, id in ipairs{ "Exit", "CloseFile", "CloseAllFiles", "SaveFile", "SaveFileAs", "SaveFileCopyAs",
  "ExportSpriteSheet", "Options", "KeyboardShortcuts", "RunScript", "DeveloperConsole", "OpenScriptFolder", "AgentChat" } do
  M.DENY[id] = true
end

function M.list_installed_extensions()
  local dir = app.fs.joinPath(app.fs.userConfigPath, "extensions")
  local out = {}
  if app.fs.isDirectory(dir) then
    for _, name in ipairs(app.fs.listFiles(dir)) do
      local f = io.open(app.fs.joinPath(dir, name, "package.json"), "r")
      if f then
        local ok, pkg = pcall(json.decode, f:read("a"))
        f:close()
        if ok and pkg then
          out[#out + 1] = {
            name = tostring(pkg.name or name),
            displayName = tostring(pkg.displayName or pkg.name or name),
            version = pkg.version and tostring(pkg.version) or nil,
            description = pkg.description and tostring(pkg.description) or nil,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.displayName:lower() < b.displayName:lower() end)
  return { extensions = out, note = "Commands added by extensions are named by their authors; check each extension's menu or docs." }
end

function M.run_extension_command(args)
  local id = tostring(args.command)
  if M.DENY[id] then error("The command '" .. id .. "' can't be run from the chat.", 0) end
  local ok, fn = pcall(function() return app.command[id] end)
  if not ok or not fn then
    error("Aseprite has no command '" .. id .. "'. Check the extension's menu or docs for its command id.", 0)
  end
  fn()
  app.refresh()
  return { command = id, ran = true }
end

return M
```

In `init.lua`:
- Add these requires: `local builtin = require("agent.tools.builtin")`, `local toolstate = require("agent.tools.toolstate")`, `local extensions = require("agent.tools.extensions")`.
- Register `get_tool_state` and `list_installed_extensions` as `"read"`; `builtin_fx` and `run_extension_command` as `"edit"`; and add a third call:
```lua
registry.register({ set_tool = toolstate.set_tool }, "setting")
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.
> If `pcall(function() app.tool = args.tool end)` succeeds for unknown ids but leaves the tool unchanged, the `app.tool.id ~= args.tool` check still gives the right error. If Aseprite's `Selection()` has no `:add`, save the selection as `Selection(s.selection.bounds)` when it isn't empty, and as an empty `Selection()` otherwise.

- [ ] **Step 5: Commit**

```bash
git add extension/agent/tools/builtin.lua extension/agent/tools/toolstate.lua extension/agent/tools/extensions.lua extension/agent/tools/init.lua tests/lua
git commit -m "feat(extension): Aseprite built-in FX, tool setup, and extension commands"
```

---

### Task 6: Custom scripts (Lua)

**Files:**
- Create: `extension/agent/tools/scripts.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_scripts.lua` (add it to the suite list)

**Interfaces:**
- `scripts.dir` is nil by default; tests override it.
- `scripts.folder() -> path`
- Handlers: `write_script` (edit) `-> {name, path}`; `run_script` (edit) `-> {name, output}`.

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_scripts.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local scripts = require("agent.tools.scripts")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end
scripts.dir = app.fs.joinPath(F.tmp, "scripts " .. os.time())

T.test("write_script saves a commented script into the Agent folder", function()
  local r = call("write_script", { name = "Say hi", description = "Prints a greeting", code = "print('hi')" })
  T.eq(r.ok, true, r.error)
  local f = io.open(r.data.path, "r"); local text = f:read("a"); f:close()
  T.eq(text:find("-- Prints a greeting", 1, true) ~= nil, true)
  T.eq(text:find("print('hi')", 1, true) ~= nil, true)
end)

T.test("run_script runs once, returns printed output and restores print", function()
  local realPrint = print
  local r = call("run_script", { name = "Say hi" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.output, "hi")
  T.eq(print, realPrint)
end)

T.test("script edits are one undo step, and a failing script rolls back", function()
  F.closeAll()
  local s = F.rgbSprite()
  call("write_script", { name = "Paint", description = "Paints one pixel", code = [[
local s = app.sprite
local cel = s.cels[1]
local img = cel.image:clone()
img:drawPixel(3, 2, app.pixelColor.rgba(0, 0, 255, 255))
cel.image = img
]] })
  T.eq(call("run_script", { name = "Paint" }).ok, true)
  T.eq(F.px(s, 3, 2, "Body"), pc.rgba(0, 0, 255, 255))
  app.undo()
  T.eq(F.px(s, 3, 2, "Body"), 0)
  call("write_script", { name = "Broken", description = "Fails halfway", code = [[
local cel = app.sprite.cels[1]
local img = cel.image:clone()
img:drawPixel(2, 2, app.pixelColor.rgba(1, 1, 1, 255))
cel.image = img
error("boom")
]] })
  local bad = call("run_script", { name = "Broken" })
  T.eq(bad.ok, false)
  T.eq(bad.error:find("boom", 1, true) ~= nil, true, bad.error)
  T.eq(F.px(s, 2, 2, "Body"), 0, "rolled back")
end)

T.test("syntax errors and missing scripts are reported", function()
  call("write_script", { name = "Syntax", description = "Bad", code = "local = 1" })
  local r = call("run_script", { name = "Syntax" })
  T.eq(r.ok, false)
  T.eq(r.error:find("Script has a syntax error", 1, true) ~= nil, true, r.error)
  T.eq(call("run_script", { name = "Nope" }).error, "There is no saved script called 'Nope'.")
  T.eq(call("write_script", { name = "../x", description = "d", code = "x" }).ok, false)
end)

F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh test_scripts` (after adding it to the suite list)
Expected: `module 'agent.tools.scripts' not found`.

- [ ] **Step 3: Implement**

`extension/agent/tools/scripts.lua`:
```lua
local M = { dir = nil }

function M.folder()
  return M.dir or app.fs.joinPath(app.fs.userConfigPath, "scripts", "Agent")
end

local function checkName(name)
  name = tostring(name or "")
  if not name:match("^[%w _%-]+$") or #name > 60 then
    error("Script names use letters, numbers, spaces, - and _ (max 60).", 0)
  end
  return name
end

function M.write_script(args)
  local name = checkName(args.name)
  local code = tostring(args.code)
  if #code > 20000 then error("Scripts are limited to 20000 characters.", 0) end
  app.fs.makeAllDirectories(M.folder())
  local path = app.fs.joinPath(M.folder(), name .. ".lua")
  local f = assert(io.open(path, "w"))
  f:write("-- " .. tostring(args.description):gsub("\n", " ") .. "\n")
  f:write("-- Written by Claude in Agent Chat on " .. os.date("%Y-%m-%d") .. "; approved by the artist.\n\n")
  f:write(code)
  if code:sub(-1) ~= "\n" then f:write("\n") end
  f:close()
  return { name = name, path = path }
end

function M.run_script(args)
  local name = checkName(args.name)
  local path = app.fs.joinPath(M.folder(), name .. ".lua")
  if not app.fs.isFile(path) then error("There is no saved script called '" .. name .. "'.", 0) end
  local chunk, syntaxErr = loadfile(path)
  if not chunk then error("Script has a syntax error: " .. tostring(syntaxErr), 0) end
  local out, realPrint = {}, print
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    out[#out + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(function()
    if app.sprite then app.transaction("Script: " .. name, chunk) else chunk() end
  end)
  print = realPrint
  if not ok then error("Script error: " .. tostring(err), 0) end
  app.refresh()
  local output = table.concat(out, "\n")
  if #output > 4000 then output = output:sub(1, 4000) .. "\n[...truncated]" end
  return { name = name, output = output }
end

return M
```

In `init.lua`, add `local scripts = require("agent.tools.scripts")` and register `write_script` and `run_script` as `"edit"`.

Update the handler-coverage list in `tests/lua/test_analyze.lua` to add:
`"get_tool_state", "set_tool", "list_installed_extensions", "run_extension_command", "check_readability", "light_preview", "dither", "gradient_fill", "pixel_perfect", "snap_to_palette", "selout", "layer_style", "builtin_fx", "make_normal_map", "write_script", "run_script"`.
(`find_extensions` runs in the bridge, so it has no Lua handler.)

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add extension/agent/tools/scripts.lua extension/agent/tools/init.lua tests/lua
git commit -m "feat(extension): Claude-written scripts saved to File > Scripts > Agent and run on approval"
```

---

### Task 7: Install, and the manual checks for the final big test

- [ ] **Step 1:** Run `cd bridge && npx vitest run && npm run typecheck` and `scripts/test-lua.sh`: everything passes. Then the headless load check for `agent.chat_window`.
- [ ] **Step 2:** `scripts/dev-install.sh`, rebuild and restart the bridge (update `~/.claude/claude-running.md`), and commit anything left.
- [ ] **Step 3:** Add these to the final big manual test (the artist runs them in Aseprite at the end):
  1. "Dither the sky between these two blues": a card, then dithered, and one undo reverts it.
  2. "Clean up my lineart": `pixel_perfect` turns L-corners into diagonals.
  3. "Snap this sprite to the project palette": off-palette colors are remapped.
  4. "Selout the outline": outline pixels take darker fill shades.
  5. "Add a 1px dark stroke and a drop shadow": new layers appear below.
  6. "Make normal maps for the knight": `knight_normal.aseprite` and `knight_height.aseprite` appear next to it. "Show me how it looks lit from the top-left": a preview only, nothing changes.
  7. "Is my sprite readable?": Claude shows value and silhouette views.
  8. "Set me up for shading with a 2px brush": the tool, ink and brush change immediately, with no card.
  9. "Is there an extension for wave effects?": Claude recommends Wave Warp with a link. "What extensions do I have?"
  10. "Write me a script that exports every tag as a PNG strip": the card shows the code, then it's saved under File > Scripts > Agent. "Run it": a separate card, then the output comes back.

---

## Self-Review Notes

- **Spec coverage (§15):**
  - hand-built FX (Task 3);
  - maps and previews (Task 4);
  - built-ins, tool setup and extensions (Task 5);
  - scripts (Task 6);
  - catalog and prompt (Task 1);
  - the setting kind without a card (Tasks 1 and 5).
- **Deviations:**
  - ColorCurve is dropped.
  - Brush is set via preferences (verified).
  - FX are RGB-only, and `builtin_fx` covers the other color modes.
