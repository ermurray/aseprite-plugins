import { z } from "zod";
import type { HistoryItem } from "./conversations.js";

const Rect = z.object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() });
const Context = z.object({
  activeSprite: z.string().optional(),
  frame: z.number().optional(),
  frameCount: z.number().optional(),
  layer: z.string().optional(),
  selection: Rect.optional(),
  openSprites: z.array(z.string()).optional(),
});

export const PROTOCOL_VERSION = 1;

const Hello = z.object({
  type: z.literal("hello"),
  token: z.string(),
  extensionVersion: z.string(),
  conversationId: z.string().optional(),
  projectRoot: z.string().nullable().optional(),
});
const UserMessage = z.object({ type: z.literal("user_message"), text: z.string().min(1), context: Context.optional(), attach: z.boolean().optional() });
const OpenProject = z.object({ type: z.literal("open_project"), projectRoot: z.string().nullable().optional(), conversationId: z.string().optional() });
const ListHistory = z.object({ type: z.literal("list_history") });
const OpenConversation = z.object({ type: z.literal("open_conversation"), conversationId: z.string() });

const Cancel = z.object({ type: z.literal("cancel") });
const NewChat = z.object({ type: z.literal("new_chat") });
const ToolResultMsg = z.object({
  type: z.literal("tool_result"),
  callId: z.string(),
  ok: z.boolean(),
  data: z.unknown().optional(),
  error: z.string().optional(),
});

const Approval = z.object({ type: z.literal("approval"), approvalId: z.string(), approved: z.boolean() });
const SetAutoApprove = z.object({ type: z.literal("set_auto_approve"), enabled: z.boolean() });
const SetDraftMode = z.object({ type: z.literal("set_draft_mode"), enabled: z.boolean() });

export const ExtensionMessage = z.discriminatedUnion("type", [Hello, UserMessage, Cancel, NewChat, ToolResultMsg, Approval, SetAutoApprove, SetDraftMode, OpenProject, ListHistory, OpenConversation]);
export type ExtensionMessage = z.infer<typeof ExtensionMessage>;

export type BridgeMessage =
  | { type: "ready"; adapter: string; protocolVersion: number; snapshotDir: string; projectRoot: string | null; projectName: string; conversationId: string; history: HistoryItem[] }
  | { type: "conversation"; conversationId: string; projectRoot: string | null; projectName: string; history: HistoryItem[] }
  | { type: "history_list"; items: { id: string; title: string; updatedAt: string }[] }
  | { type: "text_delta"; text: string }
  | { type: "notice"; text: string }
  | { type: "tool_activity"; summary: string }
  | { type: "tool_call"; callId: string; name: string; args: Record<string, unknown> }
  | { type: "turn_done" }
  | { type: "error"; message: string; hint?: string }
  | { type: "approval_request"; approvalId: string; summary: string; sprite?: string };

export type ParseResult = { ok: true; message: ExtensionMessage } | { ok: false; error: string };

export function parseExtensionMessage(raw: string): ParseResult {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { ok: false, error: "invalid JSON" };
  }
  const r = ExtensionMessage.safeParse(json);
  if (!r.success) {
    return { ok: false, error: r.error.issues.map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`).join("; ") };
  }
  return { ok: true, message: r.data };
}
