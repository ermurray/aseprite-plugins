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
