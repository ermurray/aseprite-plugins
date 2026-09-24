import type { ToolHost } from "../toolTypes.js";

export type AdapterEvent = { type: "text_delta"; text: string } | { type: "error"; message: string; hint?: string };

export type ResumeState = Record<string, unknown>;

export interface Adapter {
  readonly name: string;
  /** Runs one user turn, yielding events until the agent has finished replying. */
  send(text: string): AsyncIterable<AdapterEvent>;
  cancel(): void;
  resumeState(): ResumeState | undefined;
}

export interface AdapterContext {
  tools: ToolHost;
  systemPrompt: string;
  resume?: ResumeState;
}

export type AdapterFactory = (ctx: AdapterContext) => Adapter;
