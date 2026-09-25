export interface MessageContext {
  activeSprite?: string;
  frame?: number;
  frameCount?: number;
  layer?: string;
  selection?: { x: number; y: number; w: number; h: number };
  openSprites?: string[];
}

/** The note in front of every artist message so Claude knows where they are. */
export function formatStamp(ctx: MessageContext | undefined, draftMode: boolean, attach: boolean): string {
  const parts: string[] = [];
  if (ctx?.activeSprite) {
    let a = `active: ${ctx.activeSprite}`;
    if (ctx.frame) a += ` - frame ${ctx.frame}${ctx.frameCount ? `/${ctx.frameCount}` : ""}`;
    if (ctx.layer) a += ` - layer "${ctx.layer}"`;
    if (ctx.selection) a += ` - selection ${ctx.selection.w}x${ctx.selection.h} at (${ctx.selection.x},${ctx.selection.y})`;
    parts.push(a);
  } else {
    parts.push("active: none");
  }
  if (ctx?.openSprites?.length) parts.push(`open: ${ctx.openSprites.join(", ")}`);
  parts.push(`AI drafts: ${draftMode ? "on" : "off"}`);
  let stamp = `[${parts.join(" | ")}]`;
  if (attach) stamp += "\n[The artist attached the current view: look at it with get_snapshot before answering.]";
  return stamp;
}
