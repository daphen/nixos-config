#!/usr/bin/env python3
"""Render a PR review page from template.html + a fragments JSON.

Usage: render.py <pr-num> <fragments.json>

The skill produces only the content fragments; this inlines the current
theme palette and the fixed skeleton/CSS. Output: ~/.cache/pr-reviews/pr-<num>.html
(also printed). Theme mode comes from ~/.config/theme_mode.
"""
import json
import os
import sys
from pathlib import Path

HOME = Path(os.environ["HOME"])
SKILL_DIR = Path(__file__).resolve().parent

SLOTS = [
    "title", "meta", "verdict_class", "verdict_badge", "verdict_why",
    "diagram", "findings", "filemap", "intent", "verification",
]


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: render.py <pr-num> <fragments.json>", file=sys.stderr)
        return 2
    num = sys.argv[1].lstrip("#")
    frags = json.loads(Path(sys.argv[2]).read_text())

    mode = "light"
    mode_file = HOME / ".config" / "theme_mode"
    if mode_file.is_file():
        m = mode_file.read_text().strip()
        if m in ("light", "dark"):
            mode = m

    # Dual-theme palette: either file carries both palettes; prefer current mode.
    pal_dir = HOME / ".config" / "themes" / "generated" / "review"
    palette = ""
    for cand in (pal_dir / f"{mode}.theme", pal_dir / "light.theme", pal_dir / "dark.theme"):
        if cand.is_file():
            palette = cand.read_text()
            break
    if not palette:
        print(f"warning: no review palette in {pal_dir} — page will be unstyled", file=sys.stderr)

    html = (SKILL_DIR / "template.html").read_text()
    html = html.replace("{{MODE}}", mode).replace("{{PALETTE}}", palette).replace("{{NUM}}", num)
    for slot in SLOTS:
        html = html.replace("{{" + slot.upper() + "}}", str(frags.get(slot, "")))

    out_dir = HOME / ".cache" / "pr-reviews"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"pr-{num}.html"
    out.write_text(html)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
