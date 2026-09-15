import { describe, expect, test } from "bun:test";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import agentsExtension, { buildAgentReviewArgs } from "./index.ts";

test("registered agent_spawn forwards explicit models and preserves default and lineage semantics", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "spawn-model-"));
  const previous = { runtime: process.env.XDG_RUNTIME_DIR, name: process.env.COCKPIT_AGENT_NAME };
  const received: any[] = [];
  const sockets = new Set<net.Socket>();
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.write(JSON.stringify({ type: "roster", sessions: [] }) + "\n");
    let buffer = "";
    socket.on("data", chunk => {
      buffer += chunk;
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        received.push(JSON.parse(buffer.slice(0, newline)));
        buffer = buffer.slice(newline + 1);
      }
    });
  });
  await new Promise<void>(resolve => server.listen(path.join(dir, "agentd-test.sock"), resolve));
  try {
    process.env.XDG_RUNTIME_DIR = dir;
    process.env.COCKPIT_AGENT_NAME = "parent";
    let tool: any;
    agentsExtension({ registerTool(value: any) { if (value.name === "agent_spawn") tool = value; }, registerCommand() {}, on() {} } as any);
    expect(tool.parameters.properties.model).toBeDefined();
    for (const model of ["openai/gpt-6-astra", "openai/gpt-5.6-sol", undefined]) {
      const result = await tool.execute("call", { dir, name: "astra-name-is-not-configuration", scope: "test", profile: "coding", prompt: "do the task", model });
      const message = received.at(-1);
      expect(message).toMatchObject({ type: "spawn", session: "astra-name-is-not-configuration", cwd: dir, profile: "coding", from: "parent", prompt: "do the task" });
      if (model) expect(message.model).toBe(model);
      else expect(message).not.toHaveProperty("model");
      expect(result.content[0].text).toContain(model ?? "profile/daemon default");
      expect(result.content[0].text).toContain("runtime not yet verified");
    }
    const cli = path.resolve(import.meta.dirname, "../../../bin/.local/bin/agent");
    const child = Bun.spawn(["python3", cli, "spawn", dir, "--scope", "test", "--name", "cli-model", "--model", "openai/gpt-6-astra"], { env: process.env, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited, await new Response(child.stderr).text()).toBe(0);
    expect(received.at(-1)).toMatchObject({ type: "spawn", session: "cli-model", model: "openai/gpt-6-astra" });
    const before = received.length;
    const invalid = Bun.spawn(["python3", cli, "spawn", dir, "--scope", "test", "--model", ""], { env: process.env, stdout: "pipe", stderr: "pipe" });
    expect(await invalid.exited).toBe(1);
    expect(received).toHaveLength(before);
  } finally {
    if (previous.runtime === undefined) delete process.env.XDG_RUNTIME_DIR; else process.env.XDG_RUNTIME_DIR = previous.runtime;
    if (previous.name === undefined) delete process.env.COCKPIT_AGENT_NAME; else process.env.COCKPIT_AGENT_NAME = previous.name;
    for (const socket of sockets) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe("agent_review runtime contract bridge", () => {
  test("native schema exposes only reusable runtime contracts", () => {
    let review: any;
    agentsExtension({
      registerTool(tool: any) { if (tool.name === "agent_review") review = tool; },
      registerCommand() {},
      on() {},
    } as any);
    expect(review.parameters.properties.runtimeContract.enum).toEqual(["production", "exact-branch"]);
  });

  test("agent_whoami uses the launch identity instead of an ambiguous cwd", async () => {
    let whoami: any;
    agentsExtension({
      registerTool(tool: any) { if (tool.name === "agent_whoami") whoami = tool; },
      registerCommand() {},
      on() {},
    } as any);
    const previous = process.env.COCKPIT_AGENT_NAME;
    process.env.COCKPIT_AGENT_NAME = "exact-session-that-does-not-exist";
    const result = await whoami.execute();
    if (previous === undefined) delete process.env.COCKPIT_AGENT_NAME;
    else process.env.COCKPIT_AGENT_NAME = previous;
    expect(result.content[0].text).toContain("identity exact-session-that-does-not-exist");
    expect(result.content[0].text).not.toContain("ambiguous session path");
  });

  test("forwards exact-branch runtime contract to the canonical launcher", () => {
    expect(buildAgentReviewArgs({
      pr: "83188",
      manualTestProject: "project-id",
      browserProfileSeed: "/tmp/stopped-profile",
      runtimeContract: "exact-branch",
      allowSandboxStart: true,
    })).toEqual({ args: [
      "review", "83188",
      "--manual-test", "project-id",
      "--browser-profile-seed", "/tmp/stopped-profile",
      "--runtime-contract", "exact-branch",
      "--allow-sandbox-start",
    ] });
  });

  test("forwards explicit production and rejects missing or orphan contracts", () => {
    expect(buildAgentReviewArgs({ pr: "1", manualTestProject: "project", runtimeContract: "production" })).toEqual({
      args: ["review", "1", "--manual-test", "project", "--runtime-contract", "production"],
    });
    expect(buildAgentReviewArgs({ pr: "1", manualTestProject: "project" }).error).toContain("requires runtimeContract");
    expect(buildAgentReviewArgs({ pr: "1", runtimeContract: "exact-branch" }).error).toContain("requires manualTestProject");
    expect(buildAgentReviewArgs({ teardownContext: "pr-1", runtimeContract: "production" }).error).toContain("mutually exclusive");
  });
});
