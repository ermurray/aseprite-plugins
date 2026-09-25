import { access, constants } from "node:fs/promises";
import { join } from "node:path";

export async function isExecutable(p: string): Promise<boolean> {
  try {
    await access(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** Finds the installed Claude Code CLI. Aseprite starts the bridge with a minimal PATH, so check known spots too. */
export async function findClaude(
  env: Record<string, string | undefined>,
  home: string,
  exec: (p: string) => Promise<boolean> = isExecutable,
): Promise<string | undefined> {
  const candidates: string[] = [];
  if (env.ASEPRITE_AGENT_CLAUDE) candidates.push(env.ASEPRITE_AGENT_CLAUDE);
  for (const dir of (env.PATH ?? "").split(":").filter(Boolean)) candidates.push(join(dir, "claude"));
  candidates.push(
    join(home, ".local", "bin", "claude"),
    join(home, ".claude", "local", "claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    join(home, ".npm-global", "bin", "claude"),
  );
  for (const c of candidates) if (await exec(c)) return c;
  return undefined;
}
