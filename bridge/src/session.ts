import { randomUUID, timingSafeEqual } from "node:crypto";
import type { Adapter, AdapterFactory } from "./adapters/Adapter.js";
import { ALLOWED_COMMANDS, parseCommand } from "./commands.js";
import { ConversationStore, HistoryRecorder, summarize, type Conversation } from "./conversations.js";
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
  /** Where conversations are saved; without one they live only as long as the connection. */
  store?: ConversationStore;
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
  private conv: Conversation = new ConversationStore("").create();
  private history = new HistoryRecorder(this.conv.items);

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
        this.emit({ type: "tool_activity", summary: def.activity(args) });
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
      this.emit({ type: "approval_request", approvalId, summary, ...(typeof sprite === "string" ? { sprite } : {}) });
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
      const id = parsed.message.conversationId;
      const saved = id ? await this.deps.store?.load(id) : undefined;
      this.useConversation(saved ?? this.newConversation());
      this.deps.send({
        type: "ready",
        adapter: this.adapter!.name,
        protocolVersion: PROTOCOL_VERSION,
        snapshotDir: this.deps.snapshotDir,
        conversationId: this.conv.id,
        history: this.conv.items,
      });
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
        this.startNewChat();
        return;
      case "approval": {
        const resolve = this.approvals.get(msg.approvalId);
        this.approvals.delete(msg.approvalId);
        this.history.resolveApproval(msg.approvalId, msg.approved);
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


  private startNewChat(): void {
    this.cancel("Chat reset");
    this.useConversation(this.newConversation());
    this.busy = false;
    this.deps.send({ type: "conversation", conversationId: this.conv.id, history: this.conv.items });
  }

  private newConversation(): Conversation {
    return (this.deps.store ?? new ConversationStore("")).create();
  }

  /** Switches to a conversation and starts an adapter that resumes its agent session, if any. */
  private useConversation(conv: Conversation): void {
    this.conv = conv;
    this.history = new HistoryRecorder(conv.items);
    this.history.endTurn(); // cards left pending by a previous run can no longer be answered
    let adapter: Adapter | undefined;
    adapter = this.deps.adapterFactory({
      tools: this.toolsFor(() => adapter),
      systemPrompt: this.deps.systemPrompt,
      resume: conv.resume,
      resumeSummary: conv.resume && conv.items.length ? summarize(conv.items) : undefined,
    });
    this.adapter = adapter;
  }

  /** Sends a message to the extension and records it in the conversation history. */
  private emit(m: BridgeMessage): void {
    if (m.type === "text_delta") this.history.agentDelta(m.text);
    else if (m.type === "tool_activity") this.history.activity(m.summary);
    else if (m.type === "approval_request") this.history.approval(m.approvalId, m.summary);
    else if (m.type === "error") this.history.error(m.message, m.hint);
    else if (m.type === "notice") this.history.notice(m.text);
    this.deps.send(m);
  }

  private async persist(conv: Conversation, adapter: Adapter): Promise<void> {
    if (!this.deps.store) return;
    conv.title = new HistoryRecorder(conv.items).title();
    conv.resume = adapter.resumeState() ?? conv.resume;
    try {
      await this.deps.store.save(conv);
    } catch (e) {
      console.error(`Could not save conversation ${conv.id}: ${(e as Error).message}`);
    }
  }

  private async runTurn(text: string): Promise<void> {
    if (this.busy) {
      this.deps.send({ type: "error", message: "Still working on the previous message. Press Stop or wait for it to finish." });
      return;
    }
    const cmd = parseCommand(text);
    if (cmd?.name === "clear") {
      this.startNewChat();
      this.deps.send({ type: "turn_done" });
      return;
    }
    this.busy = true;
    const adapter = this.adapter!;
    const conv = this.conv;
    const current = () => this.adapter === adapter;
    this.history.user(text);
    await this.persist(conv, adapter);
    try {
      if (cmd && !ALLOWED_COMMANDS.has(cmd.name)) {
        this.emit({ type: "error", message: `/${cmd.name} isn't available in Aseprite.`, hint: "Try /compact, /context, /usage, /model, /effort, /recap or /clear." });
        return;
      }
      // Slash commands go to Claude Code untouched; other messages carry the drafts switch.
      const prompt = cmd ? cmd.raw : `[AI drafts: ${this.draftMode ? "on" : "off"}]\n${text}`;
      for await (const ev of adapter.send(prompt)) if (current()) this.emit(ev);
    } catch (e) {
      if (current()) this.emit({ type: "error", message: e instanceof Error ? e.message : String(e) });
    } finally {
      if (current()) this.history.endTurn();
      await this.persist(conv, adapter);
      // A turn orphaned by New chat ends silently; the new chat is already idle.
      if (current()) {
        this.busy = false;
        this.deps.send({ type: "turn_done" });
      }
    }
  }
}
