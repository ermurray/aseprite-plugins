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
