export const DRAFT_LAYER = "AI Draft";
export const NOTES_LAYER = "Agent Notes";

export function isDraftLayer(name: unknown): boolean {
  return typeof name === "string" && name.trim().toLowerCase() === DRAFT_LAYER.toLowerCase();
}
