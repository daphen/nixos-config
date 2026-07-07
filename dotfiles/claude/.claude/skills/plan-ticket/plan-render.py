#!/usr/bin/env python3
"""Render a plan artifact to a scannable HTML page.

Usage: plan-render.py <plan.md-path>

Data-driven (no LLM): reads <key>.md + <key>.progress.json + <key>.review.json,
inlines the current theme palette, and writes ~/.cache/plan-views/<key>.html
(also printed). Read-only view; nvim stays the authoring driver.
"""
import html
import json
import os
import re
import sys
from pathlib import Path

HOME = Path(os.environ["HOME"])
SKILL_DIR = Path(__file__).resolve().parent
PHASE_CLASS = {"draft": "draft", "finalized": "finalized", "implementing": "implementing", "reconciled": "reconciled"}


def md_inline(s: str) -> str:
    s = html.escape(s)
    # stash code spans first — globs like `src/assets/**` confuse the bold regex
    codes: list = []
    s = re.sub(r"`(.+?)`", lambda m: (codes.append(m.group(1)), f"\x00{len(codes)-1}\x00")[1], s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{codes[int(m.group(1))]}</code>", s)
    return s


def md_block(text: str) -> str:
    """Very light markdown → HTML for prose sections (paragraphs + bullet lists)."""
    out, buf, in_ul = [], [], False
    def flush_p():
        # join wrapped lines before inlining — bold/code spans cross hard wraps
        if buf:
            out.append("<p>" + md_inline(" ".join(buf)) + "</p>"); buf.clear()
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush_p()
            if in_ul: out.append("</ul>"); in_ul = False
            continue
        m = re.match(r"\s*[-*]\s+(.*)", line)
        if m:
            flush_p()
            if not in_ul: out.append("<ul>"); in_ul = True
            out.append("<li>" + md_inline(m.group(1)) + "</li>")
        else:
            buf.append(line.strip())
    flush_p()
    if in_ul: out.append("</ul>")
    return "\n".join(out) or '<span class="empty">—</span>'


def sections(md: str) -> dict:
    """Split markdown into {heading-lower: body} by `## ` headings."""
    secs, cur, body = {}, None, []
    for line in md.splitlines():
        h = re.match(r"^##\s+(.*)", line)
        if h:
            if cur is not None: secs[cur] = "\n".join(body).strip()
            cur = h.group(1).strip().lower(); body = []
        elif cur is not None:
            body.append(line)
    if cur is not None: secs[cur] = "\n".join(body).strip()
    return secs


def find_section(secs: dict, *needles: str) -> str:
    for k, v in secs.items():
        if any(n in k for n in needles):
            return v
    return ""


def flow_details(secs: dict) -> list:
    """Full bodies of the md's ◆ work items, in document order."""
    body = find_section(secs, "the flow", "flow")
    items, cur = [], None
    for line in body.splitlines():
        m = re.match(r"\s*\d+\.\s+(.*)", line)
        if m:
            if cur is not None:
                items.append(cur)
            cur = [m.group(1)] if "◆" in m.group(1) else None
        elif cur is not None:
            cur.append(line.strip())
    if cur is not None:
        items.append(cur)
    return ["\n".join(it).strip() for it in items]


def inject_step_details(diagram: str, secs: dict) -> str:
    """Nodes tagged data-step="N" get that ◆ step's full md body as their
    expandable .more — same text as the flow section, sourced once."""
    details = flow_details(secs)

    def close_of(s: str, start: int) -> int:
        depth, i = 0, start
        while i < len(s):
            o, c = s.find("<div", i), s.find("</div>", i)
            if c < 0:
                return -1
            if 0 <= o < c:
                depth += 1
                i = o + 4
            else:
                depth -= 1
                if depth == 0:
                    return c
                i = c + 6
        return -1

    out, pos = [], 0
    for m in re.finditer(r'<div[^>]*class="node[^"]*"[^>]*data-step="(\d+)"[^>]*>', diagram):
        n = int(m.group(1))
        if not (1 <= n <= len(details)):
            continue
        end = close_of(diagram, m.start())
        if end < 0:
            continue
        out.append(diagram[pos:end])
        out.append(f'<div class="more">{md_block(details[n - 1])}</div>')
        pos = end
    out.append(diagram[pos:])
    return "".join(out)


def render_flow(progress, secs: dict) -> str:
    flow = (progress or {}).get("flow") or []
    if not flow:
        return '<div class="empty">No flow steps recorded yet.</div>'
    details = flow_details(secs)

    def detail_for(idx, title):
        if len(details) == len(flow):
            return details[idx]
        toks = set(re.findall(r"\w{4,}", title.lower()))
        best, score = "", 0
        for d in details:
            s = len(toks & set(re.findall(r"\w{4,}", d.lower())))
            if s > score:
                best, score = d, s
        return best if score >= 2 else ""

    rows = []
    for idx, f in enumerate(flow):
        st = f.get("status", "pending")
        title = f.get("step", "")
        d = detail_for(idx, title)
        more = f'<div class="more">{md_block(d)}</div>' if d else ""
        rows.append(
            f'<div class="step {st}"><span class="dot"></span>'
            f'<span class="txt"><span class="new">◆{idx + 1}</span>{md_inline(title)}{more}</span></div>'
        )
    return "\n".join(rows)


def render_decisions(secs: dict) -> str:
    body = find_section(secs, "decision")
    if not body:
        return '<div class="empty">No decision points.</div>'
    blocks = re.split(r"(?=^###\s+)", body, flags=re.M)
    cards = []
    for b in blocks:
        b = b.strip()
        if not b.startswith("###"):
            continue
        q = re.match(r"###\s+(.*)", b).group(1).strip()
        call_m = re.search(r"\*\*Your call:\*\*\s*(.*)", b)
        call = call_m.group(1).strip() if call_m else ""
        unresolved = "(unresolved)" in call.lower() or "_(unresolved)_" in b.lower()
        cls = "dec unresolved" if unresolved else "dec"
        call_html = f'<div class="call">Your call: {md_inline(call) or "—"}</div>' if call_m else ""
        cards.append(f'<div class="{cls}"><div class="q">{md_inline(q)}</div>{call_html}</div>')
    return "\n".join(cards) or '<div class="empty">No decision points.</div>'


def step_file_refs(secs: dict) -> list:
    """Per ◆ step, the entries of its `_(files: …)_` annotation."""
    refs = []
    for d in flow_details(secs):
        m = re.search(r"_\(files:\s*([^)]+)\)_", d)
        refs.append([e.strip().strip("`") for e in m.group(1).split(",")] if m else [])
    return refs


def render_surface(progress, review, secs: dict) -> str:
    planned = (progress or {}).get("planned") or []
    if not planned:
        return '<div class="empty">No surface-area files recorded yet.</div>'
    refs = step_file_refs(secs)

    def steps_for(path):
        name = path.rsplit("/", 1)[-1].replace("_test", "")
        out = []
        for i, ents in enumerate(refs):
            if any(e and (e in path or e in name) for e in ents):
                out.append(i + 1)
        return out

    def frow(p):
        act, st = p.get("action", "modify"), p.get("status", "pending")
        f, note = p.get("file", ""), p.get("note", "")
        chips = " ".join(f"◆{n}" for n in steps_for(f))
        chips_html = f'<span class="ct">{chips}</span>' if chips else ""
        note_html = f'<div class="note">{md_inline(note)}</div>' if note else ""
        return (
            f'<div class="frow surf openable" data-file="{html.escape(f, quote=True)}"><span class="tag {act}">{act}</span>'
            f'<span class="st {st}">{st}</span>'
            f'<div class="fmain"><div class="l1"><span class="nm">{html.escape(f.rsplit("/", 1)[-1])}</span>'
            f'{chips_html}</div>{note_html}</div></div>'
        )

    groups: dict = {}
    for p in planned:
        d = p.get("file", "").rsplit("/", 1)[0] if "/" in p.get("file", "") else "."
        groups.setdefault(d, []).append(p)
    cards = [
        f'<div class="grp"><h3>{html.escape(d)}/</h3>' + "\n".join(frow(p) for p in ps) + "</div>"
        for d, ps in groups.items()
    ]
    drift = [
        f'<div class="frow surf"><span class="tag drift">drift</span><span class="st"></span>'
        f'<div class="fmain"><div class="l1"><span class="nm">{html.escape(x.get("file", x.get("hunk","")))}</span></div>'
        f'<div class="note">{md_inline(x.get("why",""))}</div></div></div>'
        for x in (review or {}).get("drift") or []
    ]
    if drift:
        cards.append('<div class="grp"><h3>drift</h3>' + "\n".join(drift) + "</div>")
    return '<div class="fmap">' + "\n".join(cards) + "</div>"


def render_verification(review) -> str:
    items = (review or {}).get("verification") or []
    if not items:
        return '<div class="empty">Not reconciled yet — run <code>--reconcile</code>.</div>'
    rows = []
    for v in items:
        r = v.get("result", "pending")
        label = v.get("check", "")
        cmd = v.get("command")
        tag = "AT" if cmd else "MT"
        rows.append(
            f'<div class="vrow"><span class="r {r}">{tag} {r}</span>'
            f'<span>{md_inline(label)}</span></div>'
        )
    return "\n".join(rows)


def render_html(md_path: Path) -> str:
    """Render the plan artifacts at md_path into the filled HTML string.
    Reusable by both the CLI (static write) and the plan-view live server."""
    key = md_path.stem
    md = md_path.read_text()

    def load(suffix):
        p = md_path.with_name(md_path.stem + suffix)
        if p.is_file():
            try: return json.loads(p.read_text())
            except Exception: return None
        return None
    progress = load(".progress.json")
    review = load(".review.json")
    diagram_p = md_path.with_name(md_path.stem + ".diagram.html")
    diagram = diagram_p.read_text() if diagram_p.is_file() else \
        '<div class="empty">No diagram yet — written at <code>--finalize</code>.</div>'
    diagram = inject_step_details(diagram, sections(md))

    secs = sections(md)
    title_m = re.search(r"^#\s+(.*)", md, flags=re.M)
    title = title_m.group(1).strip() if title_m else key
    phase = (progress or {}).get("phase")
    status_line = re.search(r"^>\s*Status:\s*`?(\w+)`?", md, flags=re.M)
    status = phase or (status_line.group(1) if status_line else "draft")
    status_cls = PHASE_CLASS.get(status, "draft")
    branch = (progress or {}).get("branch") or ""
    br_m = re.search(r"worktree:\s*`([^`]+)`", md)
    if not branch and br_m: branch = br_m.group(1)

    flow = (progress or {}).get("flow") or []
    done = sum(1 for f in flow if f.get("status") == "done")
    progress_txt = f"{done}/{len(flow)} steps" if flow else "—"

    mode = "light"
    mf = HOME / ".config" / "theme_mode"
    if mf.is_file() and mf.read_text().strip() in ("light", "dark"):
        mode = mf.read_text().strip()
    pal_dir = HOME / ".config" / "themes" / "generated" / "review"
    palette = ""
    for cand in (pal_dir / f"{mode}.theme", pal_dir / "light.theme", pal_dir / "dark.theme"):
        if cand.is_file():
            palette = cand.read_text(); break

    ui_css_path = HOME / ".claude" / "skills" / "review-pr" / "ui.css"  # shared with review-pr
    ui_css = ui_css_path.read_text() if ui_css_path.is_file() else ""
    fill = {
        "MODE": mode, "PALETTE": palette, "STYLES": ui_css, "KEY": key, "TITLE": md_inline(title),
        "STATUS": status, "STATUS_CLASS": status_cls, "BRANCH": html.escape(branch),
        "PROGRESS": progress_txt,
        "SHAPE": md_block(find_section(secs, "the shape", "shape")) or '<span class="empty">—</span>',
        "DIAGRAM": diagram,
        "FLOW": render_flow(progress, secs),
        "DECISIONS": render_decisions(secs),
        "SURFACE": render_surface(progress, review, secs),
        "VERIFICATION": render_verification(review),
        "RECON": md_block(find_section(secs, "reconciliation")),
    }
    tpl = (SKILL_DIR / "plan-view.html").read_text()
    for k, v in fill.items():
        tpl = tpl.replace("{{" + k + "}}", str(v))
    return tpl


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: plan-render.py <plan.md-path>", file=sys.stderr)
        return 2
    md_path = Path(sys.argv[1]).expanduser()
    if not md_path.is_file():
        print(f"no plan at {md_path}", file=sys.stderr)
        return 1
    out_dir = HOME / ".cache" / "plan-views"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{md_path.stem}.html"
    out.write_text(render_html(md_path))
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
