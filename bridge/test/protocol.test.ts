import { describe, expect, it } from "vitest";
import { parseExtensionMessage } from "../src/protocol.js";

describe("parseExtensionMessage", () => {
  it("accepts hello", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "hello", token: "t", extensionVersion: "0.1.0" }));
    expect(r).toEqual({ ok: true, message: { type: "hello", token: "t", extensionVersion: "0.1.0" } });
  });

  it("accepts tool_result with arbitrary data", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "tool_result", callId: "c1", ok: true, data: { w: 8 } }));
    expect(r.ok).toBe(true);
  });

  it("accepts tool_result data encoded by Lua as an empty array", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "tool_result", callId: "c1", ok: true, data: [] }));
    expect(r.ok).toBe(true);
  });

  it("rejects invalid JSON", () => {
    expect(parseExtensionMessage("{nope")).toEqual({ ok: false, error: "invalid JSON" });
  });

  it("rejects unknown types", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "launch_missiles" }));
    expect(r.ok).toBe(false);
  });

  it("rejects empty user messages", () => {
    const r = parseExtensionMessage(JSON.stringify({ type: "user_message", text: "" }));
    expect(r.ok).toBe(false);
  });
});
