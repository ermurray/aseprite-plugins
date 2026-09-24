import { z } from "zod";

export type ToolKind = "read" | "edit";

export interface ToolDef {
  name: string;
  description: string;
  kind: ToolKind;
  shape: z.ZodRawShape;
  activity(args: Record<string, unknown>): string;
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
];

export function toolDef(name: string): ToolDef | undefined {
  return TOOL_DEFS.find((d) => d.name === name);
}
