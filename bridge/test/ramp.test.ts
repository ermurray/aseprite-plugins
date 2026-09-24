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
