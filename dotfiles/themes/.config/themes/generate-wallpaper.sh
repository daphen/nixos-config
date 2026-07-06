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
CELLS="10x6" ANCHORS="4" ANCHOR_SPEC=""
STYLE="mesh" ANGLE="35" STREAK="120" ABERRATION="6"

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
        --cells)    CELLS="$2"; shift 2 ;;
        --anchors)  ANCHORS="$2"; shift 2 ;;
        --anchor-spec) ANCHOR_SPEC="$2"; shift 2 ;;
        --style)    STYLE="$2"; shift 2 ;;
        --angle)    ANGLE="$2"; shift 2 ;;
        --streak)   STREAK="$2"; shift 2 ;;
        --aberration) ABERRATION="$2"; shift 2 ;;
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
    python3 - "$mode" "$SEED" "$seedpng" "$CELLS" "$ANCHORS" "$ANCHOR_SPEC" "$STYLE" <<'EOPY'
import json, os, random, struct, sys, zlib

mode, seed, out, cells, n_anchors = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
anchor_spec = sys.argv[6] if len(sys.argv) > 6 else ""
style = sys.argv[7] if len(sys.argv) > 7 else "mesh"
GW, GH = (int(v) for v in cells.split("x"))
if style == "streaks":
    # small hot points, not fields — dense grid so cores stay tight
    GW, GH = GW * 4, GH * 4
themes = json.load(open(os.path.expanduser("~/.config/themes/colors.json")))["themes"][mode]
bg, acc = themes["background"], themes["accent"]

def c(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

# Anchor pool: base tones first so at least one anchor grounds the image,
# accents after — spatial interpolation between anchors is what makes the
# result read as ONE flowing gradient instead of isolated blobs.
if mode == "dark":
    pool = [c(bg["primary"]), c(bg["overlay"]), c(bg["prompt"]),
            c(acc["orange"]), c(acc["green"]), c(bg["primary"])]
else:
    pool = [c(bg["primary"]), c(bg["tertiary"]), c(bg["overlay"]),
            c(acc["yellow"]), c(acc["green"]), c(bg["primary"])]

rng = random.Random(seed if mode == "dark" else seed + 1)
base = c(bg["primary"])
if style == "streaks":
    # Chroma look: near-black stage, hot chromatic points. The magick pass
    # stretches these into light streaks.
    base = tuple(round(v * 0.25) for v in c(bg["primary"])) if mode == "dark" else c(bg["primary"])
    # white light reads on a dark stage; on white paper it's invisible, so
    # light mode streaks are pure chroma.
    hot = [(255, 255, 255)] if mode == "dark" else []
    hot.append(c(acc["orange"]))
    for k in ("sky", "blue", "cyan", "green"):
        if k in acc:
            hot.append(c(acc[k]))
    pool = ([base, base] + hot) if mode == "dark" else hot

anchors = []
if anchor_spec:
    # Explicit "x,y,#hex,size;…" from the studio editor — colors used as
    # given, size scales the anchor's influence radius.
    for part in anchor_spec.split(";"):
        if not part.strip():
            continue
        ax, ay, col, size = part.split(",")
        sz = float(size) * (0.45 if style == "streaks" else 1.0)
        anchors.append((float(ax), float(ay), c(col), sz))
for i in range(max(2, n_anchors)) if not anchor_spec else []:
    col = pool[0] if i == 0 else rng.choice(pool)
    # soften accents toward base so they glow rather than shout — but on a
    # white base softening IS erasing, so light mode keeps far more of the
    # accent than dark does.
    if col == pool[0]:
        t = 1.0
    elif style == "streaks":
        t = rng.uniform(0.85, 1.0)   # streak light stays chromatic
    elif mode == "dark":
        t = rng.uniform(0.35, 0.75)
    else:
        t = rng.uniform(0.65, 1.0)
    col = tuple(base[k] + (col[k] - base[k]) * t for k in range(3))
    if style == "streaks":
        # a couple of large dark stage anchors, the rest tight hot cores
        sz = 1.6 if i < 2 else rng.uniform(0.16, 0.32)
        if i < 2:
            col = base
        anchors.append((rng.random(), rng.random(), col, sz))
    else:
        anchors.append((rng.random(), rng.random(), col, 1.0))

rows = []
for y in range(GH):
    row = bytearray([0])
    for x in range(GW):
        u = x / max(1, GW - 1); v = y / max(1, GH - 1)
        if style == "streaks":
            # additive glows on a dark stage: each anchor contributes
            # exp-falloff light, everything else stays black — normalized
            # weighting would hand each anchor a whole bright region.
            import math
            acc = [float(b) for b in base]
            for ax, ay, col, size in anchors:
                d2 = (u - ax) ** 2 + (v - ay) ** 2
                g = math.exp(-d2 / (0.014 * size * size + 1e-6))
                for k in range(3):
                    acc[k] += (col[k] - base[k]) * g
            px = tuple(min(255, max(0, round(acc[k]))) for k in range(3))
        else:
            num = [0.0, 0.0, 0.0]; den = 0.0
            for ax, ay, col, size in anchors:
                d2 = (u - ax) ** 2 + (v - ay) ** 2
                w = (size * size) / (d2 + 0.02)
                den += w
                for k in range(3):
                    num[k] += col[k] * w
            px = tuple(min(255, max(0, round(num[k] / den + rng.uniform(-6, 6)))) for k in range(3))
        row += bytes(px)
    rows.append(bytes(row))

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", GW, GH, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"".join(rows)))
       + chunk(b"IEND", b""))
open(out, "wb").write(png)
EOPY

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
    if [[ "$STYLE" == "streaks" ]]; then
        # Chroma: ripple the hot points, stretch them into light with a long
        # directional motion blur (+ a shorter counter-pass for depth), split
        # the channels a few px for chromatic fringes, then crush the blacks.
        local ab_s squash
        ab_s=$(awk "BEGIN{printf \"%d\", $ABERRATION*$sc + 0.5}")
        (( ab_s < 1 )) && ab_s=1
        # Streak length -> horizontal squash/stretch smear factor. Smear on
        # the X axis (no rotation bookkeeping), then rotate the FINISHED
        # streaked image and center-crop from a 1.6x oversized render so
        # the rotation fill never reaches the crop.
        squash=$(awk "BEGIN{f=$STREAK/2; if(f<10)f=10; if(f>200)f=200; printf \"%.1f\", f}")
        local pct unpct RW RH
        pct=$(awk "BEGIN{printf \"%.3f\", 100/$squash}")
        unpct=$(awk "BEGIN{printf \"%.3f\", $squash*100}")
        RW=$(( W * 2 )); RH=$(( H * 2 + 2 * pad ))
        # Finishing is asymmetric: dark lifts faint light out of black;
        # light keeps the paper white and deepens the chromatic ink.
        local finish_args
        if [[ "$mode" == "dark" ]]; then
            finish_args=(-level "0%,22%" -sigmoidal-contrast 5x22% -modulate 100,140)
        else
            finish_args=(-level "0%,100%,0.5" -sigmoidal-contrast 4x72% -modulate 100,150)
        fi
        magick "$seedpng" \
            -filter Gaussian -resize "${RW}x${RH}!" \
            -background "$base_hex" -virtual-pixel Mirror \
            -filter Gaussian -resize "${pct}%x100%!" -resize "${RW}x${RH}!" \
            -wave "${amp_s}x${len_s}" \
            -swirl "$swirl" \
            -rotate "$ANGLE" \
            -gravity center -crop "${W}x${H}+0+0" +repage \
            \( -clone 0 -channel R -separate +channel -roll "+${ab_s}+0" \) \
            \( -clone 0 -channel G -separate +channel \) \
            \( -clone 0 -channel B -separate +channel -roll "-${ab_s}+0" \) \
            -delete 0 -combine \
            "${finish_args[@]}" \
            "${grain_args[@]}" \
            "$out"
    else
        magick "$seedpng" \
            -filter Gaussian -resize "${W}x$(( H + 2 * pad ))!" \
            -background "$base_hex" -virtual-pixel Mirror \
            -wave "${amp_s}x${len_s}" \
            -swirl "$swirl" \
            -blur "0x${blur_s}" \
            -gravity center -crop "${W}x${H}+0+0" +repage \
            "${grain_args[@]}" \
            "$out"
    fi
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
