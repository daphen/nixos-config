# remote-session-restore-cli — Validate remote work-scope cwd before spawn

> Status: `finalized` · 2026-09-04T12:32Z · worktree: `main`

## The shape

Today `agent spawn --scope work` rejects a VM-only directory by checking it on
the desktop before contacting the work scope. Instead it will positively verify
that directory over the SSH target already configured for the work-scope tunnel,
fail closed when validation cannot succeed, and then use the existing agentd
spawn transport unchanged.

## The flow

1. The public CLI currently requires every spawn cwd to exist on the desktop.
1. **◆ Validate an explicit work-scope cwd on its configured remote host.**
   - Read the deployed `agentd-work-tunnel.service` command to reuse its SSH
     executable, options, user, and host.
   - Run a read-only remote `test -d` before socket access; distinguish a
     missing directory from transport/config failure and create nothing.
   - Preserve the existing local `Path.is_dir()` and resolution path for every
     non-work spawn. _(file: dotfiles/bin/.local/bin/agent)_
1. **◆ Lock the public CLI behavior with focused process-level tests.**
   - Cover a valid remote directory, remote missing directory, remote transport
     error, and local missing directory.
   - Confirm a successful seedless spawn contains no prompt or parent/from
     fields. _(file: tests/test_agent_spawn_cli.py)_
1. Use the corrected canonical CLI once to restore only
   `every-2563-message-only` as a seedless standalone work-scope root, then
   inspect roster and repository state without resuming work.

## Decided — derivable calls, locked

- Explicit `--scope work` selects remote validation; no new flag or general
  remote-host registry is introduced.
- The deployed work-tunnel unit is the source of truth for SSH host and
  transport options, avoiding a duplicate hostname in the CLI.
- The existing agentd socket and spawn message remain unchanged after cwd
  validation.
- No daemon code, restart, VM install, worktree creation, directory creation,
  raw socket/state edit, commit, or push is allowed.

## Surface area — the containment boundary

- **modify** `dotfiles/bin/.local/bin/agent` Add work-scope remote directory
  validation before the existing spawn send.
- **create** `tests/test_agent_spawn_cli.py` Exercise the public CLI against
  fake SSH, unit configuration, and agentd endpoints.

*New: 1 · Modified: 1 · Touched: 0*

**Budget: ~100 lines changed.**

## Verification

- Public CLI tests pass for valid remote directory, remote missing/error, and
  local missing cases.
- The valid seedless case emits `type=spawn`, the requested name/cwd/profile,
  and no prompt, parent, drivenBy, or caller-origin fields.
- Existing role/launcher tests and Python compilation pass.
- The restored roster entry is idle, profile `lovable-worker`, at the exact VM
  cwd, with no parent or drivenBy; the removed old parent remains absent.
- Remote read-only repository inspection reports branch
  `daphen/every-2563-message-only`, clean HEAD
  `3e2a356f5b1068895ba2b980f3b817d6dea0e541`, and no devenv stack.

## Out of scope

- Resuming or prompting the restored ticket session.
- Changing agentd, tunnel units, VM packages, repository branches, worktrees, or
  product code.
- Creating a general remote execution/configuration framework.
- Committing or pushing any change.

## How it works

```text
validate
  ◆1  choose local or configured remote directory check  ·  dotfiles/bin/.local/bin/agent
      explicit work scope reads the deployed tunnel command and asks that same SSH host whether the directory exists
    ↓ only a positively verified cwd reaches the existing spawn request
specify
  ◆2  exercise the public command  ·  tests/test_agent_spawn_cli.py
      subprocess tests prove valid, missing, and unreachable remote directories plus unchanged local failure behavior and seedless root payload
```

## Amendments

- _none yet_

## Reconciliation

_(filled by `--reconcile`)_
