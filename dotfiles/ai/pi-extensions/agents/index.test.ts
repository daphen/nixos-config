import { describe, expect, test } from "bun:test";
import agentsExtension, { buildAgentReviewArgs } from "./index.ts";

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
