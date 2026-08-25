#!/usr/bin/env bash
# Routes URLs to the correct browser profile (personal or work).
# Default routing is by URL pattern; callers that need an explicit profile
# (e.g. ws-createwt) can pass --profile=<work|personal>.
#
# Usage:
#   browser-dispatch <url>                              URL-routed, existing window
#   browser-dispatch --profile=work <url>               force work profile
#   browser-dispatch --new-window <url>                 open in a new window
#   browser-dispatch --profile=work --new-window <url>  combine both
#   browser-dispatch --app <url>                        chromeless app-mode window
#                                                       (app-id chrome-<host>__-…)
#
# Browser binary, profile names and class names live in browser-config.sh
# — switching browsers is a one-file edit.

set -u

source "$(dirname "$0")/browser-config.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────

FORCED_PROFILE=""
NEW_WINDOW=""
APP_MODE=""
URL=""
for arg in "$@"; do
    case "$arg" in
        --profile=*)   FORCED_PROFILE="${arg#--profile=}" ;;
        --new-window)  NEW_WINDOW="--new-window" ;;
        --app)         APP_MODE=1 ;;
        *)             URL="$arg" ;;
    esac
done

# ── Spotify: play in spotify-player instead of opening a browser ───────────────
# Catches spotify: URIs and open.spotify.com/<type>/<id> links (locale prefix
# tolerated). Only track/album/playlist/artist are supported by the CLI —
# anything else (episode, show, user) falls through to the browser.
if [[ "$URL" =~ ^spotify: || "$URL" =~ ^https?://open\.spotify\.com/ ]]; then
    stype="" sid=""
    if [[ "$URL" =~ spotify:([a-z]+):([A-Za-z0-9]+) ]]; then
        stype="${BASH_REMATCH[1]}" sid="${BASH_REMATCH[2]}"
    elif [[ "$URL" =~ open\.spotify\.com/(intl-[a-z-]+/)?([a-z]+)/([A-Za-z0-9]+) ]]; then
        stype="${BASH_REMATCH[2]}" sid="${BASH_REMATCH[3]}"
    fi
    if [[ -n "$sid" && "$stype" =~ ^(track|album|playlist|artist)$ ]]; then
        # The TUI's client-API port is the source of truth for "an instance
        # is running" — window matching lied whenever the player was launched
        # outside our kitty class, and a duplicate spawn dies on the port
        # anyway. (Port must match client_port in spotify-player's app.toml.)
        SP_PORT=24915
        # NB: spotify-player's client API is a UDP socket (ss -uln, not -tln)
        sp_up() { ss -uln 2>/dev/null | grep -q ":${SP_PORT} "; }

        if sp_up; then
            # Focus the existing window if one is visible — match loosely
            # (app-id OR title), and NEVER spawn from the focus path.
            niri msg --json windows 2>/dev/null | python3 -c '
import json, subprocess, sys
try: wins = json.load(sys.stdin)
except Exception: sys.exit(0)
for w in wins:
    s = ((w.get("app_id") or "") + " " + (w.get("title") or "")).lower()
    if "spotify" in s:
        subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(w["id"])])
        break
' >/dev/null 2>&1
        else
            setsid kitty --class spotify-player -e spotify_player >/dev/null 2>&1 </dev/null &
            # Wait for the TUI to bind its port BEFORE any spotify_player CLI
            # call: with no server up, the CLI runs standalone — it grabs the
            # port itself and the freshly-spawned TUI dies on bind (the
            # "window opens then instantly closes" failure).
            for _ in $(seq 1 60); do
                sp_up && break
                sleep 0.25
            done
            sp_up || exit 0   # TUI never came up; don't poke a dead server
        fi
        # Server is up — CLI calls now connect as clients (timeout-wrapped:
        # the client can still hang during server startup hiccups). Wait for
        # the Connect device to be active; playback start 404s without one.
        active=""
        for _ in $(seq 1 20); do
            if timeout 2 spotify_player get key devices 2>/dev/null | grep -q '"is_active":true'; then
                active=1; break
            fi
            sleep 0.5
        done
        [[ -z "$active" ]] && timeout 3 spotify_player connect --name spotify-player >/dev/null 2>&1
        if [[ "$stype" == track ]]; then
            timeout 5 spotify_player playback start track --id "$sid" >/dev/null 2>&1
        else
            timeout 5 spotify_player playback start context --id "$sid" "$stype" >/dev/null 2>&1
        fi
        exit 0
    fi
fi

# ── URL routing rules ─────────────────────────────────────────────────────────

is_personal_url() {
    [[ "$1" =~ ^https?://(www\.|m\.|music\.)?youtube\.com ]] || \
    [[ "$1" =~ ^https?://youtu\.be ]]
}

is_work_url() {
    [[ "$1" =~ lovable ]] || \
    [[ "$1" =~ ^https?://(www\.)?github\.com/lovablelabs(/|$) ]]
}

# ── Profile selection ─────────────────────────────────────────────────────────

# Default: whichever browser profile was last focused. niri-focus-tracker
# writes per-app-id ids to /tmp/niri-focus-tracker/app-<app-id>;
# browser-personal / browser-work stash each profile's window id in
# /tmp/<class>-window-id at launch.
pick_last_focused_profile() {
    local last_id personal_id work_id
    last_id=$(cat \
        "/tmp/niri-focus-tracker/app-${BROWSER_CLASS_PERSONAL}" \
        "/tmp/niri-focus-tracker/app-${BROWSER_CLASS_WORK}" \
        2>/dev/null | tail -1)
    personal_id=$(cat "/tmp/${BROWSER_CLASS_PERSONAL}-window-id" 2>/dev/null)
    work_id=$(cat "/tmp/${BROWSER_CLASS_WORK}-window-id" 2>/dev/null)
    if [[ -n "$last_id" && "$last_id" == "$work_id" ]]; then
        echo "work"
    elif [[ -n "$last_id" && "$last_id" == "$personal_id" ]]; then
        echo "personal"
    else
        echo "personal"
    fi
}

# The "home" window for a profile — where forwarded URLs should tab in.
# All work windows share ONE Chromium instance (one --user-data-dir), so a
# forwarded URL otherwise lands in whichever work window was last active —
# usually a worktree preview, or a new window if that was an app-mode one.
# We focus this window first so the tab opens in it. Priority: the window on
# the persistent lovable-main workspace, then the stashed launch id, then any
# window not parked on a worktree stack.
main_window_id() {
    local cls="$1" stored
    stored=$(cat "/tmp/${cls}-window-id" 2>/dev/null)
    CLS="$cls" STORED="$stored" python3 -c '
import json, os, subprocess, sys
cls, stored = os.environ["CLS"], os.environ["STORED"]
def q(k): return json.loads(subprocess.run(["niri","msg","--json",k],
                                            capture_output=True, text=True).stdout)
wins = q("windows")
name = {s["id"]: (s.get("name") or "") for s in q("workspaces")}
mine = [w for w in wins if w.get("app_id") == cls]
def ws(w): return name.get(w.get("workspace_id"), "")
for w in mine:
    if ws(w) == "lovable-main": print(w["id"]); sys.exit(0)
if stored.isdigit() and any(w["id"] == int(stored) for w in mine):
    print(int(stored)); sys.exit(0)
for w in mine:
    n = ws(w)
    if not (n.startswith("lovable-") and n != "lovable-main"):
        print(w["id"]); sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# Work context is workspace-shaped: anything opened while a lovable-*
# workspace (main worktree included) is focused belongs in the work
# profile. URL rules still win — youtube stays personal everywhere.
on_work_workspace() {
    niri msg --json workspaces 2>/dev/null | python3 -c '
import json, sys
for w in json.load(sys.stdin):
    if w.get("is_focused") and (w.get("name") or "").startswith("lovable-"):
        sys.exit(0)
sys.exit(1)
'
}

if [[ -n "$FORCED_PROFILE" ]]; then
    PROFILE="$FORCED_PROFILE"
else
    PROFILE=$(pick_last_focused_profile)
    if on_work_workspace; then PROFILE="work"; fi
    if is_work_url "$URL"; then PROFILE="work"; fi
    if is_personal_url "$URL"; then PROFILE="personal"; fi
fi

# ── Browser dispatch ──────────────────────────────────────────────────────────

# Redirect stdout/stderr to /dev/null so chromium-based browsers don't
# print "Opening in existing browser session." to whatever terminal
# launched us (corrupts endcord's curses-rendered screen).

# App mode: chromeless window with a URL-derived app-id (chrome-<host>__-…).
# Deliberately NO --class — the derived app-id is what lets niri window-rules
# target these windows, and keeps them out of the browser focus tracking.
if [[ -n "$APP_MODE" ]]; then
    if [[ "$PROFILE" == "work" ]]; then
        DATA_DIR="$BROWSER_USER_DATA_WORK"
    else
        DATA_DIR="$BROWSER_USER_DATA_PERSONAL"
    fi
    exec "$BROWSER_BIN" \
        "${BROWSER_FLAGS[@]}" \
        --user-data-dir="$DATA_DIR" \
        --profile-directory="$BROWSER_PROFILE" \
        --app="$URL" >/dev/null 2>&1
fi

# For a plain forward (not an explicit new window), focus the profile's home
# window first so Chromium opens the URL as a tab THERE, not in whatever work
# window happened to be active last. All work windows share one Chromium
# instance, so the ONLY lever on which window receives a forwarded URL is
# which window Chromium considers "last active" — and that's driven by the
# compositor activating it. We must (1) confirm niri actually moved focus and
# (2) let Chromium drain the activation event before handing off, or the
# singleton still routes the URL to the previously-active (worktree) window.
if [[ -z "$NEW_WINDOW" ]]; then
    if [[ "$PROFILE" == "work" ]]; then
        TARGET=$(main_window_id "$BROWSER_CLASS_WORK")
    else
        TARGET=$(main_window_id "$BROWSER_CLASS_PERSONAL")
    fi
    if [[ -n "$TARGET" ]]; then
        niri msg action focus-window --id "$TARGET" >/dev/null 2>&1
        for _ in $(seq 1 20); do
            foc=$(niri msg --json windows 2>/dev/null | python3 -c '
import json, sys
print(next((w["id"] for w in json.load(sys.stdin) if w.get("is_focused")), ""))' 2>/dev/null)
            [[ "$foc" == "$TARGET" ]] && break
            sleep 0.05
        done
        sleep 0.4
    fi
fi

if [[ "$PROFILE" == "work" ]]; then
    exec "$BROWSER_BIN" \
        "${BROWSER_FLAGS[@]}" \
        "${BROWSER_FLAGS_WORK[@]}" \
        --user-data-dir="$BROWSER_USER_DATA_WORK" \
        --profile-directory="$BROWSER_PROFILE" \
        --class="$BROWSER_CLASS_WORK" \
        $NEW_WINDOW "$URL" >/dev/null 2>&1
else
    exec "$BROWSER_BIN" \
        "${BROWSER_FLAGS[@]}" \
        --user-data-dir="$BROWSER_USER_DATA_PERSONAL" \
        --profile-directory="$BROWSER_PROFILE" \
        --class="$BROWSER_CLASS_PERSONAL" \
        $NEW_WINDOW "$URL" >/dev/null 2>&1
fi
