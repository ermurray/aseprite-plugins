import { describe, expect, it } from "vitest";
import { formatStamp } from "../src/stamp.js";

describe("formatStamp", () => {
  it("describes the active sprite, open tabs and the drafts switch", () => {
    expect(
      formatStamp(
        { activeSprite: "characters/knight.aseprite", frame: 3, frameCount: 8, layer: "Body", selection: { x: 20, y: 14, w: 12, h: 8 }, openSprites: ["characters/knight.aseprite", "ref.png"] },
        false,
        false,
      ),
    ).toBe('[active: characters/knight.aseprite - frame 3/8 - layer "Body" - selection 12x8 at (20,14) | open: characters/knight.aseprite, ref.png | AI drafts: off]');
  });

  it("handles no sprite and adds the attach note", () => {
    expect(formatStamp(undefined, true, false)).toBe("[active: none | AI drafts: on]");
    expect(formatStamp({ activeSprite: "a.aseprite" }, false, true)).toBe(
      "[active: a.aseprite | AI drafts: off]\n[The artist attached the current view: look at it with get_snapshot before answering.]",
    );
  });
});
