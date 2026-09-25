import { describe, expect, it } from "vitest";
import { SYSTEM_PROMPT } from "../src/prompt.js";
import { TOOL_DEFS } from "../src/tools/definitions.js";

describe("system prompt", () => {
  it("mentions the rules Claude must follow for edits", () => {
    for (const phrase of ["approval", "Apply", "AI Draft", "create_draft_layer", "Allow AI drafts", "AI drafts: off", "reference", "annotate", "one undo"]) {
      expect(SYSTEM_PROMPT).toContain(phrase);
    }
  });
  it("does not ask the artist to insist or argue about drafts", () => {
    expect(SYSTEM_PROMPT).not.toContain("insist");
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
      if (["get_", "set_", "add_", "list_", "create_", "replace_", "layer_", "frame_", "analyze_"].some((p) => m[1].startsWith(p))) {
        expect(names.has(m[1]), m[1]).toBe(true);
      }
    }
  });
});
