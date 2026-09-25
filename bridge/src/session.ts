import { randomUUID, timingSafeEqual } from "node:crypto";
import type { Adapter, AdapterFactory } from "./adapters/Adapter.js";
import { ALLOWED_COMMANDS, parseCommand } from "./commands.js";
import { ConversationStore, HistoryRecorder, summarize, type Conversation } from "./conversations.js";
import { buildSystemPrompt, isProjectRoot, projectName, readProjectNotes } from "./project.js";
import { formatStamp, type MessageContext } from "./stamp.js";
import type { StoreRegistry } from "./stores.js";
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
  stores?: StoreRegistry;
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
  private turnCancelled = false;
  private projectRoot: string | null = null;
  private pendingProject?: { root: string | null; conversationId?: string };
  private lastContext?: MessageContext;
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
            const approved = await this.askApproval(this.summaryFor(def, args), args.sprite);
            if (stale()) return { ok: false, error: "Chat reset" };
            if (!approved) return { ok: false, error: "The artist declined this change. Ask what they would prefer instead." };
          }
        }
        this.emit({ type: "tool_activity", summary: def.activity(args) });
        if (def.runInBridge) return def.runInBridge(args, { projectRoot: this.projectRoot });
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
      await this.openProject(await this.validRoot(parsed.message.projectRoot), parsed.message.conversationId);
      this.deps.send({
        type: "ready",
        adapter: this.adapter!.name,
        protocolVersion: PROTOCOL_VERSION,
        snapshotDir: this.deps.snapshotDir,
        projectRoot: this.projectRoot,
        projectName: projectName(this.projectRoot),
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
        return this.runTurn(msg.text, msg.context, msg.attach);
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
      case "open_project": {
        const root = await this.validRoot(msg.projectRoot);
        if (this.busy) {
          this.pendingProject = { root, conversationId: msg.conversationId };
          return;
        }
        await this.openProject(root, msg.conversationId);
        this.deps.send(this.conversationMessage());
        return;
      }
      case "list_history":
        this.deps.send({ type: "history_list", items: (await this.store()?.list()) ?? [] });
        return;
      case "open_conversation": {
        if (this.busy) {
          this.deps.send({ type: "error", message: "Finish or stop the current reply before opening another chat." });
          return;
        }
        const saved = await this.store()?.load(msg.conversationId);
        if (!saved) {
          this.deps.send({ type: "error", message: "That chat no longer exists." });
          return;
        }
        this.useConversation(saved);
        this.deps.send(this.conversationMessage());
        return;
      }
      case "tool_result":
        this.broker.resolve(msg.callId, msg.ok ? { ok: true, data: msg.data } : { ok: false, error: msg.error ?? "Unknown tool error" });
        return;
    }
  }

  dispose(): void {
    this.cancel("Aseprite disconnected");
  }

  private cancel(reason: string): void {
    this.turnCancelled = true;
    this.adapter?.cancel();
    for (const resolve of this.approvals.values()) resolve(false);
    this.approvals.clear();
    this.broker.cancelAll(reason);
  }


  private startNewChat(): void {
    this.cancel("Chat reset");
    this.useConversation(this.newConversation());
    this.busy = false;
    this.deps.send(this.conversationMessage());
  }

  private newConversation(): Conversation {
    return (this.store() ?? new ConversationStore("")).create();
  }

  private store(): ConversationStore | undefined {
    return this.deps.stores?.get(this.projectRoot);
  }

  private async validRoot(root: unknown): Promise<string | null> {
    return (await isProjectRoot(root)) ? (root as string) : null;
  }

  /** Opens a project's conversation (the given one if it exists there, else a new one). */
  private async openProject(root: string | null, conversationId?: string): Promise<void> {
    this.projectRoot = root;
    const saved = conversationId ? await this.store()?.load(conversationId) : undefined;
    this.useConversation(saved ?? this.newConversation());
  }

  private conversationMessage(): BridgeMessage {
    return {
      type: "conversation",
      conversationId: this.conv.id,
      projectRoot: this.projectRoot,
      projectName: projectName(this.projectRoot),
      history: this.conv.items,
    };
  }

  private async systemPromptNow(): Promise<string> {
    if (!this.projectRoot || !(await isProjectRoot(this.projectRoot))) return buildSystemPrompt(this.deps.systemPrompt, undefined);
    return buildSystemPrompt(this.deps.systemPrompt, { name: projectName(this.projectRoot), notes: await readProjectNotes(this.projectRoot) });
  }

  private summaryFor(def: ToolDef, args: Record<string, unknown>): string {
    const summary = def.summarize!(args);
    const open = this.lastContext?.openSprites;
    const sprite = args.sprite;
    if (typeof sprite === "string" && open && !open.includes(sprite) && !open.some((o) => o.endsWith(`/${sprite}`))) {
      return `${summary} (opens it as a tab)`;
    }
    return summary;
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

  private async persist(conv: Conversation, adapter: Adapter, store: ConversationStore | undefined): Promise<void> {
    if (!store) return;
    conv.title = new HistoryRecorder(conv.items).title();
    conv.resume = adapter.resumeState() ?? conv.resume;
    try {
      await store.save(conv);
    } catch (e) {
      console.error(`Could not save conversation ${conv.id}: ${(e as Error).message}`);
    }
  }

  private async runTurn(text: string, context?: MessageContext, attach = false): Promise<void> {
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
    const store = this.store();
    const current = () => this.adapter === adapter;
    this.lastContext = context;
    this.turnCancelled = false;
    this.history.user(text);
    await this.persist(conv, adapter, store);
    try {
      // Stop, New chat or a disconnect during that save: don't start Claude at all.
      if (!current() || this.turnCancelled) return;
      if (cmd && !ALLOWED_COMMANDS.has(cmd.name)) {
        this.emit({ type: "error", message: `/${cmd.name} isn't available in Aseprite.`, hint: "Try /compact, /context, /usage, /model, /effort, /recap or /clear." });
        return;
      }
      // Slash commands go to Claude Code untouched; other messages carry the context stamp.
      const prompt = cmd ? cmd.raw : `${formatStamp(context, this.draftMode, attach)}\n${text}`;
      for await (const ev of adapter.send(prompt, { systemPrompt: await this.systemPromptNow() })) if (current()) this.emit(ev);
    } catch (e) {
      if (current()) this.emit({ type: "error", message: e instanceof Error ? e.message : String(e) });
    } finally {
      if (current()) this.history.endTurn();
      await this.persist(conv, adapter, store);
      // A turn orphaned by New chat ends silently; the new chat is already idle.
      if (current()) {
        this.busy = false;
        this.deps.send({ type: "turn_done" });
      }
      if (current() && this.pendingProject) {
        const next = this.pendingProject;
        this.pendingProject = undefined;
        await this.openProject(next.root, next.conversationId);
        this.deps.send(this.conversationMessage());
      }
    }
  }
}
