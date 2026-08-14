import { describe, expect, test } from "bun:test";
import { scheduleSelf, spawnMessage, stopSelf } from "./agentd.ts";

describe("spawn profile payload", () => {
  test("generic child omits profile for server-side inheritance", () => {
    expect(spawnMessage("child", "/repo", { prompt: "audit" }, "worker")).toEqual({
      type: "spawn", session: "child", cwd: "/repo", prompt: "audit", from: "worker",
    });
  });

  test("watcher requests the one allowed role transition", () => {
    expect(spawnMessage("watch-pr-12", "/repo", { profile: "lovable-watcher" }, "worker")).toEqual({
      type: "spawn", session: "watch-pr-12", cwd: "/repo", profile: "lovable-watcher", from: "worker",
    });
  });

  test("self-timer helpers reject every non-watcher profile before socket access", async () => {
    const previous = process.env.HEIDR_AGENT_PROFILE;
    process.env.HEIDR_AGENT_PROFILE = "lovable-reviewer";
    await expect(scheduleSelf()).rejects.toThrow("watcher-only");
    await expect(stopSelf()).rejects.toThrow("watcher-only");
    if (previous === undefined) delete process.env.HEIDR_AGENT_PROFILE;
    else process.env.HEIDR_AGENT_PROFILE = previous;
  });
});
