// Pure-node client for the agentd socket(s). No pi imports — so the CLI could
// import it too, and so it stays testable. agentd runs one daemon per scope
// ($XDG_RUNTIME_DIR/agentd-<scope>.sock) and greets every new connection with a
// {type:"roster", sessions:[...]} line; prompt/spawn are fire-and-forget writes.
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export interface Session {
  id?: string;
  name?: string;
  cwd?: string;
  status?: string;
  scope?: string;
  profile?: string;
}

const HOME = os.homedir();

function runtimeDir(): string {
  return process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid?.() ?? 1000}`;
}

function scopeSocks(): Array<{ scope: string; path: string }> {
  const rt = runtimeDir();
  let entries: string[] = [];
  try {
    entries = fs.readdirSync(rt);
  } catch {
    return [];
  }
  return entries
    .filter((f) => /^agentd-.+\.sock$/.test(f))
    .map((f) => ({ scope: f.slice("agentd-".length, -".sock".length), path: path.join(rt, f) }));
}

function expandPath(p: string): string | null {
  if (!p) return null;
  let abs = p.startsWith("~") ? path.join(HOME, p.slice(1)) : p;
  try {
    return fs.realpathSync(abs);
  } catch {
    return path.resolve(abs);
  }
}

function readRoster(sockPath: string, timeoutMs = 2000): Promise<Session[]> {
  return new Promise((resolve) => {
    const c = net.connect(sockPath);
    let buf = "";
    let done = false;
    const finish = (v: Session[]) => {
      if (done) return;
      done = true;
      try {
        c.destroy();
      } catch {}
      resolve(v);
    };
    const timer = setTimeout(() => finish([]), timeoutMs);
    c.on("data", (chunk: Buffer) => {
      buf += chunk.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        let obj: any;
        try {
          obj = JSON.parse(line);
        } catch {
          continue;
        }
        if (obj?.type === "roster") {
          clearTimeout(timer);
          finish(Array.isArray(obj.sessions) ? obj.sessions : []);
          return;
        }
      }
    });
    c.on("error", () => {
      clearTimeout(timer);
      finish([]);
    });
    c.on("close", () => {
      clearTimeout(timer);
      finish([]);
    });
  });
}

export async function allSessions(): Promise<Session[]> {
  const out: Session[] = [];
  for (const s of scopeSocks()) {
    for (const sess of await readRoster(s.path)) out.push({ ...sess, scope: s.scope });
  }
  return out;
}

export interface Resolved {
  session: Session;
  scope: string;
  sockPath: string;
  cwd: string;
}

// Match a free-form ref against every scope's roster. Exact id/name wins; then a
// cwd-path relationship; then a substring on name/cwd or an id prefix.
export async function resolveSession(ref: string): Promise<Resolved | null> {
  const abs = expandPath(ref);
  let byCwd: Resolved | null = null;
  let bySub: Resolved | null = null;
  for (const s of scopeSocks()) {
    for (const sess of await readRoster(s.path)) {
      const id = String(sess.id ?? "");
      const name = String(sess.name ?? "");
      const cwd = String(sess.cwd ?? "");
      const r: Resolved = { session: { ...sess, scope: s.scope }, scope: s.scope, sockPath: s.path, cwd };
      if (id === ref || name === ref) return r;
      if (!byCwd && abs && cwd && (cwd === abs || abs.startsWith(cwd + "/") || cwd.startsWith(abs + "/"))) byCwd = r;
      if (!bySub && ((name && name.includes(ref)) || (cwd && cwd.includes(ref)) || (id && id.startsWith(ref)))) bySub = r;
    }
  }
  return byCwd ?? bySub;
}

// This agent's OWN session name, resolved from its cwd. Stamped as `from` on
// spawn/prompt/steer so agentd can gate agent→agent messaging by spawn lineage
// (see registry.isLineage). Empty when the caller isn't a registered session
// (then agentd treats it as human and doesn't gate).
async function selfName(): Promise<string> {
  if (process.env.HEIDR_AGENT_NAME) return process.env.HEIDR_AGENT_NAME;
  try {
    const s = await resolveSession(process.cwd());
    return s ? String(s.session.name ?? s.session.id ?? "") : "";
  } catch {
    return "";
  }
}

// Write one command, then LISTEN for the daemon's verdict before dropping the socket.
// agentd answers a refused or failed delivery with an {type:"error"} event on this same
// connection; the old fire-and-forget version discarded it unread, which is how a
// lineage-refused agent_send got reported as "Delivered" — twice, to the user's face.
// Silence within the window means the daemon forwarded the line to pi.
function writeThenClose(sockPath: string, obj: { session?: unknown } & Record<string, unknown>, flushMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const c = net.connect(sockPath);
    let buf = "";
    let done = false;
    const finish = (err?: Error) => {
      if (done) return;
      done = true;
      try {
        c.destroy();
      } catch {}
      if (err) reject(err);
      else resolve();
    };
    c.on("connect", () => {
      c.write(JSON.stringify(obj) + "\n", () => {
        setTimeout(() => finish(), flushMs);
      });
    });
    c.on("data", (d) => {
      buf += d.toString();
      let i: number;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        try {
          const m = JSON.parse(line);
          if (m && m.type === "error" && (!m.session || m.session === obj.session)) {
            finish(new Error(`agentd refused: ${m.error ?? "unknown error"}`));
            return;
          }
        } catch {}
      }
    });
    c.on("error", (e) => finish(e as Error));
  });
}

async function resolveSelf(): Promise<Resolved> {
  const name = await selfName();
  const cwd = expandPath(process.env.HEIDR_AGENT_CWD || process.cwd());
  for (const scope of scopeSocks()) {
    for (const session of await readRoster(scope.path)) {
      if ((session.name === name || session.id === name) && (!cwd || expandPath(session.cwd || "") === cwd)) {
        return { session: { ...session, scope: scope.scope }, scope: scope.scope, sockPath: scope.path, cwd: session.cwd || "" };
      }
    }
  }
  throw new Error(`current agent session ${JSON.stringify(name)} is not registered`);
}

export async function scheduleSelf(): Promise<void> {
  if (process.env.HEIDR_AGENT_PROFILE !== "lovable-watcher") throw new Error("agent_schedule_self is watcher-only");
  const self = await resolveSelf();
  const name = String(self.session.name || self.session.id || "");
  await writeThenClose(self.sockPath, { type: "schedule_self", session: name, from: name }, 500);
}

export async function stopSelf(): Promise<void> {
  if (process.env.HEIDR_AGENT_PROFILE !== "lovable-watcher") throw new Error("agent_stop_self is watcher-only");
  const self = await resolveSelf();
  const name = String(self.session.name || self.session.id || "");
  await writeThenClose(self.sockPath, { type: "stop_self", session: name, from: name }, 300);
}

function callerIdentity(from: string): Record<string, string> {
  const profile = process.env.HEIDR_AGENT_PROFILE || "";
  const parent = process.env.HEIDR_AGENT_PARENT || "";
  return { from, ...(profile ? { fromProfile: profile } : {}), ...(parent ? { fromParent: parent } : {}) };
}

export async function sendPrompt(ref: string, text: string): Promise<Resolved> {
  const r = await resolveSession(ref);
  if (!r) throw new Error(`no agent session matching ${JSON.stringify(ref)}`);
  const sid = r.session.id || r.session.name;
  await writeThenClose(r.sockPath, { type: "prompt", session: sid, message: text, ...callerIdentity(await selfName()) }, 800);
  return r;
}

// Real-time steer: if the target is mid-turn, deliver into its running turn (pi drops it
// in at the next tool boundary); if it's idle, fall back to a normal prompt so the message
// is never dropped. Returns which path was taken so callers can report it.
export async function steerSession(ref: string, text: string): Promise<{ resolved: Resolved; delivered: "steer" | "prompt" }> {
  const r = await resolveSession(ref);
  if (!r) throw new Error(`no agent session matching ${JSON.stringify(ref)}`);
  const sid = r.session.id || r.session.name;
  const running = /stream|work|run|busy|think/i.test(String(r.session.status ?? ""));
  const delivered = running ? "steer" : "prompt";
  await writeThenClose(r.sockPath, { type: delivered, session: sid, message: text, ...callerIdentity(await selfName()) }, 800);
  return { resolved: r, delivered };
}

function scopeForDir(dir: string, override?: string): string {
  if (override) return override;
  const env = process.env.HEIDR_SCOPE || process.env.AGENT_SCOPE;
  if (env) return env;
  const lov = path.join(HOME, "work", "lovable");
  if (dir === lov || dir.startsWith(lov + ".") || dir.startsWith(lov + "/")) return "lovable";
  if (dir.startsWith(path.join(HOME, "personal"))) return "personal";
  return "lovable";
}

export interface SpawnOpts {
  prompt?: string;
  oneshot?: boolean;
  name?: string;
  scope?: string;
  profile?: string;
}

export function spawnMessage(name: string, dir: string, opts: SpawnOpts, from = ""): Record<string, unknown> {
  const msg: Record<string, unknown> = { type: "spawn", session: name, cwd: dir };
  if (opts.prompt) msg.prompt = opts.prompt;
  if (opts.oneshot) msg.oneshot = true;
  if (opts.profile) msg.profile = opts.profile;
  if (from) msg.from = from;
  return msg;
}

// Start a NEW session in an existing dir. Worktree creation is NOT our job — the
// caller passes a real directory. Cold-starts the scope's daemon if it's absent.
export async function spawnSession(dir: string, opts: SpawnOpts = {}): Promise<{ name: string; scope: string; dir: string }> {
  const abs = expandPath(dir);
  if (!abs || !fs.existsSync(abs) || !fs.statSync(abs).isDirectory()) {
    throw new Error(`spawn target is not a directory: ${dir}`);
  }
  // SPAWNER-OWNED scope: an agent's spawns live on ITS OWN daemon, whatever dir they
  // work in — cwd is just a working directory. Inferring scope from the dir put
  // work-commissioned infra sessions (cwd under ~/personal) on the PRIVATE daemon,
  // invisible from the cockpit that spawned them. Explicit opts.scope still wins;
  // dir inference remains the fallback for callers with no session of their own.
  let scope = opts.scope || "";
  if (!scope) {
    try {
      const self = await resolveSession(process.cwd());
      if (self) scope = self.scope;
    } catch {}
  }
  if (!scope) scope = scopeForDir(abs);
  const name = opts.name || path.basename(abs);
  const sockPath = path.join(runtimeDir(), `agentd-${scope}.sock`);
  const from = await selfName(); // record spawn lineage: this session becomes the child's parent
  const msg = spawnMessage(name, abs, opts, from);
  await writeThenClose(sockPath, msg, 500);
  return { name, scope, dir: abs };
}

// Read the last N user+assistant turns from a session's newest pi JSONL — the
// same file `pi --continue` resumes. cwd → the encoded sessions dir.
export function readTurns(cwd: string, n = 6): { file: string; turns: Array<{ role: string; text: string }> } | null {
  const enc = "--" + cwd.replace(/^\/+|\/+$/g, "").replace(/\//g, "-") + "--";
  const dir = path.join(HOME, ".pi", "agent", "sessions", enc);
  let files: string[];
  try {
    files = fs
      .readdirSync(dir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => path.join(dir, f))
      .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  } catch {
    return null;
  }
  if (files.length === 0) return null;
  const file = files[0];
  const turns: Array<{ role: string; text: string }> = [];
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let o: any;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    const m = o?.message;
    if (!m || (m.role !== "user" && m.role !== "assistant")) continue;
    let text = "";
    if (typeof m.content === "string") text = m.content;
    else if (Array.isArray(m.content))
      text = m.content
        .filter((b: any) => b && b.type === "text")
        .map((b: any) => b.text ?? "")
        .join("\n");
    text = text.trim();
    if (text) turns.push({ role: m.role, text });
  }
  return { file: path.basename(file), turns: turns.slice(-n) };
}
