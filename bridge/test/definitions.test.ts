import { describe, expect, it } from "vitest";
import { z } from "zod";
import { TOOL_DEFS, toolDef } from "../src/tools/definitions.js";

describe("tool definitions", () => {
  it("defines every Plan 2 tool with a unique name", () => {
    const names = TOOL_DEFS.map((d) => d.name);
    expect(new Set(names).size).toBe(names.length);
    expect(names.sort()).toEqual([
      "add_color_ramp", "add_palette_colors", "analyze_colors", "annotate", "builtin_fx", "check_readability", "create_draft_layer", "delete_clip", "export_sprite", "import_from_sprite", "insert_clip", "list_clips", "pin_clip", "save_clip", "dither", "find_extensions", "frame_ops", "get_tool_state", "gradient_fill", "layer_style", "light_preview", "list_installed_extensions", "make_normal_map", "pixel_perfect", "run_extension_command", "run_script", "selout", "set_tool", "snap_to_palette", "write_script", "get_palette",
      "get_pixels", "get_snapshot", "get_sprite_info", "layer_ops", "list_open_sprites", "list_project_sprites", "propose_brief_change", "propose_memory", "replace_color",
      "set_palette", "set_pixels", "transform",
    ].sort());
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

  it("create_draft_layer forwards to ensure_draft_layer", () => {
    const d = toolDef("create_draft_layer")!;
    expect(d.kind).toBe("edit");
    expect(d.forward!({ sprite: "a.aseprite" })).toEqual({ name: "ensure_draft_layer", args: { sprite: "a.aseprite" } });
    expect(d.summarize!({ sprite: "a.aseprite" })).toBe('Create a rough "AI Draft" layer on a.aseprite (40% opacity, for you to redraw over)');
  });

  it("validates colors and set_pixels shape", () => {
    const px = z.object(toolDef("set_pixels")!.shape);
    expect(px.safeParse({ layer: "Body", pixels: [{ x: 1, y: 2, color: "#ff0000" }] }).success).toBe(true);
    expect(px.safeParse({ layer: "Body", pixels: [{ x: 1, y: 2, color: "." }] }).success).toBe(true);
    expect(px.safeParse({ layer: "Body", pixels: [{ x: 1, y: 2, color: "red" }] }).success).toBe(false);
    expect(px.safeParse({ layer: "Body", pixels: [] }).success).toBe(false);
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

  it("script code and descriptions can't hide control characters, and replacing is explicit", () => {
    const script = z.object(toolDef("write_script")!.shape);
    expect(script.safeParse({ name: "a", description: "ok", code: "-- tidy\ros.execute('x')" }).success).toBe(false);
    expect(script.safeParse({ name: "a", description: "bad\rdesc", code: "x" }).success).toBe(false);
    expect(script.safeParse({ name: "a", description: "ok", code: "local t = 1\n\tprint(t)\n" }).success).toBe(true);
    for (const n of ["write_script", "run_script", "run_extension_command"]) expect(toolDef(n)!.alwaysAsk).toBe(true);
    expect(toolDef("write_script")!.summarize!({ name: "a", description: "d", code: "x", replace: true })).toContain("Replace the script");
    expect(toolDef("run_extension_command")!.summarize!({ command: "Foo" })).toBe('Run the Aseprite command "Foo" (not undoable as one step)');
  });
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
});
