import { appendFile, readFile, stat } from "node:fs/promises";
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
  };
}

export async function appendMemory(root: string, note: string): Promise<void> {
  await appendFile(join(root, PROJECT_DIR, "memory.md"), `- ${note.replace(/\s+/g, " ").trim()}\n`);
}

export function buildSystemPrompt(base: string, project?: { name: string; notes: ProjectNotes }): string {
  if (!project) {
    return `${base}\n\nThere is no project open. The artist can create one with "Make project" in the chat window; projects keep a brief, shared memory and chat history.`;
  }
  const parts = [base, `Project: ${project.name}. Sprite paths in messages and tools are relative to the project folder.`];
  parts.push(project.notes.brief ? `Project brief (written by the artist; follow it):\n${project.notes.brief}` : "The project has no brief yet.");
  if (project.notes.memory) parts.push(`Project memory (notes the artist approved earlier):\n${project.notes.memory}`);
  parts.push("When you and the artist settle a lasting decision (a style rule, palette choice, proportions), offer to save it with propose_memory.");
  return parts.join("\n\n");
}
