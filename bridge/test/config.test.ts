import { mkdtemp, readFile, stat, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { agentHome, removeBridgeInfo, snapshotDirFor, writeBridgeInfo } from "../src/config.js";

describe("config", () => {
  it("honours ASEPRITE_AGENT_HOME", () => {
    expect(agentHome({ ASEPRITE_AGENT_HOME: "/x" })).toBe("/x");
    expect(agentHome({})).toMatch(/\.aseprite-agent$/);
  });

  it("writes bridge.json with 0600 and removes it", async () => {
    const home = join(await mkdtemp(join(tmpdir(), "home-")), "nested");
    await writeBridgeInfo(home, { port: 1, token: "t", pid: 2 });
    const p = join(home, "bridge.json");
    expect(JSON.parse(await readFile(p, "utf8"))).toEqual({ port: 1, token: "t", pid: 2 });
    expect((await stat(p)).mode & 0o777).toBe(0o600);
    await removeBridgeInfo(home);
    await expect(access(p)).rejects.toThrow();
  });

  it("puts snapshots under home/tmp", () => {
    expect(snapshotDirFor("/h")).toBe("/h/tmp");
  });
});
