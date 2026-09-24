import { chmod, mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEFAULT_PORT = 47821;

export interface BridgeInfo {
  port: number;
  token: string;
  pid: number;
}

export function agentHome(env: Record<string, string | undefined> = process.env): string {
  return env.ASEPRITE_AGENT_HOME ?? join(homedir(), ".aseprite-agent");
}

export function snapshotDirFor(home: string): string {
  return join(home, "tmp");
}

export async function writeBridgeInfo(home: string, info: BridgeInfo): Promise<void> {
  await mkdir(home, { recursive: true, mode: 0o700 });
  const p = join(home, "bridge.json");
  await writeFile(p, JSON.stringify(info), { mode: 0o600 });
  await chmod(p, 0o600);
}

export async function removeBridgeInfo(home: string): Promise<void> {
  await rm(join(home, "bridge.json"), { force: true });
}
