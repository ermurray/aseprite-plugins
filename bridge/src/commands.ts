/** Claude Code slash commands that make sense from the Aseprite chat window. /clear is handled as New chat. */
export const ALLOWED_COMMANDS = new Set(["compact", "context", "usage", "model", "effort", "recap"]);

export function parseCommand(text: string): { name: string; raw: string } | undefined {
  // The name must end at whitespace or the end of the text, so "/path/file ..." stays a question.
  const m = text.trim().match(/^\/([a-z][\w-]*)(?=\s|$)([\s\S]*)$/i);
  if (!m) return undefined;
  const name = m[1].toLowerCase();
  return { name, raw: `/${name}${m[2]}` };
}
