import { createSdkMcpServer, query as sdkQuery, tool } from "@anthropic-ai/claude-agent-sdk";
import { TOOL_DEFS, type ToolDef } from "../tools/definitions.js";
import { toMcpResult, type McpToolResult } from "../tools/mcpResult.js";
import type { ToolHost } from "../toolTypes.js";
import type { Adapter, AdapterContext, AdapterEvent, AdapterFactory, ResumeState } from "./Adapter.js";

export const MCP_SERVER_NAME = "aseprite";

type QueryFn = typeof sdkQuery;

export interface ClaudeCodeOptions {
  snapshotDir: string;
  model?: string;
  queryFn?: QueryFn;
}

export function claudeCodeAdapterFactory(opts: ClaudeCodeOptions): AdapterFactory {
  return (ctx) => new ClaudeCodeAdapter(ctx, opts);
}

export function makeToolHandler(def: ToolDef, tools: ToolHost, snapshotDir: string) {
  return async (args: Record<string, unknown>): Promise<McpToolResult> => toMcpResult(await tools.call(def.name, args), snapshotDir);
}

/** Maps Agent SDK messages to adapter events. Stateful: remembers whether text has been emitted this turn. */
export function createSdkMapper() {
  let emittedText = false;
  return (msg: any): AdapterEvent | undefined => {
    if (msg?.type === "stream_event") {
      if (msg.parent_tool_use_id != null) return undefined;
      const ev = msg.event;
      if (ev?.type === "message_start" && emittedText) return { type: "text_delta", text: "\n\n" };
      if (ev?.type === "content_block_delta" && ev.delta?.type === "text_delta") {
        emittedText = true;
        return { type: "text_delta", text: ev.delta.text };
      }
      return undefined;
    }
    if (msg?.type === "result" && msg.subtype !== "success") {
      const detail = Array.isArray(msg.errors) && msg.errors.length ? `: ${msg.errors.join("; ")}` : "";
      return { type: "error", message: `Claude stopped (${msg.subtype})${detail}` };
    }
    return undefined;
  };
}

export function classifyError(e: unknown): AdapterEvent {
  const message = e instanceof Error ? e.message : String(e);
  if (/ENOENT|spawn|not found/i.test(message)) {
    return { type: "error", message: "Couldn't start Claude Code.", hint: "Install Claude Code so `claude` is on your PATH, then restart the bridge." };
  }
  if (/401|unauthori[sz]ed|not logged in|login|authenticat/i.test(message)) {
    return { type: "error", message: "Claude Code isn't logged in.", hint: "Run `claude` in a terminal and log in, then try again." };
  }
  return { type: "error", message };
}

export class ClaudeCodeAdapter implements Adapter {
  readonly name = "claude-code";
  private sessionId?: string;
  private abort?: AbortController;

  constructor(
    private ctx: AdapterContext,
    private opts: ClaudeCodeOptions,
  ) {
    const s = ctx.resume?.sessionId;
    if (typeof s === "string") this.sessionId = s;
  }

  private mcpServer() {
    return createSdkMcpServer({
      name: MCP_SERVER_NAME,
      version: "0.1.0",
      tools: TOOL_DEFS.map((def) => {
        const handler = makeToolHandler(def, this.ctx.tools, this.opts.snapshotDir);
        return tool(def.name, def.description, def.shape, async (args) => (await handler(args as Record<string, unknown>)) as any);
      }),
    });
  }

  async *send(text: string): AsyncIterable<AdapterEvent> {
    const abort = new AbortController();
    this.abort = abort;
    const map = createSdkMapper();
    try {
      const q = (this.opts.queryFn ?? sdkQuery)({
        prompt: text,
        options: {
          systemPrompt: this.ctx.systemPrompt,
          tools: [],
          allowedTools: TOOL_DEFS.map((d) => `mcp__${MCP_SERVER_NAME}__${d.name}`),
          mcpServers: { [MCP_SERVER_NAME]: this.mcpServer() },
          settingSources: [],
          includePartialMessages: true,
          abortController: abort,
          resume: this.sessionId,
          model: this.opts.model,
          env: { ...process.env, CLAUDE_AGENT_SDK_CLIENT_APP: "aseprite-agent/0.1.0" },
        },
      });
      for await (const msg of q as AsyncIterable<any>) {
        if (abort.signal.aborted) return;
        if (typeof msg?.session_id === "string") this.sessionId = msg.session_id;
        const ev = map(msg);
        if (ev) yield ev;
      }
    } catch (e) {
      if (abort.signal.aborted) return;
      yield classifyError(e);
    } finally {
      if (this.abort === abort) this.abort = undefined;
    }
  }

  cancel(): void {
    this.abort?.abort();
  }

  resumeState(): ResumeState | undefined {
    return this.sessionId ? { sessionId: this.sessionId } : undefined;
  }
}
