# vmctl ticket app startup

`vm-wt` uses this package. On the VM its wrapper invokes
`vmctl --native worktree`; source-only startup does not start the app or require
a desktop mirror. `--app` explicitly starts/reuses the ticket's tmux session.

## VM-launched apps and desktop access

Run `vm-cockpit` from the desktop when provisioning or reconnecting a VM. It
installs the same `vmctl` binary and native `vm-wt` wrapper on that VM, and
provisions `vm-dev-tunnel.service` on the desktop. The tunnel forwards only
loopback port 2015 to the existing `devenv` worktree router, which already
routes each ticket's web and `/go-api/*` traffic. It is enabled at desktop login
and reconnects after SSH failures; ticket launches need no new desktop port
mapping.

For an already-provisioned VM, `vmctl connect` installs/enables just this
tunnel, without syncing instructions or restarting agents. Select the VM using
the existing `COCKPIT_VM_HOST` and `COCKPIT_VM_USER` variables (legacy `HEIDR_*`
variables also work). The selected endpoint is stored in the user service; a
different existing service is rejected rather than silently redirected. SSH
trust and authentication must already work. No VM-to-desktop SSH access, new
public listener, or router administration port is exposed.

On the VM, `vm-wt --app EVERY-N` reuses the normal app lifecycle, finds the
existing router entry by its generated web/API ports, checks the routed page,
client asset and API health, and prints that entry's hostname. It does not claim
desktop verification. The desktop must have run the connection setup; HTTP
checks from the VM cannot establish desktop reachability. A missing router or
mismatched route fails explicitly rather than advertising a direct VM-only port
as desktop-ready. `--script-tag` still requires its explicit desktop
`vm-wt --script-tag EVERY-N` forward for port 8001.

## Ticket retirement ownership

The orchestrator owns full ticket shutdown and retirement. Workers save a
handoff and report readiness/blockers; they never invoke `--off` or `--reap`.
After David approves the exact context, the orchestrator runs
`vm-wt --reap EVERY-N` from outside the target checkout and its desktop mirror,
captures output/exit status there, and verifies completion. `--off` stops the
session/runtime but retains files and caches; `--teardown` stops only the
desktop tunnel. Native VM retirement leaves desktop mirrors/tunnels untouched.

Before contacting agentd or making changes, `--off` and `--reap` reject
non-orchestrator agent profiles and callers inside the target or mirror,
including nested and symlinked directories. Manual CLI callers remain allowed
outside those directories. These guards prevent accidental self-retirement; they
do not grant deletion permission or replace the existing safety checks.

## Certificates across the tmux boundary

New app sessions must explicitly receive `NODE_EXTRA_CA_CERTS` via tmux's
`new-session -e` option. Caller-only variables are not reliably inherited from
an already-running tmux server. Preserve an explicit caller value; otherwise use
the VM's readable `/etc/ssl/certs/ca-certificates.crt` bundle.

The launcher does not load direnv hooks. `nix develop --impure` starts the
repo's `./bin/devenv wt`, which forwards its environment to process-compose. Do
not add a separate env loader or disable TLS verification to work around this
boundary.

An existing app session is deliberately reused, not restarted or reconfigured.
After an approved launcher update, use the approved app lifecycle to obtain a
fresh process environment. Restarting agentd or reauthenticating MCPs is
unrelated.

Verify CA propagation in the supervisor/web/API and actual Confidence flag
resolution. HTTP200 or a signed-in dashboard with fallback values is not
success.

## Desktop draft mirror

`vm-sync --drafts` mirrors the VM's `~/personal/notes/storage/inbox` into the
desktop's `~/work/vm-notes/inbox`. It creates or reuses the `vm-notes-inbox`
Mutagen session with `two-way-safe` synchronization, flushes it, and refuses
success on conflicts, transfer errors, or disconnected endpoints. The canonical
desktop notes vault and standalone cached copies are not synchronization roots.

Cockpit calls this before opening a VM inbox file, then uses its ordinary local
Neovim editing path. Saved edits travel back through Mutagen; conflicting edits
remain on both sides for explicit resolution. An unrelated session with the same
name, or an unmanaged nonempty local folder, is never adopted automatically.

## Validation and deployment

`go test -race ./...` includes a public CLI regression for the default CA bundle
and a custom path containing spaces and an apostrophe.

The installed VM binary may include unpublished local changes. Check source
status and installed binary provenance before replacing it; do not rebuild an
older clean revision and silently drop those features. Keep a rollback binary,
verify the installed SHA256, and distinguish installation from live acceptance.
Installation, app restarts, and source pushes have separate approval scopes.
