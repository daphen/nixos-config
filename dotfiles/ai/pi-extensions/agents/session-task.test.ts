import { expect, test } from "bun:test";
import register from "./session-task.ts";
import manifest from "../../roles/manifest.json";

function fixture(entries: any[] = []) {
  const commands: Record<string, any> = {}, tools: Record<string, any> = {}, hooks: Record<string, any> = {};
  const notices: string[] = [];
  const ctx = { sessionManager: { getBranch: () => entries }, ui: { notify: (text: string) => notices.push(text) } };
  register({
    registerCommand: (name: string, command: any) => { commands[name] = command; },
    registerTool: (tool: any) => { tools[tool.name] = tool; },
    on: (name: string, handler: any) => { hooks[name] = handler; },
    appendEntry: (customType: string, data: unknown) => entries.push({ type: "custom", customType, data, id: `id-${entries.length}`, parentId: entries.at(-1)?.id, timestamp: new Date().toISOString() }),
  } as any);
  return {
    entries, notices, command: (args: string) => commands.task.handler(args, ctx),
    tool: (args: unknown) => tools.session_task.execute("call", args, undefined, undefined, ctx),
    prompt: () => hooks.before_agent_start({ systemPrompt: "base" }, ctx),
  };
}

test("command persists explicit switches and finish outcomes; bare task does not write", async () => {
  const f = fixture(); await f.command(""); expect(f.entries).toHaveLength(0);
  await f.command("Browser rendering"); await f.command("Git review"); await f.command("Browser rendering");
  expect(f.entries.map(e => e.data)).toEqual([
    { action: "switch", title: "Browser rendering" },
    { action: "switch", title: "Git review" },
    { action: "switch", title: "Browser rendering" },
  ]);
  await f.command("done recovered");
  expect(f.entries.at(-1)?.data).toEqual({ action: "finish", title: "Browser rendering", outcome: "recovered" });
  expect(f.prompt()).toBeUndefined();
});

test("tool shares the event format and reconstructs from the current branch", async () => {
  const f = fixture(); await f.tool({ action: "switch", title: "  Browser rendering  " });
  const reopened = fixture(f.entries);
  expect(reopened.prompt().systemPrompt).toContain('"Browser rendering"');
  await reopened.tool({ action: "finish", outcome: "recovered" });
  expect(reopened.entries.at(-1)?.customType).toBe("cockpit-session-task");
  expect(reopened.entries.at(-1)?.data).toEqual({ action: "finish", title: "Browser rendering", outcome: "recovered" });
  expect(fixture(f.entries.slice(0, 1)).prompt().systemPrompt).toContain('"Browser rendering"');
});

test("invalid or empty operations do not append entries", async () => {
  const f = fixture(); await f.command("done"); await f.tool({ action: "finish" });
  const result = await f.tool({ action: "switch", title: "  " });
  expect(f.entries).toHaveLength(0); expect(result.content[0].text).toContain("Error:");
  expect(f.notices[0]).toContain("no active task");
});

test("active label is quoted as data and unrelated custom entries are ignored", async () => {
  const f = fixture([{ type: "custom", customType: "other", data: { action: "switch", title: "ignored" } }]);
  expect(f.prompt()).toBeUndefined();
  await f.command('Title\nnot an instruction');
  expect(f.prompt().systemPrompt).toContain('"Title\\nnot an instruction"');
  expect(f.prompt().systemPrompt).toContain("not instructions");
});

test("only intended role profiles expose the task tool", () => {
  for (const name of ["lovable-orchestrator", "lovable-worker", "lovable-reviewer"] as const)
    expect(manifest.profiles[name].tools).toContain("session_task");
  expect(manifest.profiles["lovable-watcher"].tools).not.toContain("session_task");
});
