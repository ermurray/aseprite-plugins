import { z } from "zod";

export const PROTOCOL_VERSION = 1;

const Hello = z.object({ type: z.literal("hello"), token: z.string(), extensionVersion: z.string() });
const UserMessage = z.object({ type: z.literal("user_message"), text: z.string().min(1) });
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

export const ExtensionMessage = z.discriminatedUnion("type", [Hello, UserMessage, Cancel, NewChat, ToolResultMsg, Approval, SetAutoApprove]);
export type ExtensionMessage = z.infer<typeof ExtensionMessage>;

export type BridgeMessage =
  | { type: "ready"; adapter: string; protocolVersion: number; snapshotDir: string }
  | { type: "text_delta"; text: string }
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
