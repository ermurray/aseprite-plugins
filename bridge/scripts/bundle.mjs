// Bundles the bridge into one ESM file that runs with plain Node (no node_modules).
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

export async function bundle() {
  const outfile = join(root, "dist", "bridge.mjs");
  await build({
    entryPoints: [join(root, "src", "main.ts")],
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node20",
    outfile,
    banner: { js: "import { createRequire as __agentRequire } from 'module'; const require = __agentRequire(import.meta.url);" },
    external: ["bufferutil", "utf-8-validate"],
    logLevel: "warning",
  });
  return outfile;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = await bundle();
  console.log(`bundled ${out}`);
}
