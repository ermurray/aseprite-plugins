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
