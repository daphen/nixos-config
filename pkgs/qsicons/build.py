#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

import fontforge

PUA_START = 0xE000
PUA_END = 0xE4FF


def icon_sources(source_dir: Path) -> dict[str, Path]:
    defaults = {
        path.stem: path
        for path in source_dir.glob("*.svg")
        if "--" not in path.stem
    }
    defaults.update({
        path.name.removesuffix("--glyph--18.svg"): path
        for path in source_dir.glob("*--glyph--18.svg")
        if "duo" not in path.name
    })
    outlines = {
        path.name.removesuffix("--outline--18.svg") + "-outline": path
        for path in source_dir.glob("*--outline--18.svg")
        if "duo" not in path.name
    }
    return defaults | outlines


def build(source_dir: Path, output_dir: Path) -> None:
    sources = icon_sources(source_dir)
    names = sorted(sources)
    if not names:
        raise RuntimeError(f"no monochrome 18px icons found in {source_dir}")
    if PUA_START + len(names) - 1 > PUA_END:
        raise RuntimeError(f"{len(names)} icons exceed U+E000-U+E4FF")

    output_dir.mkdir(parents=True, exist_ok=True)
    font = fontforge.font()
    font.encoding = "UnicodeFull"
    font.em = 1000
    font.ascent = 850
    font.descent = 150
    font.fontname = "QsIcons"
    font.familyname = "QsIcons"
    font.fullname = "QsIcons"
    font.version = "1.0"

    mapping = {}
    for offset, name in enumerate(names):
        codepoint = PUA_START + offset
        glyph = font.createChar(codepoint, name)
        glyph.importOutlines(str(sources[name]))
        glyph.removeOverlap()
        glyph.correctDirection()
        glyph.width = 1000
        mapping[name] = codepoint

    font.generate(str(output_dir / "QsIcons.ttf"))
    font.close()
    (output_dir / "qsicons-map.json").write_text(
        json.dumps(mapping, indent=2, sort_keys=True) + "\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    build(args.source_dir, args.output_dir)


if __name__ == "__main__":
    main()
