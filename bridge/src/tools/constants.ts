export const DRAFT_LAYER = "AI Draft";
export const NOTES_LAYER = "Agent Notes";
export const PIXEL_BUDGET = { perCall: 256, perTurn: 1024 };

export function isDraftLayer(name: unknown): boolean {
  return typeof name === "string" && name.trim().toLowerCase() === DRAFT_LAYER.toLowerCase();
}
