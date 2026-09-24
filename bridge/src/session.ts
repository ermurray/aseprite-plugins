import { randomUUID, timingSafeEqual } from "node:crypto";
import type { Adapter, AdapterFactory } from "./adapters/Adapter.js";
import { PROTOCOL_VERSION, parseExtensionMessage, type BridgeMessage } from "./protocol.js";
import { ToolBroker } from "./toolBroker.js";
import { isDraftLayer } from "./tools/constants.js";
import { toolDef, type ToolDef } from "./tools/definitions.js";
import type { ToolHost } from "./toolTypes.js";

export interface SessionDeps {
  token: string;
  send: (m: BridgeMessage) => void;
  close: (code: number, reason: string) => void;
  adapterFactory: AdapterFactory;
  systemPrompt: string;
  snapshotDir: string;
  toolTimeoutMs?: number;
}

function tokensMatch(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export class Session {
  private authed = false;
  private busy = false;
  private adapter?: Adapter;
  private broker: ToolBroker;
  private autoApprove = false;
  private draftMode = false;
  private approvals = new Map<string, (approved: boolean) => void>();

  constructor(private deps: SessionDeps) {
    this.broker = new ToolBroker(deps.send, { timeoutMs: deps.toolTimeoutMs ?? 30_000 });
  }

  /** Tools for one adapter. Once that adapter is replaced (New chat), its late calls fail silently. */
  private toolsFor(owner: () => Adapter | undefined): ToolHost {
    const stale = () => this.adapter !== owner();
    return {
      call: async (name, args) => {
        if (stale()) return { ok: false, error: "Chat reset" };
        const def = toolDef(name);
        if (!def) return { ok: false, error: `Unknown tool: ${name}` };
        if (def.kind === "edit") {
          const rejection = this.checkDraftLock(def, args);
          if (rejection) return { ok: false, error: rejection };
          if (!this.autoApprove) {
            const approved = await this.askApproval(def.summarize!(args), args.sprite);
            if (stale()) return { ok: false, error: "Chat reset" };
            if (!approved) return { ok: false, error: "The artist declined this change. Ask what they would prefer instead." };
          }
        }
        this.deps.send({ type: "tool_activity", summary: def.activity(args) });
        const fwd = def.forward ? def.forward(args) : { name, args };
        return this.broker.call(fwd.name, fwd.args);
      },
    };
  }

  /** Draft tools only work while the artist has "Allow AI drafts" switched on in the window. */
  private checkDraftLock(def: ToolDef, args: Record<string, unknown>): string | undefined {
    const draftTool = def.name === "create_draft_layer" || (def.name === "set_pixels" && isDraftLayer(args.layer));
    if (!draftTool || this.draftMode) return undefined;
    return 'AI drafts are switched off. Tell the artist you will not draw it for them, but can block out a rough draft on a 40% "AI Draft" layer if they switch on "Allow AI drafts" in the chat window.';
  }

  private askApproval(summary: string, sprite: unknown): Promise<boolean> {
    const approvalId = randomUUID();
    return new Promise((resolve) => {
      this.approvals.set(approvalId, resolve);
      this.deps.send({ type: "approval_request", approvalId, summary, ...(typeof sprite === "string" ? { sprite } : {}) });
    });
  }

  async handleRaw(raw: string): Promise<void> {
    const parsed = parseExtensionMessage(raw);
    if (!this.authed) {
      if (!parsed.ok || parsed.message.type !== "hello" || !tokensMatch(parsed.message.token, this.deps.token)) {
        this.deps.close(4001, "unauthorized");
        return;
      }
      this.authed = true;
      this.adapter = this.newAdapter();
      this.deps.send({ type: "ready", adapter: this.adapter.name, protocolVersion: PROTOCOL_VERSION, snapshotDir: this.deps.snapshotDir });
      return;
    }
    if (!parsed.ok) {
      this.deps.send({ type: "error", message: `Bad message: ${parsed.error}` });
      return;
    }
    const msg = parsed.message;
    switch (msg.type) {
      case "hello":
        return;
      case "user_message":
        return this.runTurn(msg.text);
      case "cancel":
        this.cancel("Cancelled by user");
        return;
      case "new_chat":
        this.cancel("Chat reset");
        this.adapter = this.newAdapter();
        this.busy = false;
        return;
      case "approval": {
        const resolve = this.approvals.get(msg.approvalId);
        this.approvals.delete(msg.approvalId);
        resolve?.(msg.approved);
        return;
      }
      case "set_auto_approve":
        this.autoApprove = msg.enabled;
        return;
      case "set_draft_mode":
        this.draftMode = msg.enabled;
        return;
      case "tool_result":
        this.broker.resolve(msg.callId, msg.ok ? { ok: true, data: msg.data } : { ok: false, error: msg.error ?? "Unknown tool error" });
        return;
    }
  }

  dispose(): void {
    this.cancel("Aseprite disconnected");
  }

  private cancel(reason: string): void {
    this.adapter?.cancel();
    for (const resolve of this.approvals.values()) resolve(false);
    this.approvals.clear();
    this.broker.cancelAll(reason);
  }


  private newAdapter(): Adapter {
    let adapter: Adapter | undefined;
    adapter = this.deps.adapterFactory({ tools: this.toolsFor(() => adapter), systemPrompt: this.deps.systemPrompt });
    return adapter;
  }

  private async runTurn(text: string): Promise<void> {
    if (this.busy) {
      this.deps.send({ type: "error", message: "Still working on the previous message. Press Stop or wait for it to finish." });
      return;
    }
    this.busy = true;
    const adapter = this.adapter!;
    const current = () => this.adapter === adapter;
    try {
      const note = `[AI drafts: ${this.draftMode ? "on" : "off"}]`;
      for await (const ev of adapter.send(`${note}\n${text}`)) if (current()) this.deps.send(ev);
    } catch (e) {
      if (current()) this.deps.send({ type: "error", message: e instanceof Error ? e.message : String(e) });
    } finally {
      // A turn orphaned by New chat ends silently; the new chat is already idle.
      if (current()) {
        this.busy = false;
        this.deps.send({ type: "turn_done" });
      }
    }
  }
}
