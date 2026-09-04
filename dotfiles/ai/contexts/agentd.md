# agentd source

This repository owns the Go supervisor between Cockpit clients and one
`pi --mode rpc` child per session. It serves NDJSON over one socket per scope,
persists the roster, and tags child events with their session before broadcast.
Use current Go source and tests for protocol and lifecycle behavior. The
`Inter-agent coordination` section of
`/home/daphen/personal/notes/storage/references/agent-rail.md` remains useful for
cross-session topology; its opening architecture and later dev-loop/history
sections describe retired implementations.

## Repository checks

- Run `go test ./...` for behavior changes.
- Run `go build ./...` to compile without replacing the live daemon.
- Public socket behavior belongs in tests through the daemon entrypoint; do not
  add a parallel protocol or test-only exported API.

## Integration and activation

Local units and their secret-loading wrapper are defined outside this repo:

- `/home/daphen/nixos/common/home/daemons.nix`
- `/home/daphen/nixos/dotfiles/niri/.config/niri/scripts/launch-agentd`
- `/home/daphen/nixos/dotfiles/bin/.local/bin/agentd-safe-restart`
- `/home/daphen/nixos/dotfiles/ai/roles/manifest.json`

The deployed local units execute `/home/daphen/.local/bin/agentd`; the NixOS
package is built from the pinned flake input, not this dirty checkout. Installing
a local binary or restarting a scope is activation, not validation. Do neither
without explicit approval; a restart interrupts every live session in that
scope. When a restart is approved, use the scope-aware safe-restart wrapper
rather than raw process signals.

Cockpit UI source lives in `/home/daphen/personal/ai-cockpit`; do not edit UI or
role permissions here to compensate for daemon behavior.
