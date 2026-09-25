import { describe, expect, it } from "vitest";
import { findClaude } from "../src/claudePath.js";

const only = (...ok: string[]) => async (p: string) => ok.includes(p);

describe("findClaude", () => {
  it("prefers ASEPRITE_AGENT_CLAUDE, then PATH, then well-known install locations", async () => {
    expect(await findClaude({ ASEPRITE_AGENT_CLAUDE: "/x/claude" }, "/h", only("/x/claude"))).toBe("/x/claude");
    expect(await findClaude({ PATH: "/a:/b" }, "/h", only("/b/claude"))).toBe("/b/claude");
    expect(await findClaude({ PATH: "/usr/bin" }, "/h", only("/h/.local/bin/claude"))).toBe("/h/.local/bin/claude");
    expect(await findClaude({}, "/h", only("/opt/homebrew/bin/claude"))).toBe("/opt/homebrew/bin/claude");
    expect(await findClaude({}, "/h", only("/h/.claude/local/claude"))).toBe("/h/.claude/local/claude");
    expect(await findClaude({}, "/h", only())).toBeUndefined();
  });
});
