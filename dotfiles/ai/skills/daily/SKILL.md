---
name: daily
description: Generate David's morning daily briefing — today's meetings, the /standup y:/t:, and genuinely-missed overnight Slack — then push it to the Synced new-tab "Today" card. Triggers on "/daily", "daily", "my daily", "daily briefing", "generate my daily".
---

# Daily

Assemble today's briefing from REAL sources and POST it to Synced; the new-tab
card (`Shift+T`) renders whatever is pushed. Runs in EITHER agent that has the
Company Brain + Slack MCPs connected — **pi** (the cockpit orchestrator) or
Claude Code; both wire the same claude.ai MCPs, so tool names below are given
plain (each agent resolves its own prefix).

Meetings, mail, standup and spend all come from LOCAL sources (the mlqs socket,
git, Linear's API), so they need no MCP and work in a headless/cron run. **Slack
is the only leg that requires a live MCP session** — in a headless run it drops
out and the briefing is otherwise complete, so `daily-sync` is worth running on a
timer even though `missed` will then carry mail but no Slack.

Sources and why:
- **Meetings** → Company Brain `search_calendar` (the direct Google Calendar
  connector is blocked by the lovable.dev Workspace admin; Brain has a working
  path). mlqs's `agenda` command serves the same data locally and headlessly if
  this leg ever needs to move off the MCP.
- **Standup** → `standup` skill's `gather.sh` (git) + Linear state.
- **Missed** → Slack MCP, plus unread mail from the **mlqs** daemon (step 4).

## Step 1 — meetings (mlqs, local socket · Company Brain fallback)

**mlqs** holds its own calendar tokens, so this needs no MCP and works headless.
Its `agenda` command returns events with local-tz ISO `start`/`end`, `title`,
`allDay`, `meetLink`, `myStatus`. `text` is the day count.

```bash
python3 - <<'EOF' > /tmp/daily-meetings.json
import socket, json, os, time, sys, datetime
sock = (os.environ.get("XDG_RUNTIME_DIR") or "/run/user/1000") + "/mlqs.sock"
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(25); s.connect(sock)
except OSError:
    print("[]"); sys.exit(0)          # daemon down → fall back to Brain (below)
buf = b""
def events(secs):
    global buf
    t0 = time.time()
    while time.time() - t0 < secs:
        try: d = s.recv(1 << 20)
        except Exception: return
        if not d: return
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.strip():
                try: yield json.loads(line)
                except Exception: pass
for _ in events(3): pass              # drain the greeting
def dur(a, b):
    m = int((b - a).total_seconds() // 60)
    if m <= 0: return None
    h, r = divmod(m, 60)
    return f"{h}h{r}m" if h and r else (f"{h}h" if h else f"{m}m")
today, out = datetime.date.today().isoformat(), []
for acct in ("work", "gmail"):
    s.sendall((json.dumps({"type": "agenda", "account": acct, "text": "2"}) + "\n").encode())
    for ev in events(20):
        if ev.get("type") == "agenda":
            for e in ev.get("events") or []:
                st = str(e.get("start") or "")
                if not st.startswith(today): continue
                if e.get("myStatus") == "declined": continue   # noise on a day view
                row = {"title": e.get("title") or "(no title)", "calendar": acct}
                if e.get("allDay"):
                    row["time"] = "all-day"
                else:
                    row["time"] = st[11:16]
                    try:
                        a = datetime.datetime.fromisoformat(st)
                        b = datetime.datetime.fromisoformat(str(e.get("end")))
                        if (d2 := dur(a, b)): row["duration"] = d2
                    except Exception: pass
                if e.get("meetLink"): row["url"] = e["meetLink"]
                out.append(row)
            break
        if ev.get("type") in ("toast", "error"): break   # no calendar for that account
out.sort(key=lambda r: ("" if r["time"] == "all-day" else r["time"]))
print(json.dumps(out, ensure_ascii=False))
EOF
```

Keep all of today's events, even ones already past (it's a full-day view).
Declined ones are dropped; all-day events get `time: "all-day"`.

**Fallback:** if that prints `[]` because the daemon was down (not merely an empty
day), use Company Brain's `search_calendar` with today's window in local tz
(Europe/Stockholm), `start`=`YYYY-MM-DDT00:00:00+02:00`, `end`=`...T23:59:59+02:00`,
mapping each event → `{ time: "HH:MM", title, duration, url?: conferenceUrl,
calendar: "work" }`. Distinguish the two cases by whether the socket exists.

## Step 2 — standup (git + Linear)

```
bash ~/.claude/skills/standup/gather.sh "yesterday 00:00" | tee /tmp/gather.txt
```
On Monday (covering Fri+weekend) pass `"last friday 00:00"`. Keep the full raw
output in `/tmp/gather.txt` — step 5 attaches it verbatim as `standupContext` so
the Today-card chat can re-check the entire context that generated the standup. Optionally
cross-reference Linear issue state via Company Brain's `search`
(`sources: ["linear"]`), or the Linear MCP directly if the agent has it (pi does).

Curate into `standup: { y: string[], t: string[] }` per the async-standup
format ([[feedback_async_standup_format]]): terse lowercase bullets,
outsider-legible (NO ticket IDs, NO jargon), no em dashes
([[feedback_no_em_dashes]]). `y:` = yesterday's shipped + in-progress work
(biggest-effort item first); `t:` = today's actual top work. This is a
snapshot for the card, not the posted standup — do NOT run the post/log
ceremony.

## Step 3 — missed (Slack overnight)

Slack's `slack_search_public_and_private`, `query: "to:me after:<yesterday>"`
(and/or mentions). Filter to what is GENUINELY worth surfacing — skip pure bot
noise, but DO keep a real signal like an automated review flagging issues on
David's own PR. Map → `{ source, from, summary, url? }`. If nothing real, use
an empty array (the card shows "Nothing important overnight").

## Step 4 — mail (mlqs, local socket)

The blocked Gmail read scope and Brain's missing Gmail source don't apply here:
**mlqs** holds its own OAuth tokens per account, so it reads both mailboxes over
a unix socket with no MCP, no admin policy, and no interactive auth (this leg
works in a headless/cron run).

The daemon must be up. If the socket is missing or the call errors, **skip mail
silently** — leave `notes` unset, exactly like `spend`. Never fail the briefing
over mail.

```bash
python3 - <<'EOF' > /tmp/daily-mail.json
import socket, json, os, time, sys
sock = (os.environ.get("XDG_RUNTIME_DIR") or "/run/user/1000") + "/mlqs.sock"
out = []
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sock)
except OSError:
    print("[]"); sys.exit(0)          # daemon down → silent skip
buf = b""
def events(secs):
    global buf
    t0 = time.time()
    while time.time() - t0 < secs:
        try: d = s.recv(1 << 20)
        except Exception: return
        if not d: return
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.strip():
                try: yield json.loads(line)
                except Exception: pass
for _ in events(3): pass              # drain the greeting (workspaces/ping)
for acct in ("work", "gmail"):
    s.sendall((json.dumps({"type": "conversations", "account": acct,
                           "folder": "INBOX"}) + "\n").encode())
    for ev in events(15):
        # a cached frame lands first; the live one follows — take whichever
        # arrives, the unread flags are the same
        if ev.get("type") == "conversations":
            for c in ev.get("items") or []:
                if not c.get("unread"): continue
                snd = (c.get("senders") or [{}])[0]
                out.append({"account": acct, "id": c.get("id"),
                            "from": snd.get("name") or snd.get("email") or "?",
                            "subject": c.get("subject") or "",
                            "snippet": " ".join((c.get("snippet") or "").split()),
                            "date": c.get("date") or ""})
            break
print(json.dumps(out, ensure_ascii=False))
EOF
```

Each row: `account`, `id`, `from`, `subject`, `snippet`, `date` (ISO 8601).

Curate with the **same bar as the Slack step** — this is "what did I genuinely
miss", not an inbox dump. Drop CI/bot mail (`*[bot]`, build notifications),
newsletters, calendar-invite noise already covered by `meetings`, and anything
older than the overnight window. Keep real people and things needing a reply.
Add survivors to `missed` with `source: "Mail · work"` / `"Mail · gmail"`.

## Step 4.5 — Claude spend (yesterday + month-to-date)

The new-tab card can't read local transcripts, so bake the spend in here.
Run the bar's cost estimator (prints a float, USD):

```bash
y=$(~/.config/quickshell/scripts/claude-spend yesterday)
m=$(~/.config/quickshell/scripts/claude-spend month)
```

Include as `spend: { yesterday: <y>, month: <m> }` in the payload (numbers,
not strings). Omit the field entirely if the script isn't present / errors.

## Step 5 — assemble + push

Build the `DailyPayload` into `/tmp/daily.json` (shape in `synced/src/app/api/daily/route.ts`):
`{ date, generatedAt, meetings[], standup{y,t}, missed[], spend?{yesterday,month}, notes? }`.
POST to `https://synced-wine.vercel.app/api/daily`. Auth is a bearer token =
`AUTH_PASSWORD` from `~/personal/synced/.env` (quote-wrapped — strip the
quotes; NEVER echo the value):

```bash
cd ~/personal/synced
token=$(grep '^AUTH_PASSWORD=' .env | cut -d= -f2-); token="${token%\"}"; token="${token#\"}"
# Attach the full raw gather output as standupContext (verbatim, via --rawfile so
# it's the exact data — not paraphrased) → the Today chat re-checks the real
# git/PRs/Linear/roster behind the standup. Falls back to daily.json if empty.
jq --rawfile ctx /tmp/gather.txt '. + {standupContext: $ctx}' /tmp/daily.json \
  > /tmp/daily-final.json 2>/dev/null || cp /tmp/daily.json /tmp/daily-final.json
curl -s -o /tmp/r.json -w "%{http_code}\n" -X POST "https://synced-wine.vercel.app/api/daily" \
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" --data @/tmp/daily-final.json
```
Use `date +%F` for `date`, `date -u +%Y-%m-%dT%H:%M:%SZ` for `generatedAt`. The
endpoint upserts by date, so re-running `/daily` refreshes today's card.

## Step 6 — confirm

Confirm HTTP 200, then tell David it's live — open a new tab and `Shift+T`
(auto-shows once per day on the first tab).
