import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import agentsExtension, { buildAgentReviewArgs } from "./index.ts";

describe("agent_read routing", () => {
  test("registered reader uses the requested native transcript and preserves remote paths", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agent-read-public-"));
    const localCwd = fs.mkdtempSync(path.join(os.homedir(), ".cache/agent-read-cwd-"));
    const older = path.join(dir, "older.jsonl");
    const newer = path.join(dir, "newer.jsonl");
    fs.writeFileSync(older, JSON.stringify({ message: { role: "assistant", content: "requested older transcript" } }));
    fs.writeFileSync(newer, JSON.stringify({ message: { role: "assistant", content: "unrelated newer transcript" } }));
    fs.utimesSync(older, new Date(1), new Date(1));
    fs.utimesSync(newer, new Date(), new Date());
    const sessions = [
      { id: "native-old", name: "requested", cwd: localCwd },
      { id: "native-new", name: "unrelated", cwd: localCwd },
      { id: "native-remote", name: "remote", cwd: "/srv/remote/repo" },
    ];
    const requests: any[] = [];
    const socket = path.join(dir, "agentd-test.sock");
    const server = net.createServer((client) => {
      client.write(JSON.stringify({ type: "roster", sessions }) + "\n");
      client.on("data", (data) => {
        const request = JSON.parse(data.toString());
        requests.push(request);
        if (request.type === "get_state") client.write(JSON.stringify({
          type: "response", command: "get_state", session: request.session,
          data: { sessionId: request.session, sessionFile: request.session === "native-old" ? older : newer },
        }) + "\n");
        if (request.type === "get_entries") client.write(JSON.stringify({
          type: "response", command: "get_entries", session: request.session,
          data: { entries: [{ message: { role: "assistant", content: "remote transcript" } }] },
        }) + "\n");
      });
    });
    await new Promise<void>((resolve) => server.listen(socket, resolve));
    const previousRuntime = process.env.XDG_RUNTIME_DIR;
    process.env.XDG_RUNTIME_DIR = dir;
    let reader: any;
    agentsExtension({ registerTool(tool: any) { if (tool.name === "agent_read") reader = tool; } } as any);
    const text = async (agent: string) => (await reader.execute("id", { agent })).content[0].text;
    try {
      const requested = await text("requested");
      expect(requested).toContain("requested older transcript");
      expect(requested).not.toContain("unrelated newer transcript");
      expect(requests[0]).toEqual({ type: "get_state", session: "native-old" });
      expect(await text("native-old")).toContain("requested older transcript");
      expect(await text(localCwd)).toContain("requested older transcript");
      expect(await text("missing-helper-name")).toBe('No agent session matching "missing-helper-name".');
      expect(requests).toHaveLength(3);
      expect(await text("/srv/remote/repo")).toContain("remote transcript");
      expect(requests.at(-1)).toEqual({ type: "get_entries", session: "native-remote" });
    } finally {
      previousRuntime === undefined ? delete process.env.XDG_RUNTIME_DIR : process.env.XDG_RUNTIME_DIR = previousRuntime;
      await new Promise<void>((resolve) => server.close(() => resolve()));
      fs.rmSync(dir, { recursive: true, force: true });
      fs.rmSync(localCwd, { recursive: true, force: true });
    }
  });
});

describe("agent_review runtime contract bridge", () => {
  test("native schema exposes only reusable runtime contracts", () => {
    let review: any;
    agentsExtension({ registerTool(tool: any) { if (tool.name === "agent_review") review = tool; } } as any);
    expect(review.parameters.properties.runtimeContract.enum).toEqual(["production", "exact-branch"]);
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
