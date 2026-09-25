import { describe, expect, it } from "vitest";
import { StoreRegistry } from "../src/stores.js";

describe("StoreRegistry", () => {
  it("returns one shared store per project, and the global store for no project", () => {
    const r = new StoreRegistry("/home/.aseprite-agent/chats");
    expect(r.get("/art/game")).toBe(r.get("/art/game"));
    expect(r.get(null)).toBe(r.get(null));
    expect(r.get("/art/game")).not.toBe(r.get(null));
    expect((r.get("/art/game") as any).dir).toBe("/art/game/.artproject/chats");
    expect((r.get(null) as any).dir).toBe("/home/.aseprite-agent/chats");
  });
});
