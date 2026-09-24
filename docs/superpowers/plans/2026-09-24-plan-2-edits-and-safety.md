# Aseprite Agent Chat — Plan 2: Edits and Safety

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude can make small, approved, single-undo edits to the artist's open sprites (palette, colors, layers, frames, pixel fixes, outline/flip, teaching annotations). Every edit goes through an approval card; pixel painting is capped; generated blockouts are quarantined on an "AI Draft" layer that is unlocked only after the artist insists. Reference tabs (PNG/JPG and other non-`.aseprite` tabs) are readable and never editable.

**Architecture:** The bridge's `Session` wraps every edit tool call in an approval gate (approval request → artist's Apply/Deny → forward), enforces pixel budgets and draft mode, and honours an auto-approve toggle. Tool definitions gain `summarize`, `forward` and `alwaysAsk`. On the Lua side, a shared `edit` module runs every mutation inside one `app.transaction` using clone → modify → assign, and rejects reference tabs, locked layers, groups, and tilemaps. The chat window renders approval cards and shows an Apply button. The main button becomes Deny while an approval is pending, so pressing Enter denies, which is the safe default.

**Tech Stack:** Same as Plan 1. Aseprite 1.3.18 Lua API, Node 24 + TypeScript 7, `zod` v4, Claude Agent SDK 0.3.x, Vitest, headless Aseprite tests.

**Spec:** `docs/superpowers/specs/2026-09-24-aseprite-agent-chat-design.md` (§5 tools, §6 anti-generation stance, §7 protocol, §11 UI). Plan 1: `docs/superpowers/plans/2026-09-24-plan-1-walking-skeleton.md`.

## Global Constraints

- Every Plan 1 global constraint still applies: 127.0.0.1 only; modules under `extension/agent/` required as `agent.*`; `error(msg, 0)` for tool errors; **no emoji** in text Aseprite draws; frames are 1-based; layers are listed bottom to top.
- **Undo rule (verified):** every mutation happens inside `app.transaction` (via `edit.transaction`). Pixels are changed only by clone → modify → assign (`cel.image = img`). In-place `drawPixel` on a cel's image is not undoable. Each tool call = exactly one undo step.
- `app.transaction` acts on the active sprite. `edit.transaction` temporarily makes the target active and restores the previous one (verified to work and to undo correctly).
- Aseprite's `json.decode` returns **userdata**: tool args support indexing, `#`, `ipairs`/`pairs`, and numbers arrive as **floats**. Convert coordinates and indices with `math.tointeger(v) or math.floor(v)`. Every Lua tool test that takes arrays or numbers must also run with `json.decode`-built args.
- `app.command.Outline` ignores its `color` param in batch (verified). Outline and flip are implemented in Lua, not via `app.command`.
- **References:** a tab whose file extension is anything other than `aseprite`/`ase` (for example `ref.png`) is a reference: readable by all read tools, rejected by every edit tool with `"'<name>' is a reference image tab; it is read-only."` Unsaved sprites (no extension) are editable.
- **Constants (shared by bridge and Lua, spelled exactly):** draft layer `"AI Draft"` at opacity `102` (≈40%); notes layer `"Agent Notes"`; default note color `#ff3b30`; pixel budgets `256` per `set_pixels` call and `1024` per turn (spec §3 defaults; `project.json` overrides arrive in Plan 3).
- Colors in tool args are `#rrggbb` or `#rrggbbaa`; `set_pixels` also accepts `"."` (erase). In indexed sprites a color must already be in the palette, otherwise the tool errors and tells Claude to use `add_palette_colors`.
- When starting the bridge for manual checks, record it in `~/.claude/claude-running.md` and remove the line when you stop it. After changing extension code, run `scripts/dev-install.sh` (copies the extension; Aseprite ignores symlinked extensions) and restart Aseprite.

## Review Focus

1. **Claude fires several edit tools in one message** (the SDK may run tool handlers concurrently). Approval cards must queue: one visible Apply at a time, each answered in order, none lost. Covered by the concurrent-approval test in Task 2 and the model queue test in Task 9.
2. **Stop, New chat or disconnect while a card is pending.** The pending approval resolves as declined, no edit is applied, and the card shows "Cancelled". Covered in Tasks 2 and 9.
3. **Edits aimed at the wrong target:** a reference PNG tab, a locked layer, a group, a layer that doesn't exist, pixels outside the canvas, a color missing from an indexed palette. Each gets a plain error, and the sprite is untouched (no partial edit, no stray undo step). Covered in Tasks 4–7.
4. **A tool that fails halfway** (a Lua error inside the transaction) leaves nothing behind. The transaction rolls back and one Ctrl+Z doesn't undo something unrelated. Covered by the rollback test in Task 4.
5. **Budget evasion:** many small `set_pixels` calls in one reply, painting on "AI Draft" without approval, or naming the draft layer in different casing. Budgets are per turn and reset each turn; the draft-layer check is exact-name and case-insensitive. Covered in Task 2.

---

## File Structure

```
bridge/src/
  protocol.ts              + approval, set_auto_approve (in); approval_request (out)
  tools/constants.ts       NEW: DRAFT_LAYER, NOTES_LAYER, PIXEL_BUDGET, isDraftLayer
  tools/ramp.ts            NEW: colorRamp() hue-shifted palette ramps (pure)
  tools/definitions.ts     + ToolDef.summarize/forward/alwaysAsk; 12 new tools
  session.ts               approval gate, budgets, draft mode, auto-approve
  prompt.ts                edit tools, approval, budget and draft-mode rules
extension/agent/
  chat_model.lua           + approvals (add/resolve/pending), endTurn cancels, sendAction(…, pending)
  chat_render.lua          + approval card layout
  chat_window.lua          + Apply button, Deny-on-Enter, auto-approve checkbox, approval messages
  tools/edit.lua           NEW: reference check, drawable layer, transaction, canvas image, colors
  tools/color.lua          + parseHex, rgbaOf(value, mode, palette)
  tools/pixels.lua         NEW: set_pixels, replace_color
  tools/palette.lua        NEW: set_palette, add_palette_colors
  tools/layers.lua         NEW: layer_ops, ensure_draft_layer
  tools/frames.lua         NEW: frame_ops
  tools/geometry.lua       NEW: pure point sets (line, rect, circle, arrow, dot)
  tools/annotate.lua       NEW: annotate (Agent Notes layer)
  tools/transform.lua      NEW: transform (outline, flip_horizontal, flip_vertical)
  tools/analyze.lua        NEW: analyze_colors, list_open_sprites
  tools/inspect.lua        render() exported for reuse
  tools/init.lua           registers all handlers
tests/lua/
  fixtures.lua             NEW: shared sprite builders + closeAll
  test_edit.lua, test_pixels.lua, test_palette.lua, test_layers_frames.lua,
  test_geometry.lua, test_annotate_transform.lua, test_analyze.lua   NEW
  run.lua                  suite list extended
```

---

### Task 1: Tool definitions, constants, and color ramps (bridge)

**Files:**
- Create: `bridge/src/tools/constants.ts`, `bridge/src/tools/ramp.ts`
- Modify: `bridge/src/tools/definitions.ts`
- Test: `bridge/test/ramp.test.ts`, `bridge/test/definitions.test.ts` (replace the first test; add new ones)

**Interfaces:**
- Consumes: `ToolDef` from Plan 1.
- Produces:
  - `constants.ts`: `DRAFT_LAYER = "AI Draft"`, `NOTES_LAYER = "Agent Notes"`, `PIXEL_BUDGET = { perCall: 256, perTurn: 1024 }`, `isDraftLayer(name: unknown): boolean` (trimmed, case-insensitive)
  - `ramp.ts`: `colorRamp(base: string, steps: number, hueShift?: number, spread?: number): string[]`, `hexToHsv(hex)`, `hsvToHex(h, s, v)`
  - `ToolDef` gains `summarize?(args): string`, `forward?(args): { name: string; args: Record<string, unknown> }`, `alwaysAsk?: boolean`
  - New tool names: read: `list_open_sprites`, `analyze_colors`; edit: `set_palette`, `add_palette_colors`, `add_color_ramp` (forwards to `add_palette_colors`), `replace_color`, `layer_ops`, `frame_ops`, `set_pixels`, `annotate`, `transform`, `request_draft_mode` (`alwaysAsk`, forwards to `ensure_draft_layer`)

> **Spec deltas (rulings):** spec §5's `run_command` becomes `transform` (outline and flip written in Lua, because `app.command.Outline` ignores its color in batch). `recolor_region` is folded into `replace_color`'s optional `region`. `propose_memory` moves to Plan 3 with `memory.md`. `annotate` draws shapes only, no text labels, because the Lua `Image` API has no text drawing; Claude refers to marks by position in chat.

- [ ] **Step 1: Write the failing tests**

`bridge/test/ramp.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { colorRamp, hexToHsv, hsvToHex } from "../src/tools/ramp.js";

const HEX = /^#[0-9a-f]{6}$/;
const luminance = (hex: string) => {
  const n = parseInt(hex.slice(1), 16);
  return 0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255);
};

describe("hsv conversions", () => {
  it("round-trips", () => {
    for (const hex of ["#000000", "#ffffff", "#c8503c", "#3c8cc8", "#808080"]) {
      const [h, s, v] = hexToHsv(hex);
      expect(hsvToHex(h, s, v)).toBe(hex);
    }
  });
});

describe("colorRamp", () => {
  it("returns `steps` valid colors, dark to light, with the base in the middle", () => {
    const ramp = colorRamp("#c8503c", 5);
    expect(ramp).toHaveLength(5);
    for (const c of ramp) expect(c).toMatch(HEX);
    expect(ramp[2]).toBe("#c8503c");
    for (let i = 1; i < ramp.length; i++) expect(luminance(ramp[i])).toBeGreaterThan(luminance(ramp[i - 1]));
  });

  it("shifts hue: shadows by -hueShift, highlights by +hueShift", () => {
    const ramp = colorRamp("#c8503c", 3, 20);
    const [h0] = hexToHsv(ramp[0]);
    const [h1] = hexToHsv(ramp[1]);
    const [h2] = hexToHsv(ramp[2]);
    const diff = (a: number, b: number) => ((a - b + 540) % 360) - 180;
    expect(diff(h0, h1)).toBeLessThan(0);
    expect(diff(h2, h1)).toBeGreaterThan(0);
  });

  it("handles greys and extremes without NaN", () => {
    for (const base of ["#808080", "#000000", "#ffffff"]) {
      for (const c of colorRamp(base, 7)) expect(c).toMatch(HEX);
    }
  });
});
```

Replace the first test in `bridge/test/definitions.test.ts` (`"has the four read tools with unique names"`) with these tests, and keep the rest of the file:
```ts
  it("defines every Plan 2 tool with a unique name", () => {
    const names = TOOL_DEFS.map((d) => d.name);
    expect(new Set(names).size).toBe(names.length);
    expect(names.sort()).toEqual([
      "add_color_ramp", "add_palette_colors", "analyze_colors", "annotate", "frame_ops", "get_palette",
      "get_pixels", "get_snapshot", "get_sprite_info", "layer_ops", "list_open_sprites", "replace_color",
      "request_draft_mode", "set_palette", "set_pixels", "transform",
    ]);
  });

  it("gives every edit tool an approval summary, and read tools none", () => {
    for (const d of TOOL_DEFS) {
      if (d.kind === "edit") expect(typeof d.summarize).toBe("function");
      else expect(d.summarize).toBeUndefined();
    }
  });

  it("summaries are plain ASCII", () => {
    const s = toolDef("set_pixels")!.summarize!({ sprite: "knight.aseprite", layer: "Body", pixels: [{ x: 0, y: 0, color: "#ff0000" }] });
    expect(s).toBe('Set 1 pixel on knight.aseprite > "Body"');
    expect(toolDef("replace_color")!.summarize!({ from: "#c8503c", to: "#b8443a", layer: "Body" })).toBe(
      'Replace #c8503c with #b8443a in the active sprite > "Body"',
    );
  });

  it("add_color_ramp forwards computed colors to add_palette_colors", () => {
    const fwd = toolDef("add_color_ramp")!.forward!({ sprite: "a.aseprite", base: "#c8503c", steps: 5 });
    expect(fwd.name).toBe("add_palette_colors");
    expect(fwd.args.sprite).toBe("a.aseprite");
    expect((fwd.args.colors as string[]).length).toBe(5);
  });

  it("request_draft_mode always asks and forwards to ensure_draft_layer", () => {
    const d = toolDef("request_draft_mode")!;
    expect(d.alwaysAsk).toBe(true);
    expect(d.forward!({ sprite: "a.aseprite", quote: "just draw it" })).toEqual({ name: "ensure_draft_layer", args: { sprite: "a.aseprite" } });
    expect(d.summarize!({ quote: "just draw it" })).toContain('You said: "just draw it"');
  });

  it("validates colors and set_pixels shape", () => {
    const px = z.object(toolDef("set_pixels")!.shape);
    expect(px.safeParse({ layer: "Body", pixels: [{ x: 1, y: 2, color: "#ff0000" }] }).success).toBe(true);
    expect(px.safeParse({ layer: "Body", pixels: [{ x: 1, y: 2, color: "." }] }).success).toBe(true);
    expect(px.safeParse({ layer: "Body", pixels: [{ x: 1, y: 2, color: "red" }] }).success).toBe(false);
    expect(px.safeParse({ layer: "Body", pixels: [] }).success).toBe(false);
  });
```

`bridge/test/constants.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { isDraftLayer } from "../src/tools/constants.js";

describe("isDraftLayer", () => {
  it("matches the draft layer name regardless of case and surrounding spaces", () => {
    expect(isDraftLayer("AI Draft")).toBe(true);
    expect(isDraftLayer(" ai draft ")).toBe(true);
    expect(isDraftLayer("AI Drafts")).toBe(false);
    expect(isDraftLayer(undefined)).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npx vitest run test/ramp.test.ts test/definitions.test.ts test/constants.test.ts`
Expected: FAIL. `ramp.js` and `constants.js` are not found, and the definitions tests fail on the missing tools.

- [ ] **Step 3: Implement constants and ramp**

`bridge/src/tools/constants.ts`:
```ts
export const DRAFT_LAYER = "AI Draft";
export const NOTES_LAYER = "Agent Notes";
export const PIXEL_BUDGET = { perCall: 256, perTurn: 1024 };

export function isDraftLayer(name: unknown): boolean {
  return typeof name === "string" && name.trim().toLowerCase() === DRAFT_LAYER.toLowerCase();
}
```

`bridge/src/tools/ramp.ts`:
```ts
const clamp01 = (x: number) => Math.min(1, Math.max(0, x));

export function hexToHsv(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1, 7), 16);
  const r = ((n >> 16) & 255) / 255;
  const g = ((n >> 8) & 255) / 255;
  const b = (n & 255) / 255;
  const max = Math.max(r, g, b);
  const d = max - Math.min(r, g, b);
  let h = 0;
  if (d > 0) {
    if (max === r) h = 60 * (((g - b) / d) % 6);
    else if (max === g) h = 60 * ((b - r) / d + 2);
    else h = 60 * ((r - g) / d + 4);
  }
  return [(h + 360) % 360, max === 0 ? 0 : d / max, max];
}

export function hsvToHex(h: number, s: number, v: number): string {
  const c = v * s;
  const hp = (((h % 360) + 360) % 360) / 60;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  const [r, g, b] =
    hp < 1 ? [c, x, 0] : hp < 2 ? [x, c, 0] : hp < 3 ? [0, c, x] : hp < 4 ? [0, x, c] : hp < 5 ? [x, 0, c] : [c, 0, x];
  const m = v - c;
  const to = (u: number) => Math.round((u + m) * 255).toString(16).padStart(2, "0");
  return `#${to(r)}${to(g)}${to(b)}`;
}

/**
 * A dark-to-light ramp around `base`. Shadows rotate hue by -hueShift and gain a little
 * saturation; highlights rotate by +hueShift and lose some. `spread` (0..1) sets how far
 * the ends move toward black and white. For odd `steps` the middle color is `base`.
 */
export function colorRamp(base: string, steps: number, hueShift = 20, spread = 0.6): string[] {
  const [h, s, v] = hexToHsv(base);
  const out: string[] = [];
  for (let i = 0; i < steps; i++) {
    const t = steps === 1 ? 0 : (i / (steps - 1)) * 2 - 1; // -1 darkest .. +1 lightest
    if (t === 0) {
      out.push(base.slice(0, 7).toLowerCase());
      continue;
    }
    const vi = t < 0 ? v + t * v * spread : v + t * (1 - v) * spread;
    const si = t < 0 ? s - t * 0.1 : s - t * 0.15 * s;
    // Guarantee strictly increasing brightness even when the base sits at black or white.
    const floor = t < 0 ? 0 : v;
    out.push(hsvToHex(h + t * hueShift, clamp01(si), clamp01(Math.max(vi, floor + 0.02 * t))));
  }
  return out;
}
```

- [ ] **Step 4: Extend the tool definitions**

In `bridge/src/tools/definitions.ts`, replace the `ToolDef` interface with:
```ts
export interface ToolDef {
  name: string;
  description: string;
  kind: ToolKind;
  shape: z.ZodRawShape;
  activity(args: Record<string, unknown>): string;
  /** Edit tools only: one plain-ASCII line shown on the approval card. */
  summarize?(args: Record<string, unknown>): string;
  /** The tool name and args actually sent to the extension. Defaults to this tool's own. */
  forward?(args: Record<string, unknown>): { name: string; args: Record<string, unknown> };
  /** Edit tools that must show an approval card even when auto-approve is on. */
  alwaysAsk?: boolean;
}
```

Add these imports at the top:
```ts
import { DRAFT_LAYER, NOTES_LAYER } from "./constants.js";
import { colorRamp } from "./ramp.js";
```

Add these helpers after `spriteName`:
```ts
const hexColor = z.string().regex(/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/, "use #rrggbb or #rrggbbaa");
const target = (a: Record<string, unknown>) => (typeof a.layer === "string" ? `${spriteName(a)} > "${a.layer}"` : spriteName(a));
const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;
const frameRange = z.object({ from: z.number().int().min(1), to: z.number().int().min(1) });
```

Append these entries to `TOOL_DEFS`:
```ts
  {
    name: "list_open_sprites",
    kind: "read",
    description:
      "List the tabs open in Aseprite: name, path, size, frames, whether it is the active tab, and kind: 'sprite' (editable .aseprite file) or 'reference' (an image like .png/.jpg opened as a tab; read-only reference material). Use references for comparison, proportions and color picking.",
    shape: {},
    activity: () => "Listed open tabs",
  },
  {
    name: "analyze_colors",
    kind: "read",
    description:
      "Color statistics for one frame (flattened): unique color count, the most used colors with pixel counts, near-duplicate color pairs (candidates to merge), and palette entries not used in the frame.",
    shape: { sprite: spriteArg, frame: frameArg },
    activity: (a) => `Analyzed colors in ${spriteName(a)}`,
  },
  {
    name: "set_palette",
    kind: "edit",
    description: "Replace the whole palette. In indexed sprites pixels keep their indices, so their colors change.",
    shape: { sprite: spriteArg, colors: z.array(hexColor).min(1).max(256) },
    activity: (a) => `Replaced the palette of ${spriteName(a)}`,
    summarize: (a) => `Replace the palette of ${spriteName(a)} with ${plural((a.colors as string[]).length, "color")}`,
  },
  {
    name: "add_palette_colors",
    kind: "edit",
    description: "Append colors to the palette (colors already present are skipped).",
    shape: { sprite: spriteArg, colors: z.array(hexColor).min(1).max(64) },
    activity: (a) => `Added colors to the palette of ${spriteName(a)}`,
    summarize: (a) => `Add ${(a.colors as string[]).join(" ")} to the palette of ${spriteName(a)}`,
  },
  {
    name: "add_color_ramp",
    kind: "edit",
    description:
      "Build a hue-shifted ramp (dark to light) around a base color and append it to the palette. hueShift rotates highlights by +degrees and shadows by -degrees; spread (0.2-1) sets how close the ends get to black and white.",
    shape: {
      sprite: spriteArg,
      base: hexColor,
      steps: z.number().int().min(3).max(9),
      hueShift: z.number().min(-60).max(60).optional(),
      spread: z.number().min(0.2).max(1).optional(),
    },
    activity: (a) => `Added a ${a.steps}-step ramp to ${spriteName(a)}`,
    summarize: (a) => {
      const colors = colorRamp(a.base as string, a.steps as number, a.hueShift as number | undefined, a.spread as number | undefined);
      return `Add a ${a.steps}-step ramp to the palette of ${spriteName(a)}: ${colors.join(" ")}`;
    },
    forward: (a) => ({
      name: "add_palette_colors",
      args: {
        sprite: a.sprite,
        colors: colorRamp(a.base as string, a.steps as number, a.hueShift as number | undefined, a.spread as number | undefined),
      },
    }),
  },
  {
    name: "replace_color",
    kind: "edit",
    description:
      "Replace one color with another across a layer (or all editable layers), a frame range (default all frames) and an optional region. tolerance (0-255, default 0) also matches colors whose channels differ by at most that much.",
    shape: {
      sprite: spriteArg,
      from: hexColor,
      to: hexColor,
      tolerance: z.number().int().min(0).max(255).optional(),
      layer: z.string().optional(),
      frames: frameRange.optional(),
      region: rect().optional(),
    },
    activity: (a) => `Replaced ${a.from} with ${a.to} in ${target(a)}`,
    summarize: (a) => {
      let s = `Replace ${a.from} with ${a.to} in ${target(a)}`;
      const f = a.frames as { from: number; to: number } | undefined;
      if (f) s += `, frames ${f.from}-${f.to}`;
      if (a.region) s += " (region only)";
      if (typeof a.tolerance === "number" && a.tolerance > 0) s += `, tolerance ${a.tolerance}`;
      return s;
    },
  },
  {
    name: "layer_ops",
    kind: "edit",
    description:
      "Layer housekeeping. action: 'add' (name, optional toIndex), 'rename' (layer, name), 'set' (layer + any of visible, opacity 0-255, blendMode), 'move' (layer, toIndex; 1 = bottom of its group).",
    shape: {
      sprite: spriteArg,
      action: z.enum(["add", "rename", "set", "move"]),
      layer: z.string().optional(),
      name: z.string().min(1).optional(),
      visible: z.boolean().optional(),
      opacity: z.number().int().min(0).max(255).optional(),
      blendMode: z
        .enum(["normal", "multiply", "screen", "overlay", "darken", "lighten", "color_dodge", "color_burn", "hard_light",
          "soft_light", "difference", "exclusion", "hue", "saturation", "color", "luminosity", "addition", "subtract", "divide"])
        .optional(),
      toIndex: z.number().int().min(1).optional(),
    },
    activity: (a) => `Layer ${a.action} in ${spriteName(a)}`,
    summarize: (a) => {
      switch (a.action) {
        case "add":
          return `Add layer "${a.name}" to ${spriteName(a)}`;
        case "rename":
          return `Rename layer "${a.layer}" to "${a.name}" in ${spriteName(a)}`;
        case "move":
          return `Move layer "${a.layer}" to position ${a.toIndex} in ${spriteName(a)}`;
        default: {
          const parts: string[] = [];
          if (typeof a.visible === "boolean") parts.push(a.visible ? "show" : "hide");
          if (typeof a.opacity === "number") parts.push(`opacity ${a.opacity}`);
          if (typeof a.blendMode === "string") parts.push(`blend ${a.blendMode}`);
          return `Set layer "${a.layer}" in ${spriteName(a)}: ${parts.join(", ") || "no changes"}`;
        }
      }
    },
  },
  {
    name: "frame_ops",
    kind: "edit",
    description:
      "Frame housekeeping. action: 'add_empty' (after frame, default last), 'duplicate' (frame), 'set_duration' (frame..toFrame, durationMs), 'add_tag' (name, frame..toFrame).",
    shape: {
      sprite: spriteArg,
      action: z.enum(["add_empty", "duplicate", "set_duration", "add_tag"]),
      frame: z.number().int().min(1).optional(),
      toFrame: z.number().int().min(1).optional(),
      durationMs: z.number().int().min(1).max(65535).optional(),
      name: z.string().min(1).optional(),
    },
    activity: (a) => `Frame ${a.action} in ${spriteName(a)}`,
    summarize: (a) => {
      const range = a.toFrame ? `frames ${a.frame}-${a.toFrame}` : `frame ${a.frame ?? "(last)"}`;
      switch (a.action) {
        case "add_empty":
          return `Add an empty frame after ${range} in ${spriteName(a)}`;
        case "duplicate":
          return `Duplicate ${range} in ${spriteName(a)}`;
        case "set_duration":
          return `Set ${range} of ${spriteName(a)} to ${a.durationMs} ms`;
        default:
          return `Tag ${range} of ${spriteName(a)} as "${a.name}"`;
      }
    },
  },
  {
    name: "set_pixels",
    kind: "edit",
    description: `Set individual pixels on a layer for small fixes (stray pixels, jaggies, anti-aliasing, a highlight). color '.' erases. Limited to 256 pixels per call and 1024 per reply; it is not for painting artwork. Painting on the "${DRAFT_LAYER}" layer is only possible after request_draft_mode was approved.`,
    shape: {
      sprite: spriteArg,
      layer: z.string(),
      frame: frameArg,
      pixels: z
        .array(z.object({ x: z.number().int().min(0), y: z.number().int().min(0), color: z.union([hexColor, z.literal(".")]) }))
        .min(1)
        .max(4096),
    },
    activity: (a) => `Set ${plural((a.pixels as unknown[]).length, "pixel")} on ${target(a)}`,
    summarize: (a) => {
      let s = `Set ${plural((a.pixels as unknown[]).length, "pixel")} on ${target(a)}`;
      if (typeof a.frame === "number") s += `, frame ${a.frame}`;
      return s;
    },
  },
  {
    name: "annotate",
    kind: "edit",
    description: `Draw teaching marks (dot, line, arrow, rect, circle) on the "${NOTES_LAYER}" layer, created on top if missing. Use this to show the artist where to look instead of painting for them. clear: true wipes the notes on that frame first. Marks have no text; refer to them by position in your reply.`,
    shape: {
      sprite: spriteArg,
      frame: frameArg,
      clear: z.boolean().optional(),
      color: hexColor.optional(),
      shapes: z
        .array(
          z.object({
            type: z.enum(["dot", "line", "arrow", "rect", "circle"]),
            x: z.number().int(),
            y: z.number().int(),
            x2: z.number().int().optional(),
            y2: z.number().int().optional(),
            w: z.number().int().min(1).optional(),
            h: z.number().int().min(1).optional(),
            r: z.number().int().min(0).optional(),
          }),
        )
        .max(50),
    },
    activity: (a) => `Drew notes on ${spriteName(a)}`,
    summarize: (a) => {
      const n = (a.shapes as unknown[]).length;
      return `${a.clear ? "Clear and draw" : "Draw"} ${plural(n, "note mark")} on ${spriteName(a)} ("${NOTES_LAYER}" layer)`;
    },
  },
  {
    name: "transform",
    kind: "edit",
    description:
      "Apply a pixel operation to one layer in one frame. action: 'outline' (1px outline in color, place 'outside' (default) or 'inside'), 'flip_horizontal', 'flip_vertical' (optionally only within region).",
    shape: {
      sprite: spriteArg,
      layer: z.string(),
      frame: frameArg,
      action: z.enum(["outline", "flip_horizontal", "flip_vertical"]),
      color: hexColor.optional(),
      place: z.enum(["outside", "inside"]).optional(),
      region: rect().optional(),
    },
    activity: (a) => `Applied ${a.action} to ${target(a)}`,
    summarize: (a) =>
      a.action === "outline"
        ? `Outline ${target(a)} ${a.place ?? "outside"} in ${a.color ?? "#000000"}`
        : `${a.action === "flip_horizontal" ? "Flip horizontally" : "Flip vertically"}: ${target(a)}${a.region ? " (region only)" : ""}`,
  },
  {
    name: "request_draft_mode",
    kind: "edit",
    alwaysAsk: true,
    description: `Only after the artist has insisted on you blocking something out, even after you offered to guide them: ask to unlock a rough "${DRAFT_LAYER}" layer (40% opacity) that set_pixels may paint on without the usual limit. quote must be the artist's own words insisting.`,
    shape: { sprite: spriteArg, quote: z.string().min(3) },
    activity: (a) => `Unlocked the ${DRAFT_LAYER} layer on ${spriteName(a)}`,
    summarize: (a) =>
      `Unlock a rough "${DRAFT_LAYER}" layer on ${spriteName(a)} (40% opacity; redraw over it, then delete it). You said: "${a.quote}"`,
    forward: (a) => ({ name: "ensure_draft_layer", args: { sprite: a.sprite } }),
  },
```

- [ ] **Step 5: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: ramp, constants and definitions tests pass. `claudeCode.test.ts` "locks Claude Code down" now **fails**, because its hard-coded `allowedTools` list has 4 names. Replace that assertion with:
```ts
    expect([...o.allowedTools].sort()).toEqual(TOOL_DEFS.map((d) => `mcp__aseprite__${d.name}`).sort());
```
and add `import { TOOL_DEFS, toolDef } from "../src/tools/definitions.js";` (replacing the existing `toolDef` import). Re-run: everything passes and tsc is clean.

- [ ] **Step 6: Commit**

```bash
git add bridge/src/tools bridge/test/ramp.test.ts bridge/test/constants.test.ts bridge/test/definitions.test.ts bridge/test/claudeCode.test.ts
git commit -m "feat(bridge): edit tool definitions, color ramps and shared constants"
```

---

### Task 2: Approval gate, budgets, draft mode, and auto-approve (bridge)

**Files:**
- Modify: `bridge/src/protocol.ts`, `bridge/src/session.ts`
- Test: `bridge/test/approval.test.ts`, `bridge/test/protocol.test.ts` (add cases)

**Interfaces:**
- Consumes: `ToolDef.summarize/forward/alwaysAsk`, `isDraftLayer`, `PIXEL_BUDGET` (Task 1); `Session` from Plan 1.
- Produces (protocol):
  - in: `{ type: "approval"; approvalId: string; approved: boolean }`, `{ type: "set_auto_approve"; enabled: boolean }`
  - out: `{ type: "approval_request"; approvalId: string; summary: string; sprite?: string }`
- Session behaviour, in order, for an edit tool:
  1. budget and draft checks (rejections never show a card);
  2. approval, unless auto-approve is on and the tool isn't `alwaysAsk`;
  3. mark draft mode on for an approved `request_draft_mode`;
  4. count budget pixels;
  5. `tool_activity`;
  6. forward to the extension.
- A declined edit returns `{ ok: false, error: "The artist declined this change. Ask what they would prefer instead." }`.
- Cancel, New chat and disconnect resolve every pending approval as declined. Draft mode resets on New chat; the pixel budget resets at the start of every turn.

- [ ] **Step 1: Write the failing tests**

Add to `bridge/test/protocol.test.ts`:
```ts
  it("accepts approval and set_auto_approve", () => {
    expect(parseExtensionMessage(JSON.stringify({ type: "approval", approvalId: "a1", approved: true })).ok).toBe(true);
    expect(parseExtensionMessage(JSON.stringify({ type: "set_auto_approve", enabled: false })).ok).toBe(true);
    expect(parseExtensionMessage(JSON.stringify({ type: "approval", approvalId: "a1" })).ok).toBe(false);
  });
```

`bridge/test/approval.test.ts`:
```ts
import { afterEach, describe, expect, it } from "vitest";
import type { AdapterContext, AdapterEvent } from "../src/adapters/Adapter.js";
import type { BridgeMessage } from "../src/protocol.js";
import { startServer, type BridgeServer } from "../src/server.js";
import type { ToolResult } from "../src/toolTypes.js";
import { connectClient, scriptedAdapterFactory, type TestClient } from "./helpers.js";

const TOKEN = "t";
let server: BridgeServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

type Script = (ctx: AdapterContext, text: string) => AsyncIterable<AdapterEvent>;

/** Starts a server whose adapter runs `script`, and a client that answers every tool_call with ok. */
async function setup(script: Script) {
  server = await startServer({ port: 0, token: TOKEN, adapterFactory: scriptedAdapterFactory(script), systemPrompt: "", snapshotDir: "/s" });
  const c = await connectClient(server.port);
  c.ws.on("message", (raw) => {
    const m = JSON.parse(raw.toString()) as BridgeMessage;
    if (m.type === "tool_call") c.send({ type: "tool_result", callId: m.callId, ok: true, data: { did: m.name, args: m.args } });
  });
  c.send({ type: "hello", token: TOKEN, extensionVersion: "t" });
  await c.waitFor((m) => m.type === "ready");
  return c;
}

const px = (n: number, layer = "Body") => ({ layer, pixels: Array.from({ length: n }, (_, i) => ({ x: i, y: 0, color: "#ff0000" })) });

async function approveNext(c: TestClient, approved: boolean) {
  const req = await c.waitFor((m) => m.type === "approval_request" && !(m as any).answered);
  (req as any).answered = true;
  if (req.type !== "approval_request") throw new Error("unreachable");
  c.send({ type: "approval", approvalId: req.approvalId, approved });
  return req;
}

function recorder() {
  const results: ToolResult[] = [];
  return { results, push: (r: ToolResult) => (results.push(r), r) };
}

describe("approval gate", () => {
  it("asks before an edit and forwards it when approved", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(2)));
    });
    c.send({ type: "user_message", text: "fix" });
    const req = await approveNext(c, true);
    expect(req).toMatchObject({ summary: 'Set 2 pixels on the active sprite > "Body"' });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.map((m) => m.type)).toEqual(["ready", "approval_request", "tool_activity", "tool_call", "turn_done"]);
    expect(rec.results[0].ok).toBe(true);
  });

  it("does not forward a declined edit", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("replace_color", { from: "#000000", to: "#111111" }));
    });
    c.send({ type: "user_message", text: "fix" });
    await approveNext(c, false);
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "tool_call")).toBe(false);
    expect(rec.results[0]).toEqual({ ok: false, error: "The artist declined this change. Ask what they would prefer instead." });
  });

  it("read tools never ask", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("get_palette", {});
    });
    c.send({ type: "user_message", text: "look" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "approval_request")).toBe(false);
  });

  it("queues concurrent approvals and answers them in order", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      const all = await Promise.all([
        ctx.tools.call("layer_ops", { action: "add", name: "A" }),
        ctx.tools.call("layer_ops", { action: "add", name: "B" }),
      ]);
      all.forEach((r) => rec.push(r));
    });
    c.send({ type: "user_message", text: "two layers" });
    const first = await approveNext(c, true);
    const second = await approveNext(c, false);
    expect(first.type === "approval_request" && second.type === "approval_request" && first.approvalId !== second.approvalId).toBe(true);
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results.map((r) => r.ok)).toEqual([true, false]);
  });

  it("auto-approve skips cards, except for request_draft_mode", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("layer_ops", { action: "add", name: "A" });
      await ctx.tools.call("request_draft_mode", { quote: "please just block it out" });
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "go" });
    const req = await c.waitFor((m) => m.type === "approval_request");
    expect(req).toMatchObject({ summary: expect.stringContaining("AI Draft") });
    const calls = c.received.filter((m) => m.type === "tool_call");
    expect(calls).toHaveLength(1);
    c.send({ type: "approval", approvalId: (req as any).approvalId, approved: true });
    await c.waitFor((m) => m.type === "turn_done");
  });

  it("cancel resolves a pending approval as declined", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(1)));
    });
    c.send({ type: "user_message", text: "fix" });
    await c.waitFor((m) => m.type === "approval_request");
    c.send({ type: "cancel" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results[0].ok).toBe(false);
    expect(c.received.some((m) => m.type === "tool_call")).toBe(false);
  });
});

describe("pixel budgets and draft mode", () => {
  it("rejects a set_pixels call over 256 pixels without asking", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(257)));
    });
    c.send({ type: "user_message", text: "paint" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(c.received.some((m) => m.type === "approval_request")).toBe(false);
    expect(rec.results[0]).toMatchObject({ ok: false, error: expect.stringContaining("256 pixels per call") });
  });

  it("caps a reply at 1024 pixels and resets next turn", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      for (let i = 0; i < 5; i++) rec.push(await ctx.tools.call("set_pixels", px(256)));
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "paint a lot" });
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results.map((r) => r.ok)).toEqual([true, true, true, true, false]);
    expect(rec.results[4]).toMatchObject({ error: expect.stringContaining("budget for this reply") });

    rec.results.length = 0;
    const before = c.received.length;
    c.send({ type: "user_message", text: "again" });
    await c.waitFor((m) => m.type === "turn_done" && c.received.indexOf(m) >= before);
    expect(rec.results[0].ok).toBe(true);
  });

  it("keeps the AI Draft layer locked until request_draft_mode is approved", async () => {
    const rec = recorder();
    const c = await setup(async function* (ctx) {
      rec.push(await ctx.tools.call("set_pixels", px(10, "ai draft")));
      rec.push(await ctx.tools.call("request_draft_mode", { quote: "no really, block it out for me" }));
      rec.push(await ctx.tools.call("set_pixels", px(2000, "AI Draft")));
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "draw it" });
    await approveNext(c, true);
    await c.waitFor((m) => m.type === "turn_done");
    expect(rec.results[0]).toMatchObject({ ok: false, error: expect.stringContaining("locked") });
    expect(rec.results[1].ok).toBe(true);
    expect(rec.results[2].ok).toBe(true);
    const calls = c.received.filter((m) => m.type === "tool_call").map((m) => (m as any).name);
    expect(calls).toEqual(["ensure_draft_layer", "set_pixels"]);
  });

  it("New chat turns draft mode off again", async () => {
    const rec = recorder();
    let turn = 0;
    const c = await setup(async function* (ctx) {
      turn++;
      if (turn === 1) rec.push(await ctx.tools.call("request_draft_mode", { quote: "block it out please" }));
      else rec.push(await ctx.tools.call("set_pixels", px(5, "AI Draft")));
    });
    c.send({ type: "user_message", text: "one" });
    await approveNext(c, true);
    await c.waitFor((m) => m.type === "turn_done");
    c.send({ type: "new_chat" });
    const before = c.received.length;
    c.send({ type: "user_message", text: "two" });
    await c.waitFor((m) => m.type === "turn_done" && c.received.indexOf(m) >= before);
    expect(rec.results[1]).toMatchObject({ ok: false, error: expect.stringContaining("locked") });
  });

  it("add_color_ramp is forwarded as add_palette_colors", async () => {
    const c = await setup(async function* (ctx) {
      await ctx.tools.call("add_color_ramp", { base: "#c8503c", steps: 3 });
    });
    c.send({ type: "set_auto_approve", enabled: true });
    c.send({ type: "user_message", text: "ramp" });
    const call = await c.waitFor((m) => m.type === "tool_call");
    expect(call).toMatchObject({ name: "add_palette_colors" });
    expect(((call as any).args.colors as string[]).length).toBe(3);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npx vitest run test/approval.test.ts test/protocol.test.ts`
Expected: FAIL. No `approval_request` is ever sent, edit tools go straight to `tool_call`, and the protocol rejects `approval`.

- [ ] **Step 3: Extend the protocol**

In `bridge/src/protocol.ts` add:
```ts
const Approval = z.object({ type: z.literal("approval"), approvalId: z.string(), approved: z.boolean() });
const SetAutoApprove = z.object({ type: z.literal("set_auto_approve"), enabled: z.boolean() });
```
add both to the `discriminatedUnion` list, and add to `BridgeMessage`:
```ts
  | { type: "approval_request"; approvalId: string; summary: string; sprite?: string }
```

- [ ] **Step 4: Implement the gate in the session**

In `bridge/src/session.ts`:

Add imports:
```ts
import { randomUUID } from "node:crypto";
import { PIXEL_BUDGET, isDraftLayer } from "./tools/constants.js";
import type { ToolDef } from "./tools/definitions.js";
```
(merge `randomUUID` into the existing `node:crypto` import alongside `timingSafeEqual`).

Add fields to `Session`:
```ts
  private autoApprove = false;
  private draftMode = false;
  private turnPixels = 0;
  private approvals = new Map<string, (approved: boolean) => void>();
```

Replace `toolsFor` with:
```ts
  /** Tools for one adapter. Once that adapter is replaced (New chat), its late calls fail silently. */
  private toolsFor(owner: () => Adapter | undefined): ToolHost {
    const stale = () => this.adapter !== owner();
    return {
      call: async (name, args) => {
        if (stale()) return { ok: false, error: "Chat reset" };
        const def = toolDef(name);
        if (!def) return { ok: false, error: `Unknown tool: ${name}` };
        if (def.kind === "edit") {
          const rejection = this.checkBudget(def, args);
          if (rejection) return { ok: false, error: rejection };
          if (def.alwaysAsk || !this.autoApprove) {
            const approved = await this.askApproval(def.summarize!(args), args.sprite);
            if (stale()) return { ok: false, error: "Chat reset" };
            if (!approved) return { ok: false, error: "The artist declined this change. Ask what they would prefer instead." };
          }
          if (def.name === "request_draft_mode") this.draftMode = true;
          if (def.name === "set_pixels" && !isDraftLayer(args.layer)) this.turnPixels += (args.pixels as unknown[]).length;
        }
        this.deps.send({ type: "tool_activity", summary: def.activity(args) });
        const fwd = def.forward ? def.forward(args) : { name, args };
        return this.broker.call(fwd.name, fwd.args);
      },
    };
  }

  /** Returns a rejection message when a set_pixels call breaks the budget or draft rules. */
  private checkBudget(def: ToolDef, args: Record<string, unknown>): string | undefined {
    if (def.name !== "set_pixels") return undefined;
    const n = (args.pixels as unknown[]).length;
    if (isDraftLayer(args.layer)) {
      return this.draftMode
        ? undefined
        : "The AI Draft layer is locked. Offer guidance first; only if the artist insists, call request_draft_mode with their words.";
    }
    if (n > PIXEL_BUDGET.perCall) {
      return `set_pixels is limited to ${PIXEL_BUDGET.perCall} pixels per call (got ${n}). It is for small fixes; guide the artist instead of painting for them.`;
    }
    if (this.turnPixels + n > PIXEL_BUDGET.perTurn) {
      return `The pixel budget for this reply is used up (${PIXEL_BUDGET.perTurn} pixels). Describe the remaining changes so the artist can make them.`;
    }
    return undefined;
  }

  private askApproval(summary: string, sprite: unknown): Promise<boolean> {
    const approvalId = randomUUID();
    return new Promise((resolve) => {
      this.approvals.set(approvalId, resolve);
      this.deps.send({ type: "approval_request", approvalId, summary, ...(typeof sprite === "string" ? { sprite } : {}) });
    });
  }
```

In `handleRaw`'s switch, add:
```ts
      case "approval": {
        const resolve = this.approvals.get(msg.approvalId);
        this.approvals.delete(msg.approvalId);
        resolve?.(msg.approved);
        return;
      }
      case "set_auto_approve":
        this.autoApprove = msg.enabled;
        return;
```

In the `new_chat` case, add `this.draftMode = false;`.

Replace `cancel` with:
```ts
  private cancel(reason: string): void {
    this.adapter?.cancel();
    for (const resolve of this.approvals.values()) resolve(false);
    this.approvals.clear();
    this.broker.cancelAll(reason);
  }
```

In `runTurn`, directly after `this.busy = true;`, add `this.turnPixels = 0;`.

- [ ] **Step 5: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all pass, including every Plan 1 server test. tsc is clean.

- [ ] **Step 6: Commit**

```bash
git add bridge/src/protocol.ts bridge/src/session.ts bridge/test/approval.test.ts bridge/test/protocol.test.ts
git commit -m "feat(bridge): approval gate, pixel budgets, draft mode and auto-approve"
```

---

### Task 3: System prompt for edits

**Files:**
- Modify: `bridge/src/prompt.ts`
- Test: `bridge/test/prompt.test.ts`

**Interfaces:** Produces the `SYSTEM_PROMPT` string (same export as Plan 1).

- [ ] **Step 1: Write the failing test**

`bridge/test/prompt.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { SYSTEM_PROMPT } from "../src/prompt.js";
import { TOOL_DEFS } from "../src/tools/definitions.js";

describe("system prompt", () => {
  it("mentions the rules Claude must follow for edits", () => {
    for (const phrase of ["approval", "Apply", "AI Draft", "request_draft_mode", "reference", "annotate", "one undo"]) {
      expect(SYSTEM_PROMPT).toContain(phrase);
    }
  });
  it("no longer claims there are no editing tools", () => {
    expect(SYSTEM_PROMPT).not.toContain("no drawing or editing tools");
  });
  it("is plain ASCII (the chat font cannot show other glyphs Claude might copy)", () => {
    expect(SYSTEM_PROMPT).toMatch(/^[\x09\x0A\x0D\x20-\x7E]+$/);
  });
  it("only names tools that exist", () => {
    const names = new Set(TOOL_DEFS.map((d) => d.name));
    for (const m of SYSTEM_PROMPT.matchAll(/\b([a-z]+(?:_[a-z]+)+)\b/g)) {
      if (["get_", "set_", "add_", "list_", "request_", "replace_", "layer_", "frame_", "analyze_"].some((p) => m[1].startsWith(p))) {
        expect(names.has(m[1]), m[1]).toBe(true);
      }
    }
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd bridge && npx vitest run test/prompt.test.ts`
Expected: FAIL, because the prompt lacks "approval" and still says "no drawing or editing tools".

- [ ] **Step 3: Replace the prompt**

`bridge/src/prompt.ts`:
```ts
export const SYSTEM_PROMPT = `You are an art assistant living inside Aseprite, the pixel-art editor. You help the artist improve their own work: critique, teaching, color and palette advice, animation feedback, and small, approved edits.

How you work:
- Look before you speak. Call get_sprite_info and get_snapshot before commenting on a sprite. Use get_pixels when exact colors or single-pixel placement matter; snapshots are resized images and can hide that detail. analyze_colors finds near-duplicate colors and unused palette entries.
- Be specific: point to coordinates, frames (numbered from 1, as in Aseprite), layers, and colors by hex.
- Teach. Name the principle behind each suggestion (light direction, value contrast, hue shifting, silhouette readability, cluster shapes, anti-aliasing, animation arcs and timing) so the artist gets better, not just this sprite.
- Be concise. Lead with the one to three changes that matter most. Plain text only: no markdown tables, no emoji (the chat window's font cannot show them).

Tabs and references:
- list_open_sprites shows every open tab. Tabs of kind "reference" (a .png or .jpg opened in Aseprite) are the artist's reference material: look at them with get_snapshot and get_pixels, compare proportions, colors and values against the sprite, but never try to edit them.
- Every tool takes an optional "sprite" argument naming an open tab by file name; omit it for the active tab. Layers are listed bottom to top.

Edits:
- Every edit tool asks the artist for approval first: they see a card with your one-line summary and press Apply or Deny. Say what you are about to change and why before calling the tool. If they deny, ask what they would prefer; do not retry the same edit.
- Each edit is one undo step (Ctrl+Z) for the artist.
- Prefer teaching over doing. To point at a problem, use annotate to draw marks on the "Agent Notes" layer rather than fixing it yourself. Use set_pixels only for small fixes: stray pixels, jaggies, a highlight, anti-aliasing. It is limited to 256 pixels per call and 1024 per reply.
- Palette help: add_color_ramp builds hue-shifted ramps; add_palette_colors and set_palette change the palette; replace_color swaps colors across layers and frames.
- Housekeeping: layer_ops (add, rename, show/hide, opacity, blend mode, move) and frame_ops (add, duplicate, durations, tags). transform does outlines and flips.

You are not an art generator. If the artist asks you to draw, create, or generate artwork for them, push back once, kindly: explain that you are here to help them make it, and offer alternatives such as a construction breakdown, silhouette and proportion marks with annotate, a palette plan, or a critique of their first pass. Only if they insist after that may you call request_draft_mode with their exact words; if they approve, block out rough shapes on the "AI Draft" layer only (40% opacity), then tell them to redraw over it in their own layers and delete the draft layer. Never put generated artwork on the artist's own layers.`;
```

- [ ] **Step 4: Run the tests**

Run: `cd bridge && npx vitest run && npm run typecheck`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bridge/src/prompt.ts bridge/test/prompt.test.ts
git commit -m "feat(bridge): system prompt covers edits, approvals, references and draft mode"
```

---

### Task 4: Lua edit infrastructure and test fixtures

**Files:**
- Create: `extension/agent/tools/edit.lua`, `tests/lua/fixtures.lua`
- Modify: `extension/agent/tools/color.lua` (add `parseHex`, `rgbaOf`), `extension/agent/tools/inspect.lua` (export `render`), `tests/lua/run.lua` (suite list)
- Test: `tests/lua/test_edit.lua`

**Interfaces:**
- Consumes: `sprites.resolve/frame/layer/name` (Plan 1).
- Produces:
  - `color.parseHex(hex) -> r, g, b, a` (errors `"Invalid color '<x>'; use #rrggbb or #rrggbbaa."`), `color.rgbaOf(value, colorMode, palette) -> r, g, b, a`
  - `inspect.render(sprite, frame, layerName?) -> Image` (now public)
  - `edit.DRAFT_LAYER`, `edit.NOTES_LAYER`, `edit.DRAFT_OPACITY = 102`
  - `edit.isReference(sprite) -> bool`, `edit.editableSprite(ref) -> Sprite`, `edit.drawableLayer(sprite, name) -> Layer`
  - `edit.transaction(sprite, label, fn) -> fn's result` (one undo step; restores the active sprite; re-raises errors after rollback)
  - `edit.transparentValue(sprite)`, `edit.pixelValue(sprite, hexOrDot)`, `edit.canvasImage(sprite, layer, frame) -> Image`, `edit.commit(sprite, layer, frame, img)`
  - `edit.int(v) -> integer` (JSON floats to integers)
  - `fixtures.closeAll()`, `fixtures.rgbSprite(name?)` (the Plan 1 4x3 sprite), `fixtures.tmp`, `fixtures.decode(tbl)` (round-trips a Lua table through `json.encode`/`json.decode` to get userdata args)

- [ ] **Step 1: Shared fixtures**

`tests/lua/fixtures.lua`:
```lua
local F = {}
local pc = app.pixelColor

F.tmp = app.fs.joinPath(app.fs.tempPath, "aseagent-tests")
app.fs.makeAllDirectories(F.tmp)

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
```

- [ ] **Step 2: Write the failing tests**

`tests/lua/test_edit.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local edit = require("agent.tools.edit")
local color = require("agent.tools.color")
local pc = app.pixelColor

T.test("parseHex reads #rrggbb and #rrggbbaa and rejects junk", function()
  T.deepEq({ color.parseHex("#0a141e") }, { 10, 20, 30, 255 })
  T.deepEq({ color.parseHex("#0A141E80") }, { 10, 20, 30, 128 })
  T.errors(function() color.parseHex("red") end, "Invalid color 'red'; use #rrggbb or #rrggbbaa.")
end)

T.test("references are non-aseprite tabs; unsaved sprites are editable", function()
  F.closeAll()
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(F.tmp, "ref.png"))
  T.eq(edit.isReference(ref), true)
  local unsaved = Sprite(2, 2)
  T.eq(edit.isReference(unsaved), false)
  app.sprite = ref
  T.errors(function() edit.editableSprite() end, "'ref.png' is a reference image tab; it is read-only.")
end)

T.test("drawableLayer rejects groups and locked layers", function()
  F.closeAll()
  local s = F.rgbSprite()
  local g = s:newGroup()
  g.name = "Grp"
  local locked = s:newLayer()
  locked.name = "Locked"
  locked.isEditable = false
  T.errors(function() edit.drawableLayer(s, "Grp") end, "Layer 'Grp' is a group; name one of its layers.")
  T.errors(function() edit.drawableLayer(s, "Locked") end, "Layer 'Locked' is locked.")
  T.eq(edit.drawableLayer(s, "Body").name, "Body")
end)

T.test("transaction is one undo step and restores the active sprite", function()
  F.closeAll()
  local s = F.rgbSprite()
  local other = Sprite(2, 2)
  app.sprite = other
  edit.transaction(s, "test", function()
    local img = edit.canvasImage(s, s.layers[1], s.frames[1])
    img:drawPixel(3, 2, pc.rgba(0, 0, 255, 255))
    edit.commit(s, s.layers[1], s.frames[1], img)
    s:newLayer().name = "Extra"
  end)
  T.eq(app.sprite == other, true, "active sprite restored")
  T.eq(F.px(s, 3, 2, "Body"), pc.rgba(0, 0, 255, 255))
  T.eq(#s.layers, 2)
  app.sprite = s
  app.undo()
  T.eq(F.px(s, 3, 2, "Body"), 0)
  T.eq(#s.layers, 1)
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(255, 0, 0, 255), "earlier content untouched by the undo")
end)

T.test("a failing transaction rolls back and re-raises", function()
  F.closeAll()
  local s = F.rgbSprite()
  T.errors(function()
    edit.transaction(s, "boom", function()
      local img = edit.canvasImage(s, s.layers[1], s.frames[1])
      img:drawPixel(2, 2, pc.rgba(1, 1, 1, 255))
      edit.commit(s, s.layers[1], s.frames[1], img)
      error("boom", 0)
    end)
  end, "boom")
  T.eq(F.px(s, 2, 2, "Body"), 0)
end)

T.test("pixelValue maps colors per color mode", function()
  F.closeAll()
  local rgb = F.rgbSprite()
  T.eq(edit.pixelValue(rgb, "#0a141e"), pc.rgba(10, 20, 30, 255))
  T.eq(edit.pixelValue(rgb, "."), 0)
  local gray = Sprite(2, 2, ColorMode.GRAYSCALE)
  T.eq(pc.grayaV(edit.pixelValue(gray, "#ffffff")), 255)
  local idx = Sprite(2, 2, ColorMode.INDEXED)
  idx.palettes[1]:resize(3)
  idx.palettes[1]:setColor(2, Color{ r = 10, g = 20, b = 30, a = 255 })
  T.eq(edit.pixelValue(idx, "#0a141e"), 2)
  T.eq(edit.pixelValue(idx, "."), idx.transparentColor)
  T.errors(function() edit.pixelValue(idx, "#123456") end, "#123456 is not in the palette")
end)

T.test("canvasImage covers the whole canvas even when the cel is smaller or missing", function()
  F.closeAll()
  local s = F.rgbSprite()
  local l = s:newLayer()
  l.name = "Empty"
  local img = edit.canvasImage(s, l, s.frames[1])
  T.eq(img.width, 4)
  T.eq(img.height, 3)
  T.eq(img:getPixel(0, 0), 0)
end)

T.test("int converts JSON floats", function()
  T.eq(math.type(edit.int(F.decode({ n = 3 }).n)), "integer")
  T.eq(edit.int(2.0), 2)
end)

F.closeAll()
```

Update `tests/lua/run.lua`'s suite list to:
```lua
local suites = {
  "test_chat_model", "test_chat_render", "test_tools_inspect", "test_connection",
  "test_edit", "test_pixels", "test_palette", "test_layers_frames", "test_geometry",
  "test_annotate_transform", "test_analyze",
}
```

- [ ] **Step 3: Run to verify failure**

Run: `scripts/test-lua.sh edit`
Expected: non-zero exit. `agent.tools.edit` is not found, and `color.parseHex` is nil.

- [ ] **Step 4: Implement**

Append to `extension/agent/tools/color.lua` (before `return M`):
```lua
function M.parseHex(hex)
  local s = type(hex) == "string" and hex:match("^#(%x+)$")
  if not s or (#s ~= 6 and #s ~= 8) then
    error("Invalid color '" .. tostring(hex) .. "'; use #rrggbb or #rrggbbaa.", 0)
  end
  local a = #s == 8 and tonumber(s:sub(7, 8), 16) or 255
  return tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16), a
end

-- r, g, b, a of a raw pixel value in the given color mode.
function M.rgbaOf(value, colorMode, palette)
  if colorMode == ColorMode.RGB then
    return pc.rgbaR(value), pc.rgbaG(value), pc.rgbaB(value), pc.rgbaA(value)
  elseif colorMode == ColorMode.GRAYSCALE then
    local v = pc.grayaV(value)
    return v, v, v, pc.grayaA(value)
  end
  if value >= #palette then return 0, 0, 0, 0 end
  local c = palette:getColor(value)
  return c.red, c.green, c.blue, c.alpha
end
```

In `extension/agent/tools/inspect.lua`, rename `local function render(` to `function M.render(`. Move the `local M = { snapshotDir = nil }` line above it if needed, and replace the three internal `render(` calls with `M.render(`.

`extension/agent/tools/edit.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")

local M = {
  DRAFT_LAYER = "AI Draft",
  NOTES_LAYER = "Agent Notes",
  DRAFT_OPACITY = 102,
}

function M.int(v)
  return math.tointeger(v) or math.floor(v)
end

function M.isReference(sprite)
  local ext = app.fs.fileExtension(sprite.filename):lower()
  return ext ~= "" and ext ~= "aseprite" and ext ~= "ase"
end

function M.editableSprite(ref)
  local s = sprites.resolve(ref)
  if M.isReference(s) then
    error("'" .. sprites.name(s) .. "' is a reference image tab; it is read-only.", 0)
  end
  return s
end

function M.drawableLayer(sprite, name)
  local l = sprites.layer(sprite, name)
  if l.isGroup then error("Layer '" .. name .. "' is a group; name one of its layers.", 0) end
  if l.isTilemap or l.isReference then error("Layer '" .. name .. "' is a tilemap or reference layer; it can't be edited.", 0) end
  if not l.isEditable then error("Layer '" .. name .. "' is locked.", 0) end
  return l
end

-- Runs fn as one undoable step on `sprite` (temporarily active). Errors roll back and re-raise.
function M.transaction(sprite, label, fn)
  local prev = app.sprite
  if prev ~= sprite then app.sprite = sprite end
  local out
  local ok, err = pcall(function()
    app.transaction("Agent: " .. label, function() out = fn() end)
  end)
  if prev and prev ~= sprite then app.sprite = prev end
  if not ok then error(err, 0) end
  return out
end

function M.transparentValue(sprite)
  if sprite.colorMode == ColorMode.INDEXED then return sprite.transparentColor end
  return 0
end

function M.pixelValue(sprite, hex)
  if hex == "." then return M.transparentValue(sprite) end
  local r, g, b, a = color.parseHex(hex)
  local pc = app.pixelColor
  if sprite.colorMode == ColorMode.RGB then return pc.rgba(r, g, b, a) end
  if sprite.colorMode == ColorMode.GRAYSCALE then
    return pc.graya(math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5), a)
  end
  local pal = sprite.palettes[1]
  for i = 0, #pal - 1 do
    local c = pal:getColor(i)
    if c.red == r and c.green == g and c.blue == b and c.alpha == a then return i end
  end
  error(hex .. " is not in the palette of " .. sprites.name(sprite) .. " (indexed mode). Add it with add_palette_colors first.", 0)
end

-- A full-canvas copy of the layer's image in `frame` (transparent where there is no cel).
function M.canvasImage(sprite, layer, frame)
  local img = Image(sprite.spec)
  img:clear(M.transparentValue(sprite))
  local cel = layer:cel(frame)
  if cel then img:drawImage(cel.image, cel.position, 255, BlendMode.SRC) end
  return img
end

-- Writes a full-canvas image back as the layer's cel in `frame`. Call inside M.transaction.
function M.commit(sprite, layer, frame, img)
  local cel = layer:cel(frame)
  if cel then
    cel.image = img
    cel.position = Point(0, 0)
  else
    sprite:newCel(layer, frame, img, Point(0, 0))
  end
end

return M
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all suites pass (`0 failed`). Suites whose files don't exist yet are skipped by `run.lua`.

- [ ] **Step 6: Commit**

```bash
git add extension/agent/tools/edit.lua extension/agent/tools/color.lua extension/agent/tools/inspect.lua tests/lua/fixtures.lua tests/lua/test_edit.lua tests/lua/run.lua
git commit -m "feat(extension): edit infrastructure (references, layers, one-step transactions, colors)"
```

---

### Task 5: Pixel and palette tools (Lua)

**Files:**
- Create: `extension/agent/tools/pixels.lua`, `extension/agent/tools/palette.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_pixels.lua`, `tests/lua/test_palette.lua`

**Interfaces:**
- Consumes: `edit.*`, `color.*`, `sprites.*` (Task 4).
- Produces handlers (registered in `init.lua`):
  - `set_pixels{sprite?, layer, frame?, pixels[{x,y,color}]} -> {sprite, layer, frame, changed}`. Creates "AI Draft" (opacity 102) if it's the target and missing.
  - `replace_color{sprite?, from, to, tolerance?, layer?, frames?{from,to}, region?} -> {sprite, replaced, cels}`
  - `set_palette{sprite?, colors} -> {sprite, size}`
  - `add_palette_colors{sprite?, colors} -> {sprite, added, size}`

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_pixels.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args)) end

T.test("set_pixels paints and erases in one undo step", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("set_pixels", { layer = "Body", pixels = { { x = 3, y = 2, color = "#0000ff" }, { x = 0, y = 0, color = "." } } })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.changed, 2)
  T.eq(F.px(s, 3, 2, "Body"), pc.rgba(0, 0, 255, 255))
  T.eq(F.px(s, 0, 0, "Body"), 0)
  app.undo()
  T.eq(F.px(s, 3, 2, "Body"), 0)
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(255, 0, 0, 255))
end)

T.test("set_pixels rejects out-of-canvas pixels without changing anything", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("set_pixels", { layer = "Body", pixels = { { x = 1, y = 1, color = "#0000ff" }, { x = 9, y = 0, color = "#0000ff" } } })
  T.eq(r.error, "Pixel (9,0) is outside the sprite (4x3).")
  T.eq(F.px(s, 1, 1, "Body"), 0)
end)

T.test("set_pixels refuses reference tabs", function()
  F.closeAll()
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(F.tmp, "ref2.png"))
  app.sprite = ref
  T.eq(call("set_pixels", { layer = "Layer 1", pixels = { { x = 0, y = 0, color = "#000000" } } }).error,
    "'ref2.png' is a reference image tab; it is read-only.")
end)

T.test("set_pixels on AI Draft creates the layer at 40% opacity", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("set_pixels", { layer = "AI Draft", pixels = { { x = 0, y = 1, color = "#ffffff" } } })
  T.eq(r.ok, true, r.error)
  local top = s.layers[#s.layers]
  T.eq(top.name, "AI Draft")
  T.eq(top.opacity, 102)
end)

T.test("replace_color swaps colors across frames, with tolerance and region", function()
  F.closeAll()
  local s = F.rgbSprite()
  s:newFrame(1)
  local r = call("replace_color", { from = "#ff0000", to = "#00ffff" })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.replaced, 2)
  T.eq(F.px(s, 0, 0, "Body", 1), pc.rgba(0, 255, 255, 255))
  T.eq(F.px(s, 0, 0, "Body", 2), pc.rgba(0, 255, 255, 255))
  app.undo()
  T.eq(F.px(s, 0, 0, "Body", 2), pc.rgba(255, 0, 0, 255))
  T.eq(call("replace_color", { from = "#fe0101", to = "#000000", tolerance = 0 }).data.replaced, 0)
  T.eq(call("replace_color", { from = "#fe0101", to = "#000000", tolerance = 2, frames = { from = 1, to = 1 } }).data.replaced, 1)
  T.eq(call("replace_color", { from = "#00ff00", to = "#000000", region = { x = 2, y = 0, w = 2, h = 3 } }).data.replaced, 0)
end)

T.test("replace_color in indexed mode remaps indices", function()
  F.closeAll()
  local s = Sprite(2, 1, ColorMode.INDEXED)
  local pal = s.palettes[1]
  pal:resize(3)
  pal:setColor(1, Color{ r = 10, g = 20, b = 30 })
  pal:setColor(2, Color{ r = 40, g = 50, b = 60 })
  local img = s.cels[1].image:clone()
  img:drawPixel(0, 0, 1)
  s.cels[1].image = img
  app.sprite = s
  local r = call("replace_color", { from = "#0a141e", to = "#28323c" })
  T.eq(r.data.replaced, 1)
  T.eq(s.cels[1].image:getPixel(0, 0), 2)
end)
```

`tests/lua/test_palette.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")

local function call(name, args) return tools.dispatch(name, F.decode(args)) end

T.test("set_palette replaces the palette in one undo step", function()
  F.closeAll()
  local s = F.rgbSprite()
  local before = #s.palettes[1]
  local r = call("set_palette", { colors = { "#000000", "#ffffff", "#ff000080" } })
  T.eq(r.ok, true, r.error)
  T.eq(#s.palettes[1], 3)
  T.eq(s.palettes[1]:getColor(2).alpha, 128)
  app.undo()
  T.eq(#s.palettes[1], before)
end)

T.test("add_palette_colors appends new colors and skips existing ones", function()
  F.closeAll()
  local s = F.rgbSprite()
  call("set_palette", { colors = { "#000000" } })
  local r = call("add_palette_colors", { colors = { "#000000", "#123456", "#abcdef" } })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.added, 2)
  T.eq(#s.palettes[1], 3)
  T.eq(s.palettes[1]:getColor(1).red, 0x12)
end)

T.test("indexed palettes are limited to 256 colors", function()
  F.closeAll()
  local s = Sprite(2, 2, ColorMode.INDEXED)
  app.sprite = s
  local pal = s.palettes[1]
  pal:resize(256)
  for i = 0, 255 do pal:setColor(i, Color{ r = i, g = 0, b = 0 }) end
  T.eq(call("add_palette_colors", { colors = { "#123457" } }).error,
    "The palette would exceed 256 colors (indexed mode). Replace or merge colors first.")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh pixels && scripts/test-lua.sh palette`
Expected: failures `Unknown tool: set_pixels` etc.

- [ ] **Step 3: Implement pixels**

`extension/agent/tools/pixels.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local function ensureDraftLayer(s)
  for _, l in ipairs(s.layers) do
    if l.name == edit.DRAFT_LAYER then return l end
  end
  local l
  edit.transaction(s, "create AI Draft layer", function()
    l = s:newLayer()
    l.name = edit.DRAFT_LAYER
    l.opacity = edit.DRAFT_OPACITY
  end)
  return l
end
M.ensureDraftLayer = ensureDraftLayer

function M.set_pixels(args)
  local s = edit.editableSprite(args.sprite)
  local layerName = tostring(args.layer)
  if layerName:lower() == edit.DRAFT_LAYER:lower() then
    ensureDraftLayer(s)
    layerName = edit.DRAFT_LAYER
  end
  local layer = edit.drawableLayer(s, layerName)
  local frame = sprites.frame(s, args.frame)
  local pts = {}
  for i = 1, #args.pixels do
    local p = args.pixels[i]
    local x, y = edit.int(p.x), edit.int(p.y)
    if x < 0 or y < 0 or x >= s.width or y >= s.height then
      error(("Pixel (%d,%d) is outside the sprite (%dx%d)."):format(x, y, s.width, s.height), 0)
    end
    pts[#pts + 1] = { x = x, y = y, v = edit.pixelValue(s, p.color) }
  end
  edit.transaction(s, ("set %d pixels"):format(#pts), function()
    local img = edit.canvasImage(s, layer, frame)
    for _, p in ipairs(pts) do img:drawPixel(p.x, p.y, p.v) end
    edit.commit(s, layer, frame, img)
  end)
  return { sprite = sprites.name(s), layer = layer.name, frame = frame.frameNumber, changed = #pts }
end

local function editableLayers(layers, out)
  for _, l in ipairs(layers) do
    if l.isGroup then
      editableLayers(l.layers, out)
    elseif l.isEditable and not l.isTilemap and not l.isReference then
      out[#out + 1] = l
    end
  end
  return out
end

function M.replace_color(args)
  local s = edit.editableSprite(args.sprite)
  local layers = args.layer and { edit.drawableLayer(s, args.layer) } or editableLayers(s.layers, {})
  local fr, fg, fb, fa = color.parseHex(args.from)
  local toValue = edit.pixelValue(s, args.to)
  local tol = args.tolerance and edit.int(args.tolerance) or 0
  local first, last = 1, #s.frames
  if args.frames then
    first, last = edit.int(args.frames.from), math.min(edit.int(args.frames.to), #s.frames)
  end
  local rx, ry, rw, rh = 0, 0, s.width, s.height
  if args.region then
    rx, ry, rw, rh = edit.int(args.region.x), edit.int(args.region.y), edit.int(args.region.w), edit.int(args.region.h)
  end
  local pal = s.palettes[1]
  local function matches(v)
    local r, g, b, a = color.rgbaOf(v, s.colorMode, pal)
    return math.abs(r - fr) <= tol and math.abs(g - fg) <= tol and math.abs(b - fb) <= tol and math.abs(a - fa) <= tol
  end
  local replaced, cels = 0, 0
  edit.transaction(s, ("replace %s with %s"):format(args.from, args.to), function()
    for _, layer in ipairs(layers) do
      for f = first, last do
        local cel = layer:cel(f)
        if cel then
          local img, pos, changed = cel.image:clone(), cel.position, 0
          for y = 0, img.height - 1 do
            local sy = pos.y + y
            if sy >= ry and sy < ry + rh then
              for x = 0, img.width - 1 do
                local sx = pos.x + x
                if sx >= rx and sx < rx + rw and matches(img:getPixel(x, y)) then
                  img:drawPixel(x, y, toValue)
                  changed = changed + 1
                end
              end
            end
          end
          if changed > 0 then
            cel.image = img
            replaced, cels = replaced + changed, cels + 1
          end
        end
      end
    end
  end)
  return { sprite = sprites.name(s), replaced = replaced, cels = cels }
end

return M
```

- [ ] **Step 4: Implement palette**

`extension/agent/tools/palette.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local edit = require("agent.tools.edit")

local M = {}

local function toColor(hex)
  local r, g, b, a = color.parseHex(hex)
  return Color{ r = r, g = g, b = b, a = a }
end

function M.set_palette(args)
  local s = edit.editableSprite(args.sprite)
  local n = #args.colors
  local colors = {}
  for i = 1, n do colors[i] = toColor(args.colors[i]) end
  edit.transaction(s, ("set palette (%d colors)"):format(n), function()
    local pal = Palette(n)
    for i = 1, n do pal:setColor(i - 1, colors[i]) end
    s:setPalette(pal)
  end)
  return { sprite = sprites.name(s), size = #s.palettes[1] }
end

function M.add_palette_colors(args)
  local s = edit.editableSprite(args.sprite)
  local pal = s.palettes[1]
  local existing = {}
  for i = 0, #pal - 1 do existing[color.fromColor(pal:getColor(i))] = true end
  local new = {}
  for i = 1, #args.colors do
    local c = toColor(args.colors[i])
    local key = color.fromColor(c)
    if not existing[key] then
      existing[key] = true
      new[#new + 1] = c
    end
  end
  if #new == 0 then return { sprite = sprites.name(s), added = 0, size = #pal } end
  if s.colorMode == ColorMode.INDEXED and #pal + #new > 256 then
    error("The palette would exceed 256 colors (indexed mode). Replace or merge colors first.", 0)
  end
  edit.transaction(s, ("add %d palette colors"):format(#new), function()
    local base = #pal
    pal:resize(base + #new)
    for i, c in ipairs(new) do pal:setColor(base + i - 1, c) end
  end)
  return { sprite = sprites.name(s), added = #new, size = #s.palettes[1] }
end

return M
```

Replace `extension/agent/tools/init.lua` with:
```lua
local registry = require("agent.tools.registry")
local inspect = require("agent.tools.inspect")
local pixels = require("agent.tools.pixels")
local palette = require("agent.tools.palette")

registry.register{
  get_sprite_info = inspect.get_sprite_info,
  get_snapshot = inspect.get_snapshot,
  get_pixels = inspect.get_pixels,
  get_palette = inspect.get_palette,
  set_pixels = pixels.set_pixels,
  replace_color = pixels.replace_color,
  set_palette = palette.set_palette,
  add_palette_colors = palette.add_palette_colors,
}

return registry
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add extension/agent/tools/pixels.lua extension/agent/tools/palette.lua extension/agent/tools/init.lua tests/lua/test_pixels.lua tests/lua/test_palette.lua
git commit -m "feat(extension): set_pixels, replace_color and palette tools"
```

---

### Task 6: Layer and frame tools (Lua)

**Files:**
- Create: `extension/agent/tools/layers.lua`, `extension/agent/tools/frames.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_layers_frames.lua`

**Interfaces:**
- Consumes: `edit.*`, `pixels.ensureDraftLayer` (Task 5).
- Produces handlers:
  - `layer_ops{sprite?, action, layer?, name?, visible?, opacity?, blendMode?, toIndex?} -> {sprite, layer, index?}`
  - `ensure_draft_layer{sprite?} -> {sprite, layer = "AI Draft", opacity = 102, created}`
  - `frame_ops{sprite?, action, frame?, toFrame?, durationMs?, name?} -> {sprite, frame?, frameCount}`

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_layers_frames.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")

local function call(name, args) return tools.dispatch(name, F.decode(args)) end

T.test("layer_ops add, rename, set, move - each one undo step", function()
  F.closeAll()
  local s = F.rgbSprite()
  T.eq(call("layer_ops", { action = "add", name = "Shading" }).ok, true)
  T.eq(s.layers[2].name, "Shading")
  T.eq(call("layer_ops", { action = "add", name = "Shading" }).error, "A layer named 'Shading' already exists.")
  T.eq(call("layer_ops", { action = "rename", layer = "Shading", name = "Shade" }).ok, true)
  local r = call("layer_ops", { action = "set", layer = "Shade", visible = false, opacity = 128, blendMode = "multiply" })
  T.eq(r.ok, true, r.error)
  T.eq(s.layers[2].isVisible, false)
  T.eq(s.layers[2].opacity, 128)
  T.eq(s.layers[2].blendMode, BlendMode.MULTIPLY)
  app.undo()
  T.eq(s.layers[2].opacity, 255)
  T.eq(s.layers[2].isVisible, true)
  T.eq(call("layer_ops", { action = "move", layer = "Shade", toIndex = 1 }).ok, true)
  T.eq(s.layers[1].name, "Shade")
end)

T.test("layer_ops reports missing arguments plainly", function()
  F.closeAll()
  F.rgbSprite()
  T.eq(call("layer_ops", { action = "add" }).error, "layer_ops add needs 'name'.")
  T.eq(call("layer_ops", { action = "set", name = "x" }).error, "layer_ops set needs 'layer'.")
  T.eq(call("layer_ops", { action = "set", layer = "Body", blendMode = "sparkle" }).error, "Unknown blend mode 'sparkle'.")
end)

T.test("ensure_draft_layer creates the draft layer once", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("ensure_draft_layer", {})
  T.eq(r.ok, true, r.error)
  T.eq(r.data.created, true)
  T.eq(s.layers[#s.layers].name, "AI Draft")
  T.eq(s.layers[#s.layers].opacity, 102)
  T.eq(call("ensure_draft_layer", {}).data.created, false)
  T.eq(#s.layers, 2)
end)

T.test("frame_ops add_empty, duplicate, set_duration, add_tag", function()
  F.closeAll()
  local s = F.rgbSprite()
  local d = call("frame_ops", { action = "duplicate", frame = 1 })
  T.eq(d.ok, true, d.error)
  T.eq(#s.frames, 2)
  T.eq(F.px(s, 0, 0, "Body", 2), F.px(s, 0, 0, "Body", 1))
  local e = call("frame_ops", { action = "add_empty" })
  T.eq(e.data.frame, 3)
  T.eq(s.layers[1]:cel(3), nil)
  T.eq(call("frame_ops", { action = "set_duration", frame = 1, toFrame = 3, durationMs = 150 }).ok, true)
  T.eq(math.floor(s.frames[3].duration * 1000 + 0.5), 150)
  T.eq(call("frame_ops", { action = "add_tag", name = "idle", frame = 1, toFrame = 2 }).ok, true)
  T.eq(s.tags[1].name, "idle")
  T.eq(s.tags[1].toFrame.frameNumber, 2)
  app.undo()
  T.eq(#s.tags, 0)
  T.eq(call("frame_ops", { action = "set_duration", frame = 9, durationMs = 100 }).error, "Frame 9 does not exist (sprite has 3 frames).")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh layers`
Expected: `Unknown tool: layer_ops`.

- [ ] **Step 3: Implement**

`extension/agent/tools/layers.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local pixels = require("agent.tools.pixels")

local M = {}

local function need(args, action, key)
  if args[key] == nil then error(("layer_ops %s needs '%s'."):format(action, key), 0) end
  return args[key]
end

local function exists(s, name)
  local ok = pcall(sprites.layer, s, name)
  return ok
end

function M.layer_ops(args)
  local s = edit.editableSprite(args.sprite)
  local action = args.action
  if action == "add" then
    local name = need(args, "add", "name")
    if exists(s, name) then error("A layer named '" .. name .. "' already exists.", 0) end
    local l
    edit.transaction(s, "add layer " .. name, function()
      l = s:newLayer()
      l.name = name
      if args.toIndex then l.stackIndex = edit.int(args.toIndex) end
    end)
    return { sprite = sprites.name(s), layer = l.name, index = l.stackIndex }
  end

  local layer = sprites.layer(s, need(args, action, "layer"))
  if not layer.isEditable then error("Layer '" .. layer.name .. "' is locked.", 0) end
  if action == "rename" then
    local name = need(args, "rename", "name")
    if exists(s, name) then error("A layer named '" .. name .. "' already exists.", 0) end
    edit.transaction(s, "rename layer", function() layer.name = name end)
  elseif action == "set" then
    local mode
    if args.blendMode then
      mode = BlendMode[tostring(args.blendMode):upper()]
      if mode == nil then error("Unknown blend mode '" .. tostring(args.blendMode) .. "'.", 0) end
    end
    edit.transaction(s, "set layer " .. layer.name, function()
      if args.visible ~= nil then layer.isVisible = args.visible end
      if args.opacity then layer.opacity = edit.int(args.opacity) end
      if mode then layer.blendMode = mode end
    end)
  elseif action == "move" then
    local to = edit.int(need(args, "move", "toIndex"))
    edit.transaction(s, "move layer " .. layer.name, function() layer.stackIndex = to end)
  else
    error("Unknown layer action '" .. tostring(action) .. "'.", 0)
  end
  return { sprite = sprites.name(s), layer = layer.name, index = layer.stackIndex }
end

function M.ensure_draft_layer(args)
  local s = edit.editableSprite(args.sprite)
  local created = not exists(s, edit.DRAFT_LAYER)
  pixels.ensureDraftLayer(s)
  return { sprite = sprites.name(s), layer = edit.DRAFT_LAYER, opacity = edit.DRAFT_OPACITY, created = created }
end

return M
```

`extension/agent/tools/frames.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")

local M = {}

local function need(args, action, key)
  if args[key] == nil then error(("frame_ops %s needs '%s'."):format(action, key), 0) end
  return args[key]
end

function M.frame_ops(args)
  local s = edit.editableSprite(args.sprite)
  local action = args.action
  local result = { sprite = sprites.name(s) }
  if action == "add_empty" then
    local after = args.frame and sprites.frame(s, args.frame).frameNumber or #s.frames
    edit.transaction(s, "add empty frame", function() s:newEmptyFrame(after + 1) end)
    result.frame = after + 1
  elseif action == "duplicate" then
    local n = sprites.frame(s, need(args, "duplicate", "frame")).frameNumber
    edit.transaction(s, "duplicate frame " .. n, function() s:newFrame(n) end)
    result.frame = n + 1
  elseif action == "set_duration" then
    local from = sprites.frame(s, need(args, "set_duration", "frame")).frameNumber
    local to = args.toFrame and sprites.frame(s, args.toFrame).frameNumber or from
    local seconds = edit.int(need(args, "set_duration", "durationMs")) / 1000
    edit.transaction(s, "set frame durations", function()
      for f = from, to do s.frames[f].duration = seconds end
    end)
  elseif action == "add_tag" then
    local name = need(args, "add_tag", "name")
    local from = sprites.frame(s, need(args, "add_tag", "frame")).frameNumber
    local to = args.toFrame and sprites.frame(s, args.toFrame).frameNumber or from
    edit.transaction(s, "add tag " .. name, function() s:newTag(from, to).name = name end)
  else
    error("Unknown frame action '" .. tostring(action) .. "'.", 0)
  end
  result.frameCount = #s.frames
  return result
end

return M
```

In `extension/agent/tools/init.lua`, add these requires:
```lua
local layers = require("agent.tools.layers")
local frames = require("agent.tools.frames")
```
and these registry entries:
```lua
  layer_ops = layers.layer_ops,
  ensure_draft_layer = layers.ensure_draft_layer,
  frame_ops = frames.frame_ops,
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
git add extension/agent/tools/layers.lua extension/agent/tools/frames.lua extension/agent/tools/init.lua tests/lua/test_layers_frames.lua
git commit -m "feat(extension): layer and frame housekeeping tools and the AI Draft layer"
```

---

### Task 7: Geometry, annotate, and transform (Lua)

**Files:**
- Create: `extension/agent/tools/geometry.lua`, `extension/agent/tools/annotate.lua`, `extension/agent/tools/transform.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_geometry.lua`, `tests/lua/test_annotate_transform.lua`

**Interfaces:**
- Consumes: `edit.*`.
- Produces:
  - `geometry.line(x1,y1,x2,y2)`, `geometry.rect(x,y,w,h)`, `geometry.circle(cx,cy,r)`, `geometry.arrow(x1,y1,x2,y2)`, `geometry.dot(x,y)`. Each returns a de-duplicated list of `{x, y}`.
  - handlers `annotate{sprite?, frame?, clear?, color?, shapes[]} -> {sprite, layer = "Agent Notes", frame, marks}`
  - handler `transform{sprite?, layer, frame?, action, color?, place?, region?} -> {sprite, layer, frame, changed}`

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_geometry.lua`:
```lua
local T = require("testlib")
local G = require("agent.tools.geometry")

local function key(pts)
  local t = {}
  for _, p in ipairs(pts) do t[#t + 1] = p.x .. "," .. p.y end
  table.sort(t)
  return table.concat(t, " ")
end

T.test("line is a Bresenham line including both ends", function()
  T.eq(key(G.line(0, 0, 3, 0)), "0,0 1,0 2,0 3,0")
  T.eq(key(G.line(0, 0, 2, 2)), "0,0 1,1 2,2")
  T.eq(#G.line(0, 0, 5, 2), 6)
end)

T.test("rect is the outline only", function()
  T.eq(key(G.rect(0, 0, 3, 3)), "0,0 0,1 0,2 1,0 1,2 2,0 2,1 2,2")
  T.eq(#G.rect(0, 0, 1, 1), 1)
end)

T.test("circle is symmetric and r=0 is a dot", function()
  T.eq(key(G.circle(5, 5, 0)), "5,5")
  local pts = G.circle(0, 0, 3)
  local set = {}
  for _, p in ipairs(pts) do set[p.x .. "," .. p.y] = true end
  for _, p in ipairs(pts) do
    T.eq(set[(-p.x) .. "," .. p.y], true)
    T.eq(set[p.x .. "," .. (-p.y)], true)
  end
  T.eq(set["3,0"], true)
  T.eq(set["0,0"], nil, "outline, not filled")
end)

T.test("arrow is the shaft plus a head at the tip", function()
  local shaft = G.line(0, 0, 10, 0)
  local arrow = G.arrow(0, 0, 10, 0)
  T.eq(#arrow > #shaft, true)
  local set = {}
  for _, p in ipairs(arrow) do set[p.x .. "," .. p.y] = true end
  T.eq(set["10,0"], true)
  T.eq(set["8,2"] or set["8,-2"] or set["7,2"] or set["7,-2"], true, "head wings behind the tip")
end)

T.test("points are de-duplicated", function()
  T.eq(#G.line(2, 2, 2, 2), 1)
end)
```

`tests/lua/test_annotate_transform.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args)) end

T.test("annotate draws on a new top Agent Notes layer, clipped to the canvas", function()
  F.closeAll()
  local s = F.rgbSprite()
  local r = call("annotate", { shapes = { { type = "dot", x = 1, y = 1 }, { type = "line", x = 0, y = 2, x2 = 10, y2 = 2 } } })
  T.eq(r.ok, true, r.error)
  T.eq(r.data.marks, 2)
  local top = s.layers[#s.layers]
  T.eq(top.name, "Agent Notes")
  T.eq(F.px(s, 1, 1, "Agent Notes"), pc.rgba(255, 59, 48, 255))
  T.eq(F.px(s, 3, 2, "Agent Notes"), pc.rgba(255, 59, 48, 255))
  T.eq(F.px(s, 1, 1, "Body"), 0, "artist's layer untouched")
  app.undo()
  T.eq(#s.layers, 1, "one undo removes notes layer and marks")
end)

T.test("annotate clear wipes previous marks on that frame", function()
  F.closeAll()
  local s = F.rgbSprite()
  call("annotate", { shapes = { { type = "dot", x = 0, y = 0 } } })
  call("annotate", { clear = true, color = "#00ff00", shapes = { { type = "dot", x = 3, y = 0 } } })
  T.eq(F.px(s, 0, 0, "Agent Notes"), 0)
  T.eq(F.px(s, 3, 0, "Agent Notes"), pc.rgba(0, 255, 0, 255))
end)

T.test("annotate needs the right fields per shape", function()
  F.closeAll()
  F.rgbSprite()
  T.eq(call("annotate", { shapes = { { type = "line", x = 0, y = 0 } } }).error, "A line needs x2 and y2.")
  T.eq(call("annotate", { shapes = { { type = "circle", x = 0, y = 0 } } }).error, "A circle needs r.")
end)

T.test("transform outline outside surrounds opaque pixels with the color", function()
  F.closeAll()
  local s = F.rgbSprite() -- red (0,0), green (1,0)
  local r = call("transform", { layer = "Body", action = "outline", color = "#000000" })
  T.eq(r.ok, true, r.error)
  T.eq(F.px(s, 0, 1, "Body"), pc.rgba(0, 0, 0, 255))
  T.eq(F.px(s, 2, 0, "Body"), pc.rgba(0, 0, 0, 255))
  T.eq(F.px(s, 2, 1, "Body"), 0, "diagonal neighbours are not outlined")
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(255, 0, 0, 255), "original pixels kept")
  app.undo()
  T.eq(F.px(s, 0, 1, "Body"), 0)
end)

T.test("transform outline inside recolors the edge pixels", function()
  F.closeAll()
  local s = F.rgbSprite()
  call("transform", { layer = "Body", action = "outline", place = "inside", color = "#0000ff" })
  T.eq(F.px(s, 0, 0, "Body"), pc.rgba(0, 0, 255, 255))
end)

T.test("transform flips the whole layer or a region", function()
  F.closeAll()
  local s = F.rgbSprite()
  call("transform", { layer = "Body", action = "flip_horizontal" })
  T.eq(F.px(s, 3, 0, "Body"), pc.rgba(255, 0, 0, 255))
  T.eq(F.px(s, 2, 0, "Body"), pc.rgba(0, 255, 0, 255))
  app.undo()
  call("transform", { layer = "Body", action = "flip_vertical", region = { x = 0, y = 0, w = 1, h = 3 } })
  T.eq(F.px(s, 0, 2, "Body"), pc.rgba(255, 0, 0, 255))
  T.eq(F.px(s, 1, 0, "Body"), pc.rgba(0, 255, 0, 255), "outside the region untouched")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh geometry && scripts/test-lua.sh annotate`
Expected: `module 'agent.tools.geometry' not found`.

- [ ] **Step 3: Implement geometry**

`extension/agent/tools/geometry.lua`:
```lua
local G = {}

local function collector()
  local pts, seen = {}, {}
  local function add(x, y)
    local k = x .. "," .. y
    if not seen[k] then
      seen[k] = true
      pts[#pts + 1] = { x = x, y = y }
    end
  end
  return pts, add
end

local function bresenham(add, x1, y1, x2, y2)
  local dx, dy = math.abs(x2 - x1), -math.abs(y2 - y1)
  local sx, sy = x1 < x2 and 1 or -1, y1 < y2 and 1 or -1
  local err = dx + dy
  while true do
    add(x1, y1)
    if x1 == x2 and y1 == y2 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x1 = x1 + sx end
    if e2 <= dx then err = err + dx; y1 = y1 + sy end
  end
end

function G.dot(x, y)
  return { { x = x, y = y } }
end

function G.line(x1, y1, x2, y2)
  local pts, add = collector()
  bresenham(add, x1, y1, x2, y2)
  return pts
end

function G.rect(x, y, w, h)
  local pts, add = collector()
  local x2, y2 = x + w - 1, y + h - 1
  bresenham(add, x, y, x2, y)
  bresenham(add, x, y2, x2, y2)
  bresenham(add, x, y, x, y2)
  bresenham(add, x2, y, x2, y2)
  return pts
end

function G.circle(cx, cy, r)
  local pts, add = collector()
  local x, y, err = r, 0, 1 - r
  while x >= y do
    for _, p in ipairs{ { x, y }, { y, x }, { -y, x }, { -x, y }, { -x, -y }, { -y, -x }, { y, -x }, { x, -y } } do
      add(cx + p[1], cy + p[2])
    end
    y = y + 1
    if err < 0 then
      err = err + 2 * y + 1
    else
      x = x - 1
      err = err + 2 * (y - x) + 1
    end
  end
  return pts
end

function G.arrow(x1, y1, x2, y2)
  local pts, add = collector()
  bresenham(add, x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 0 then
    local head = math.max(2, math.min(4, len / 3))
    local ux, uy = dx / len, dy / len
    for _, sign in ipairs{ 1, -1 } do
      -- rotate the reversed direction by +/-35 degrees
      local a = math.rad(35) * sign
      local rx = -ux * math.cos(a) + uy * math.sin(a)
      local ry = -ux * math.sin(a) - uy * math.cos(a)
      bresenham(add, x2, y2, math.floor(x2 + rx * head + 0.5), math.floor(y2 + ry * head + 0.5))
    end
  end
  return pts
end

return G
```

> Check the arrow's wing coordinates for `G.arrow(0,0,10,0)`: `head = 3.33`, and the wings end near `(7,2)` and `(7,-2)`. The test accepts `(7|8, ±2)`. If the rotation sign convention puts the wings in front of the tip, the test fails. Fix the formula (the wings must have `x < 10`), don't change the test.

- [ ] **Step 4: Implement annotate and transform**

`extension/agent/tools/annotate.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")
local G = require("agent.tools.geometry")

local M = { DEFAULT_COLOR = "#ff3b30" }

local function shapePoints(sh)
  local t, x, y = sh.type, edit.int(sh.x), edit.int(sh.y)
  if t == "dot" then return G.dot(x, y) end
  if t == "line" or t == "arrow" then
    if sh.x2 == nil or sh.y2 == nil then error("A " .. t .. " needs x2 and y2.", 0) end
    return G[t](x, y, edit.int(sh.x2), edit.int(sh.y2))
  end
  if t == "rect" then
    if sh.w == nil or sh.h == nil then error("A rect needs w and h.", 0) end
    return G.rect(x, y, edit.int(sh.w), edit.int(sh.h))
  end
  if t == "circle" then
    if sh.r == nil then error("A circle needs r.", 0) end
    return G.circle(x, y, edit.int(sh.r))
  end
  error("Unknown shape type '" .. tostring(t) .. "'.", 0)
end

function M.annotate(args)
  local s = edit.editableSprite(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local value = edit.pixelValue(s, args.color or M.DEFAULT_COLOR)
  local all = {}
  for i = 1, #args.shapes do
    for _, p in ipairs(shapePoints(args.shapes[i])) do all[#all + 1] = p end
  end
  edit.transaction(s, "notes", function()
    local layer
    for _, l in ipairs(s.layers) do
      if l.name == edit.NOTES_LAYER then layer = l end
    end
    if not layer then
      layer = s:newLayer()
      layer.name = edit.NOTES_LAYER
    end
    local img = args.clear and Image(s.spec) or edit.canvasImage(s, layer, frame)
    if args.clear then img:clear(edit.transparentValue(s)) end
    for _, p in ipairs(all) do
      if p.x >= 0 and p.y >= 0 and p.x < s.width and p.y < s.height then img:drawPixel(p.x, p.y, value) end
    end
    edit.commit(s, layer, frame, img)
  end)
  return { sprite = sprites.name(s), layer = edit.NOTES_LAYER, frame = frame.frameNumber, marks = #args.shapes }
end

return M
```

`extension/agent/tools/transform.lua`:
```lua
local sprites = require("agent.tools.sprites")
local edit = require("agent.tools.edit")

local M = {}

local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function outline(src, s, value, place)
  local clear = edit.transparentValue(s)
  local out = src:clone()
  local w, h, changed = src.width, src.height, 0
  local function opaque(x, y)
    return x >= 0 and y >= 0 and x < w and y < h and src:getPixel(x, y) ~= clear
  end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local here = opaque(x, y)
      if here == (place == "inside") then
        for _, d in ipairs(N4) do
          if opaque(x + d[1], y + d[2]) ~= here then
            out:drawPixel(x, y, value)
            changed = changed + 1
            break
          end
        end
      end
    end
  end
  return out, changed
end

local function flip(src, horizontal, rx, ry, rw, rh)
  local out = src:clone()
  for y = ry, ry + rh - 1 do
    for x = rx, rx + rw - 1 do
      local sx = horizontal and (rx + rw - 1 - (x - rx)) or x
      local sy = horizontal and y or (ry + rh - 1 - (y - ry))
      out:drawPixel(x, y, src:getPixel(sx, sy))
    end
  end
  return out, rw * rh
end

function M.transform(args)
  local s = edit.editableSprite(args.sprite)
  local layer = edit.drawableLayer(s, args.layer)
  local frame = sprites.frame(s, args.frame)
  local action = args.action
  local value = action == "outline" and edit.pixelValue(s, args.color or "#000000") or nil
  local rx, ry, rw, rh = 0, 0, s.width, s.height
  if args.region then
    rx, ry = math.max(0, edit.int(args.region.x)), math.max(0, edit.int(args.region.y))
    rw = math.min(s.width, edit.int(args.region.x) + edit.int(args.region.w)) - rx
    rh = math.min(s.height, edit.int(args.region.y) + edit.int(args.region.h)) - ry
    if rw <= 0 or rh <= 0 then error("Region is outside the sprite.", 0) end
  end
  local changed = 0
  edit.transaction(s, action .. " " .. layer.name, function()
    local img = edit.canvasImage(s, layer, frame)
    local out
    if action == "outline" then
      out, changed = outline(img, s, value, args.place or "outside")
    elseif action == "flip_horizontal" or action == "flip_vertical" then
      out, changed = flip(img, action == "flip_horizontal", rx, ry, rw, rh)
    else
      error("Unknown transform '" .. tostring(action) .. "'.", 0)
    end
    edit.commit(s, layer, frame, out)
  end)
  return { sprite = sprites.name(s), layer = layer.name, frame = frame.frameNumber, changed = changed }
end

return M
```

In `extension/agent/tools/init.lua`, add these requires:
```lua
local annotate = require("agent.tools.annotate")
local transform = require("agent.tools.transform")
```
and these entries:
```lua
  annotate = annotate.annotate,
  transform = transform.transform,
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add extension/agent/tools/geometry.lua extension/agent/tools/annotate.lua extension/agent/tools/transform.lua extension/agent/tools/init.lua tests/lua/test_geometry.lua tests/lua/test_annotate_transform.lua
git commit -m "feat(extension): teaching annotations, outline and flip"
```

---

### Task 8: Color analysis and open-tab listing (Lua)

**Files:**
- Create: `extension/agent/tools/analyze.lua`
- Modify: `extension/agent/tools/init.lua`
- Test: `tests/lua/test_analyze.lua`

**Interfaces:**
- Consumes: `inspect.render`, `color.*`, `edit.isReference`, `sprites.*`.
- Produces:
  - `analyze.distance(hexA, hexB) -> number` (redmean RGB distance, 0..~765)
  - handler `analyze_colors{sprite?, frame?} -> {sprite, frame, uniqueColors, topColors[{color, count}], nearDuplicates[{a, b, distance}], unusedPaletteEntries}`
  - handler `list_open_sprites{} -> {tabs[{name, path, active, kind, width, height, frames}]}`

- [ ] **Step 1: Write the failing tests**

`tests/lua/test_analyze.lua`:
```lua
local T = require("testlib")
local F = require("fixtures")
local tools = require("agent.tools")
local analyze = require("agent.tools.analyze")
local pc = app.pixelColor

local function call(name, args) return tools.dispatch(name, F.decode(args or {})) end

T.test("distance is zero for equal colors and grows with difference", function()
  T.eq(analyze.distance("#102030", "#102030"), 0)
  T.eq(analyze.distance("#000000", "#010101") < analyze.distance("#000000", "#808080"), true)
end)

T.test("analyze_colors counts colors and finds near duplicates", function()
  F.closeAll()
  local s = F.rgbSprite()
  local img = s.cels[1].image:clone()
  img:drawPixel(2, 0, pc.rgba(254, 1, 1, 255)) -- near-duplicate of red
  img:drawPixel(3, 0, pc.rgba(255, 0, 0, 255))
  s.cels[1].image = img
  local r = call("analyze_colors")
  T.eq(r.ok, true, r.error)
  T.eq(r.data.uniqueColors, 3)
  T.deepEq(r.data.topColors[1], { color = "#ff0000", count = 2 })
  T.eq(#r.data.nearDuplicates, 1)
  T.eq(r.data.nearDuplicates[1].a == "#ff0000" or r.data.nearDuplicates[1].b == "#ff0000", true)
end)

T.test("analyze_colors works on reference tabs", function()
  F.closeAll()
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(F.tmp, "ref3.png"))
  app.sprite = ref
  T.eq(call("analyze_colors").ok, true)
end)

T.test("list_open_sprites marks the active tab and references", function()
  F.closeAll()
  F.rgbSprite("hero.aseprite")
  local ref = Sprite(2, 2)
  ref:saveAs(app.fs.joinPath(F.tmp, "ref4.png"))
  app.sprite = ref
  local r = call("list_open_sprites")
  T.eq(r.ok, true, r.error)
  local byName = {}
  for _, t in ipairs(r.data.tabs) do byName[t.name] = t end
  T.eq(byName["hero.aseprite"].kind, "sprite")
  T.eq(byName["hero.aseprite"].active, false)
  T.eq(byName["ref4.png"].kind, "reference")
  T.eq(byName["ref4.png"].active, true)
  T.eq(byName["hero.aseprite"].width, 4)
end)

F.closeAll()
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh analyze`
Expected: `module 'agent.tools.analyze' not found`.

- [ ] **Step 3: Implement**

`extension/agent/tools/analyze.lua`:
```lua
local sprites = require("agent.tools.sprites")
local color = require("agent.tools.color")
local inspect = require("agent.tools.inspect")
local edit = require("agent.tools.edit")

local M = { NEAR = 24, TOP = 16 }

-- "Redmean" weighted RGB distance: cheap and closer to perception than plain RGB.
function M.distance(a, b)
  local r1, g1, b1 = color.parseHex(a)
  local r2, g2, b2 = color.parseHex(b)
  local rm = (r1 + r2) / 2
  local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
  return math.sqrt((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db)
end

function M.analyze_colors(args)
  local s = sprites.resolve(args.sprite)
  local frame = sprites.frame(s, args.frame)
  local img = inspect.render(s, frame)
  local pal = s.palettes[1]
  local counts, list = {}, {}
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local hex = color.pixelToHex(img:getPixel(x, y), s.colorMode, pal, s.transparentColor)
      if hex ~= "." then
        if not counts[hex] then list[#list + 1] = hex end
        counts[hex] = (counts[hex] or 0) + 1
      end
    end
  end
  table.sort(list, function(a, b) return counts[a] > counts[b] or (counts[a] == counts[b] and a < b) end)
  local top = {}
  for i = 1, math.min(M.TOP, #list) do top[i] = { color = list[i], count = counts[list[i]] } end
  local near = {}
  for i = 1, math.min(64, #list) do
    for j = i + 1, math.min(64, #list) do
      local d = M.distance(list[i], list[j])
      if d < M.NEAR and #near < 10 then near[#near + 1] = { a = list[i], b = list[j], distance = math.floor(d + 0.5) } end
    end
  end
  local unused = 0
  for i = 0, #pal - 1 do
    if not counts[color.fromColor(pal:getColor(i))] then unused = unused + 1 end
  end
  return {
    sprite = sprites.name(s),
    frame = frame.frameNumber,
    uniqueColors = #list,
    topColors = top,
    nearDuplicates = near,
    unusedPaletteEntries = unused,
  }
end

function M.list_open_sprites()
  local tabs = {}
  for _, s in ipairs(app.sprites) do
    tabs[#tabs + 1] = {
      name = sprites.name(s),
      path = s.filename,
      active = app.sprite == s,
      kind = edit.isReference(s) and "reference" or "sprite",
      width = s.width,
      height = s.height,
      frames = #s.frames,
    }
  end
  return { tabs = tabs }
end

return M
```

In `extension/agent/tools/init.lua`, add `local analyze = require("agent.tools.analyze")` and these entries:
```lua
  analyze_colors = analyze.analyze_colors,
  list_open_sprites = analyze.list_open_sprites,
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
git add extension/agent/tools/analyze.lua extension/agent/tools/init.lua tests/lua/test_analyze.lua
git commit -m "feat(extension): analyze_colors and list_open_sprites (reference tabs)"
```

---

### Task 9: Approval cards in the chat window

**Files:**
- Modify: `extension/agent/chat_model.lua`, `extension/agent/chat_render.lua`, `extension/agent/chat_window.lua`
- Test: `tests/lua/test_chat_model.lua`, `tests/lua/test_chat_render.lua` (add cases)

**Interfaces:**
- Consumes: protocol `approval_request{approvalId, summary, sprite?}` in; `approval{approvalId, approved}` and `set_auto_approve{enabled}` out (Task 2).
- Produces:
  - `ChatModel:addApproval(id, summary)`, `ChatModel:resolveApproval(id, approved)`, `ChatModel:pendingApproval() -> item|nil`. `ChatModel:endTurn()` now marks pending approvals `"cancelled"`.
  - `ChatModel.sendAction(busy, text, approvalPending) -> "send"|"ignore"|"stop"|"reject_busy"|"deny"`
  - Render kinds `approval_label`, `approval`, `approval_state`.
  - Window: an **Apply** button that is visible only while an approval is pending; the main button reads **Deny** while one is pending (Enter denies); an **Auto-approve edits** checkbox, re-sent to the bridge on every `ready`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/lua/test_chat_model.lua`:
```lua
T.test("approvals queue, resolve in order, and cancel at end of turn", function()
  local m = ChatModel.new()
  m:addApproval("a1", "Add layer \"A\"")
  m:addApproval("a2", "Add layer \"B\"")
  T.eq(m:pendingApproval().id, "a1")
  m:resolveApproval("a1", true)
  T.eq(m:pendingApproval().id, "a2")
  m:endTurn()
  T.eq(m:pendingApproval(), nil)
  T.eq(m.items[1].state, "applied")
  T.eq(m.items[2].state, "cancelled")
  m:resolveApproval("a2", true)
  T.eq(m.items[2].state, "cancelled", "late answers don't change a cancelled card")
end)

T.test("sendAction with a pending approval: Enter denies, typing is rejected", function()
  T.eq(ChatModel.sendAction(true, "", true), "deny")
  T.eq(ChatModel.sendAction(true, "wait", true), "reject_busy")
  T.eq(ChatModel.sendAction(true, "", false), "stop")
end)
```

Add to `tests/lua/test_chat_render.lua`:
```lua
T.test("approval cards show a label, the summary and the state", function()
  local items = { { kind = "approval", id = "a1", text = "Set 2 pixels on hero", state = "pending" } }
  local lay = R.layout(items, { width = 40, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude" })
  T.deepEq(lay.lines, {
    { text = "Claude wants to:", kind = "approval_label", y = 0 },
    { text = "Set 2 pixels on hero", kind = "approval", y = 10 },
    { text = "Apply or Deny below", kind = "approval_state", y = 20 },
  })
  items[1].state = "denied"
  T.eq(R.layout(items, { width = 40, measure = chars, lineHeight = 10, gap = 5, agentLabel = "Claude" }).lines[3].text, "Denied")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-lua.sh chat`
Expected: failures. `addApproval` is nil, and the layout has no approval label.

- [ ] **Step 3: Implement the model and render changes**

In `extension/agent/chat_model.lua`, add these methods before `ChatModel.sendAction`:
```lua
function ChatModel:addApproval(id, summary)
  self.items[#self.items + 1] = { kind = "approval", id = id, text = summary, state = "pending" }
  self.streaming = false
end

function ChatModel:resolveApproval(id, approved)
  for _, item in ipairs(self.items) do
    if item.kind == "approval" and item.id == id and item.state == "pending" then
      item.state = approved and "applied" or "denied"
    end
  end
end

function ChatModel:pendingApproval()
  for _, item in ipairs(self.items) do
    if item.kind == "approval" and item.state == "pending" then return item end
  end
  return nil
end
```
Replace `endTurn` with:
```lua
function ChatModel:endTurn()
  self.streaming = false
  for _, item in ipairs(self.items) do
    if item.kind == "approval" and item.state == "pending" then item.state = "cancelled" end
  end
end
```
Replace `sendAction` with:
```lua
-- What the Send/Stop/Deny button (and Enter) should do. A typed follow-up while busy is
-- rejected rather than silently cancelling; with an approval pending, Enter denies it.
function ChatModel.sendAction(busy, text, approvalPending)
  local empty = (text or ""):match("^%s*$") ~= nil
  if approvalPending then return empty and "deny" or "reject_busy" end
  if busy then return empty and "stop" or "reject_busy" end
  return empty and "ignore" or "send"
end
```

In `extension/agent/chat_render.lua`, add after `local PREFIX = ...`:
```lua
local APPROVAL_STATE = {
  pending = "Apply or Deny below",
  applied = "Approved",
  denied = "Denied",
  cancelled = "Cancelled",
}
```
and in `R.layout`, inside the item loop, replace the `label`/text section with:
```lua
    local label = LABELS[item.kind] or (item.kind == "agent" and (opts.agentLabel or "Agent")) or nil
    if item.kind == "approval" then label = (opts.agentLabel or "Agent") .. " wants to:" end
    if label then
      lines[#lines + 1] = { text = label, kind = item.kind .. "_label", y = y }
      y = y + opts.lineHeight
    end
    for _, l in ipairs(R.wrap((PREFIX[item.kind] or "") .. item.text, opts.width, opts.measure)) do
      lines[#lines + 1] = { text = l, kind = item.kind, y = y }
      y = y + opts.lineHeight
    end
    if item.kind == "approval" then
      lines[#lines + 1] = { text = APPROVAL_STATE[item.state] or item.state, kind = "approval_state", y = y }
      y = y + opts.lineHeight
    end
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-lua.sh`
Expected: all suites pass.

- [ ] **Step 5: Wire the window**

In `extension/agent/chat_window.lua`:

Add colors:
```lua
  approval_label = Color{ r = 240, g = 180, b = 80 },
  approval_state = Color{ r = 140, g = 140, b = 140 },
```

Add `autoApprove = false,` to the fields in `ChatWindow.new`.

In `build()`, replace the input row with:
```lua
  dlg:newrow()
  dlg:button{ id = "apply", text = "Apply", visible = false, onclick = function() self:answerApproval(true) end }
  dlg:check{
    id = "autoapprove",
    text = "Auto-approve edits",
    selected = self.autoApprove,
    onclick = function()
      self.autoApprove = self.dlg.data.autoapprove
      self.conn:send{ type = "set_auto_approve", enabled = self.autoApprove }
    end,
  }
  dlg:newrow()
  dlg:entry{ id = "input", hexpand = true }
  dlg:button{ id = "send", text = "Send", focus = true, onclick = function() self:onSendOrStop() end }
```

Add these methods:
```lua
function ChatWindow:mainButtonText()
  if self.model:pendingApproval() then return "Deny" end
  return self.busy and "Stop" or "Send"
end

function ChatWindow:syncButtons()
  if not self.open then return end
  self.dlg:modify{ id = "send", text = self:mainButtonText() }
  self.dlg:modify{ id = "apply", visible = self.model:pendingApproval() ~= nil }
end

function ChatWindow:answerApproval(approved)
  local item = self.model:pendingApproval()
  if not item then return end
  self.conn:send{ type = "approval", approvalId = item.id, approved = approved }
  self.model:resolveApproval(item.id, approved)
  self:syncButtons()
  self:repaint()
end
```

In `show()`, replace the two `modify` lines after `dlg:show` with:
```lua
    self.dlg:modify{ id = "status", text = STATUS_TEXT[self.conn.status] or self.conn.status }
    self:syncButtons()
```

In `setBusy`, replace the final `modify` line with `self:syncButtons()`.

In `onSendOrStop`, change the first lines to:
```lua
  local text = (self.dlg.data.input or ""):match("^%s*(.-)%s*$")
  local action = ChatModel.sendAction(self.busy, text, self.model:pendingApproval() ~= nil)
  if action == "deny" then
    self:answerApproval(false)
    return
  elseif action == "stop" then
```
(keep the rest of the chain unchanged).

In `onMessage`:
- in the `ready` branch, add `self.conn:send{ type = "set_auto_approve", enabled = self.autoApprove }`;
- add a branch:
```lua
  elseif m.type == "approval_request" then
    self.model:addApproval(m.approvalId, m.summary)
    self:syncButtons()
```
- in the `tool_call` branch, after sending the result, add `if res.ok then app.refresh() end`;
- in the `turn_done` branch, after `self:setBusy(false)`, add `self:syncButtons()`.

In `newChat`, after `self.model:clear()`, add `self:syncButtons()`.

- [ ] **Step 6: Headless load check, install, and commit**

Run: `scripts/test-lua.sh` (all pass). Then run the headless load check from Plan 1 Task 8: a scratch script that requires `agent.chat_window` and calls `ChatWindow.new{ prefs = {} }` under `aseprite -b`. Expected: `load true`, `new true`.

```bash
scripts/dev-install.sh
git add extension/agent/chat_model.lua extension/agent/chat_render.lua extension/agent/chat_window.lua tests/lua/test_chat_model.lua tests/lua/test_chat_render.lua
git commit -m "feat(extension): approval cards, Apply/Deny, auto-approve toggle"
```

- [ ] **Step 7: Manual checklist (the artist runs these in Aseprite)**

Rebuild and restart the bridge (`cd bridge && npm run build`, stop the old pid, `npm start`, update `~/.claude/claude-running.md`), restart Aseprite, and open a small sprite plus a PNG reference tab:
1. Ask Claude to "add a 5-step skin ramp to the palette". A card appears with the colors, the **Apply** button shows, and the main button reads **Deny**. Apply: the palette grows, and one Ctrl+Z removes the whole ramp.
2. Ask for another change and press **Enter**. It is denied, and Claude asks what you'd prefer.
3. Ask "where is my light source inconsistent? mark it". Marks appear on an "Agent Notes" layer. Your layers are untouched.
4. Ask Claude to "compare my sprite with the reference". It uses list_open_sprites and looks at the PNG. Ask it to "fix the reference" and it refuses, because references are read-only.
5. Ask "draw me a knight". Claude pushes back. Insist ("no, really, just block it out"). A **draft mode** card appears quoting you. Apply: an "AI Draft" layer at 40% opacity gets a rough blockout. Your own layers are untouched.
6. Tick **Auto-approve edits** and ask for a layer rename. It happens without a card. Ask for draft mode in a new chat: the card still appears.
7. Ask for an edit, and while the card is pending press **Stop**: the card shows "Cancelled" and nothing changes.
8. In a new chat, ask Claude to "clean up stray pixels" on a busy sprite. Its fixes stay under the pixel budget. If it hits the budget, it tells you what's left to do.

---

## Self-Review Notes

- **Spec coverage:**
  - §5 edit tools: palette, ramps, replace (with region), layer_ops, frame_ops, set_pixels, annotate, transform (replacing run_command), request_draft_mode.
  - §5 read tools: analyze_colors, list_open_sprites (new; covers references).
  - §6 friction levels 1–3: prompt (Task 3), budgets (Task 2), quarantine plus explicit insistence (Tasks 2, 5, 6).
  - §5 approval flow: cards, the auto-approve exception for draft mode, one undo step per edit.
  - §12: over-budget and Stop-with-card rows.
- **Deferred to later plans:** `propose_memory` and `project.json` budget overrides (Plan 3, with `.artproject`); "Open & apply" and editing non-open sprites (Plan 3); import, clips and exports (Plan 4).
- **Deviations** are ledgered as rulings in Task 1's spec-delta note.
