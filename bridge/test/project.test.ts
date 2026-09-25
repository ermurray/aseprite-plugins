import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { appendMemory, buildSystemPrompt, changeBrief, describeBriefChange, isProjectRoot, projectName, readProjectNotes } from "../src/project.js";

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
    expect(await readProjectNotes(await project())).toEqual({ brief: "", memory: "", palette: [] });
  });

  it("appends one tidy line per memory note", async () => {
    const root = await project({ "memory.md": "# Project memory\n" });
    await appendMemory(root, "  Hero uses a   2px outline\n");
    expect(await readFile(join(root, ".artproject", "memory.md"), "utf8")).toBe("# Project memory\n- Hero uses a 2px outline\n");
  });

  it("builds the system prompt from the base plus project notes", () => {
    const withNotes = buildSystemPrompt("BASE", { name: "Game", notes: { brief: "Light from top-left.", memory: "- 2px outline", palette: [] } });
    expect(withNotes.startsWith("BASE")).toBe(true);
    expect(withNotes).toContain("Project: Game.");
    expect(withNotes).toContain("Light from top-left.");
    expect(withNotes).toContain("- 2px outline");
    expect(withNotes).toContain("propose_memory");
    expect(buildSystemPrompt("BASE", { name: "Game", notes: { brief: "", memory: "", palette: [] } })).toContain("no brief yet");
    expect(buildSystemPrompt("BASE", undefined)).toContain("There is no project open");
    expect(buildSystemPrompt("BASE", undefined)).toContain("Set up project");
  });
});

describe("project palette and brief changes", () => {
  const GPL = "GIMP Palette\n#\n  0   0   0\tblack\n255 128  64\torange\n 34  32  52\t\n";

  it("reads palette.gpl and lists its colors in the system prompt", async () => {
    const root = await project({ "palette.gpl": GPL });
    const notes = await readProjectNotes(root);
    expect(notes.palette).toEqual(["#000000", "#ff8040", "#222034"]);
    const prompt = buildSystemPrompt("BASE", { name: "Game", notes });
    expect(prompt).toContain("Project palette (3 colors): #000000 #ff8040 #222034");
    expect((await readProjectNotes(await project())).palette).toEqual([]);
  });

  it("changes a brief field line in place, or adds it when missing", async () => {
    const brief = "# Project brief\n\n- Sprite size: 32x32\n- Light direction: top-left\n\n## Notes\n\n(not set)\n";
    const root = await project({ "brief.md": brief });
    await changeBrief(root, "light", "from the right");
    await changeBrief(root, "outline", "1px dark, never black");
    await changeBrief(root, "notes", "Cozy village mood");
    await changeBrief(root, "notes", "Night scenes use the blue ramp");
    const text = await readFile(join(root, ".artproject", "brief.md"), "utf8");
    expect(text).toContain("- Light direction: from the right");
    expect(text).not.toContain("top-left");
    expect(text).toContain("- Outline style: 1px dark, never black");
    expect(text).toContain("## Notes\n\nCozy village mood\nNight scenes use the blue ramp\n");
    expect(text).not.toContain("(not set)");
  });

  it("describes brief changes for the approval card", () => {
    expect(describeBriefChange("light", "from the right")).toBe('Update the brief: Light direction -> "from the right"');
    expect(describeBriefChange("notes", "Cozy")).toBe('Add to the brief notes: "Cozy"');
  });
});
