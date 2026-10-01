# Automatic checkpoints and optional Jev pruning

Automatic threshold/overflow checkpoints remain deterministic and bounded to
20,000 UTF-8 bytes. Manual `/compact` stays with Pi. No model-window or native
cut-point change is made by this extension.

## Controls

- `/jev-pruning status`: mode and the current task's latest classification
  counts, latency, proposed source bytes, and returned usage. Bytes are not
  token or cost savings; reported Jev usage is separate from Pi's main-model
  totals.
- `/jev-pruning shadow`: opt this saved session into classification only.
- `/jev-pruning on`: explicitly opt into replacing selected output in requests
  and automatic checkpoints. Review shadow suggestions before using this.
- `/jev-pruning off`: stop requests and restore un-compacted original results.

Default is off, including in new sessions and forks. Permission survives a
restart of the same saved session and is bound to its repository directory.
Turning off applies across branches. Turning on never activates earlier shadow
suggestions. A new user request expires earlier task selections.

## Data and credentials

Opt-in sends complete eligible repository read results, their arguments, and at
most 8 KiB of recent task text to Typesafe AI's `jev-latest` systemone endpoint.
System instructions, thinking, and the entire transcript are not sent. Reads
outside the repository (including resolved symlinks), notes, `.git`, `.pi`, SSH
files, `.env*`, `.jsonl` records, the current session file, and named
credential/secret/key files are excluded. These path checks are **not
sanitization**: allowed source and task text can contain secrets. Only opt in
for content you are permitted to share with that provider.

The key comes from `TYPESAFEAI_API_KEY`, or a bounded `fish --no-config` child
loading `~/.config/fish/secrets.fish`. No extra secret file, endpoint override,
agentd restart, or development flag is needed. Missing credentials retain all
content and produce a warning on the first attempted classification.

## Limits and recovery

Classification begins around 60% of the effective context window. This is a
fresh size estimate, not exact token accounting. Each user request allows one
pass, at most four parallel requests of 64 KiB each, with a two-second deadline
including credential lookup. Missing usage is unknown, not zero cost. Oversized
complete results are retained, not judged from excerpts. Batch errors,
cancellation, invalid scores, and timeouts retain the whole pass; there is no
retry in that user request.

Only successful text `read` results of at least 1 KiB are eligible. The last
three tool results, open batches, errors, images, truncated results, mutations,
unknown tools, and all user/assistant records stay intact. A keep score of 0.1
or less permits omission. Scores can be wrong: this is not lossless memory.

Decisions are small `jev-pruning` custom entries in the original session JSONL.
Suggestions identify exact source entries without copying their contents.
Omission markers identify the file, entry ID, and tool call of the saved
original. Retrieve that record with existing tools if needed; do not rerun a
mutation. The original records are never deleted. Off cannot undo a native
checkpoint already written; older originals remain in the saved session. Native
preflight compaction can also happen before this request-filter hook runs.

## Pilot

Load the extension only in the approved Pi session, then use shadow mode.
Interactive Pi supports `/reload`; agentd's RPC mode does not support that TUI
command. There, restart only the named Pi child while preserving its session; do
not restart Cockpit or agentd. Review at least 20 suggestions across five
genuine user turns, including useful old evidence. Record classifier
latency/usage and actual main-provider cache usage. A missed essential fact
blocks promotion. Live pruning needs a separate explicit opt-in. Compare real
rollover frequency before expanding; use off on regressions.
