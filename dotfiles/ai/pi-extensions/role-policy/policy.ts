import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const ROLE_PROFILES = [
  "lovable-orchestrator",
  "lovable-worker",
  "lovable-reviewer",
  "lovable-watcher",
] as const;

export type RoleProfile = (typeof ROLE_PROFILES)[number];
export type MutationGrant = "push" | "pr-create" | "pr-update" | "post" | "merge";

export function isRoleProfile(value: string): value is RoleProfile {
  return ROLE_PROFILES.includes(value as RoleProfile);
}

function expandHome(value: string): string {
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return value;
}

export function canonicalPath(value: string, cwd: string): string {
  const absolute = path.resolve(cwd, expandHome(value.replace(/^@/, "")));
  let existing = absolute;
  const suffix: string[] = [];
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break;
    suffix.unshift(path.basename(existing));
    existing = parent;
  }
  let resolved = existing;
  try {
    resolved = fs.realpathSync(existing);
  } catch {}
  return path.join(resolved, ...suffix);
}

function under(candidate: string, root: string): boolean {
  return candidate === root || candidate.startsWith(root + path.sep);
}

export function writeRoots(profile: RoleProfile, cwd: string, home = os.homedir()): string[] {
  const vault = path.join(home, "personal", "notes", "storage");
  switch (profile) {
    case "lovable-orchestrator":
      return [vault];
    case "lovable-reviewer":
      return [path.join(vault, "reviews"), "/tmp"];
    case "lovable-worker":
      return [cwd, path.join(cwd, ".plans"), "/tmp"];
    case "lovable-watcher":
      return [];
  }
}

export function mayWrite(profile: RoleProfile, target: string, cwd: string, home = os.homedir()): boolean {
  const candidate = canonicalPath(target, cwd);
  return writeRoots(profile, cwd, home)
    .map((root) => canonicalPath(root, cwd))
    .some((root) => under(candidate, root));
}

function denied(text: string, phrase: RegExp): boolean {
  const match = phrase.exec(text);
  if (!match || match.index < 0) return false;
  const prefix = text.slice(Math.max(0, match.index - 24), match.index);
  return /(?:do\s+not|don't|dont|never|without|no)\s*$/i.test(prefix);
}

export function grantsFromPrompt(text: string): Set<MutationGrant> {
  const grants = new Set<MutationGrant>();
  const request = String.raw`(?:^\s*|\b(?:please|can you|could you|go ahead and|you may)\s+|\b(?:and|then)\s+)`;
  const patterns: Array<[MutationGrant, RegExp]> = [
    ["push", new RegExp(request + String.raw`(?:git\s+)?push\b`, "im")],
    ["pr-create", new RegExp(request + String.raw`(?:create|open)\s+(?:the\s+|a\s+)?pr\b`, "im")],
    ["pr-update", new RegExp(request + String.raw`update\s+(?:the\s+)?pr\b`, "im")],
    ["post", new RegExp(request + String.raw`post\s+(?:the\s+|a\s+)?(?:comment|review|reply)\b`, "im")],
    ["merge", new RegExp(request + String.raw`merge(?:\s+(?:(?:the\s+)?(?:pr|pull request|branch)|it|this|then))?\b`, "im")],
  ];
  for (const [grant, pattern] of patterns) {
    if (pattern.test(text) && !denied(text, pattern)) grants.add(grant);
  }
  const pushApproval = /^\s*(?:(?:I|David)\s+)?(?:explicitly\s+|hereby\s+)?approve(?:d)?\s+pushing\b[^?\n]*$/im;
  if (pushApproval.test(text)) grants.add("push");
  return grants;
}

export function mutationForCommand(command: string): MutationGrant | null {
  if (/\bgit\b[^;&|\n]*\bpush\b/i.test(command)) return "push";
  if (/\bgh\s+pr\s+create\b/i.test(command)) return "pr-create";
  if (/\bgh\s+pr\s+edit\b/i.test(command)) return "pr-update";
  if (/\bgh\s+pr\s+(?:comment|review)\b/i.test(command)) return "post";
  if (/\bgh\s+pr\s+merge\b/i.test(command) || /\bgit\b[^;&|\n]*\bmerge\b/i.test(command)) return "merge";
  if (/\bgh\s+api\b[^\n]*(?:(?:--method|-X)\s*(?:POST|PUT|PATCH|DELETE)\b|(?:-f|--field|--raw-field|--input)(?:\s|=))/i.test(command)) return "post";
  if (/\bcurl\b(?=[^\n]*(?:api\.github\.com|github\.com\/api))(?=[^\n]*(?:(?:-X|--request)\s*(?:POST|PUT|PATCH|DELETE)\b|(?:-d|--data|--json)(?:\s|=)))[^\n]*/i.test(command)) return "post";
  return null;
}

export function alwaysDestructive(command: string): boolean {
  return /\bgit\b[^;&|\n]*\b(?:reset\s+--hard|clean\s+-\S*f\S*)\b/i.test(command) ||
    /\bgit\b[^;&|\n]*\bbranch\s+-D\b/.test(command) ||
    /\bgit\b[^;&|\n]*\bpush\b[^\n]*(?:--force|-f\b)/i.test(command);
}

export function watcherCommandAllowed(command: string): boolean {
  if (alwaysDestructive(command) || mutationForCommand(command)) return false;
  if (/(?:^|[^|])>{1,2}\s*/.test(command) || /(^|[^&])&([^&]|$)|`|\$\(/.test(command) || /\b(?:rm|mv|cp|install|tee|touch|mkdir|sed\s+-i|perl\s+-i)\b/.test(command)) return false;
  const segments = command.split(/(?:&&|\|\||(?<!\|)\|(?!\|)|;|\n)/).map((part) => part.trim()).filter(Boolean);
  return segments.length > 0 && segments.every((part) =>
    /^(?:timeout\s+\d+\s+)?(?:date\b|printf\b|jq\b|gh\s+pr\s+(?:view|checks|status)\b(?!.*--watch)|gh\s+api\b(?!.*(?:--method|-X|-f\s|--field\s|--raw-field\s))|git\s+(?:status|diff|log|show|rev-parse|ls-files|remote\s+-v|branch\s+--show-current)\b)/.test(part),
  );
}

export function commandDecision(profile: RoleProfile, command: string, grants: Set<MutationGrant>): string | null {
  if (alwaysDestructive(command)) return "destructive or force Git operations are blocked for every role";
  if (profile !== "lovable-worker" && /\bgit\b[^;&|\n]*\bbranch\s+(?:-d|--delete)\b/i.test(command)) {
    return `${profile} may not delete branches`;
  }
  if (profile === "lovable-watcher" && !watcherCommandAllowed(command)) {
    return "lovable-watcher shell is limited to one-shot read-only gh/git inspection; sleeping and polling are blocked";
  }
  if (profile === "lovable-reviewer" && (/(?:^|[;&|\s])(?:sleep|watch|while|until)\b|--watch\b/i.test(command) || /\bfor\b[^\n]*\bgh\s+(?:pr|api)\b/i.test(command))) {
    return "lovable-reviewer must make one attempt and return idle; sleeping and foreground polling are blocked";
  }
  const mutation = mutationForCommand(command);
  if (!mutation) return null;
  if (profile === "lovable-reviewer" && mutation === "merge") {
    return grants.has("merge") ? null : "lovable-reviewer requires an explicit merge request in the current user turn";
  }
  if (profile !== "lovable-worker") return `${profile} may not mutate GitHub or merge`;
  if (!grants.has(mutation)) return `lovable-worker requires an explicit request for this exact ${mutation} action in the current user turn`;
  return null;
}
