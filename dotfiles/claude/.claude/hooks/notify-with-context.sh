#!/usr/bin/env bash
# Claude Code Notification hook: replace the generic
# "Claude is waiting for your input" text with a notification that
# names the project/worktree, so multiple concurrent Claude sessions
# are distinguishable in the notification center.
#
# Mechanics:
#   - Claude sends its own generic "Claude Code" notification regardless;
#     we can't suppress it from the hook. Quickshell's Notifications.qml
#     drops it (app=kitty + summary "Claude Code") so only ours shows.
#     (This was a mako rule until the notification daemon moved to
#     quickshell.)
#   - Our custom notification uses kitty's OSC 99 protocol via
#     `kitten notify --only-print-escape-code`, written directly to
#     /dev/tty so it reaches the kitty instance that fired the hook.
#     Kitty registers a default action that focuses the originating
#     window when invoked via makoctl — which is what the Super+i
#     dispatcher relies on.
#   - We pick a distinct summary ("Claude · <label>") so the suppression
#     above doesn't hide our notification too.
#
# Stdin: JSON with `cwd`, `message`, `session_id`, `transcript_path`.
# Stdout: ignored (Claude only writes hook stdout to debug logs).

input=$(cat)

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
message=$(printf '%s' "$input" | jq -r '.message // "Waiting for input"' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

# Cockpit records the focused nvim pid and selected agent. Suppress only that
# agent; an older one-line marker keeps the previous safe, all-rail behavior.
_rail_file="${XDG_RUNTIME_DIR:-/tmp}/agent-rail-focused"
_rail_pid=$(sed -n '1p' "$_rail_file" 2>/dev/null)
_rail_session=$(sed -n '2p' "$_rail_file" 2>/dev/null)
if [ -n "$_rail_pid" ] && kill -0 "$_rail_pid" 2>/dev/null \
    && { [ -z "$_rail_session" ] || [ "$_rail_session" = "$session_id" ]; }; then
    exit 0
fi
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

# The session's custom name, if it was renamed via claude-rename (which
# appends a {"type":"custom-title",...} event to the transcript).
session_name() {
    local tp="$transcript"
    if [ -z "$tp" ] && [ -n "$session_id" ]; then
        tp=$(find "$HOME/.claude/projects" -name "${session_id}.jsonl" 2>/dev/null | head -1)
    fi
    [ -n "$tp" ] && [ -f "$tp" ] || return 0
    grep '"type":"custom-title"' "$tp" 2>/dev/null | tail -1 \
        | jq -r '.customTitle // empty' 2>/dev/null
}

# Label priority:
#   1. lovable worktree name — matched anywhere in cwd so it works even
#      when the session cd'd into a subdir; kept in `lovable.daphen-<name>`
#      form because quickshell's focus-dismiss matches on it.
#   2. the session's custom name — for sessions not in a worktree (home-
#      or main-checkout-launched), e.g. "slk-tui".
#   3. cwd-based fallback (parent/base), else PWD basename.
wt=$(printf '%s' "$cwd" | grep -oE 'lovable\.daphen-[^/]+' | head -1)
sname=$(session_name)
if [ -n "$wt" ]; then
    label="$wt"
elif [ -n "$sname" ]; then
    label="$sname"
elif [ -n "$cwd" ]; then
    base=$(basename "$cwd")
    parent=$(basename "$(dirname "$cwd")")
    case "$parent" in
        home|"$USER"|"~"|/) label="$base" ;;
        *) label="$parent/$base" ;;
    esac
else
    label="$(basename "$PWD" 2>/dev/null || echo claude)"
fi

# Focus is delivered by embedding this session's niri window id in the
# notification as a hint; kitty-osc-jump reads it and focuses the window
# directly. The old kitty-OSC path was unreliable here: NixOS wraps kitty
# as ".kitty-wrapped" (so a comm=="kitty" match never fired) and Claude
# Code runs the hook without the window's tty, so the OSC never reached
# kitty to register its focus action.
#
# Resolve the niri window by walking PPID to the hosting kitty process —
# its pid is the niri window's pid.
win_id=""
pid=$PPID
for _ in $(seq 1 12); do
    [ -z "$pid" ] || [ "$pid" -le 1 ] && break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$comm" in
        *kitty*)
            win_id=$(niri msg --json windows 2>/dev/null \
                | jq -r --argjson p "$pid" '[.[] | select(.pid == $p)][0].id // empty' 2>/dev/null)
            break
            ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

# Cockpit context, when this session is one of its tabs: the agent kitty is
# shared, so the window id alone can't say WHICH context raised the prompt —
# the jump scripts cockpit-switch on this hint before focusing.
#
# The authoritative source is the kitty TAB the session lives in (its title
# IS the context name): the hook inherits KITTY_LISTEN_ON/KITTY_WINDOW_ID
# from the session's shell. Only trusted for cockpit sockets — ordinary
# kitties have auto-generated tab titles. cwd parsing is the fallback.
ctx=""
case "${KITTY_LISTEN_ON:-}" in
    unix:${XDG_RUNTIME_DIR:-/tmp}/kitty-cockpit-*)
        if [ -n "${KITTY_WINDOW_ID:-}" ]; then
            ctx=$(kitty @ --to "$KITTY_LISTEN_ON" ls 2>/dev/null \
                | jq -r --argjson w "$KITTY_WINDOW_ID" \
                    '[.[].tabs[] | select(any(.windows[]; .id == $w)) | .title][0] // empty' 2>/dev/null)
        fi
        ;;
esac
if [ -z "$ctx" ]; then
    if [ -n "$wt" ]; then
        ctx="${wt#lovable.daphen-}"
    elif [ "$cwd" = "$HOME/work/lovable" ] || case "$cwd" in "$HOME/work/lovable/"*) true ;; *) false ;; esac; then
        ctx="main"
    fi
fi
# When the session is a cockpit tab, the tab title is also the clearest
# human label — "Claude · every-2554-variant-matrix" says the workstream.
[ -n "$ctx" ] && label="$ctx"

# Agent-declared "I need you to continue": this hook only fires when Claude
# is blocked on input (permission prompt / idle prompt). The marker makes
# the cockpit's awaiting-you authoritative; cockpit-wants-input-clear
# removes it when you respond.
if [ -n "$ctx" ]; then
    mkdir -p "$HOME/.local/state/cockpit/wants-input"
    touch "$HOME/.local/state/cockpit/wants-input/$ctx"
fi

# Brand: an explicit `app` field wins; otherwise infer — pi/Heidr agents (via the
# claude-hooks extension) send NO transcript_path, while Claude Code always does. So
# a Heidr agent's toast reads "Heidr · <ctx>", a real Claude session's "Claude · …".
brand=$(printf '%s' "$input" | jq -r '.app // empty' 2>/dev/null)
if [ -z "$brand" ]; then
    if [ -z "$transcript" ]; then brand="Heidr"; else brand="Claude"; fi
fi

notify-send --app-name=kitty ${win_id:+--hint=int:niri-window:$win_id} \
    ${ctx:+--hint=string:cockpit-context:$ctx} \
    "$brand · $label" "$message" 2>/dev/null || true
