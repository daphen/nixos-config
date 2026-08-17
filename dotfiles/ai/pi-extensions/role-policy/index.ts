import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { consumeReviewPush } from "../agents/agentd.ts";
import {
  approvalResultIsApproved,
  commandFromCardText,
  commandDecision,
  grantsFromApprovalCard,
  grantsFromPrompt,
  isRoleProfile,
  mayWrite,
  mutationForCommand,
  type MutationGrant,
  type RoleProfile,
} from "./policy.ts";

type Manifest = {
  schemaVersion: number;
  bundleVersion: string;
  profiles: Record<string, { tools: string[] }>;
};

function manifestPath(): string {
  const configured = process.env.HEIDR_ROLE_MANIFEST;
  if (configured) return configured.replace(/^~(?=\/)/, os.homedir());
  return path.join(os.homedir(), ".pi", "agent", "roles", "manifest.json");
}

function failClosed(pi: ExtensionAPI, reason: string): never {
  pi.setActiveTools([]);
  throw new Error(`Heidr role policy failed closed: ${reason}`);
}

export default function rolePolicy(pi: ExtensionAPI) {
  const rawProfile = process.env.HEIDR_AGENT_PROFILE ?? "";
  // Inert for every NON-ROLE launch: no env at all (plain pi — the extension also
  // loads globally via the dotfiles symlink) and the daemon's builtin non-role
  // profiles ("chat", "coding" — agentd stamps HEIDR_AGENT_PROFILE on every child).
  // Fail closed only when the value claims to be a role and isn't a known one:
  // that's a role launch with a broken contract. Failing closed on the global
  // path crash-looped every plain pi (setActiveTools during load hard-crashes
  // pi >= 0.83) — the newtab outage, twice.
  if (!rawProfile || rawProfile === "chat" || rawProfile === "coding") return;
  if (!isRoleProfile(rawProfile)) failClosed(pi, `unknown HEIDR_AGENT_PROFILE ${JSON.stringify(rawProfile)}`);
  const profile: RoleProfile = rawProfile;
  const cwd = process.env.HEIDR_AGENT_CWD || process.cwd();
  const parent = process.env.HEIDR_AGENT_PARENT || "";

  let manifest: Manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath(), "utf8"));
  } catch (error) {
    failClosed(pi, `cannot load manifest: ${String(error)}`);
  }
  if (manifest.schemaVersion !== 1 || !manifest.bundleVersion) failClosed(pi, "unsupported manifest schema/version");
  const expectedTools = manifest.profiles[profile]?.tools;
  if (!Array.isArray(expectedTools) || expectedTools.length === 0) failClosed(pi, `manifest has no tools for ${profile}`);

  let grants = new Set<MutationGrant>();
  const pendingApprovals = new Map<string, Set<MutationGrant>>();

  const activateExpectedTools = () => {
    const available = new Set(pi.getAllTools().map((tool) => tool.name));
    const missing = expectedTools.filter((name) => !available.has(name));
    if (missing.length > 0) failClosed(pi, `required tools are not registered: ${missing.join(", ")}`);
    pi.setActiveTools(expectedTools);
  };

  pi.on("session_start", activateExpectedTools);

  pi.on("input", (event) => {
    const requested = grantsFromPrompt(event.text);
    grants = profile === "lovable-worker" ? requested :
      profile === "lovable-reviewer" && requested.has("merge") ? new Set<MutationGrant>(["merge"]) : new Set<MutationGrant>();
    return { action: "continue" };
  });

  pi.on("before_agent_start", (event) => {
    activateExpectedTools();
    return {
      systemPrompt: `${event.systemPrompt}\n\n[Heidr role: ${profile} | cwd: ${cwd} | bundle: ${manifest.bundleVersion}]`,
    };
  });

  pi.on("tool_call", async (event) => {
    if (event.toolName === "ask_user" && event.input.kind === "confirm") {
      const cardText = [event.input.title, event.input.message].filter((value) => typeof value === "string").join("\n");
      const cardGrants = grantsFromApprovalCard(cardText);
      // A card that QUOTES a command grants that command's mutation on approval,
      // regardless of how the card is worded — parsing approval prose was the
      // recurring lockout (three deploy-bounce-retype cycles in one day).
      const quoted = commandFromCardText(cardText);
      const quotedMutation = quoted ? mutationForCommand(quoted) : null;
      if (quotedMutation) cardGrants.add(quotedMutation);
      pendingApprovals.set(event.toolCallId, cardGrants);
    }

    if ((event.toolName === "write" || event.toolName === "edit") && typeof event.input.path === "string") {
      if (!mayWrite(profile, event.input.path, cwd)) {
        return { block: true, reason: `${profile} may not write ${event.input.path}` };
      }
    }

    if (profile === "lovable-watcher" && !["bash", "agent_send", "agent_report_review_findings", "agent_schedule_self", "agent_stop_self"].includes(event.toolName)) {
      return { block: true, reason: `lovable-watcher may only inspect once, report to its parent, schedule itself, or stop itself` };
    }
    if (profile === "lovable-watcher" && event.toolName === "agent_send" && (!parent || event.input.agent !== parent)) {
      return { block: true, reason: `lovable-watcher may message only its worker parent ${parent || "(missing)"}` };
    }

    if (event.toolName === "bash" && typeof event.input.command === "string") {
      let reason = commandDecision(profile, event.input.command, grants);
      if (reason && profile === "lovable-worker" && mutationForCommand(event.input.command) === "push") {
        if (await consumeReviewPush(event.input.command)) reason = null;
      }
      if (reason) return { block: true, reason };
      if (profile === "lovable-reviewer" && /\b(?:gh\s+pr|git\b[^;&|\n]*)\s+merge\b/i.test(event.input.command)) grants.delete("merge");
    }

    return undefined;
  });

  pi.on("tool_result", (event) => {
    if (event.toolName !== "ask_user") return undefined;
    const approved = pendingApprovals.get(event.toolCallId);
    pendingApprovals.delete(event.toolCallId);
    if (!event.isError && approved && approvalResultIsApproved(event.content)) {
      for (const grant of approved) grants.add(grant);
    }
    return undefined;
  });
}
