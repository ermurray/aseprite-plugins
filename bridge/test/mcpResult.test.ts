import { mkdtemp, writeFile, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { toMcpResult } from "../src/tools/mcpResult.js";

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "snap-"));
});

const exists = (p: string) => access(p).then(() => true, () => false);

describe("toMcpResult", () => {
  it("wraps plain data as JSON text", async () => {
    expect(await toMcpResult({ ok: true, data: { width: 8 } }, dir)).toEqual({ content: [{ type: "text", text: '{"width":8}' }] });
  });

  it("marks errors", async () => {
    expect(await toMcpResult({ ok: false, error: "No sprite is open in Aseprite." }, dir)).toEqual({
      content: [{ type: "text", text: "Error: No sprite is open in Aseprite." }],
      isError: true,
    });
  });

  it("turns a snapshot into image content and deletes the file", async () => {
    const png = join(dir, "aseagent-1-1.png");
    await writeFile(png, Buffer.from([137, 80, 78, 71]));
    const r = await toMcpResult({ ok: true, data: { pngPath: png, scale: 32 } }, dir);
    expect(r.content[0]).toEqual({ type: "image", data: Buffer.from([137, 80, 78, 71]).toString("base64"), mimeType: "image/png" });
    expect(r.content[1]).toEqual({ type: "text", text: '{"scale":32}' });
    expect(await exists(png)).toBe(false);
  });

  it("refuses paths outside the snapshot dir and does not delete them", async () => {
    const other = await mkdtemp(join(tmpdir(), "other-"));
    const outside = join(other, "aseagent-1-1.png");
    await writeFile(outside, "x");
    const r = await toMcpResult({ ok: true, data: { pngPath: outside } }, dir);
    expect(r.isError).toBe(true);
    expect(await exists(outside)).toBe(true);
  });

  it("refuses traversal and non-snapshot names", async () => {
    for (const p of [join(dir, "..", "aseagent-1.png"), join(dir, "secrets.png"), join(dir, "aseagent-1.txt")]) {
      expect((await toMcpResult({ ok: true, data: { pngPath: p } }, dir)).isError).toBe(true);
    }
  });
});
