# Automatic checkpoints and optional Jev pruning

Automatic threshold/overflow checkpoints remain deterministic and bounded to
20,000 UTF-8 bytes. Manual `/compact` stays with Pi. No model-window or native
cut-point change is made by this extension.

## Controls

- `/jev-pruning status`: mode and the current task's latest classification
  counts, latency, proposed source bytes, and returned usage. Bytes are not
  token or cost savings; reported Jev usage is separate from Pi's main-model
  totals.
- `/jev-pruning shadow <personal task>`: classify approved old reads without
  changing requests. State the personal task explicitly; existing shadow
  permissions without a task send nothing until this command is run again.
- `/jev-pruning compact <personal task>`: explicitly opt a personal-only saved
  session into immediate paired call/result classification and outgoing
  compaction. It does not wait for the 60% scheduling threshold.
- `/jev-pruning on`: older read-result-only opt-in, retained for compatibility;
  it sends complete eligible read results. Do not use it for the paired pilot.
- `/jev-pruning off`: stop requests and restore un-compacted original results.

Default is off, including in new sessions and forks. Permission survives a
restart of the same saved session and is bound to its repository directory.
Turning off applies across branches. Turning on never activates earlier shadow
suggestions. A new user request expires earlier task selections.

## Data and credentials

Shadow sends only the declared personal task and a chronological list of
eligible repository read paths and result byte counts to Typesafe AI's
`jev-latest` systemone endpoint. It asks separately whether each call and its
full result should stay, recording hypothetical scores without changing context.
No read contents or incidental conversation text are sent in shadow. `compact`
sends only the declared task, old built-in tool names, approved repository paths
for file tools, and result byte counts. Bash commands and all result bodies stay
local. **Use `compact` only in a personal-only session**: even tool names and
sizes from a mixed work/VM session are outside this approval. `on` retains its
earlier behavior: it sends complete eligible read results, their arguments, and
at most 8 KiB of recent task text. System instructions, thinking, and the entire
transcript are not sent in any mode. Reads outside the repository (including
resolved symlinks), notes, `.git`, `.pi`, SSH files, `.env*`, `.jsonl` records,
the current session file, and named credential/secret/key files are excluded.
These path checks are **not sanitization**: allowed source and task text can
contain secrets. Only opt in for content you are permitted to share with that
provider.

The key comes from `TYPESAFEAI_API_KEY`, or a bounded `fish --no-config` child
loading `~/.config/fish/secrets.fish`. No extra secret file, endpoint override,
agentd restart, or development flag is needed. Missing credentials retain all
content and produce a warning on the first attempted classification.

## Limits and recovery

Shadow and legacy `on` classification begin around 60% of the effective context
window. Explicit `compact` classifies immediately. The scheduling estimate is
not exact token accounting. Each user request allows one pass, at most four
parallel requests of 64 KiB each, with a two-second deadline including
credential lookup. Missing usage is unknown, not zero cost. Oversized complete
results are retained, not judged from excerpts. Batch errors, cancellation,
invalid scores, and timeouts retain the whole pass; there is no retry in that
user request.

Shadow and legacy `on` consider successful text `read` results of at least 1
KiB. `compact` also considers completed built-in `bash`, `edit`, and `write`
text results of at least 512 bytes. The latest three completed results, open
batches, errors, images, truncated outputs, and all user text stay intact. At
scores below 0.5, `compact` drops a read call and its paired result when both
are low; otherwise it replaces a low-scored result with a saved-record
reference. Mutation calls are never dropped or rerun. Assistant thinking and
text are retained. Shadow suggestions never become live decisions; legacy `on`
still requires a result score at or below 0.1. Scores can be wrong.

Decisions are small `jev-pruning` custom entries in the original session JSONL.
Suggestions identify exact source entries without copying their contents.
Omission markers identify the file, entry ID, and tool call of the saved
original. Retrieve that record with existing tools if needed; do not rerun a
mutation. The original records are never deleted. Off cannot undo a native
checkpoint already written; older originals remain in the saved session. Native
preflight compaction can also happen before this request-filter hook runs.

## Pilot

Load the extension only in the approved Pi session, then run
`/jev-pruning shadow <personal task>`. Interactive Pi supports `/reload`;
agentd's RPC mode does not support that TUI command. There, restart only the
named Pi child while preserving its session; do not restart Cockpit or agentd.
Review at least 20 suggestions across five genuine user turns, including useful
old evidence. Record classifier latency/usage and actual main-provider cache
usage. A missed essential fact blocks promotion. The immediate `compact` mode is
an explicit live opt-in **for a personal-only session**, not a default or
permission to transmit mixed work history. Compare actual outgoing provider
requests and rollover frequency before relying on savings; use `off` on
regressions.
