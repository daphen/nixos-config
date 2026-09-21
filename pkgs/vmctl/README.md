# vmctl ticket app startup

`vm-wt` uses this package. On the VM its wrapper invokes
`vmctl --native worktree`; source-only startup does not start the app or require
a desktop mirror. `--app` explicitly starts/reuses the ticket's tmux session.

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

## Validation and deployment

`go test -race ./...` includes a public CLI regression for the default CA bundle
and a custom path containing spaces and an apostrophe.

The installed VM binary may include unpublished local changes. Check source
status and installed binary provenance before replacing it; do not rebuild an
older clean revision and silently drop those features. Keep a rollback binary,
verify the installed SHA256, and distinguish installation from live acceptance.
Installation, app restarts, and source pushes have separate approval scopes.
