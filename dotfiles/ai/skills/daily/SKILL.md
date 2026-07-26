---
name: daily
description: Generate David's morning daily briefing — today's meetings, the /standup y:/t:, and genuinely-missed overnight Slack — then push it to the Synced new-tab "Today" card. Triggers on "/daily", "daily", "my daily", "daily briefing", "generate my daily".
---

# Daily

Assemble today's briefing from REAL sources and POST it to Synced; the new-tab
card (`Shift+T`) renders whatever is pushed. Run this in an interactive Claude
Code session — it needs the claude.ai MCPs (Company Brain, Slack), which are
NOT available in headless/cron runs. This is the manual "sit-down" command.

Sources and why (mail is deliberately absent — see step 4):
- **Meetings** → Company Brain `search_calendar` (the direct Google Calendar
  connector is blocked by the lovable.dev Workspace admin; Brain has a working
  path).
- **Standup** → `standup` skill's `gather.sh` (git) + Linear state.
- **Missed** → Slack MCP.

## Step 1 — meetings (Company Brain)

`mcp__claude_ai_Company_Brain__search_calendar` with today's window in local tz
(Europe/Stockholm), `start`=`YYYY-MM-DDT00:00:00+02:00`, `end`=`...T23:59:59+02:00`.
Map each event → `{ time: "HH:MM", title, duration, url?: conferenceUrl, calendar: "work" }`.
Keep all of today's events, even ones already past (it's a full-day view).

## Step 2 — standup (git + Linear)

```
bash ~/.claude/skills/standup/gather.sh "yesterday 00:00"
```
On Monday (covering Fri+weekend) pass `"last friday 00:00"`. Optionally
cross-reference Linear issue state via
`mcp__claude_ai_Company_Brain__search` (`sources: ["linear"]`).

Curate into `standup: { y: string[], t: string[] }` per the async-standup
format ([[feedback_async_standup_format]]): terse lowercase bullets,
outsider-legible (NO ticket IDs, NO jargon), no em dashes
([[feedback_no_em_dashes]]). `y:` = yesterday's shipped + in-progress work
(biggest-effort item first); `t:` = today's actual top work. This is a
snapshot for the card, not the posted standup — do NOT run the post/log
ceremony.

## Step 3 — missed (Slack overnight)

`mcp__claude_ai_Slack__slack_search_public_and_private`, `query: "to:me after:<yesterday>"`
(and/or mentions). Filter to what is GENUINELY worth surfacing — skip pure bot
noise, but DO keep a real signal like an automated review flagging issues on
David's own PR. Map → `{ source, from, summary, url? }`. If nothing real, use
an empty array (the card shows "Nothing important overnight").

## Step 4 — mail (currently skipped)

Work Gmail's read scope is blocked by the lovable.dev Workspace admin policy,
and Company Brain has no Gmail source, so mail is omitted — silently, do NOT
add a "mail skipped" line to `notes` (leave `notes` unset). Future paths if
this is revisited: point the Gmail connector at a personal Google account (no
admin lock), or connect the Superhuman MCP. If a Gmail read path is working,
query `in:inbox is:unread newer_than:1d`, filter to genuinely important
overnight threads, and add them to `missed` with `source: "Gmail · <inbox>"`.

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

Build the `DailyPayload` (shape in `synced/src/app/api/daily/route.ts`):
`{ date, generatedAt, meetings[], standup{y,t}, missed[], spend?{yesterday,month}, notes? }`.
POST to `https://synced-wine.vercel.app/api/daily`. Auth is a bearer token =
`AUTH_PASSWORD` from `~/personal/synced/.env` (quote-wrapped — strip the
quotes; NEVER echo the value):

```bash
cd ~/personal/synced
token=$(grep '^AUTH_PASSWORD=' .env | cut -d= -f2-); token="${token%\"}"; token="${token#\"}"
curl -s -o /tmp/r.json -w "%{http_code}\n" -X POST "https://synced-wine.vercel.app/api/daily" \
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" --data @/tmp/daily.json
```
Use `date +%F` for `date`, `date -u +%Y-%m-%dT%H:%M:%SZ` for `generatedAt`. The
endpoint upserts by date, so re-running `/daily` refreshes today's card.

## Step 6 — confirm

Confirm HTTP 200, then tell David it's live — open a new tab and `Shift+T`
(auto-shows once per day on the first tab).
