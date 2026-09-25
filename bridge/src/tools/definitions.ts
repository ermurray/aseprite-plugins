import { z } from "zod";
import { DRAFT_LAYER, NOTES_LAYER } from "./constants.js";
import { colorRamp } from "./ramp.js";
import { appendMemory } from "../project.js";
import type { ToolResult } from "../toolTypes.js";

export type ToolKind = "read" | "edit";

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
  /** Tools the bridge runs itself (no extension round-trip). */
  runInBridge?(args: Record<string, unknown>, env: { projectRoot: string | null }): Promise<ToolResult>;
}

const spriteArg = z
  .string()
  .optional()
  .describe("Sprite to use: file name (e.g. knight.aseprite) or full path of an open sprite. Omit for the active sprite.");
const frameArg = z.number().int().min(1).optional().describe("1-based frame number. Omit for the active frame.");
const layerArg = z.string().optional().describe("Name of a (non-group) layer. Omit for the flattened visible image.");

function rect(max?: number) {
  const side = max ? z.number().int().min(1).max(max) : z.number().int().min(1);
  return z.object({ x: z.number().int().min(0), y: z.number().int().min(0), w: side, h: side });
}

const spriteName = (a: Record<string, unknown>) => (typeof a.sprite === "string" ? a.sprite : "the active sprite");

const hexColor = z.string().regex(/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/, "use #rrggbb or #rrggbbaa");
const target = (a: Record<string, unknown>) => (typeof a.layer === "string" ? `${spriteName(a)} > "${a.layer}"` : spriteName(a));
const len = (v: unknown) => (Array.isArray(v) ? v.length : 0);
const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;
const frameRange = z.object({ from: z.number().int().min(1), to: z.number().int().min(1) });

export const TOOL_DEFS: ToolDef[] = [
  {
    name: "get_sprite_info",
    kind: "read",
    description:
      "Describe a sprite: size, color mode, frame count and durations (ms), layer tree (bottom to top) with visibility, opacity and blend mode, tags, palette size, selection, and the active frame and layer if it is the active sprite.",
    shape: { sprite: spriteArg },
    activity: (a) => `Inspected ${spriteName(a)}`,
  },
  {
    name: "get_snapshot",
    kind: "read",
    description:
      "Get a PNG image of a frame (flattened, or one layer), optionally cropped to a region. Small sprites are upscaled with nearest-neighbour so pixels stay crisp; `scale` in the result says by how much. Use get_pixels when exact colors matter.",
    shape: {
      sprite: spriteArg,
      frame: frameArg,
      layer: layerArg,
      region: rect().optional().describe("Crop rectangle in sprite pixels."),
      maxSize: z.number().int().min(64).max(1024).optional().describe("Target long edge in pixels for upscaling (default 512)."),
    },
    activity: (a) => {
      let s = `Looked at ${spriteName(a)}`;
      if (typeof a.frame === "number") s += `, frame ${a.frame}`;
      if (typeof a.layer === "string") s += `, layer "${a.layer}"`;
      return s;
    },
  },
  {
    name: "get_pixels",
    kind: "read",
    description:
      "Read exact pixel colors in a region (max 64x64) as rows of hex colors ('#rrggbb', '#rrggbbaa' when translucent, '.' when transparent). Flattened image unless a layer is given.",
    shape: { sprite: spriteArg, frame: frameArg, layer: layerArg, region: rect(64).describe("Region in sprite pixels, max 64x64.") },
    activity: (a) => {
      const r = a.region as { x: number; y: number; w: number; h: number } | undefined;
      return r ? `Read ${r.w}x${r.h} pixels at (${r.x},${r.y}) in ${spriteName(a)}` : `Read pixels in ${spriteName(a)}`;
    },
  },
  {
    name: "get_palette",
    kind: "read",
    description: "List the sprite's palette as hex colors in index order (index 0 first), plus the transparent index for indexed sprites.",
    shape: { sprite: spriteArg },
    activity: (a) => `Read the palette of ${spriteName(a)}`,
  },
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
    summarize: (a) => `Replace the palette of ${spriteName(a)} with ${plural(len(a.colors), "color")}`,
  },
  {
    name: "add_palette_colors",
    kind: "edit",
    description: "Append colors to the palette (colors already present are skipped).",
    shape: { sprite: spriteArg, colors: z.array(hexColor).min(1).max(64) },
    activity: (a) => `Added colors to the palette of ${spriteName(a)}`,
    summarize: (a) => `Add ${(Array.isArray(a.colors) ? a.colors : []).join(" ")} to the palette of ${spriteName(a)}`,
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
    description: `Set individual pixels on a layer for fixes (stray pixels, jaggies, anti-aliasing, a highlight). color '.' erases. It is not for painting artwork for the artist. Painting on the "${DRAFT_LAYER}" layer only works while the artist has "Allow AI drafts" switched on.`,
    shape: {
      sprite: spriteArg,
      layer: z.string(),
      frame: frameArg,
      pixels: z
        .array(z.object({ x: z.number().int().min(0), y: z.number().int().min(0), color: z.union([hexColor, z.literal(".")]) }))
        .min(1)
        .max(4096),
    },
    activity: (a) => `Set ${plural(len(a.pixels), "pixel")} on ${target(a)}`,
    summarize: (a) => {
      let s = `Set ${plural(len(a.pixels), "pixel")} on ${target(a)}`;
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
      const n = len(a.shapes);
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
    name: "create_draft_layer",
    kind: "edit",
    description: `Only while the artist has "Allow AI drafts" switched on: create the rough "${DRAFT_LAYER}" layer (40% opacity) so set_pixels can block out shapes on it for the artist to redraw over. Never paint finished art.`,
    shape: { sprite: spriteArg },
    activity: (a) => `Created the ${DRAFT_LAYER} layer on ${spriteName(a)}`,
    summarize: (a) => `Create a rough "${DRAFT_LAYER}" layer on ${spriteName(a)} (40% opacity, for you to redraw over)`,
    forward: (a) => ({ name: "ensure_draft_layer", args: { sprite: a.sprite } }),
  },

  {
    name: "list_project_sprites",
    kind: "read",
    description:
      "List every .aseprite/.ase file in the current project (paths relative to the project folder) and whether each is open. Any of them can be passed as `sprite` to other tools, even if it is not open: reads open it in the background, edits open it as a tab.",
    shape: {},
    activity: () => "Listed the project's sprites",
  },
  {
    name: "propose_memory",
    kind: "edit",
    description:
      "Save a lasting project decision to the project's memory.md (one short sentence, e.g. 'Hero uses a 2px dark outline, never black'). The artist approves it first. Only works inside a project.",
    shape: { note: z.string().min(3).max(300) },
    activity: () => "Saved a note to project memory",
    summarize: (a) => `Save to project memory: "${a.note}"`,
    runInBridge: async (a, env) => {
      if (!env.projectRoot) {
        return { ok: false, error: 'There is no project yet. The artist can press "Set up project" in the chat window.' };
      }
      await appendMemory(env.projectRoot, String(a.note));
      return { ok: true, data: { saved: true } };
    },
  },
];

export function toolDef(name: string): ToolDef | undefined {
  return TOOL_DEFS.find((d) => d.name === name);
}
