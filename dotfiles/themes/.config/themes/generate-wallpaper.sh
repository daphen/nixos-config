#!/usr/bin/env bash
# Shader-style grainy mesh-gradient wallpapers, generated from colors.json.
#
#   generate-wallpaper.sh [light|dark|both] [--seed N] [--size WxH] [--set]
#
# Pipeline: a tiny seed grid of weighted palette colors (python stdlib PNG)
# is blown up to full size (gaussian filter = smooth mesh blend), liquified
# with wave+swirl distortions, then finished with soft film grain. --set
# points the theme wallpaper symlink at the result and applies via waypaper.
set -euo pipefail

THEMES_DIR="$HOME/.config/themes"
COLORS_FILE="$THEMES_DIR/colors.json"
OUT_DIR="$HOME/Pictures/Wallpapers/generated"
MODE="${1:-both}"
SEED=$RANDOM
SIZE="3840x2400"
SET_LINK=0
# Optional explicit knobs — default to seed-derived when empty.
WAVE_AMP="" WAVE_LEN="" SWIRL="" BLUR="" GRAIN="" OUT=""

shift $(( $# > 0 ? 1 : 0 )) || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) SEED="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --set)  SET_LINK=1; shift ;;
        --wave-amp) WAVE_AMP="$2"; shift 2 ;;
        --wave-len) WAVE_LEN="$2"; shift 2 ;;
        --swirl)    SWIRL="$2"; shift 2 ;;
        --blur)     BLUR="$2"; shift 2 ;;
        --grain)    GRAIN="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$OUT_DIR"
W="${SIZE%x*}"; H="${SIZE#*x}"

gen_one() {
    local mode="$1"
    local out="${OUT:-$OUT_DIR/mesh-$mode-$SEED.png}"
    local seedpng
    seedpng="$(mktemp --suffix=.png)"

    # Weighted palette: mostly background tones so the accents read as
    # soft glows, not a color explosion.
    python3 - "$mode" "$SEED" "$seedpng" <<'PY'
import json, os, random, struct, sys, zlib

mode, seed, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
themes = json.load(open(os.path.expanduser("~/.config/themes/colors.json")))["themes"][mode]
bg, acc = themes["background"], themes["accent"]

def c(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

if mode == "dark":
    weighted = ([c(bg["primary"])] * 10 + [c(bg["overlay"])] * 4
                + [c(bg["prompt"])] * 2 + [c(acc["orange"])] * 1
                + [c(acc["green"])] * 1)
else:
    weighted = ([c(bg["primary"])] * 8 + [c(bg["tertiary"])] * 5
                + [c(bg["overlay"])] * 3 + [c(acc["yellow"])] * 1
                + [c(acc["green"])] * 1)

rng = random.Random(seed if mode == "dark" else seed + 1)
W, H = 10, 6
base = c(bg["primary"])
rows = []
for y in range(H):
    row = bytearray([0])
    for x in range(W):
        px = rng.choice(weighted)
        # pull every point toward the base so accents glow instead of shout
        t = rng.uniform(0.35, 0.8)
        px = tuple(round(base[i] + (px[i] - base[i]) * t) for i in range(3))
        row += bytes(px)
    rows.append(bytes(row))

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"".join(rows)))
       + chunk(b"IEND", b""))
open(out, "wb").write(png)
PY

    # Liquify + grain. Wave/swirl parameters keyed off the seed so each
    # run has its own flow. -wave grows the canvas and fills the new bands
    # with -background (white by default!), so render oversized in the
    # mode's base color and center-crop the target out of the middle.
    local base_hex
    base_hex=$(jq -r ".themes.$mode.background.primary" "$COLORS_FILE")
    local wave_amp="${WAVE_AMP:-$(( 30 + SEED % 50 ))}"
    local wave_len="${WAVE_LEN:-$(( 1200 + SEED % 900 ))}"
    local swirl="${SWIRL:-$(( 15 + SEED % 40 ))}"
    local blur="${BLUR:-80}"
    local grain="${GRAIN:-0.12}"
    # Knobs are calibrated at 3840 wide; scale them to the render size so a
    # small preview looks like the final.
    local sc; sc=$(awk "BEGIN{printf \"%.4f\", $W/3840}")
    local amp_s len_s blur_s
    amp_s=$(awk "BEGIN{printf \"%d\", $wave_amp*$sc + 0.5}")
    len_s=$(awk "BEGIN{printf \"%d\", $wave_len*$sc + 0.5}")
    blur_s=$(awk "BEGIN{printf \"%.1f\", $blur*$sc}")
    (( amp_s < 1 )) && amp_s=1
    (( len_s < 8 )) && len_s=8
    local pad=$(( amp_s * 2 + 60 ))
    local grain_args=(-attenuate "$grain" +noise Gaussian)
    [[ "$grain" == "0" || "$grain" == "0.0" ]] && grain_args=()
    magick "$seedpng" \
        -filter Gaussian -resize "${W}x$(( H + 2 * pad ))!" \
        -background "$base_hex" -virtual-pixel Mirror \
        -wave "${amp_s}x${len_s}" \
        -swirl "$swirl" \
        -blur "0x${blur_s}" \
        -gravity center -crop "${W}x${H}+0+0" +repage \
        "${grain_args[@]}" \
        "$out"
    rm -f "$seedpng"
    echo "$out"

    if [[ "$SET_LINK" == 1 ]]; then
        ln -sf "$out" "$THEMES_DIR/wallpaper-$mode"
        if [[ "$(cat "$HOME/.config/theme_mode" 2>/dev/null)" == "$mode" ]] && command -v waypaper &>/dev/null; then
            waypaper --wallpaper "$out" &>/dev/null &
        fi
    fi
}

case "$MODE" in
    light|dark) gen_one "$MODE" ;;
    both) gen_one "dark"; gen_one "light" ;;
    *) echo "usage: generate-wallpaper.sh [light|dark|both] [--seed N] [--size WxH] [--set]" >&2; exit 1 ;;
esac
