import { execFile } from "node:child_process";
import { copyFile, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { bundle } from "../scripts/bundle.mjs";

const run = promisify(execFile);

describe("bundled bridge", () => {
  it("runs from a folder with no node_modules", async () => {
    const out = await bundle();
    const dir = await mkdtemp(join(tmpdir(), "bundle-"));
    await copyFile(out, join(dir, "bridge.mjs"));
    const { stdout } = await run(process.execPath, [join(dir, "bridge.mjs"), "--version"]);
    expect(stdout.trim()).toBe("0.9.0");
  }, 60_000);
});
