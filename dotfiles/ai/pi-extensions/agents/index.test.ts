import { describe, expect, test } from "bun:test";
import agentsExtension, { buildAgentReviewArgs } from "./index.ts";

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
