#!/usr/bin/env python3
"""spritecook: AI first drafts for pixel-art sprites, finished by hand in Aseprite."""
import argparse
import base64
import json
import os
import shutil
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
    if w > size:
        # A prop reaching past the canvas is cropped; shrinking would make the character jump in size between loops.
        counts = np.concatenate([[0], np.cumsum(alpha.sum(0))])
        start = int(np.argmax(counts[size:] - counts[:-size]))
        cells, alpha = cells[:, start:start + size], alpha[:, start:start + size]
        w = size
    if h > size:
        cells, alpha, h = cells[h - size:], alpha[h - size:], size
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
    native = grid
    for _ in range(4):
        cells, alpha = clean(img, palette, grid, tolerance)
        y0, y1, x0, x1 = bbox(alpha)
        fit = max((y1 - y0) / (size - 2), (x1 - x0) / size)
        factor = max(fit, 1.0)
        if height and abs((y1 - y0) / height - 1) > 0.08:
            factor = max(fit, (y1 - y0) / height)
        if 0.98 <= factor <= 1.02 or (factor < 1 and not height):
            break
        grid = scaled(grid, factor)
    else:
        cells, alpha = clean(img, palette, grid, tolerance)
    if grid[0] > native[0] * 1.3:
        print(f"warning: the art was drawn about {grid[0] / native[0]:.1f}x finer than {size}x{size}, so detail was lost; "
              f"a {size * 2}x{size * 2} project would keep it", file=sys.stderr)
    return grid, cells, alpha


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


def tag_frames(sprite, tag):
    with tempfile.TemporaryDirectory() as tmp:
        sheet = Path(tmp) / "sheet.png"
        aseprite("--ignore-layer", "spritecook lint", "--frame-tag", tag, str(sprite), "--sheet-type", "horizontal",
                 "--sheet", str(sheet))
        strip = np.asarray(Image.open(sheet).convert("RGBA"))
    size = strip.shape[0]
    return [strip[:, i:i + size].copy() for i in range(0, strip.shape[1], size)]


def write_frames(project, sprite, frames, tag, append, replace=False):
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, frame in enumerate(frames):
            path = Path(tmp) / f"{i:03d}.png"
            Image.fromarray(frame, "RGBA").save(path)
            paths.append(str(path))
        listing = Path(tmp) / "frames.txt"
        listing.write_text("\n".join(paths) + "\n")
        if replace:
            aseprite("--script-param", f"out={sprite}", "--script-param", f"list={listing}",
                     "--script-param", f"tag={tag}", "--script", str(SHARE / "replace.lua"))
            return
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
    shutil.copyfile(SHARE / "AGENTS.md", project / "AGENTS.md")
    colours = len(read_palette(project / "palette.gpl"))
    print(f"project {project}: {args.size}x{args.size} sprites, palette {args.palette} ({colours} colours)")


def reference_board(sprite):
    """Frame 1 of a sprite, scaled onto a white 1024 board, as PNG bytes; also its opaque height."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / "base.png"
        aseprite(str(sprite), "--frame-range", "0,0", "--save-as", str(base))
        reference = Image.open(base).convert("RGBA")
        height = int(np.ptp(np.where(np.asarray(reference)[..., 3] > 0)[0])) + 1
        board = Image.new("RGBA", (1024, 1024), "white")
        board.alpha_composite(reference.resize((1024, 1024), Image.Resampling.NEAREST))
        board.convert("RGB").save(base)
        return base.read_bytes(), height


def cmd_draw(args):
    project, size, palette = load_project(args.project)
    sprite = project / f"{args.name}.aseprite"
    if sprite.exists() and not args.force:
        fail(f"{sprite} exists; pick another name or pass --force")
    ref = height = None
    if args.like:
        ref, height = reference_board(Path(args.like).resolve())
        prompt = (f"The exact same character as the reference: same species, face, fur colours, proportions, pose, "
                  f"outline and pixel size. Change only the outfit and props: {args.prompt}. Full body, drawn as a "
                  f"{size}x{size} pixel sprite filling most of the frame. {STYLE}")
    else:
        prompt = f"{args.prompt}. Full body, drawn as a {size}x{size} pixel sprite filling most of the frame. {STYLE}"
    img = raw_image(project, args.name, args.source, prompt, args.quality, "1024x1024", ref)
    grid, cells, alpha = fit_grid(img, palette, size, args.tolerance, height)
    write_frames(project, sprite, [place(cells, alpha, size)], "", append=False)
    print(f"{sprite}  (pixel grid {grid[0]:.1f}px in the raw image)")
    print(refresh_preview(sprite))


def cmd_scene(args):
    project, size, palette = load_project(args.project)
    out = project / "scenes" / f"{args.name}.png"
    if out.exists() and not args.force:
        fail(f"{out} exists; pick another name or pass --force")
    floor = args.height - round(args.height * 0.19)
    prompt = (f"Wide pixel art game background scene: {args.prompt}. Drawn as a {args.width}x{args.height} pixel image "
              f"with crisp square pixels, flat cel shading, limited palette, no anti-aliasing, no text, no characters, "
              f"no people, no animals. The floor surface runs flat and level across the bottom fifth of the image; "
              f"keep the centre of the floor clear so a character can stand there. Fill the whole frame edge to edge.")
    ref = None
    if args.like:
        ref = Path(args.like).read_bytes()
        prompt += (" This is another spot on the very same ship as the reference image: match its art style, wood colours, "
                   "weather, sky and lighting exactly.")
    img = raw_image(project, f"scene-{args.name}", args.source, prompt, args.quality, "1536x1024", ref)
    h, w, _ = img.shape
    keep = int(w * args.height / args.width)
    end = int(h * args.bottom)
    img = img[max(0, end - keep):end] if keep < h else img
    cells = sample_cells(img, (w / args.width, 0.0, img.shape[0] / args.height, 0.0))[:args.height, :args.width]
    flat = cells.reshape(-1, 3)
    cells = snap(flat, palette).reshape(cells.shape)
    everywhere = np.ones(cells.shape[:2], bool)
    for _ in range(2):
        cells = despeckle(cells, everywhere)
    out.parent.mkdir(exist_ok=True)
    Image.fromarray(cells.astype(np.uint8), "RGB").save(out)
    print(f"{out}  ({args.width}x{args.height}, floor at row {floor})")


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


def split_grid(alpha, count):
    """Frames laid out in one row or in two rows: cut rows at an empty band near the middle, then columns per row."""
    rows = alpha.sum(1)
    ys = np.where(rows > 0)[0]
    top, bottom = ys.min(), ys.max() + 1
    lo, hi = int(top + (bottom - top) * 0.35), int(top + (bottom - top) * 0.65)
    cut = lo + int(np.argmin(rows[lo:hi]))
    if count % 2 or rows[cut] or not alpha[:cut].any() or not alpha[cut:].any():
        return split_frames(alpha, count)
    masks = []
    for band in (slice(0, cut), slice(cut, None)):
        part = np.zeros_like(alpha)
        part[band] = alpha[band]
        masks += split_frames(part, count // 2)
    return masks


def neighbourhood(mask):
    padded = np.pad(mask, 1)
    h, w = mask.shape
    return [padded[1 + dy:1 + dy + h, 1 + dx:1 + dx + w] for dy in (-1, 0, 1) for dx in (-1, 0, 1)]


def shifted(frame, dy, dx):
    out = np.zeros_like(frame)
    h, w = frame.shape[:2]
    out[max(dy, 0):h + min(dy, 0), max(dx, 0):w + min(dx, 0)] = frame[max(-dy, 0):h + min(-dy, 0), max(-dx, 0):w + min(-dx, 0)]
    return out


def stabilise(frames):
    """Generated frames are separate drawings, so static parts shimmer. Align them, take the frame closest to the per-pixel majority as the
    still image, and keep a frame's own pixels only in solid regions of real motion: one-pixel slivers are redraw noise."""
    first = frames[0]
    aligned = []
    for frame in frames:
        offsets = [(dy, dx) for dy in range(-3, 4) for dx in range(-3, 4)]
        best = min(offsets, key=lambda o: (shifted(frame, *o) != first).any(2).sum())
        aligned.append(shifted(frame, *best))
    stack = np.stack(aligned)
    keys = stack.astype(np.int64)
    keys = keys[..., 0] << 24 | keys[..., 1] << 16 | keys[..., 2] << 8 | keys[..., 3]
    votes = (keys[:, None] == keys[None, :]).sum(1)
    vote = np.take_along_axis(stack, votes.argmax(0)[None, ..., None], 0)[0]
    # A per-pixel vote erases features each frame drew in a slightly different spot (eyes); keep a real frame.
    still = min(aligned, key=lambda frame: (frame != vote).any(2).sum())
    out = []
    for frame in aligned:
        moving = (frame != still).any(2)
        moving = np.logical_and.reduce(neighbourhood(moving))
        for _ in range(2):
            moving = np.logical_or.reduce(neighbourhood(moving))
        result = still.copy()
        result[moving] = frame[moving]
        alpha = result[..., 3] > 0
        labels, count = components(alpha)
        sizes = np.bincount(labels.ravel(), minlength=count + 1)
        result[alpha & (sizes[labels] < 4)] = 0
        out.append(result)
    return out


def cmd_stabilise(args):
    sprite = Path(args.sprite).resolve()
    frames = tag_frames(sprite, args.tag)
    project = sprite.parent
    write_frames(project, sprite, stabilise(frames), args.tag, append=True, replace=True)
    print(f"{sprite}: stabilised '{args.tag}' ({len(frames)} frames)")
    print(refresh_preview(sprite))


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
    ref, height = reference_board(sprite)
    hint = f" ({args.prompt})" if args.prompt else ""
    layout = "a 2x2 grid, read left to right then top to bottom" if args.count == 4 else f"one horizontal row"
    prompt = (f"Sprite sheet of a {args.count}-frame looping {args.tag} animation{hint} for this exact character; the last "
              f"frame leads smoothly back into the first. Redraw the character identically in every frame: same design, "
              f"colours, proportions, pixel size and facing as the reference, and only the moving parts change. All "
              f"{args.count} frames in {layout}, evenly spaced with clear empty space between them, never touching, "
              f"each a full body pose. {STYLE}")
    canvas = "1024x1024" if args.count == 4 else "1536x1024"
    img = raw_image(project, f"{sprite.stem}-{args.tag}", args.source, prompt, args.quality, canvas, ref)

    grid = detect_grid(img)
    attempt = 0
    while True:
        cells, alpha = clean(img, palette, grid, args.tolerance)
        masks = split_grid(alpha, args.count)
        boxes = [bbox(mask) for mask in masks]
        tallest = max(y1 - y0 for y0, y1, _, _ in boxes)
        factor = max(tallest / height, tallest / (size - 1))
        attempt += 1
        if attempt == 5 or abs(factor - 1) <= 0.08:
            break
        grid = scaled(grid, factor)
    frames = stabilise([place(cells, mask, size) for mask in masks])
    write_frames(project, sprite, frames, args.tag, append=True)
    print(f"{sprite}: added {len(frames)} '{args.tag}' frames")
    print(refresh_preview(sprite))


def refresh_preview(sprite):
    """Write preview/<name>.{png,lint,json} for the Cockpit sprite bench; the .json lands last."""
    sprite = Path(sprite).resolve()
    preview = sprite.parent / "preview"
    preview.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=preview) as tmp:
        sheet, data, lint = Path(tmp) / "sheet.png", Path(tmp) / "sheet.json", Path(tmp) / "lint.json"
        aseprite("--ignore-layer", "spritecook lint", str(sprite), "--sheet", str(sheet), "--data", str(data),
                 "--format", "json-array", "--list-tags", "--sheet-type", "horizontal")
        report = aseprite(str(sprite), "--script-param", f"out={lint}", "--script", str(SHARE / "Lint.lua")).strip()
        os.replace(sheet, preview / f"{sprite.stem}.png")
        os.replace(lint, preview / f"{sprite.stem}.lint")
        os.replace(data, preview / f"{sprite.stem}.json")
    return report


def cmd_preview(args):
    print(refresh_preview(args.sprite))


def cmd_lint(args):
    print(refresh_preview(args.sprite))


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
    p.add_argument("--like", help="keep the character from this .aseprite and change only what the prompt says")
    p.set_defaults(run=cmd_draw)

    p = sub.add_parser("scene", help="generate a full-frame background scene for sprites to stand in")
    p.add_argument("name")
    p.add_argument("prompt")
    p.add_argument("--project", default=".")
    p.add_argument("--force", action="store_true")
    p.add_argument("--width", type=int, default=144)
    p.add_argument("--height", type=int, default=80)
    p.add_argument("--bottom", type=float, default=1.0, help="where the crop band ends, as a fraction of the image height")
    p.add_argument("--like", help="raw image of another scene on the same set, used as a reference")
    p.set_defaults(run=cmd_scene)

    p = sub.add_parser("stabilise", help="remove redraw shimmer from a generated animation, in place")
    p.add_argument("sprite")
    p.add_argument("tag")
    p.set_defaults(run=cmd_stabilise)

    p = sub.add_parser("animate", help="add animation frames generated from the sprite's first frame")
    p.add_argument("sprite")
    p.add_argument("tag", help="e.g. idle, walk, run, attack, jump")
    p.add_argument("--frames", dest="count", type=int, default=4)
    p.add_argument("--prompt", default="", help="extra motion description")
    p.set_defaults(run=cmd_animate)

    for name, run, text in (("lint", cmd_lint, "report stray pixels, doubled corners and off-palette colours"),
                            ("preview", cmd_preview, "refresh the Cockpit sprite bench preview"),
                            ("export", cmd_export, "write a sprite sheet and JSON to export/")):
        p = sub.add_parser(name, help=text)
        p.add_argument("sprite")
        p.set_defaults(run=run)

    for name in ("draw", "scene", "animate"):
        p = sub.choices[name]
        p.add_argument("--from", dest="source", help="use this raw image instead of generating one")
        p.add_argument("--quality", default="medium", choices=["low", "medium", "high"])
        p.add_argument("--tolerance", type=float, default=60, help="background removal strength")

    args = ap.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
