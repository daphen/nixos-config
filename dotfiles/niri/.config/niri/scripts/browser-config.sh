#!/usr/bin/env bash
# Single source of truth for the daily browser. Sourced by
# browser-personal, browser-work, browser-dispatch, chromium-launch,
# browser-work-new, and sync-bookmarks.
#
# Profiles run as separate processes via --user-data-dir so Chromium's
# "first-launch wins" --class quirk doesn't apply: each profile has
# its own master process and gets its own --class correctly. Side
# benefits: theme/extension restarts only affect one profile, force-
# quitting work doesn't kill personal, etc.
#
# Tested switches: Vivaldi ↔ Helium (both Chromium-based, identical
# CLI). Brave/Chrome/Edge would also work. Firefox needs different
# launcher logic (no --class, profile flag is -P) so this config
# isn't enough for that switch.

# Path to the browser binary.
BROWSER_BIN="/etc/profiles/per-user/daphen/bin/helium"

# File dialogs via the portal (termfilechooser → yazi-in-kitty). Set here
# because niri-spawned processes don't see home.sessionVariables until
# re-login; every launcher sources this file.
export GTK_USE_PORTAL=1

# Wayland app-id assigned via --class. KEPT STABLE across browser
# switches (it's just a label) so niri window-rules and ws-focus's
# BROWSER_CLASSES never need to change.
BROWSER_CLASS_PERSONAL="browser-personal"
BROWSER_CLASS_WORK="browser-work"

# Per-profile data dirs. Each is its own Chromium "data root" with a
# Default/ subdir inside. The pre-split layout had everything under
# ~/.config/net.imput.helium/{Default, Profile 2} — that's preserved
# only as a migration source.
BROWSER_USER_DATA_PERSONAL="$HOME/.config/helium-personal"
BROWSER_USER_DATA_WORK="$HOME/.config/helium-work"

# Profile-directory name INSIDE each data-dir. Always "Default" now
# that we have separate data-dirs per profile.
BROWSER_PROFILE="Default"

# sync-bookmarks compatibility: previously a single CONFIG_ROOT pointed
# at the shared data-dir. Keep it pointing at the personal data-dir
# since that's where the synced Bookmarks live (work profile doesn't
# use the bookmark sync workflow).
BROWSER_CONFIG_ROOT="$BROWSER_USER_DATA_PERSONAL"

# Bare process name for `pgrep` (used by sync-bookmarks to detect a
# running browser before overwriting Bookmarks). Browser-specific.
BROWSER_PROCESS_NAME="helium"

# Flags passed to every Helium invocation. Disable AsyncDns so the
# browser uses glibc's resolver instead of its own — glibc honors the
# unloaded-IPv6-module state and skips ::1; the built-in resolver
# adds it via RFC 6761 and pays a Happy Eyeballs penalty per fetch.
# Features disabled for EVERY profile. Kept as a variable so the work profile can
# extend it — Chromium takes the LAST --disable-features occurrence, so the work
# launcher passes a SUPERSET of this list rather than a second, competing flag.
BROWSER_DISABLE_FEATURES="AsyncDns"

# Work profile only: the authenticated browser that Playwright drives.
#   * remote-debugging-port — a stable CDP endpoint, so agents attach to THIS
#     already-signed-in instance instead of cloning the profile (cookies are
#     encrypted against the real keyring and unreadable in a copy).
#   * Local/Private Network Access — an HTTPS sandbox origin must be allowed to
#     fetch the loopback branch runtime (http://localhost:8001/lovable.js), or the
#     runtime never executes and every measurement reflects the default tile.
# Loopback-bound, work profile only: the personal browser never gets a CDP port.
BROWSER_CDP_PORT="${COCKPIT_CERT_CDP_PORT:-9333}"
BROWSER_FLAGS_WORK=(
    --remote-debugging-port="$BROWSER_CDP_PORT"
    --remote-allow-origins=*
    --disable-features="$BROWSER_DISABLE_FEATURES,LocalNetworkAccessChecks,PrivateNetworkAccessSendPreflights,PrivateNetworkAccessRespectPreflightResults"
)

BROWSER_FLAGS=(
    --disable-features="$BROWSER_DISABLE_FEATURES"
    # Run natively on Wayland (niri) instead of XWayland. Without this
    # Chromium defaults to X11 ozone, so getDisplayMedia uses the X11
    # capturer — which has no real desktop to grab under niri, breaking
    # full-screen/window share. Wayland ozone routes capture through the
    # xdg-desktop-portal ScreenCast picker instead.
    --ozone-platform-hint=auto
    # Netflix (and other adaptive players) dump bitrate when Chromium marks
    # an unfocused window occluded/backgrounded — Wayland occlusion detection
    # misfires for visible-but-unfocused surfaces, so video playing next to
    # your work degrades to ~480p. Keep unfocused windows first-class.
    --disable-backgrounding-occluded-windows
    --disable-renderer-backgrounding
    # NOTE: --disable-background-timer-throttling was REMOVED. With it, a hidden/
    # unfocused tab's timers (incl. video decode) ran full-tilt — a background YouTube
    # tab silently software-decoded VP9 at ~90% of a core (the ~1%/min battery drain).
    # Background tabs now throttle normally. The two flags above still keep *visible*
    # unfocused windows first-class for Netflix-style adaptive bitrate.
    #
    # (HW video decode via VA-API isn't enabled here: on this hybrid NVIDIA+AMD + ANGLE
    # + Wayland setup the VA-API→GL frame import silently falls back to software, and
    # flags alone didn't fix it — revisit as its own task if it matters.)
)

# Point GLib at gsettings-desktop-schemas so Chromium's GTK theme code
# (and the org.freedesktop.appearance portal route) can resolve
# color-scheme on each launch. Needed until niri itself inherits this
# via home-manager session vars (next login).
if [ -z "${GSETTINGS_SCHEMA_DIR:-}" ]; then
    _schema=$(echo /nix/store/*-gsettings-desktop-schemas-*/share/gsettings-schemas/gsettings-desktop-schemas-*/glib-2.0/schemas 2>/dev/null | tr ' ' '\n' | grep -v '*' | head -1)
    [ -n "$_schema" ] && [ -d "$_schema" ] && export GSETTINGS_SCHEMA_DIR="$_schema"
fi
