import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import rolePolicy from "./index.ts";
import {
  commandDecision,
  grantsFromPrompt,
  isRoleProfile,
  mayWrite,
  mutationForCommand,
  watcherCommandAllowed,
} from "./policy.ts";

const AI = path.resolve(import.meta.dir, "../..");

describe("path policy", () => {
  test("worker stays in its canonical worktree and cannot escape through a symlink", () => {
    const root = fs.mkdtempSync(path.join(os.homedir(), ".cache/heidr-policy-"));
    const cwd = path.join(root, "worktree");
    const outside = path.join(root, "outside");
    fs.mkdirSync(cwd); fs.mkdirSync(outside);
    fs.symlinkSync(outside, path.join(cwd, "escape"));
    expect(mayWrite("lovable-worker", path.join(cwd, "src/new.ts"), cwd, root)).toBe(true);
    expect(mayWrite("lovable-worker", path.join(cwd, "escape/new.ts"), cwd, root)).toBe(false);
    expect(mayWrite("lovable-worker", path.join(outside, "new.ts"), cwd, root)).toBe(false);
    fs.rmSync(root, { recursive: true, force: true });
  });

  test("orchestrator and reviewer only write their artifact roots", () => {
    const home = fs.mkdtempSync(path.join(os.homedir(), ".cache/heidr-home-"));
    const vault = path.join(home, "personal/notes/storage");
    fs.mkdirSync(path.join(vault, "reviews"), { recursive: true });
    expect(mayWrite("lovable-orchestrator", path.join(vault, "plans/x.md"), "/repo", home)).toBe(true);
    expect(mayWrite("lovable-orchestrator", "/repo/src/x.ts", "/repo", home)).toBe(false);
    expect(mayWrite("lovable-reviewer", path.join(vault, "reviews/pr-1.md"), "/repo", home)).toBe(true);
    expect(mayWrite("lovable-reviewer", path.join(vault, "plans/x.md"), "/repo", home)).toBe(false);
    expect(mayWrite("lovable-watcher", "/tmp/x", "/repo", home)).toBe(false);
    fs.rmSync(home, { recursive: true, force: true });
  });
});

describe("GitHub mutation delegation", () => {
  test("classifies each exact mutation", () => {
    expect(mutationForCommand("git push origin HEAD")).toBe("push");
    expect(mutationForCommand("gh pr create --fill")).toBe("pr-create");
    expect(mutationForCommand("gh pr edit 1 --title x")).toBe("pr-update");
    expect(mutationForCommand("gh pr comment 1 -b ok")).toBe("post");
    expect(mutationForCommand("gh pr merge 1")).toBe("merge");
  });

  test("worker permission is current-turn and action-specific", () => {
    expect(commandDecision("lovable-worker", "git push", grantsFromPrompt("CI is green"))).toContain("explicit request");
    expect(commandDecision("lovable-worker", "git push", grantsFromPrompt("Please push this branch"))).toBeNull();
    expect(commandDecision("lovable-worker", "gh pr merge 1", grantsFromPrompt("Please push this branch"))).toContain("merge");
    expect(grantsFromPrompt("Do not push").has("push")).toBe(false);
    expect(grantsFromPrompt("Why didn't you push?").has("push")).toBe(false);
  });

  test("explicit approval wording grants push only", () => {
    const prompts = [
      "David explicitly approved pushing the completed export-contract fix b3698679c5c to PR #83188 now.",
      "Approve pushing this commit now.",
      "I approve pushing b3698679c5c.",
      "Approved pushing the validated commit.",
    ];
    for (const prompt of prompts) {
      expect([...grantsFromPrompt(prompt)]).toEqual(["push"]);
      expect(commandDecision("lovable-worker", "git push origin HEAD", grantsFromPrompt(prompt))).toBeNull();
      expect(commandDecision("lovable-worker", "gh pr merge 83188", grantsFromPrompt(prompt))).toContain("merge");
    }
  });

  test("descriptive or non-authorizing push mentions grant nothing", () => {
    for (const prompt of [
      "Did David approve pushing this commit?",
      "David approved pushing this commit?",
      "Who approved pushing this commit?",
      "We discussed whether to approve pushing after CI.",
      "The previous push was approved yesterday.",
      "Approval for pushing is still pending.",
      "I have not approved pushing this commit.",
    ]) expect(grantsFromPrompt(prompt).has("push")).toBe(false);
  });

  test("reviewer gets one explicitly requested merge attempt without polling", () => {
    expect(commandDecision("lovable-reviewer", "gh pr merge 12 --auto", grantsFromPrompt("Merge then"))).toBeNull();
    expect(commandDecision("lovable-reviewer", "gh pr merge 12 --auto", new Set())).toContain("explicit merge request");
    expect(commandDecision("lovable-reviewer", "gh pr checks 12 --watch", new Set())).toContain("foreground polling");
    expect(commandDecision("lovable-reviewer", "sleep 30", new Set())).toContain("foreground polling");
  });

  test("other roles cannot push and force operations are always blocked", () => {
    for (const role of ["lovable-orchestrator", "lovable-reviewer", "lovable-watcher"] as const) {
      expect(commandDecision(role, "git push", new Set(["push"]))).not.toBeNull();
    }
    expect(commandDecision("lovable-worker", "git push --force", new Set(["push"]))).toContain("destructive");
    expect(commandDecision("lovable-reviewer", "git branch -d old", new Set())).not.toBeNull();
  });
});

describe("reviewer attempt consumption", () => {
  test("one explicit merge instruction permits exactly one command", () => {
    const oldProfile = process.env.HEIDR_AGENT_PROFILE;
    const oldManifest = process.env.HEIDR_ROLE_MANIFEST;
    process.env.HEIDR_AGENT_PROFILE = "lovable-reviewer";
    process.env.HEIDR_ROLE_MANIFEST = path.join(AI, "roles/manifest.json");
    const handlers: Record<string, (event: any) => any> = {};
    const pi = {
      setActiveTools: () => {},
      getAllTools: () => [],
      on: (name: string, handler: (event: any) => any) => { handlers[name] = handler; },
    } as any;
    rolePolicy(pi);
    handlers.input({ text: "Merge the PR" });
    expect(handlers.tool_call({ toolName: "bash", input: { command: "gh pr merge 12 --auto" } })).toBeUndefined();
    expect(handlers.tool_call({ toolName: "bash", input: { command: "gh pr merge 12 --auto" } }).reason).toContain("explicit merge request");
    if (oldProfile === undefined) delete process.env.HEIDR_AGENT_PROFILE; else process.env.HEIDR_AGENT_PROFILE = oldProfile;
    if (oldManifest === undefined) delete process.env.HEIDR_ROLE_MANIFEST; else process.env.HEIDR_ROLE_MANIFEST = oldManifest;
  });
});

describe("global extension containment", () => {
  test("non-role launches are inert and unknown role claims fail closed", () => {
    const previous = process.env.HEIDR_AGENT_PROFILE;
    let active: string[] = ["bash"];
    const pi = { setActiveTools: (tools: string[]) => { active = tools; } } as any;
    for (const profile of [undefined, "chat", "coding"]) {
      if (profile === undefined) delete process.env.HEIDR_AGENT_PROFILE;
      else process.env.HEIDR_AGENT_PROFILE = profile;
      expect(() => rolePolicy(pi)).not.toThrow();
      expect(active).toEqual(["bash"]);
    }
    process.env.HEIDR_AGENT_PROFILE = "unknown-role";
    expect(() => rolePolicy(pi)).toThrow("failed closed");
    expect(active).toEqual([]);
    if (previous === undefined) delete process.env.HEIDR_AGENT_PROFILE;
    else process.env.HEIDR_AGENT_PROFILE = previous;
  });
});

describe("watcher containment and manifest", () => {
  test("watcher shell permits one inspection but never waiting", () => {
    expect(watcherCommandAllowed("gh pr view 12 --json state | jq .state")).toBe(true);
    expect(watcherCommandAllowed("git status && sleep 300")).toBe(false);
    expect(watcherCommandAllowed("gh pr checks 12 --watch")).toBe(false);
    expect(watcherCommandAllowed("gh pr view 12 &")).toBe(false);
    expect(watcherCommandAllowed("gh pr comment 12 -b hi")).toBe(false);
    expect(watcherCommandAllowed("touch finding.txt")).toBe(false);
  });

  test("manifest tools are locked to names inventoried from pi.getAllTools", () => {
    const known = new Set(["read", "bash", "edit", "write", "grep", "find", "ls", "agent_roster", "agent_read", "agent_send", "agent_steer", "agent_review", "agent_spawn", "agent_whoami", "agent_schedule_self", "agent_stop_self", "ask_user", "mcp"]);
    const manifest = JSON.parse(fs.readFileSync(path.join(AI, "roles/manifest.json"), "utf8"));
    for (const [profile, spec] of Object.entries<any>(manifest.profiles)) {
      expect(isRoleProfile(profile)).toBe(true);
      for (const tool of spec.tools) expect(known.has(tool)).toBe(true);
    }
    expect(manifest.profiles["lovable-watcher"].tools).toEqual(["bash", "agent_send", "agent_schedule_self", "agent_stop_self"]);
  });
});
