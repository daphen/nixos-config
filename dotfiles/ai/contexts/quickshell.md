# Desktop Quickshell entry

This lexical cwd is a live symlink into
`/home/daphen/nixos/dotfiles/quickshell/.config/quickshell`. Before editing,
read `/home/daphen/nixos/AGENTS.md` and the Quickshell section of
`/home/daphen/nixos/dotfiles/SYSTEM.md`.

This tree owns the desktop bar, minimap, notifications, and pickers. It does not
own Cockpit's rail or embedded terminal; those live in the separate
`/home/daphen/personal/ai-cockpit` repository.

Changes are live-linked and Quickshell watches QML, but a parse failure leaves
the old component running. Load changed QML in an isolated instance with the
real imports and inspect loader errors before reporting success. Do not restart
the desktop shell or a visible Cockpit for validation.
