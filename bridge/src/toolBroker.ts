import { randomUUID } from "node:crypto";
import type { BridgeMessage } from "./protocol.js";
import type { ToolHost, ToolResult } from "./toolTypes.js";

type Pending = { resolve: (r: ToolResult) => void; timer: NodeJS.Timeout };

export class ToolBroker implements ToolHost {
  private pending = new Map<string, Pending>();

  constructor(
    private send: (msg: BridgeMessage) => void,
    private opts: { timeoutMs: number; newId?: () => string },
  ) {}

  call(name: string, args: Record<string, unknown>): Promise<ToolResult> {
    const callId = (this.opts.newId ?? randomUUID)();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(callId);
        resolve({ ok: false, error: `Tool ${name} timed out after ${this.opts.timeoutMs / 1000}s` });
      }, this.opts.timeoutMs);
      this.pending.set(callId, { resolve, timer });
      this.send({ type: "tool_call", callId, name, args });
    });
  }

  resolve(callId: string, result: ToolResult): boolean {
    const p = this.pending.get(callId);
    if (!p) return false;
    clearTimeout(p.timer);
    this.pending.delete(callId);
    p.resolve(result);
    return true;
  }

  cancelAll(reason: string): void {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.resolve({ ok: false, error: reason });
    }
    this.pending.clear();
  }

  get pendingCount(): number {
    return this.pending.size;
  }
}
