#!/usr/bin/env bash
# UserPromptSubmit / PostToolUse hook: the user responded (typed a prompt or
# approved a tool), so this session is no longer blocked — drop the
# wants-input marker notify-with-context.sh set for its cockpit context.
case "${KITTY_LISTEN_ON:-}" in
    unix:${XDG_RUNTIME_DIR:-/tmp}/kitty-cockpit-*) ;;
    *) exit 0 ;;
esac
[ -n "${KITTY_WINDOW_ID:-}" ] || exit 0
ctx=$(kitty @ --to "$KITTY_LISTEN_ON" ls 2>/dev/null \
    | jq -r --argjson w "$KITTY_WINDOW_ID" \
        '[.[].tabs[] | select(any(.windows[]; .id == $w)) | .title][0] // empty' 2>/dev/null)
[ -n "$ctx" ] && rm -f "$HOME/.local/state/cockpit/wants-input/$ctx"
exit 0
