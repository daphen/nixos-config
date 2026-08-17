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

type ActionLanguage = {
  direct: string;
  approved: string;
};

const ACTION_LANGUAGE: Record<MutationGrant, ActionLanguage> = {
  push: {
    direct: String.raw`(?:(?:git\s+)?push|ship)(?:\s+(?:(?:the|this|that)\s+)?(?:commit|branch|changes|head)|\s+it)?\b`,
    approved: String.raw`(?:(?:git\s+)?push(?:ing)?|ship(?:ping)?)(?:\s+(?:(?:the|this|that)\s+)?(?:commit|branch|changes|head)|\s+it)?\b`,
  },
  "pr-create": {
    direct: String.raw`(?:create|open)\s+(?:(?:the|a|this)\s+)?(?:pr|pull request)\b`,
    approved: String.raw`(?:creat(?:e|ing)|open(?:ing)?)\s+(?:(?:the|a|this)\s+)?(?:pr|pull request)\b`,
  },
  "pr-update": {
    direct: String.raw`(?:update|edit)\s+(?:(?:the|this)\s+)?(?:pr|pull request)\b`,
    approved: String.raw`(?:updat(?:e|ing)|edit(?:ing)?)\s+(?:(?:the|this)\s+)?(?:pr|pull request)\b`,
  },
  post: {
    direct: String.raw`(?:(?:post|send|leave|add)\s+(?:\S+\s+){0,3}?(?:comment|review|reply)\b|(?:trigger|request)\s+(?:a\s+)?(?:new\s+)?claude\s+review\b)`,
    approved: String.raw`(?:(?:post(?:ing)?|send(?:ing)?|leave|leaving|add(?:ing)?)\s+(?:\S+\s+){0,3}?(?:comment|review|reply)\b|(?:trigger(?:ing)?|request(?:ing)?)\s+(?:a\s+)?(?:new\s+)?claude\s+review\b)`,
  },
  merge: {
    direct: String.raw`(?:merge|land)(?:\s+(?:(?:the|this|that)\s+)?(?:pr|pull request|branch|commit)|\s+it)?\b`,
    approved: String.raw`(?:merg(?:e|ing)|land(?:ing)?)(?:\s+(?:(?:the|this|that)\s+)?(?:pr|pull request|branch|commit)|\s+it)?\b`,
  },
};

function lineAuthorizes(line: string, language: ActionLanguage, approvalCard: boolean): boolean {
  const trimmed = line.trim();
  if (!trimmed) return false;
  const politeQuestion = /^(?:can|could|would|will)\s+you\b/i.test(trimmed);
  if (trimmed.includes("?") && !approvalCard && !politeQuestion) return false;

  const direct = language.direct;
  const approved = language.approved;
  const patterns = [
    new RegExp(String.raw`^\s*(?:please\s+)?${direct}`, "i"),
    new RegExp(String.raw`^\s*(?:can|could|would|will)\s+you\s+(?:please\s+)?${direct}`, "i"),
    new RegExp(String.raw`^\s*(?:go\s+ahead(?:\s+and)?|you\s+may|feel\s+free\s+to)\s+${direct}`, "i"),
    new RegExp(String.raw`^\s*(?:(?:i|david)\s+)?(?:explicitly\s+|hereby\s+)?approve(?:s|d)?\s+(?:you\s+)?(?:\S+\s+){0,4}?${approved}`, "i"),
    new RegExp(String.raw`\b(?:and|then)\s+(?:please\s+)?${direct}`, "i"),
  ];
  return patterns.some((pattern) => {
    const match = pattern.exec(trimmed);
    if (!match) return false;
    const suffix = trimmed.slice(match.index + match[0].length).split(/[.!?;]/, 1)[0];
    if (/^\s+(?:approval|permission|request|status)\b/i.test(suffix)) return false;
    return !/\b(?:yesterday|previously|earlier|already|pending|later|tomorrow|last\s+(?:turn|time|week))\b/i.test(suffix);
  });
}

// An approval that names the literal command ("approves executing this exact
// command now: git merge --no-ff origin/main ...") grants exactly that
// command's mutation. The verb-phrase grammar can never enumerate every way a
// human phrases approval, but a spelled-out command is unambiguous.
const INLINE_COMMAND_APPROVAL = /(approv\w+|authoriz\w+|go\s+ahead)([^.!?;:]{0,120})[:\u2014-]\s*[`"']?((?:git|gh)\s[^!?\n`]+)/i;

function inlineCommandGrant(line: string, approvalCard: boolean): MutationGrant | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  if (trimmed.includes("?") && !approvalCard) return null;
  const m = INLINE_COMMAND_APPROVAL.exec(trimmed);
  if (!m) return null;
  // "does not authorize: git push" must never grant.
  if (/(?:\bnot\b|\bnever\b|n't\b|\bwithout\b)/i.test(trimmed.slice(0, m.index + m[1].length + m[2].length))) return null;
  return mutationForCommand(m[3]);
}

function grantsFromLanguage(text: string, approvalCard: boolean): Set<MutationGrant> {
  const grants = new Set<MutationGrant>();
  const lines = text.split(/\r?\n/);
  for (const grant of Object.keys(ACTION_LANGUAGE) as MutationGrant[]) {
    if (lines.some((line) => lineAuthorizes(line, ACTION_LANGUAGE[grant], approvalCard))) grants.add(grant);
  }
  for (const line of lines) {
    const g = inlineCommandGrant(line, approvalCard);
    if (g) grants.add(g);
  }
  return grants;
}

export function grantsFromPrompt(text: string): Set<MutationGrant> {
  return grantsFromLanguage(text, false);
}

export function grantsFromApprovalCard(text: string): Set<MutationGrant> {
  return grantsFromLanguage(text, true);
}

export function approvalResultIsApproved(content: unknown): boolean {
  if (!Array.isArray(content)) return false;
  const text = content
    .filter((item): item is { type: string; text: string } => typeof item === "object" && item !== null && "type" in item && "text" in item)
    .filter((item) => item.type === "text")
    .map((item) => item.text)
    .join("\n")
    .trim();
  return /^approved$/i.test(text);
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
