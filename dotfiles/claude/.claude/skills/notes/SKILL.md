---
name: notes
description: Read, search, and write the user's personal notes — markdown files in the vault at ~/personal/notes/storage/, auto-synced to the backend by the notes-cli -watch service and indexed by the notes-memory MCP. Triggers on "my notes", "add a note", "find/search notes about X", "what did I write about Y", "save this as a note", "create a note", "read my notes on Z".
metadata:
  type: workflow
---

# notes

Local-file-first. The canonical store is the vault at `~/personal/notes/storage/` —
notes are plain markdown files on disk. A push-only watcher (`notes-cli -watch`, a
systemd user service) auto-syncs file changes UP to the backend (Neon via
`/api/sync`), where the `notes-memory` MCP indexes them for semantic search.
Backend → local is the rare direction, pulled on demand with `notes-cli -pull`.

The old flat `~/notes/` directory is a stale pre-vault store — don't read or write
it. Everything lives under `~/personal/notes/storage/`.

## Layout (subdirs by kind)

- `inbox/` — quick, uncategorized notes
- `journal/<YYYY-MM-DD>.md` — daily notes + todos
- `plans/` — plans / project write-ups
- `references/` — reference material, links
- `meetings/` — meeting notes
- `memory/` — durable memories; these carry frontmatter
  (`name`, `description`, `metadata.type: user|feedback|project|reference`)

## Saving — write a FILE when the vault exists; MCP only as fallback

When `~/personal/notes/storage/` exists locally, save by **writing a markdown file**
into the right subdir (descriptive kebab-case name; `journal/` uses the date). The
watcher syncs it up — do NOT run a manual push.

Do NOT call the `notes-memory` MCP `save_memory`/`save_note`/`add_todo` tools when
the vault exists: they write straight to the backend and SKIP the local file,
creating phantom notes (searchable but never in the vault, and they don't sync
back down).

Only when the vault dir is ABSENT (lovbox SSH sandboxes, mobile) use the MCP
`save_*` tools — the backend is the only reachable store there.

## Recall — pull, then search

When the vault exists locally, run `notes-cli -pull` first (syncs down anything
written elsewhere — a lovbox, mobile), then search the vault:

```
notes-cli -pull
rg -i "design system" ~/personal/notes/storage/ -l   # files matching
rg -i "design system" ~/personal/notes/storage/      # matches with context
ls -t ~/personal/notes/storage/inbox | head -20      # recently touched
```

Where the vault is absent, recall via the MCP: `notes-memory.search_notes(query)`.

## Don'ts

- Don't open the TUI (`notes-cli` with no flags) — it blocks.
- Don't write to `~/notes/` (stale) or the deprecated auto-memory at
  `~/.claude/projects/-home-daphen/memory/` — the vault is canonical.
- Don't call MCP `save_*` while the vault exists locally — phantom notes.
- Don't run `notes-cli -init` — config already exists.
