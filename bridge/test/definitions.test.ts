import { describe, expect, it } from "vitest";
import { z } from "zod";
import { TOOL_DEFS, toolDef } from "../src/tools/definitions.js";

describe("tool definitions", () => {
  it("has the four read tools with unique names", () => {
    expect(TOOL_DEFS.map((d) => d.name).sort()).toEqual(["get_palette", "get_pixels", "get_snapshot", "get_sprite_info"]);
    expect(TOOL_DEFS.every((d) => d.kind === "read")).toBe(true);
  });

  it("limits get_pixels regions to 64x64", () => {
    const schema = z.object(toolDef("get_pixels")!.shape);
    expect(schema.safeParse({ region: { x: 0, y: 0, w: 64, h: 64 } }).success).toBe(true);
    expect(schema.safeParse({ region: { x: 0, y: 0, w: 65, h: 1 } }).success).toBe(false);
    expect(schema.safeParse({}).success).toBe(false);
  });

  it("uses 1-based frames", () => {
    const schema = z.object(toolDef("get_snapshot")!.shape);
    expect(schema.safeParse({ frame: 0 }).success).toBe(false);
    expect(schema.safeParse({ frame: 1 }).success).toBe(true);
  });

  it("writes plain-text activity summaries (no emoji)", () => {
    const s = toolDef("get_snapshot")!.activity({ sprite: "knight.aseprite", frame: 3, layer: "Body" });
    expect(s).toBe('Looked at knight.aseprite, frame 3, layer "Body"');
    expect(toolDef("get_sprite_info")!.activity({})).toBe("Inspected the active sprite");
    expect(toolDef("get_pixels")!.activity({ region: { x: 2, y: 3, w: 4, h: 5 } })).toBe("Read 4x5 pixels at (2,3) in the active sprite");
    for (const d of TOOL_DEFS) expect(d.activity({})).toMatch(/^[\x20-\x7E]+$/);
  });
});
