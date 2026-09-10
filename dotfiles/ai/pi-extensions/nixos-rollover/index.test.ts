import { expect, test, spyOn } from "bun:test";
import os from "node:os";
import path from "node:path";
import install from "./index.ts";

test("nixos project registers rolling checkpoint and model-window hooks", () => {
  const cwd = spyOn(process, "cwd").mockReturnValue(path.join(os.homedir(), "nixos"));
  try {
    const events: string[] = [];
    install({ on(name: string) { events.push(name); } } as any);
    expect(events.sort()).toEqual(["model_select", "session_before_compact", "session_start"]);
  } finally { cwd.mockRestore(); }
});

test("other projects register no hooks", () => {
  const cwd = spyOn(process, "cwd").mockReturnValue(path.join(os.homedir(), "personal/ai-cockpit"));
  try {
    const events: string[] = [];
    install({ on(name: string) { events.push(name); } } as any);
    expect(events).toEqual([]);
  } finally { cwd.mockRestore(); }
});
