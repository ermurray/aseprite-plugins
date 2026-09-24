import { readFile, rm } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import type { ToolResult } from "../toolTypes.js";

export type McpContent = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };
export interface McpToolResult {
  content: McpContent[];
  isError?: boolean;
}

const SNAPSHOT_NAME = /^aseagent-[\w-]+\.png$/;

const errorResult = (message: string): McpToolResult => ({ content: [{ type: "text", text: `Error: ${message}` }], isError: true });

function isSnapshotPath(path: string, snapshotDir: string): boolean {
  const p = resolve(path);
  return dirname(p) === resolve(snapshotDir) && SNAPSHOT_NAME.test(basename(p));
}

export async function toMcpResult(r: ToolResult, snapshotDir: string): Promise<McpToolResult> {
  if (!r.ok) return errorResult(r.error);
  const data = (r.data ?? {}) as Record<string, unknown>;
  const pngPath = data.pngPath;
  if (typeof pngPath !== "string") return { content: [{ type: "text", text: JSON.stringify(r.data ?? null) }] };

  const { pngPath: _omit, ...rest } = data;
  if (!isSnapshotPath(pngPath, snapshotDir)) return errorResult("snapshot path is outside the bridge snapshot directory");
  try {
    const buf = await readFile(pngPath);
    return {
      content: [
        { type: "image", data: buf.toString("base64"), mimeType: "image/png" },
        { type: "text", text: JSON.stringify(rest) },
      ],
    };
  } catch (e) {
    return errorResult(`snapshot file unreadable (${(e as Error).message})`);
  } finally {
    await rm(pngPath, { force: true });
  }
}
