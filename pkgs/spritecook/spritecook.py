#!/usr/bin/env python3
"""spritecook: AI first drafts for pixel-art sprites, finished by hand in Aseprite."""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

SHARE = Path(os.environ.get("SPRITECOOK_SHARE", Path(__file__).parent))
ASEPRITE = os.environ.get("SPRITECOOK_ASEPRITE", "aseprite")
CACHE = Path.home() / ".cache/spritecook"
STYLE = (
    "pixel art game sprite, crisp hard-edged square pixels, bold dark 1px outline, flat cel shading "
    "lit from the top left, limited palette, no anti-aliasing, no gradients, no text, no shadow, "
    "centered on a plain flat solid white background"
)


def fail(message):
    sys.exit(f"spritecook: {message}")


# Grid detection and cleanup


def edge_profile(img, axis):
    diff = np.abs(np.diff(img, axis=axis)).sum(axis=2)
    return diff.sum(axis=1 - axis)


def find_grid(profile, smin=4.0, smax=48.0):
    # The FFT finds the period robustly; a phase search then refines it locally.
    n = len(profile)
    spectrum = np.abs(np.fft.rfft(profile - profile.mean()))
    freqs = np.arange(len(spectrum))
    valid = (freqs > 0) & (freqs >= n / smax) & (freqs <= n / smin)
    coarse = n / freqs[valid][np.argmax(spectrum[valid])]
    mean = profile.mean() + 1e-9
    best = (-1.0, coarse, 0.0)
    for size in np.arange(coarse * 0.95, coarse * 1.05, 0.02):
        for phase in np.linspace(0, size, int(8 * size), endpoint=False):
            idx = np.round(np.arange(phase, n, size)).astype(int)
            best = max(best, (profile[idx[idx < n]].mean() / mean, size, phase))
    return best[1], best[2]


def detect_grid(img):
    sx, px = find_grid(edge_profile(img, 1))
    sy, py = find_grid(edge_profile(img, 0))
    return sx, px, sy, py


def sample_cells(img, grid):
    sx, px, sy, py = grid
    h, w, _ = img.shape
    xs = np.arange(px % sx - sx, w, sx)
    ys = np.arange(py % sy - sy, h, sy)
    xs, ys = xs[xs + sx * 0.5 > 0], ys[ys + sy * 0.5 > 0]
    out = np.full((len(ys), len(xs), 3), 255.0)
    for j, y0 in enumerate(ys):
        for i, x0 in enumerate(xs):
            a0, a1 = int(max(0, y0 + sy * 0.25)), int(min(h, y0 + sy * 0.75))
            b0, b1 = int(max(0, x0 + sx * 0.25)), int(min(w, x0 + sx * 0.75))
            patch = img[a0:max(a1, a0 + 1), b0:max(b1, b0 + 1)].reshape(-1, 3)
            if len(patch):
                out[j, i] = np.median(patch, axis=0)
    return out


def cut_background(cells, tolerance):
    h, w, _ = cells.shape
    border = np.concatenate([cells[0], cells[-1], cells[:, 0], cells[:, -1]])
    bg = np.median(border, axis=0)
    distance = np.sqrt(((cells - bg) ** 2).sum(2))
    near = distance < tolerance
    alpha = np.ones((h, w), bool)
    queue = deque((y, x) for y in range(h) for x in range(w) if (y in (0, h - 1) or x in (0, w - 1)) and near[y, x])
    for y, x in queue:
        alpha[y, x] = False
    while queue:
        y, x = queue.popleft()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < h and 0 <= nx < w and alpha[ny, nx] and near[ny, nx]:
                alpha[ny, nx] = False
                queue.append((ny, nx))
    # Models paint a one-cell tinted fringe between outline and background; peel it once with a looser match.
    padded = np.pad(alpha, 1, constant_values=True)
    touches_bg = ~(padded[:-2, 1:-1] & padded[2:, 1:-1] & padded[1:-1, :-2] & padded[1:-1, 2:])
    alpha &= ~(touches_bg & (distance < tolerance * 2))
    for _ in range(2):
        padded = np.pad(alpha, 1)
        neighbours = padded[:-2, 1:-1].astype(int) + padded[2:, 1:-1] + padded[1:-1, :-2] + padded[1:-1, 2:]
        alpha &= neighbours >= 2
    return alpha


def oklab(rgb):
    c = rgb / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    lms = np.cbrt(c @ np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                                [0.2119034982, 0.6806995451, 0.1073969566],
                                [0.0883024619, 0.2817188376, 0.6299787005]]).T)
    return lms @ np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                           [1.9779984951, -2.4285922050, 0.4505937099],
                           [0.0259040371, 0.7827717662, -0.8086757660]]).T


def snap(colors, palette):
    distance = ((oklab(colors)[:, None] - oklab(palette)[None]) ** 2).sum(2)
    return palette[np.argmin(distance, axis=1)]


def neighbours4(mask):
    p = np.pad(mask, 1)
    return p[:-2, 1:-1], p[2:, 1:-1], p[1:-1, :-2], p[1:-1, 2:]


def patch_outline(cells, alpha):
    if not alpha.any():
        return cells, alpha
    luma = cells @ np.array([0.299, 0.587, 0.114])
    outline = cells[alpha][np.argmin(luma[alpha])]
    # Fringe specks sit outside the dark outline: light, touching it, with no light neighbour inside.
    for _ in range(2):
        dark, light = alpha & (luma <= 70), alpha & (luma > 70)
        touches_dark = np.logical_or.reduce(neighbours4(dark))
        touches_light = np.logical_or.reduce(neighbours4(light))
        outside = ~np.logical_and.reduce(neighbours4(alpha))
        alpha = alpha & ~(light & outside & touches_dark & ~touches_light)
    bright = np.pad(alpha & (luma > 70), 1)
    ring = ~alpha & (bright[:-2, 1:-1] | bright[2:, 1:-1] | bright[1:-1, :-2] | bright[1:-1, 2:])
    cells = cells.copy()
    cells[ring] = outline
    return cells, alpha | ring


def despeckle(cells, alpha):
    """Merge lone low-contrast pixels into the closest neighbouring colour so shading reads as clusters.

    High-contrast lone pixels (eye glints, sparks) are deliberate and stay for the artist to judge."""
    h, w = alpha.shape
    out = cells.copy()
    lab = np.zeros_like(cells)
    lab[alpha] = oklab(cells[alpha])
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if not alpha[y, x]:
                continue
            window = alpha[y - 1:y + 2, x - 1:x + 2].copy()
            window[1, 1] = False
            if window.sum() < 3:
                continue
            around = cells[y - 1:y + 2, x - 1:x + 2][window]
            if (around == cells[y, x]).all(1).any():
                continue
            distance = np.sqrt(((lab[y - 1:y + 2, x - 1:x + 2][window] - lab[y, x]) ** 2).sum(1))
            if distance.min() < 0.15:
                out[y, x] = around[np.argmin(distance)]
    return out


def clean(img, palette, grid, tolerance):
    cells = sample_cells(img, grid)
    alpha = cut_background(cells, tolerance)
    cells[alpha] = snap(cells[alpha], palette)
    for _ in range(3):
        cells = despeckle(cells, alpha)
    return patch_outline(cells, alpha)


def bbox(alpha):
    ys, xs = np.where(alpha)
    if not len(ys):
        fail("nothing left after removing the background; try a lower --tolerance")
    return ys.min(), ys.max() + 1, xs.min(), xs.max() + 1


def scaled(grid, factor):
    sx, px, sy, py = grid
    return sx * factor, px, sy * factor, py


def place(cells, alpha, size):
    labels, count = components(alpha)
    sizes = np.bincount(labels.ravel(), minlength=count + 1)
    alpha = alpha & (sizes[labels] >= 3)
    y0, y1, x0, x1 = bbox(alpha)
    cells, alpha = cells[y0:y1, x0:x1], alpha[y0:y1, x0:x1]
    h, w = alpha.shape
    canvas = np.zeros((size, size, 4), np.uint8)
    centroid = np.where(alpha)[1].mean()
    left = int(np.clip(round(size / 2 - centroid), 0, size - w))
    top = max(0, size - 1 - h)
    region = canvas[top:top + h, left:left + w]
    region[alpha] = np.concatenate([cells[alpha], np.full((int(alpha.sum()), 1), 255)], axis=1)
    return canvas


def fit_grid(img, palette, size, tolerance, height=None):
    """Grid whose cleaned sprite fits the canvas, optionally matching a reference height."""
    grid = detect_grid(img)
    for _ in range(4):
        cells, alpha = clean(img, palette, grid, tolerance)
        y0, y1, x0, x1 = bbox(alpha)
        factor = max((y1 - y0) / (size - 2), (x1 - x0) / size, 1.0)
        if height:
            factor = max(factor, (y1 - y0) / height) if abs((y1 - y0) / height - 1) > 0.08 else factor
        if factor <= 1.02:
            return grid, cells, alpha
        grid = scaled(grid, factor)
    return grid, *clean(img, palette, grid, tolerance)


# Projects, palettes and Aseprite


def load_project(directory):
    config = Path(directory) / "spritecook.json"
    if not config.exists():
        fail(f"{directory} is not a spritecook project (no spritecook.json); run `spritecook new` first")
    data = json.loads(config.read_text())
    return Path(directory), data["size"], read_palette(Path(directory) / "palette.gpl")


def read_palette(path):
    rows = [line.split()[:3] for line in path.read_text().splitlines()[1:] if line[:1].isdigit() or line[:1] == " "]
    return np.array([[float(v) for v in row] for row in rows if len(row) == 3])


def fetch_palette(name):
    source = Path(name)
    if source.exists():
        text = source.read_text()
    else:
        cached = CACHE / "palettes" / f"{name}.hex"
        if not cached.exists():
            try:
                with urllib.request.urlopen(f"https://lospec.com/palette-list/{name}.hex", timeout=20) as response:
                    cached.parent.mkdir(parents=True, exist_ok=True)
                    cached.write_bytes(response.read())
            except urllib.error.URLError as error:
                fail(f"could not download Lospec palette '{name}': {error}")
        text = cached.read_text()
    if text.startswith("GIMP Palette"):
        return text
    colours = [line.strip().lstrip("#") for line in text.splitlines() if len(line.strip().lstrip("#")) == 6]
    if not colours:
        fail(f"palette '{name}' has no colours")
    rows = "\n".join(f"{int(c[0:2], 16):3d} {int(c[2:4], 16):3d} {int(c[4:6], 16):3d}\t#{c}" for c in colours)
    return f"GIMP Palette\nName: {source.stem}\n#\n{rows}\n"


def aseprite(*args):
    result = subprocess.run([ASEPRITE, "-b", *args], capture_output=True, text=True)
    if result.returncode:
        fail(f"aseprite failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def write_frames(project, sprite, frames, tag, append):
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, frame in enumerate(frames):
            path = Path(tmp) / f"{i:03d}.png"
            Image.fromarray(frame, "RGBA").save(path)
            paths.append(str(path))
        listing = Path(tmp) / "frames.txt"
        listing.write_text("\n".join(paths) + "\n")
        aseprite(
            "--script-param", f"out={sprite}",
            "--script-param", f"list={listing}",
            "--script-param", f"palette={project / 'palette.gpl'}",
            "--script-param", f"size={frames[0].shape[0]}",
            "--script-param", f"tag={tag}",
            "--script-param", f"append={1 if append else 0}",
            "--script", str(SHARE / "build.lua"),
        )


# OpenAI image generation


def generate(prompt, quality, size, ref=None):
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        fail("OPENAI_API_KEY is not set")
    fields = {"model": "gpt-image-2", "prompt": prompt, "size": size, "quality": quality, "output_format": "png"}
    if ref is None:
        body = json.dumps(fields).encode()
        kind, endpoint = "application/json", "generations"
    else:
        boundary = uuid.uuid4().hex
        parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()]
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="image[]"; filename="ref.png"\r\n'
                     f"Content-Type: image/png\r\n\r\n".encode() + ref + b"\r\n")
        body = b"".join(parts) + f"--{boundary}--\r\n".encode()
        kind, endpoint = f"multipart/form-data; boundary={boundary}", "edits"
    request = urllib.request.Request(f"https://api.openai.com/v1/images/{endpoint}", body,
                                     {"Authorization": f"Bearer {key}", "Content-Type": kind})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return base64.b64decode(json.load(response)["data"][0]["b64_json"])
    except urllib.error.HTTPError as error:
        fail(f"image generation failed ({error.code}): {error.read().decode()[:400]}")


def raw_image(project, label, source, prompt, quality, size, ref=None):
    if source:
        return np.asarray(Image.open(source).convert("RGB"), dtype=float)
    print(f"generating {label} (about a minute)…", flush=True)
    data = generate(prompt, quality, size, ref)
    path = project / "raw" / f"{label}-{time.strftime('%Y%m%d-%H%M%S')}.png"
    path.parent.mkdir(exist_ok=True)
    path.write_bytes(data)
    print(f"raw image: {path}  (reuse with --from)")
    return np.asarray(Image.open(path).convert("RGB"), dtype=float)


# Commands


def cmd_new(args):
    project = Path(args.dir)
    project.mkdir(parents=True, exist_ok=True)
    (project / "palette.gpl").write_text(fetch_palette(args.palette))
    (project / "spritecook.json").write_text(json.dumps({"size": args.size, "palette": args.palette}, indent=2) + "\n")
    colours = len(read_palette(project / "palette.gpl"))
    print(f"project {project}: {args.size}x{args.size} sprites, palette {args.palette} ({colours} colours)")


def cmd_draw(args):
    project, size, palette = load_project(args.project)
    sprite = project / f"{args.name}.aseprite"
    if sprite.exists() and not args.force:
        fail(f"{sprite} exists; pick another name or pass --force")
    prompt = f"{args.prompt}. Full body, drawn as a {size}x{size} pixel sprite filling most of the frame. {STYLE}"
    img = raw_image(project, args.name, args.source, prompt, args.quality, "1024x1024")
    grid, cells, alpha = fit_grid(img, palette, size, args.tolerance)
    write_frames(project, sprite, [place(cells, alpha, size)], "", append=False)
    print(f"{sprite}  (pixel grid {grid[0]:.1f}px in the raw image)")


def components(alpha):
    labels = np.zeros(alpha.shape, int)
    h, w = alpha.shape
    count = 0
    for y, x in zip(*np.where(alpha)):
        if labels[y, x]:
            continue
        count += 1
        labels[y, x] = count
        queue = deque([(y, x)])
        while queue:
            cy, cx = queue.popleft()
            for ny in range(max(0, cy - 1), min(h, cy + 2)):
                for nx in range(max(0, cx - 1), min(w, cx + 2)):
                    if alpha[ny, nx] and not labels[ny, nx]:
                        labels[ny, nx] = count
                        queue.append((ny, nx))
    return labels, count


def split_frames(alpha, count):
    """One mask per frame: cut at the emptiest column near each even boundary, then give whole pieces to the frame holding their centre."""
    columns = alpha.sum(0)
    xs = np.where(columns > 0)[0]
    left, right = xs.min(), xs.max() + 1
    step = (right - left) / count
    cuts = [left]
    for i in range(1, count):
        lo, hi = int(left + step * (i - 0.3)), int(left + step * (i + 0.3))
        cuts.append(lo + int(np.argmin(columns[lo:hi])))
    cuts.append(right)
    labels, n = components(alpha)
    slot = np.clip(np.searchsorted(cuts, np.arange(alpha.shape[1]), side="right") - 1, 0, count - 1)
    slots = np.broadcast_to(slot, alpha.shape)
    assign = np.where(alpha, slots, -1)
    for label in range(1, n + 1):
        piece = labels == label
        shares = np.bincount(slots[piece], minlength=count) / piece.sum()
        # Pieces mostly inside one slot move whole; characters touching across a cut stay split at it.
        if shares.max() >= 0.75:
            assign[piece] = int(np.argmax(shares))
    masks = [alpha & (assign == i) for i in range(count)]
    return masks


def cmd_animate(args):
    sprite = Path(args.sprite).resolve()
    project, size, palette = load_project(sprite.parent)
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / "base.png"
        aseprite(str(sprite), "--frame-range", "0,0", "--save-as", str(base))
        reference = Image.open(base).convert("RGBA")
    height = int(np.ptp(np.where(np.asarray(reference)[..., 3] > 0)[0])) + 1
    board = Image.new("RGBA", (1024, 1024), "white")
    board.alpha_composite(reference.resize((1024, 1024), Image.Resampling.NEAREST))
    buffer = Path(tempfile.mkstemp(suffix=".png")[1])
    board.convert("RGB").save(buffer)
    hint = f" ({args.prompt})" if args.prompt else ""
    prompt = (f"Sprite sheet of a {args.count}-frame {args.tag} animation{hint} for this exact character. "
              f"Same design, colours, proportions and pixel size as the reference. All {args.count} frames in one "
              f"horizontal row, evenly spaced with clear empty space between them, never touching, same facing direction, each a full body pose. {STYLE}")
    img = raw_image(project, f"{sprite.stem}-{args.tag}", args.source, prompt, args.quality, "1536x1024", buffer.read_bytes())
    buffer.unlink()

    grid = detect_grid(img)
    attempt = 0
    while True:
        cells, alpha = clean(img, palette, grid, args.tolerance)
        masks = split_frames(alpha, args.count)
        boxes = [bbox(mask) for mask in masks]
        tallest = max(y1 - y0 for y0, y1, _, _ in boxes)
        widest = max(x1 - x0 for _, _, x0, x1 in boxes)
        factor = max(tallest / height, widest / size)
        attempt += 1
        if attempt == 5 or (abs(factor - 1) <= 0.08 and widest <= size and tallest <= size - 1):
            break
        grid = scaled(grid, factor)
    frames = [place(cells, mask, size) for mask in masks]
    write_frames(project, sprite, frames, args.tag, append=True)
    print(f"{sprite}: added {len(frames)} '{args.tag}' frames")


def cmd_lint(args):
    print(aseprite(str(Path(args.sprite).resolve()), "--script", str(SHARE / "Lint.lua")).strip())


def cmd_export(args):
    sprite = Path(args.sprite).resolve()
    out = sprite.parent / "export"
    out.mkdir(exist_ok=True)
    aseprite("--ignore-layer", "spritecook lint", str(sprite), "--sheet", str(out / f"{sprite.stem}.png"),
             "--data", str(out / f"{sprite.stem}.json"), "--format", "json-array", "--list-tags", "--sheet-type", "packed")
    print(f"{out / sprite.stem}.png + .json")


def main():
    ap = argparse.ArgumentParser(prog="spritecook", description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("new", help="start a project with a fixed sprite size and palette")
    p.add_argument("dir")
    p.add_argument("--size", type=int, default=64)
    p.add_argument("--palette", default="endesga-32", help="Lospec palette slug, or a .hex/.gpl file")
    p.set_defaults(run=cmd_new)

    p = sub.add_parser("draw", help="generate a new sprite from a description")
    p.add_argument("name")
    p.add_argument("prompt")
    p.add_argument("--project", default=".")
    p.add_argument("--force", action="store_true")
    p.set_defaults(run=cmd_draw)

    p = sub.add_parser("animate", help="add animation frames generated from the sprite's first frame")
    p.add_argument("sprite")
    p.add_argument("tag", help="e.g. idle, walk, run, attack, jump")
    p.add_argument("--frames", dest="count", type=int, default=4)
    p.add_argument("--prompt", default="", help="extra motion description")
    p.set_defaults(run=cmd_animate)

    for name, run, text in (("lint", cmd_lint, "report stray pixels, doubled corners and off-palette colours"),
                            ("export", cmd_export, "write a sprite sheet and JSON to export/")):
        p = sub.add_parser(name, help=text)
        p.add_argument("sprite")
        p.set_defaults(run=run)

    for name in ("draw", "animate"):
        p = sub.choices[name]
        p.add_argument("--from", dest="source", help="use this raw image instead of generating one")
        p.add_argument("--quality", default="medium", choices=["low", "medium", "high"])
        p.add_argument("--tolerance", type=float, default=60, help="background removal strength")

    args = ap.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
