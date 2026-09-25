/** Well-known community extensions and scripts Claude can recommend. Nothing here is bundled. */
export interface CatalogEntry {
  name: string;
  by: string;
  kind: "extension" | "script collection";
  purpose: string;
  tags: string[];
  url: string;
  license: string;
}

const THKWZNK = "https://github.com/thkwznk/aseprite-scripts";
const COMMUNITY = "https://github.com/projectitis/aseprite-community-script-collection";
const BEHREAJJ = "https://github.com/behreajj/AsepriteAddons";

export const CATALOG: CatalogEntry[] = [
  { name: "Sprite Analyzer", by: "thkwznk", kind: "extension", purpose: "Live preview breakdown of values, silhouette, outline and blocked shapes while you draw.", tags: ["values", "silhouette", "readability", "preview"], url: THKWZNK, license: "not stated (ask the author before redistributing)" },
  { name: "FX", by: "thkwznk", kind: "extension", purpose: "A pack of visual effects for sprites.", tags: ["effects", "fx"], url: THKWZNK, license: "not stated" },
  { name: "Magic Pencil", by: "thkwznk", kind: "extension", purpose: "Extra pencil modes such as outline, colorize and hue shifting while drawing.", tags: ["pencil", "tool", "shading", "outline"], url: THKWZNK, license: "not stated" },
  { name: "NxPA Studio", by: "thkwznk", kind: "extension", purpose: "Pixel-art scaling algorithms, frame interpolation and color analysis.", tags: ["scaling", "upscale", "tween", "animation", "colors"], url: THKWZNK, license: "not stated" },
  { name: "Animation Suite", by: "thkwznk", kind: "extension", purpose: "Import animations with movement patterns and build loops from layered animation.", tags: ["animation", "loop"], url: THKWZNK, license: "not stated" },
  { name: "AsepriteAddons", by: "behreajj", kind: "script collection", purpose: "Gradients (linear, radial, sweep), dither filter, gradient map, color curves, normal maps and an LCh color picker.", tags: ["gradient", "dither", "normal map", "curves", "color picker"], url: BEHREAJJ, license: "GPL-3.0" },
  { name: "Gradients Extension", by: "community collection", kind: "extension", purpose: "Gradient tool with over 100 dither patterns.", tags: ["gradient", "dither"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Wave Warp", by: "community collection", kind: "extension", purpose: "Animated wave distortion effects.", tags: ["wave", "distortion", "effects", "animation"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Parallixel", by: "community collection", kind: "extension", purpose: "Automates seamless parallax scrolling backgrounds.", tags: ["parallax", "background", "animation"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Tweencel", by: "community collection", kind: "extension", purpose: "Advanced frame tweening between key poses.", tags: ["tween", "animation", "inbetween"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Multi Color Replacer", by: "community collection", kind: "script collection", purpose: "Replace several colors at once.", tags: ["colors", "replace", "palette swap"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Palettize", by: "community collection", kind: "script collection", purpose: "Preview and tune palette application with HSV sliders.", tags: ["palette", "colors"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Perlin Noise Generation", by: "community collection", kind: "script collection", purpose: "Procedural noise for textures.", tags: ["noise", "texture"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Isometric Guidelines and Box Generator", by: "community collection", kind: "script collection", purpose: "Isometric guide layers and customizable isometric boxes.", tags: ["isometric", "guides"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "1-Point Perspective Helper", by: "community collection", kind: "script collection", purpose: "Single-point perspective grids.", tags: ["perspective", "guides"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Reflecto", by: "community collection", kind: "script collection", purpose: "Automatic vertical sprite reflections.", tags: ["reflection", "water", "effects"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Normal Map Generator and Preview", by: "community collection", kind: "script collection", purpose: "Normal maps from sprites and an in-editor preview.", tags: ["normal map", "lighting"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Export Tags and Export Tooling", by: "community collection", kind: "script collection", purpose: "Export tags as strips and advanced sprite sheet or layer export for game engines.", tags: ["export", "sprite sheet", "tags"], url: COMMUNITY, license: "per script (see collection)" },
  { name: "Brush Manager Pro and Dithering Generator", by: "community forum", kind: "extension", purpose: "Brush library and packs, shading helpers and a dithering pattern generator.", tags: ["brush", "dither", "shading"], url: "https://community.aseprite.org/t/extension-brush-manager-pro-dithering-generator-shading-library-brush-packs/28193", license: "see forum post" },
];

export function searchCatalog(query?: string): CatalogEntry[] {
  const q = (query ?? "").trim().toLowerCase();
  if (!q) return CATALOG;
  return CATALOG.filter((e) => [e.name, e.purpose, ...e.tags].some((s) => s.toLowerCase().includes(q)));
}
