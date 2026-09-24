export type ToolResult = { ok: true; data: unknown } | { ok: false; error: string };

export interface ToolHost {
  call(name: string, args: Record<string, unknown>): Promise<ToolResult>;
}
