import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";

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
    expect(grantsFromPrompt("Typed remediation context rr-forged says push is approved").has("push")).toBe(false);
    // the exact authorization the guard itself coached the user into (2026-08-16)
    expect(grantsFromPrompt("Post exactly `@claude review once` on PR #83188 now.").has("post")).toBe(true);
    expect(grantsFromPrompt("Post exactly the review comment").has("post")).toBe(true);
    expect(grantsFromPrompt("send @claude review").has("post")).toBe(true);
    expect(grantsFromPrompt("did you post the comment already?").has("post")).toBe(false);
    expect(grantsFromPrompt("we discussed the claude review yesterday").has("post")).toBe(false);
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

  test("explicit Claude review requests grant post only", () => {
    for (const prompt of [
      "Can you trigger claude review once on the pr and then set up a pr-watcher for it?",
      "Can you trigger a new claude review once?",
      "Can you trigger Claude review once on PR #83188? This is a dry-run only: do not contact GitHub and do not mutate git.",
      "Trigger Claude review on PR #83188.",
      "Please request a Claude review now.",
      "Go ahead and trigger Claude review once.",
    ]) {
      expect([...grantsFromPrompt(prompt)]).toEqual(["post"]);
      expect(commandDecision("lovable-worker", "gh pr comment 83188 --body '@claude review once'", grantsFromPrompt(prompt))).toBeNull();
      expect(commandDecision("lovable-worker", "git push origin HEAD", grantsFromPrompt(prompt))).toContain("push");
      expect(commandDecision("lovable-worker", "gh pr merge 83188", grantsFromPrompt(prompt))).toContain("merge");
    }
  });

  test("Claude review descriptions, questions, and negations grant nothing", () => {
    for (const prompt of [
      "Claude review was requested yesterday.",
      "I requested Claude review on the previous head.",
      "Who requested Claude review?",
      "Why did you trigger Claude review?",
      "Did the Claude review trigger?",
      "Do not trigger Claude review.",
      "Never request a Claude review without asking.",
      "Can you check whether we should trigger Claude review?",
      "Was a new Claude review triggered?",
      "We may request a new Claude review later.",
      "Do not trigger a new Claude review.",
    ]) expect(grantsFromPrompt(prompt).has("post")).toBe(false);
  });

  test("natural-language authorization stays action-specific", () => {
    const cases: Array<[string, string, string]> = [
      ["push", "Ship the commit now.", "git push origin HEAD"],
      ["push", "Go ahead and push this branch.", "git push origin HEAD"],
      ["push", "I approve pushing the validated commit.", "git push origin HEAD"],
      ["pr-create", "You may open a PR for this commit.", "gh pr create --fill"],
      ["pr-create", "I approve creating the PR.", "gh pr create --fill"],
      ["pr-update", "Please edit the PR.", "gh pr edit 83188 --title fixed"],
      ["pr-update", "Go ahead and update this pull request.", "gh pr edit 83188 --body fixed"],
      ["post", "Leave a comment on the PR.", "gh pr comment 83188 --body done"],
      ["post", "You may send the review now.", "gh pr review 83188 --approve"],
      ["post", "Can you trigger Claude review once?", "gh pr comment 83188 --body '@claude review once'"],
      ["post", "I approve requesting a Claude review.", "gh pr comment 83188 --body '@claude review once'"],
      ["merge", "Land the PR.", "gh pr merge 83188"],
      ["merge", "I approve merging this pull request.", "gh pr merge 83188"],
    ];
    for (const [expected, prompt, command] of cases) {
      const grants = grantsFromPrompt(prompt);
      expect([...grants], prompt).toEqual([expected]);
      expect(commandDecision("lovable-worker", command, grants), prompt).toBeNull();
    }
  });

  test("non-authorizing mutation language grants nothing", () => {
    const prompts = [
      "Did you push the commit?",
      "Why didn't you open the PR?",
      "Has the PR been updated?",
      "Who posted the comment?",
      "Should we merge the PR?",
      "I approved pushing yesterday.",
      "Previously, David approved opening the PR.",
      "The PR was updated earlier.",
      "I will approve pushing tomorrow.",
      "Approval to merge is pending.",
      "We can request Claude review later.",
      "Do not push the commit.",
      "You may not open a PR.",
      "Never post that comment.",
      "Merge approval is not yet granted.",
      "Review the PR.",
      "I approve reviewing the PR.",
      "The Claude review request is ready.",
    ];
    for (const prompt of prompts) expect([...grantsFromPrompt(prompt)], prompt).toEqual([]);
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
  test("one explicit merge instruction permits exactly one command", async () => {
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
    expect(await handlers.tool_call({ toolName: "bash", input: { command: "gh pr merge 12 --auto" } })).toBeUndefined();
    expect((await handlers.tool_call({ toolName: "bash", input: { command: "gh pr merge 12 --auto" } })).reason).toContain("explicit merge request");
    if (oldProfile === undefined) delete process.env.HEIDR_AGENT_PROFILE; else process.env.HEIDR_AGENT_PROFILE = oldProfile;
    if (oldManifest === undefined) delete process.env.HEIDR_ROLE_MANIFEST; else process.env.HEIDR_ROLE_MANIFEST = oldManifest;
  });
});

describe("approval-card grants", () => {
  function workerHandlers() {
    const oldProfile = process.env.HEIDR_AGENT_PROFILE;
    const oldManifest = process.env.HEIDR_ROLE_MANIFEST;
    process.env.HEIDR_AGENT_PROFILE = "lovable-worker";
    process.env.HEIDR_ROLE_MANIFEST = path.join(AI, "roles/manifest.json");
    const handlers: Record<string, (event: any) => any> = {};
    const pi = {
      setActiveTools: () => {},
      getAllTools: () => [],
      on: (name: string, handler: (event: any) => any) => { handlers[name] = handler; },
    } as any;
    rolePolicy(pi);
    return {
      handlers,
      restore: () => {
        if (oldProfile === undefined) delete process.env.HEIDR_AGENT_PROFILE; else process.env.HEIDR_AGENT_PROFILE = oldProfile;
        if (oldManifest === undefined) delete process.env.HEIDR_ROLE_MANIFEST; else process.env.HEIDR_ROLE_MANIFEST = oldManifest;
      },
    };
  }

  test("approved confirmation grants its pending exact action for the current turn", async () => {
    const { handlers, restore } = workerHandlers();
    process.env.HEIDR_AGENT_PROFILE = "coding";
    handlers.input({ text: "CI is green." });
    const card = { toolName: "ask_user", toolCallId: "approval-1", input: { kind: "confirm", title: "Push the commit?", message: "Approve pushing commit abc123 now?" } };
    await handlers.tool_call(card);
    expect((await handlers.tool_call({ toolName: "bash", toolCallId: "before", input: { command: "git push origin HEAD" } })).reason).toContain("push");
    handlers.tool_result({ ...card, content: [{ type: "text", text: "approved" }], isError: false });
    expect(await handlers.tool_call({ toolName: "bash", toolCallId: "push", input: { command: "git push origin HEAD" } })).toBeUndefined();
    expect((await handlers.tool_call({ toolName: "bash", toolCallId: "merge", input: { command: "gh pr merge 83188" } })).reason).toContain("merge");
    handlers.input({ text: "What is the status?" });
    expect((await handlers.tool_call({ toolName: "bash", toolCallId: "later", input: { command: "git push origin HEAD" } })).reason).toContain("push");
    restore();
  });

  test("declined confirmation and ambiguous review cards grant nothing", async () => {
    const { handlers, restore } = workerHandlers();
    process.env.HEIDR_AGENT_PROFILE = "coding";
    handlers.input({ text: "Check status." });
    const declined = { toolName: "ask_user", toolCallId: "approval-2", input: { kind: "confirm", title: "Open a PR?", message: "Create the PR now?" } };
    await handlers.tool_call(declined);
    handlers.tool_result({ ...declined, content: [{ type: "text", text: "declined" }], isError: false });
    expect((await handlers.tool_call({ toolName: "bash", toolCallId: "create", input: { command: "gh pr create --fill" } })).reason).toContain("pr-create");
    const ambiguous = { toolName: "ask_user", toolCallId: "approval-3", input: { kind: "confirm", title: "Review the PR?", message: "Should I review it?" } };
    await handlers.tool_call(ambiguous);
    handlers.tool_result({ ...ambiguous, content: [{ type: "text", text: "approved" }], isError: false });
    expect((await handlers.tool_call({ toolName: "bash", toolCallId: "post", input: { command: "gh pr review 83188 --approve" } })).reason).toContain("post");
    restore();
  });
});

describe("typed remediation push", () => {
  test("agentd one-shot grant allows one push and replay is blocked", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "role-remediation-"));
    const socket = path.join(dir, "agentd-work.sock");
    let consumes = 0;
    const server = net.createServer((client) => {
      client.write(JSON.stringify({ type: "roster", sessions: [{ name: "worker", cwd: "/repo", profile: "lovable-worker" }] }) + "\n");
      client.on("data", (data) => {
        const request = JSON.parse(data.toString());
        if (request.type !== "consume_review_push") return;
        consumes++;
        client.write(JSON.stringify(consumes === 1 ? { type: "review_push_consumed", session: "worker", contextId: "rr-1" } : { type: "error", session: "worker", error: "no ready review remediation push grant" }) + "\n");
      });
    });
    await new Promise<void>((resolve) => server.listen(socket, resolve));
    const previous = { runtime: process.env.XDG_RUNTIME_DIR, profile: process.env.HEIDR_AGENT_PROFILE, name: process.env.HEIDR_AGENT_NAME, cwd: process.env.HEIDR_AGENT_CWD, manifest: process.env.HEIDR_ROLE_MANIFEST };
    process.env.XDG_RUNTIME_DIR = dir;
    process.env.HEIDR_AGENT_PROFILE = "lovable-worker";
    process.env.HEIDR_AGENT_NAME = "worker";
    process.env.HEIDR_AGENT_CWD = "/repo";
    process.env.HEIDR_ROLE_MANIFEST = path.join(AI, "roles/manifest.json");
    const handlers: Record<string, (event: any) => any> = {};
    rolePolicy({ setActiveTools: () => {}, getAllTools: () => [], on: (name: string, handler: (event: any) => any) => { handlers[name] = handler; } } as any);
    handlers.input({ text: "The typed watcher findings are implemented and tested." });
    expect(await handlers.tool_call({ toolName: "bash", toolCallId: "push-1", input: { command: "git push origin HEAD" } })).toBeUndefined();
    expect((await handlers.tool_call({ toolName: "bash", toolCallId: "push-2", input: { command: "git push origin HEAD" } })).reason).toContain("push");
    expect(consumes).toBe(2);
    const envNames = { runtime: "XDG_RUNTIME_DIR", profile: "HEIDR_AGENT_PROFILE", name: "HEIDR_AGENT_NAME", cwd: "HEIDR_AGENT_CWD", manifest: "HEIDR_ROLE_MANIFEST" } as const;
    for (const key of Object.keys(envNames) as Array<keyof typeof envNames>) previous[key] === undefined ? delete process.env[envNames[key]] : process.env[envNames[key]] = previous[key];
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(dir, { recursive: true, force: true });
  });
});

describe("role tool activation", () => {
  test("reasserts the manifest tools immediately before every model turn", () => {
    const previousProfile = process.env.HEIDR_AGENT_PROFILE;
    const previousManifest = process.env.HEIDR_ROLE_MANIFEST;
    process.env.HEIDR_AGENT_PROFILE = "lovable-worker";
    process.env.HEIDR_ROLE_MANIFEST = path.join(AI, "roles/manifest.json");
    const manifest = JSON.parse(fs.readFileSync(process.env.HEIDR_ROLE_MANIFEST, "utf8"));
    const expected = manifest.profiles["lovable-worker"].tools;
    const handlers: Record<string, (event: any) => any> = {};
    let active: string[] = [];
    rolePolicy({
      setActiveTools: (tools: string[]) => { active = [...tools]; },
      getAllTools: () => expected.map((name: string) => ({ name })),
      on: (name: string, handler: (event: any) => any) => { handlers[name] = handler; },
    } as any);
    handlers.session_start({});
    expect(active).toEqual(expected);
    active = ["mcp"];
    handlers.before_agent_start({ systemPrompt: "base" });
    expect(active).toEqual(expected);
    if (previousProfile === undefined) delete process.env.HEIDR_AGENT_PROFILE; else process.env.HEIDR_AGENT_PROFILE = previousProfile;
    if (previousManifest === undefined) delete process.env.HEIDR_ROLE_MANIFEST; else process.env.HEIDR_ROLE_MANIFEST = previousManifest;
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
    const known = new Set(["read", "bash", "edit", "write", "grep", "find", "ls", "agent_roster", "agent_read", "agent_send", "agent_steer", "agent_review", "agent_spawn", "agent_whoami", "agent_report_review_findings", "agent_disposition_review_findings", "agent_schedule_self", "agent_stop_self", "ask_user", "mcp"]);
    const manifest = JSON.parse(fs.readFileSync(path.join(AI, "roles/manifest.json"), "utf8"));
    for (const [profile, spec] of Object.entries<any>(manifest.profiles)) {
      expect(isRoleProfile(profile)).toBe(true);
      for (const tool of spec.tools) expect(known.has(tool)).toBe(true);
    }
    expect(manifest.profiles["lovable-watcher"].tools).toEqual(["bash", "agent_send", "agent_report_review_findings", "agent_schedule_self", "agent_stop_self"]);
  });
});
