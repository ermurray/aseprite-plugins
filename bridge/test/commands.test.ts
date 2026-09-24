import { describe, expect, it } from "vitest";
import { ALLOWED_COMMANDS, parseCommand } from "../src/commands.js";

describe("parseCommand", () => {
  it("recognises slash commands and their arguments", () => {
    expect(parseCommand("/compact")).toEqual({ name: "compact", raw: "/compact" });
    expect(parseCommand("  /model sonnet ")).toEqual({ name: "model", raw: "/model sonnet" });
    expect(parseCommand("make the /sky warmer")).toBeUndefined();
    expect(parseCommand("/")).toBeUndefined();
  });
  it("does not mistake paths for commands, and normalises the command name", () => {
    expect(parseCommand("/path/file looks wrong?")).toBeUndefined();
    expect(parseCommand("/usr/local is where it lives")).toBeUndefined();
    expect(parseCommand("/Model Sonnet")).toEqual({ name: "model", raw: "/model Sonnet" });
  });
  it("allows only commands that make sense inside Aseprite", () => {
    expect([...ALLOWED_COMMANDS].sort()).toEqual(["compact", "context", "effort", "model", "recap", "usage"]);
  });
});
