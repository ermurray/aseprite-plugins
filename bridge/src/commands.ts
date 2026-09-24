/** Claude Code slash commands that make sense from the Aseprite chat window. /clear is handled as New chat. */
export const ALLOWED_COMMANDS = new Set(["compact", "context", "usage", "model", "effort", "recap"]);

export function parseCommand(text: string): { name: string; raw: string } | undefined {
  const raw = text.trim();
  const m = raw.match(/^\/([a-z][\w-]*)/i);
  return m ? { name: m[1].toLowerCase(), raw } : undefined;
}
