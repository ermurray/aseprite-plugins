import { timingSafeEqual } from "node:crypto";
import type { Adapter, AdapterFactory } from "./adapters/Adapter.js";
import { PROTOCOL_VERSION, parseExtensionMessage, type BridgeMessage } from "./protocol.js";
import { ToolBroker } from "./toolBroker.js";
import { toolDef } from "./tools/definitions.js";
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

  constructor(private deps: SessionDeps) {
    this.broker = new ToolBroker(deps.send, { timeoutMs: deps.toolTimeoutMs ?? 30_000 });
  }

  /** Tools for one adapter. Once that adapter is replaced (New chat), its late calls fail silently. */
  private toolsFor(owner: () => Adapter | undefined): ToolHost {
    return {
      call: (name, args) => {
        if (this.adapter !== owner()) return Promise.resolve({ ok: false, error: "Chat reset" });
        const def = toolDef(name);
        this.deps.send({ type: "tool_activity", summary: def ? def.activity(args) : `Used ${name}` });
        return this.broker.call(name, args);
      },
    };
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
      for await (const ev of adapter.send(text)) if (current()) this.deps.send(ev);
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
