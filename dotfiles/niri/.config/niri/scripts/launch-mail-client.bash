#!/usr/bin/env bash
# Launch the native QML mail client. The packaged mlqs-client wrapper ensures
# the mlqs daemon is running, then opens the Quickshell UI from the Nix store.
# niri-jump-or-exec focuses an existing window instead of calling this.
export QML2_IMPORT_PATH="$HOME/.local/share/qml"
# Route Qt file dialogs (Save-as for attachment downloads) through the
# xdg portal, where termfilechooser serves them as yazi-in-kitty.
export QT_QPA_PLATFORMTHEME=xdgdesktopportal
export PATH="$HOME/.local/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$PATH"


# Replace a stale daemon: after a rebuild the running mlqs may be an older
# store build. pgrep by name — a full /proc sweep costs ~2s of forks.
CURRENT=$(readlink -f "$(command -v mlqs)" 2>/dev/null)
KILLED=""
for pid in $(pgrep -x mlqs 2>/dev/null); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
    if [ -n "$CURRENT" ] && [ "$exe" != "$CURRENT" ]; then
        kill "$pid" 2>/dev/null && KILLED="$KILLED $pid"
    fi
done

# Wait for the killed daemon to actually exit — the wrapper below checks for a
# running daemon, and a dying process (graceful shutdown takes ~1s) would make
# it skip the restart, leaving the UI with no daemon at all.
for pid in $KILLED; do
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    # still up after 5s of SIGTERM patience — force it, a half-dead daemon
    # makes the wrapper below skip the restart and the UI comes up empty
    kill -9 "$pid" 2>/dev/null || true
done


# The -p config dir of one process, absolute. May be RELATIVE on the command line
# (`qs -p ui` from the repo, as a QML load test does) — such a process has no "mlqs"
# anywhere in argv, so resolve against its cwd or the strays a dev session leaves
# behind stay invisible to every reap here.
_mlqs_ui_cfg() {
  local pid="$1" cfg="" prev="" a cwd
  while IFS= read -r -d '' a; do
    if [ "$prev" = "-p" ]; then cfg="$a"; break; fi
    prev="$a"
  done < "/proc/$pid/cmdline" 2>/dev/null
  [ -n "$cfg" ] || return 1
  case "$cfg" in
    /*) ;;
    *) cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 1; cfg="$cwd/$cfg" ;;
  esac
  printf '%s' "$cfg"
}

# Every quickshell process serving the mlqs UI, oldest first.
_mlqs_ui_pids() {
  local p pid comm cfg
  for p in /proc/[0-9]*; do
    # Shortlist on comm with a BUILTIN read — no fork. Doing readlink/tr for every
    # /proc entry costs ~2.5s on this box (≈700 procs), and this runs before every
    # summon, so it has to stay in the millisecond range.
    # 2>/dev/null on the redirect itself: a process exiting mid-sweep makes the
    # open fail, and bash reports that on stderr before `|| continue` is reached
    { read -r comm < "$p/comm"; } 2>/dev/null || continue
    case "$comm" in *quickshell*) ;; *) continue ;; esac
    pid=${p#/proc/}
    cfg=$(_mlqs_ui_cfg "$pid")
    [ -n "$cfg" ] || continue
    case "${cfg%/}" in *mlqs/ui) echo "$(awk '{print $22}' "$p/stat" 2>/dev/null) $pid" ;; esac
  done | sort -n | awk '{print $2}'
}

# Pids that currently own a window titled "mlqs". A crashed quickshell re-execs
# WITHOUT its -p arguments but keeps its window mapped, so the config-path lookup
# below cannot see it — and such an orphan then maps a second window on every
# summon. niri knows who owns the window, so ask it.
_mlqs_win_pids() {
  niri msg --json windows 2>/dev/null | python3 -c '
import json, sys
try: ws = json.load(sys.stdin)
except Exception: sys.exit(0)
for w in ws:
    if (w.get("title") or "") == "mlqs" and w.get("pid"):
        print(w["pid"])
' 2>/dev/null
}

# Collapse to ONE warm UI *before* summoning. summonui is a BROADCAST: every
# connected client maps a window, so N stray UIs mean N windows on one keypress.
# The orphan reap further down cannot help — the summon path exits as soon as the
# first window maps and never reaches it.
#
# Kill by BUILD, not by age: after a rebuild a stale-build UI is still connected and
# will map on the next summon, and "newest process" is not "current build" — a
# lingering old one that happened to start later would survive and the fresh one
# would be killed. Same test the daemon replacement above uses.
CUR_UI=""
if [ -n "$CURRENT" ]; then CUR_UI="${CURRENT%/bin/mlqs}/share/mlqs/ui"; fi
# Union of both views: processes serving the current UI dir, AND anything holding an
# mlqs window (which catches crash orphans that lost their -p).
mapfile -t MLQS_UIS < <({ _mlqs_ui_pids; _mlqs_win_pids; } | awk '!seen[$0]++')
KEEP=""
for pid in "${MLQS_UIS[@]}"; do
  [ -d "/proc/$pid" ] || continue
  if [ -n "$CUR_UI" ] && [ "$(_mlqs_ui_cfg "$pid")" = "$CUR_UI" ]; then
    KEEP="$pid"                   # a current-build UI; last one wins
  fi
done
for pid in "${MLQS_UIS[@]}"; do
  [ -d "/proc/$pid" ] || continue
  # anything that is not THE kept current-build UI must not survive to be summoned:
  # a stale build, a working copy, or a crash orphan with no -p at all
  [ "$pid" = "$KEEP" ] || kill "$pid" 2>/dev/null
done

# Warm summon: q hides the UI (the process stays warm) — poke the daemon,
# which broadcasts to the hidden window; it remaps in ~100ms. Fall through
# to a cold start only when no window appears.
if printf '{"type":"summonui"}\n' | python3 -c '
import socket, sys, os
s = socket.socket(socket.AF_UNIX)
s.settimeout(0.5)
s.connect(os.environ["XDG_RUNTIME_DIR"] + "/mlqs.sock")
s.sendall(sys.stdin.buffer.read())
' 2>/dev/null; then
    for _ in $(seq 1 12); do
        if niri msg --json windows 2>/dev/null | grep -q '"title": *"mlqs"'; then
            exit 0
        fi
        sleep 0.05
    done
fi

# Reap windowless mlqs UI orphans (failed config load leaves quickshell alive
# without a window, blocking niri-jump-or-exec).
WIN_PIDS=" $(niri msg --json windows 2>/dev/null | python3 -c 'import json,sys;[print(w.get("pid")) for w in json.load(sys.stdin)]' 2>/dev/null | tr "\n" " ") "
for pid in $(_mlqs_ui_pids); do
    case "$WIN_PIDS" in *" $pid "*) ;; *) kill "$pid" 2>/dev/null ;; esac
done

exec mlqs-client >> /tmp/mlqs-ui.log 2>&1
