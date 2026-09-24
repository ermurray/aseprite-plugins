import { afterEach, describe, expect, it, vi } from "vitest";
import type { BridgeMessage } from "../src/protocol.js";
import { ToolBroker } from "../src/toolBroker.js";

function setup(timeoutMs = 1000) {
  const sent: BridgeMessage[] = [];
  let n = 0;
  const broker = new ToolBroker((m) => sent.push(m), { timeoutMs, newId: () => `c${++n}` });
  return { broker, sent };
}

afterEach(() => vi.useRealTimers());

describe("ToolBroker", () => {
  it("sends tool_call and resolves with the matching result", async () => {
    const { broker, sent } = setup();
    const p = broker.call("get_palette", { sprite: "a.aseprite" });
    expect(sent).toEqual([{ type: "tool_call", callId: "c1", name: "get_palette", args: { sprite: "a.aseprite" } }]);
    expect(broker.resolve("c1", { ok: true, data: { size: 4 } })).toBe(true);
    await expect(p).resolves.toEqual({ ok: true, data: { size: 4 } });
    expect(broker.pendingCount).toBe(0);
  });

  it("ignores unknown call ids", () => {
    const { broker } = setup();
    expect(broker.resolve("nope", { ok: true, data: null })).toBe(false);
  });

  it("times out with an error result", async () => {
    vi.useFakeTimers();
    const { broker } = setup(30_000);
    const p = broker.call("get_snapshot", {});
    vi.advanceTimersByTime(30_000);
    await expect(p).resolves.toEqual({ ok: false, error: "Tool get_snapshot timed out after 30s" });
    expect(broker.pendingCount).toBe(0);
  });

  it("cancelAll resolves every pending call with the reason", async () => {
    const { broker } = setup();
    const a = broker.call("a", {});
    const b = broker.call("b", {});
    broker.cancelAll("Aseprite disconnected");
    await expect(a).resolves.toEqual({ ok: false, error: "Aseprite disconnected" });
    await expect(b).resolves.toEqual({ ok: false, error: "Aseprite disconnected" });
    expect(broker.pendingCount).toBe(0);
  });
});
