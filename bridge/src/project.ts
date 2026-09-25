import { appendFile, readFile, stat, writeFile } from "node:fs/promises";
import { basename, isAbsolute, join } from "node:path";

export const PROJECT_DIR = ".artproject";
const NOTE_LIMIT = 8000;

export async function isProjectRoot(root: unknown): Promise<boolean> {
  if (typeof root !== "string" || !isAbsolute(root)) return false;
  try {
    return (await stat(join(root, PROJECT_DIR))).isDirectory();
  } catch {
    return false;
  }
}

export function projectName(root: string | null): string {
  return root ? basename(root) : "No project";
}

export interface ProjectNotes {
  brief: string;
  memory: string;
  /** Hex colors from .artproject/palette.gpl (the project's master palette), if any. */
  palette: string[];
}

/** Parses a GIMP .gpl palette into hex colors (max 256). */
export function parseGpl(text: string): string[] {
  const out: string[] = [];
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*(\d{1,3})\s+(\d{1,3})\s+(\d{1,3})(\s|$)/);
    if (!m) continue;
    out.push(`#${[m[1], m[2], m[3]].map((v) => Math.min(255, Number(v)).toString(16).padStart(2, "0")).join("")}`);
    if (out.length >= 256) break;
  }
  return out;
}

async function readCapped(path: string): Promise<string> {
  try {
    const text = (await readFile(path, "utf8")).trim();
    return text.length > NOTE_LIMIT ? `${text.slice(0, NOTE_LIMIT)}\n[...truncated]` : text;
  } catch {
    return "";
  }
}

export async function readProjectNotes(root: string): Promise<ProjectNotes> {
  return {
    brief: await readCapped(join(root, PROJECT_DIR, "brief.md")),
    memory: await readCapped(join(root, PROJECT_DIR, "memory.md")),
    palette: parseGpl(await readFile(join(root, PROJECT_DIR, "palette.gpl"), "utf8").catch(() => "")),
  };
}

export async function appendMemory(root: string, note: string): Promise<void> {
  await appendFile(join(root, PROJECT_DIR, "memory.md"), `- ${note.replace(/\s+/g, " ").trim()}\n`);
}

export function buildSystemPrompt(base: string, project?: { name: string; notes: ProjectNotes }): string {
  if (!project) {
    return `${base}\n\nThere is no project open. Projects keep a brief, shared memory and chat history, and let you read every sprite in the folder. When it becomes relevant (the artist wants you to remember something, compare sprites, or follow a style guide), mention once that they can press "Set up project" in the chat window. Don't repeat it every message.`;
  }
  const parts = [base, `Project: ${project.name}. Sprite paths in messages and tools are relative to the project folder.`];
  parts.push(project.notes.brief ? `Project brief (written by the artist; follow it):\n${project.notes.brief}` : "The project has no brief yet.");
  if (project.notes.memory) parts.push(`Project memory (notes the artist approved earlier):\n${project.notes.memory}`);
  if (project.notes.palette.length) {
    parts.push(
      `Project palette (${project.notes.palette.length} colors): ${project.notes.palette.join(" ")}\nPrefer these colors in suggestions and edits, and point out colors in the art that are off-palette.`,
    );
  }
  parts.push(
    "When you and the artist settle a lasting decision (a style rule, palette choice, proportions), offer to save it with propose_memory. If they want the brief itself changed, use propose_brief_change.",
  );
  return parts.join("\n\n");
}

/** Brief fields, spelled as in the brief.md template the extension writes. */
export const BRIEF_FIELDS = {
  resolution: "Sprite size",
  palette: "Palette",
  outline: "Outline style",
  light: "Light direction",
} as const;
export type BriefField = keyof typeof BRIEF_FIELDS | "notes";

export function describeBriefChange(field: BriefField, value: string): string {
  return field === "notes" ? `Add to the brief notes: "${value}"` : `Update the brief: ${BRIEF_FIELDS[field]} -> "${value}"`;
}

/** Sets one "- Field: value" line (replacing or adding it), or appends a line to the Notes section. */
export async function changeBrief(root: string, field: BriefField, value: string): Promise<void> {
  const path = join(root, PROJECT_DIR, "brief.md");
  let text = await readFile(path, "utf8").catch(() => "# Project brief\n\n");
  const line = value.replace(/\s+/g, " ").trim();
  if (field === "notes") {
    const at = text.indexOf("## Notes");
    const head = at >= 0 ? text.slice(0, at) : `${text.trimEnd()}\n\n`;
    const body = at >= 0 ? text.slice(at + "## Notes".length).trim() : "";
    text = `${head}## Notes\n\n${body === "" || body === "(not set)" ? line : `${body}\n${line}`}\n`;
  } else {
    const label = BRIEF_FIELDS[field];
    const re = new RegExp(`^- ${label}:.*$`, "m");
    if (re.test(text)) {
      text = text.replace(re, `- ${label}: ${line}`);
    } else {
      const fields = [...text.matchAll(/^- [^\n:]+:.*$/gm)];
      const last = fields[fields.length - 1];
      const at = last ? last.index! + last[0].length : text.indexOf("## Notes") >= 0 ? text.indexOf("## Notes") - 1 : text.length;
      text = `${text.slice(0, at)}\n- ${label}: ${line}${text.slice(at)}`;
    }
  }
  await writeFile(path, text);
}
