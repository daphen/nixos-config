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
- `/jev-pruning reviewed <personal task>`: immediately classify complete
  approved repository reads without changing requests. Use only in a fresh
  personal-only session after explicit permission to send those contents. Unlike
  metadata shadow, this can distinguish the relevance of the actual read text.
  Suggestions remain hypothetical.
- `/jev-pruning on`: older read-result-only opt-in, retained for compatibility;
  it sends complete eligible read results and only omits scores at or below 0.1.
  Do not activate it based on `reviewed` scores without a separate sign-off.
- The former metadata-only `/jev-pruning compact` is disabled. Its scores
  proposed hiding real passing tests and actionable QML loader errors. Old
  stored compact permissions do not enable classification or filtering.
- `/jev-pruning off`: stop requests and restore un-compacted original results.

Default is off, including in new sessions and forks. `reviewed` requires its own
opt-in; an old `compact` permission cannot broaden into content sharing.
Permission survives a restart of the same saved session and is bound to its
repository directory. Turning off applies across branches. Turning on never
activates earlier shadow suggestions. A new user request expires earlier task
selections.

## Data and credentials

Shadow sends only the declared personal task and a chronological list of
eligible repository read paths and result byte counts to Typesafe AI's
`jev-latest` systemone endpoint. It asks separately whether each call and its
full result should stay, recording hypothetical scores without changing context.
No read contents or incidental conversation text are sent in shadow. `reviewed`
sends the declared personal task and complete approved repository `read` results
with their arguments; it sends no incidental conversation, bash commands or
outputs, mutation results, notes, or work/VM paths. File content may still
contain sensitive text; inspect the personal session before opting in. `on`
retains its earlier behavior: it sends complete eligible read results, their
arguments, and at most 8 KiB of recent task text. System instructions, thinking,
and the entire transcript are not sent in any mode. Reads outside the repository
(including resolved symlinks), notes, `.git`, `.pi`, SSH files, `.env*`,
`.jsonl` records, the current session file, and named credential/secret/key
files are excluded. These path checks are **not sanitization**: allowed source
and task text can contain secrets. Only opt in for content you are permitted to
share with that provider.

The key comes from `TYPESAFEAI_API_KEY`, or a bounded `fish --no-config` child
loading `~/.config/fish/secrets.fish`. No extra secret file, endpoint override,
agentd restart, or development flag is needed. Missing credentials retain all
content and produce a warning on the first attempted classification.

## Limits and recovery

Shadow and legacy `on` classification begin around 60% of the effective context
window. Explicit `reviewed` classifies immediately. The scheduling estimate is
not exact token accounting. Each user request allows one pass, at most four
parallel requests of 64 KiB each, with a two-second deadline including
credential lookup. Missing usage is unknown, not zero cost. Oversized complete
results are retained, not judged from excerpts. Batch errors, cancellation,
invalid scores, and timeouts retain the whole pass; there is no retry in that
user request.

Shadow, `reviewed`, and legacy `on` consider successful text `read` results of
at least 1 KiB. The latest three completed results, open batches, errors,
images, truncated outputs, mutations, bash results, and all user text stay
intact. `reviewed` records hypothetical result omissions below 0.5 but filters
nothing. Shadow suggestions never become live decisions; legacy `on` still
requires a result score at or below 0.1. Scores can be wrong.

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
usage. A missed essential fact blocks promotion. Start `reviewed` in a newly
approved, personal-only session, inspect genuine suggestions including useful
old reads, and compare actual main-provider usage before requesting a separate
live-pruning approval. The old metadata-only `compact` is not a safe activation
path. Use `off` on regressions.
