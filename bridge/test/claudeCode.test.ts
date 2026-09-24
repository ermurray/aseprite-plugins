import { describe, expect, it } from "vitest";
import type { AdapterEvent } from "../src/adapters/Adapter.js";
import { ClaudeCodeAdapter, classifyError, createSdkMapper, makeToolHandler } from "../src/adapters/claudeCode.js";
import { toolDef } from "../src/tools/definitions.js";

const delta = (text: string, parent: string | null = null) => ({
  type: "stream_event",
  parent_tool_use_id: parent,
  session_id: "s1",
  event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
});
const messageStart = { type: "stream_event", parent_tool_use_id: null, session_id: "s1", event: { type: "message_start" } };

function fakeQuery(messages: unknown[], calls: any[]) {
  return ((params: any) => {
    calls.push(params);
    return (async function* () {
      for (const m of messages) yield m;
    })();
  }) as any;
}

async function collect(it: AsyncIterable<AdapterEvent>) {
  const out: AdapterEvent[] = [];
  for await (const e of it) out.push(e);
  return out;
}

const noTools = { call: async () => ({ ok: true as const, data: {} }) };

describe("createSdkMapper", () => {
  it("maps top-level text deltas and ignores subagent deltas", () => {
    const map = createSdkMapper();
    expect(map(delta("Hi"))).toEqual({ type: "text_delta", text: "Hi" });
    expect(map(delta("sub", "tool-1"))).toBeUndefined();
  });

  it("separates consecutive assistant messages with a blank line", () => {
    const map = createSdkMapper();
    expect(map(messageStart)).toBeUndefined();
    map(delta("Let me look."));
    expect(map(messageStart)).toEqual({ type: "text_delta", text: "\n\n" });
  });

  it("maps failed results to errors", () => {
    const map = createSdkMapper();
    expect(map({ type: "result", subtype: "error_max_turns", errors: ["too many"] })).toEqual({
      type: "error",
      message: "Claude stopped (error_max_turns): too many",
    });
    expect(map({ type: "result", subtype: "success" })).toBeUndefined();
  });
});

describe("classifyError", () => {
  it("explains a missing CLI", () => {
    expect(classifyError(new Error("spawn claude ENOENT"))).toMatchObject({ hint: expect.stringContaining("claude") });
  });
  it("explains a missing login", () => {
    expect(classifyError(new Error("401 Unauthorized"))).toMatchObject({ hint: expect.stringContaining("log in") });
  });
  it("passes other errors through", () => {
    expect(classifyError(new Error("weird"))).toEqual({ type: "error", message: "weird" });
  });
});

describe("ClaudeCodeAdapter", () => {
  it("streams text and locks Claude Code down to the aseprite tools", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: fakeQuery([delta("Hello")], calls) });
    expect(await collect(a.send("hi"))).toEqual([{ type: "text_delta", text: "Hello" }]);
    const o = calls[0].options;
    expect(calls[0].prompt).toBe("hi");
    expect(o.systemPrompt).toBe("SP");
    expect(o.tools).toEqual([]);
    expect(o.settingSources).toEqual([]);
    expect(o.includePartialMessages).toBe(true);
    expect([...o.allowedTools].sort()).toEqual([
      "mcp__aseprite__get_palette",
      "mcp__aseprite__get_pixels",
      "mcp__aseprite__get_snapshot",
      "mcp__aseprite__get_sprite_info",
    ]);
    expect(Object.keys(o.mcpServers)).toEqual(["aseprite"]);
  });

  it("resumes the SDK session on the next turn", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: fakeQuery([delta("x")], calls) });
    await collect(a.send("one"));
    await collect(a.send("two"));
    expect(calls[0].options.resume).toBeUndefined();
    expect(calls[1].options.resume).toBe("s1");
    expect(a.resumeState()).toEqual({ sessionId: "s1" });
  });

  it("starts from a stored session id", async () => {
    const calls: any[] = [];
    const a = new ClaudeCodeAdapter(
      { tools: noTools, systemPrompt: "SP", resume: { sessionId: "old" } },
      { snapshotDir: "/s", queryFn: fakeQuery([], calls) },
    );
    await collect(a.send("hi"));
    expect(calls[0].options.resume).toBe("old");
  });

  it("turns SDK exceptions into classified errors", async () => {
    const throwing = (() => {
      throw new Error("spawn claude ENOENT");
    }) as any;
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: throwing });
    const evs = await collect(a.send("hi"));
    expect(evs[0]).toMatchObject({ type: "error", hint: expect.stringContaining("claude") });
  });

  it("cancel aborts the running query", async () => {
    let signal: AbortSignal | undefined;
    const q = ((params: any) => {
      signal = params.options.abortController.signal;
      return (async function* () {
        yield delta("a");
        await new Promise((r) => setTimeout(r, 50));
        if (signal!.aborted) throw new Error("aborted");
        yield delta("b");
      })();
    }) as any;
    const a = new ClaudeCodeAdapter({ tools: noTools, systemPrompt: "SP" }, { snapshotDir: "/s", queryFn: q });
    const out: AdapterEvent[] = [];
    for await (const e of a.send("hi")) {
      out.push(e);
      a.cancel();
    }
    expect(signal!.aborted).toBe(true);
    expect(out).toEqual([{ type: "text_delta", text: "a" }]);
  });
});

describe("makeToolHandler", () => {
  it("forwards to the tool host and converts the result", async () => {
    const seen: unknown[] = [];
    const handler = makeToolHandler(toolDef("get_palette")!, { call: async (n, a) => (seen.push([n, a]), { ok: true, data: { size: 2 } }) }, "/s");
    expect(await handler({ sprite: "a.aseprite" })).toEqual({ content: [{ type: "text", text: '{"size":2}' }] });
    expect(seen).toEqual([["get_palette", { sprite: "a.aseprite" }]]);
  });
});
