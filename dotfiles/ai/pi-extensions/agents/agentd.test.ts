import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import net from "node:net";
import path from "node:path";
import {
  consumeReviewPush,
  dispositionReviewFindings,
  readRemoteTurns,
  readSessionTurns,
  readTurns,
  reportReviewFindings,
  scheduleSelf,
  spawnMessage,
  stopSelf,
  type Resolved,
} from "./agentd.ts";

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

  test("remote sessions use agentd entries without a local transcript lookup", async () => {
    const resolved: Resolved = {
      session: { name: "every-2741" }, scope: "work", sockPath: "/run/agentd-work.sock",
      cwd: "/home/remote/src/lovable-every-2741",
    };
    let localCalls = 0;
    const result = await readSessionTurns(resolved, 2, {
      local: () => { localCalls++; throw new Error("must not read local session storage"); },
      remote: async () => ({ file: "agentd:get_entries", turns: [{ role: "assistant", text: "b3698679c5c" }] }),
    });
    expect(localCalls).toBe(0);
    expect(result?.turns[0]?.text).toBe("b3698679c5c");
  });

  test("remote read requests get_entries from the resolved agentd socket", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agent-read-socket-"));
    const socket = path.join(dir, "agentd.sock");
    let request: any;
    const server = net.createServer((client) => client.on("data", (data) => {
      request = JSON.parse(data.toString());
      client.write(JSON.stringify({
        type: "response", command: "get_entries", session: "remote",
        data: { entries: [{ message: { role: "assistant", content: "remote answer" } }] },
      }) + "\n");
    }));
    await new Promise<void>((resolve) => server.listen(socket, resolve));
    const result = await readRemoteTurns({
      session: { name: "remote" }, scope: "work", sockPath: socket, cwd: "/home/remote/repo",
    });
    expect(request).toEqual({ type: "get_entries", session: "remote" });
    expect(result?.turns).toEqual([{ role: "assistant", text: "remote answer" }]);
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(dir, { recursive: true, force: true });
  });

  test("local session JSONL reads remain unchanged", () => {
    const cwd = fs.mkdtempSync(path.join(os.homedir(), ".cache/agent-read-local-"));
    const encoded = "--" + cwd.replace(/^\/+|\/+$/g, "").replace(/\//g, "-") + "--";
    const sessionDir = path.join(os.homedir(), ".pi/agent/sessions", encoded);
    fs.mkdirSync(sessionDir, { recursive: true });
    fs.writeFileSync(path.join(sessionDir, "local.jsonl"), [
      JSON.stringify({ message: { role: "user", content: "question" } }),
      JSON.stringify({ message: { role: "assistant", content: [{ type: "text", text: "answer" }] } }),
    ].join("\n"));
    expect(readTurns(cwd, 2)?.turns).toEqual([
      { role: "user", text: "question" }, { role: "assistant", text: "answer" },
    ]);
    fs.rmSync(cwd, { recursive: true, force: true });
    fs.rmSync(sessionDir, { recursive: true, force: true });
  });

  test("typed remediation tools send authenticated structured payloads", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agent-remediation-socket-"));
    const socket = path.join(dir, "agentd-work.sock");
    const requests: any[] = [];
    const server = net.createServer((client) => {
      client.write(JSON.stringify({ type: "roster", sessions: [{ name: "watch", cwd: "/repo", profile: "lovable-watcher" }, { name: "worker", cwd: "/repo", profile: "lovable-worker" }] }) + "\n");
      client.on("data", (data) => {
        const request = JSON.parse(data.toString());
        requests.push(request);
        const type = request.type === "report_review_findings" ? "review_remediation_reported" :
          request.type === "disposition_review_findings" ? "review_remediation_dispositioned" : "review_push_consumed";
        client.write(JSON.stringify({ type, session: request.session, contextId: "ctx-1" }) + "\n");
      });
    });
    await new Promise<void>((resolve) => server.listen(socket, resolve));
    const old = { runtime: process.env.XDG_RUNTIME_DIR, profile: process.env.HEIDR_AGENT_PROFILE, name: process.env.HEIDR_AGENT_NAME, parent: process.env.HEIDR_AGENT_PARENT, cwd: process.env.HEIDR_AGENT_CWD };
    process.env.XDG_RUNTIME_DIR = dir;
    process.env.HEIDR_AGENT_NAME = "watch";
    process.env.HEIDR_AGENT_CWD = "/repo";
    process.env.HEIDR_AGENT_PARENT = "worker";
    process.env.HEIDR_AGENT_PROFILE = "lovable-watcher";
    expect(await reportReviewFindings(12, "feature", "abc", [{ id: "F1", url: "https://example/F1", paths: ["a.ts"] }])).toBe("ctx-1");
    process.env.HEIDR_AGENT_NAME = "worker";
    process.env.HEIDR_AGENT_PROFILE = "lovable-worker";
    await dispositionReviewFindings("ctx-1", "implemented", [{ id: "F1", implemented: true, tested: true }], ["bun test"], ["def"]);
    expect(await consumeReviewPush("git push origin HEAD")).toBe(true);
    expect(requests.map((request) => request.type)).toEqual(["report_review_findings", "disposition_review_findings", "consume_review_push"]);
    expect(requests[0]).toMatchObject({ from: "watch", fromProfile: "lovable-watcher", fromParent: "worker", pr: 12, branch: "feature", head: "abc" });
    expect(requests[1]).toMatchObject({ from: "worker", fromProfile: "lovable-worker", contextId: "ctx-1", outcome: "implemented" });
    for (const [key, value] of Object.entries(old)) value === undefined ? delete process.env[key === "runtime" ? "XDG_RUNTIME_DIR" : key === "profile" ? "HEIDR_AGENT_PROFILE" : key === "name" ? "HEIDR_AGENT_NAME" : key === "parent" ? "HEIDR_AGENT_PARENT" : "HEIDR_AGENT_CWD"] : process.env[key === "runtime" ? "XDG_RUNTIME_DIR" : key === "profile" ? "HEIDR_AGENT_PROFILE" : key === "name" ? "HEIDR_AGENT_NAME" : key === "parent" ? "HEIDR_AGENT_PARENT" : "HEIDR_AGENT_CWD"] = value;
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(dir, { recursive: true, force: true });
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
