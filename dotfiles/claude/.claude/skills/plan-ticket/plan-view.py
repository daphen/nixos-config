#!/usr/bin/env python3
"""Live plan viewer — the missing server half of plan-view.html.

    plan-view.py <key> [--plandir DIR] [--open] [--serve]

Ensures a single local server (port 8746) that renders plans fresh per
request (`/plan/<key>`) and pushes an SSE event (`/events`) whenever any
artifact in the plan dir changes — plan-view.html reloads in place with
scroll/focus preserved. `--open` routes the URL through browser-dispatch.
Typical use (from the plan-ticket skill's --go): ensure + open.
"""
import argparse
import importlib.util
import os
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8746
HOME = Path(os.environ["HOME"])
SKILL = Path(__file__).resolve().parent

_spec = importlib.util.spec_from_file_location("plan_render", SKILL / "plan-render.py")
plan_render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plan_render)


def default_plandir() -> Path:
    vault = HOME / "personal" / "notes" / "storage" / "plans"
    return vault if vault.is_dir() else Path.cwd() / ".plans"


def port_in_use() -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", PORT)) == 0


class Handler(BaseHTTPRequestHandler):
    plandir: Path

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/plan/"):
            key = self.path.split("/plan/", 1)[1].split("?")[0]
            md = self.plandir / f"{key}.md"
            if not md.is_file():
                self.send_error(404, f"no plan {key} in {self.plandir}")
                return
            body = plan_render.render_html(md).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            last = self._snapshot()
            try:
                while True:
                    time.sleep(1)
                    cur = self._snapshot()
                    if cur != last:
                        last = cur
                        self.wfile.write(b"data: reload\n\n")
                    else:
                        self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)

    def _snapshot(self):
        out = []
        for f in sorted(self.plandir.glob("*")):
            try:
                out.append((f.name, f.stat().st_mtime_ns))
            except FileNotFoundError:
                pass
        return tuple(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("key", nargs="?", help="plan key (EVERY-1234 or slug)")
    ap.add_argument("--plandir", type=Path, default=None)
    ap.add_argument("--open", action="store_true", help="open the plan in the browser")
    ap.add_argument("--serve", action="store_true", help="run the blocking server (internal)")
    args = ap.parse_args()
    plandir = (args.plandir or default_plandir()).expanduser().resolve()

    if args.serve:
        Handler.plandir = plandir
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
        return 0

    if not args.key:
        print("key required unless --serve", file=sys.stderr)
        return 2

    if not port_in_use():
        subprocess.Popen(
            ["setsid", sys.executable, str(Path(__file__).resolve()),
             "--serve", "--plandir", str(plandir)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        for _ in range(30):
            if port_in_use():
                break
            time.sleep(0.1)

    # 127.0.0.1, not localhost — the vimium exclusion rule keys off it.
    url = f"http://127.0.0.1:{PORT}/plan/{args.key}"
    print(url)
    if args.open:
        # chromeless app-mode window in the WORK profile — that's where the
        # vimium localhost exclusions (and work session state) live.
        dispatch = HOME / ".config" / "niri" / "scripts" / "browser-dispatch"
        opener = [str(dispatch), "--profile=work", "--app"] if dispatch.is_file() else ["xdg-open"]
        subprocess.Popen(opener + [url], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
