import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { appendMemory, buildSystemPrompt, isProjectRoot, projectName, readProjectNotes } from "../src/project.js";

async function project(files: Record<string, string> = {}) {
  const root = await mkdtemp(join(tmpdir(), "proj "));
  await mkdir(join(root, ".artproject"));
  for (const [name, text] of Object.entries(files)) await writeFile(join(root, ".artproject", name), text);
  return root;
}

describe("project helpers", () => {
  it("recognises only absolute folders that contain .artproject", async () => {
    const root = await project();
    expect(await isProjectRoot(root)).toBe(true);
    expect(await isProjectRoot(join(root, "nope"))).toBe(false);
    expect(await isProjectRoot("relative/path")).toBe(false);
    expect(await isProjectRoot(null)).toBe(false);
    expect(await isProjectRoot(await mkdtemp(join(tmpdir(), "plain-")))).toBe(false);
  });

  it("names projects after their folder", () => {
    expect(projectName("/art/My Game")).toBe("My Game");
    expect(projectName(null)).toBe("No project");
  });

  it("reads brief and memory, tolerating missing files and capping size", async () => {
    const root = await project({ "brief.md": "32x32 characters\n", "memory.md": "x".repeat(9000) });
    const notes = await readProjectNotes(root);
    expect(notes.brief).toBe("32x32 characters");
    expect(notes.memory.length).toBeLessThan(8100);
    expect(notes.memory.endsWith("[...truncated]")).toBe(true);
    expect(await readProjectNotes(await project())).toEqual({ brief: "", memory: "" });
  });

  it("appends one tidy line per memory note", async () => {
    const root = await project({ "memory.md": "# Project memory\n" });
    await appendMemory(root, "  Hero uses a   2px outline\n");
    expect(await readFile(join(root, ".artproject", "memory.md"), "utf8")).toBe("# Project memory\n- Hero uses a 2px outline\n");
  });

  it("builds the system prompt from the base plus project notes", () => {
    const withNotes = buildSystemPrompt("BASE", { name: "Game", notes: { brief: "Light from top-left.", memory: "- 2px outline" } });
    expect(withNotes.startsWith("BASE")).toBe(true);
    expect(withNotes).toContain("Project: Game.");
    expect(withNotes).toContain("Light from top-left.");
    expect(withNotes).toContain("- 2px outline");
    expect(withNotes).toContain("propose_memory");
    expect(buildSystemPrompt("BASE", { name: "Game", notes: { brief: "", memory: "" } })).toContain("no brief yet");
    expect(buildSystemPrompt("BASE", undefined)).toContain("There is no project open");
  });
});
