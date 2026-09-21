import os
import socket
import subprocess
import sys
import textwrap
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "dotfiles/niri/.config/niri/scripts/vm-slice-reaper"
AGENT = """
import socket,sys
s=socket.socket(); s.bind(('127.0.0.1',int(sys.argv[1]))); s.listen(); print('ready',flush=True)
c,_=s.accept(); c.sendall(b'{"sessions":[]}\\n'); c.close()
"""
HTTP = """
import http.server,sys,threading
class S(http.server.HTTPServer):
 allow_reuse_address=True
class H(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  status=int(sys.argv[2]) if self.path=='/project/stop' else 404
  self.send_response(200 if status==299 else status); self.end_headers()
  self.wfile.write(b'not-json')
  if status != 299: threading.Thread(target=self.server.shutdown,daemon=True).start()
 def log_message(self,*args): pass
s=S(('127.0.0.1',int(sys.argv[1])),H); print('ready',flush=True); s.serve_forever()
"""
def free_port(span=1):
    for port in range(30000, 60000):
        sockets = [socket.socket() for _ in range(span)]
        try:
            for offset, sock in enumerate(sockets): sock.bind(("127.0.0.1", port + offset))
            return port
        except OSError: pass
        finally:
            for sock in sockets: sock.close()
    raise RuntimeError("no test ports")
def start(code, cwd, *args):
    child = subprocess.Popen(
        [sys.executable, "-c", textwrap.dedent(code), *map(str, args)],
        cwd=cwd, stdout=subprocess.PIPE, text=True)
    assert child.stdout.readline().strip() == "ready"
    return child


def test_public_cli_stops_only_its_exact_controller_and_reports_failures(tmp_path):
    wt = tmp_path / "src/lovable-every-1"; (wt / ".devenv/state").mkdir(parents=True)
    base = free_port(7); (wt / ".devenv/state/wt-base-port").write_text(str(base))
    bindir = tmp_path / "bin"; bindir.mkdir(); tmux = bindir / "tmux"
    tmux.write_text("#!/bin/sh\n[ \"$1:$TMUX_FAIL\" = ls:1 ] && echo wt-every-1 && exit 0\nexit 2\n")
    tmux.chmod(0o755); ss = bindir / "ss"; real_ss = subprocess.check_output(["which", "ss"], text=True).strip()
    ss.write_text(f"#!/bin/sh\n{real_ss} \"$@\" | {{ [ \"$SS_HIDE_PID\" = 1 ] && sed 's/users:.*/ /' || cat; }}\n"); ss.chmod(0o755); children = []
    def run(tmux_fail=False, hide_pid=False):
        agent_port = free_port(); children.append(start(AGENT, wt, agent_port))
        env = os.environ | {"HOME": str(tmp_path), "AGENTD_SOCK": str(tmp_path / "none"), "AGENTD_PORT": str(agent_port),
                            "SLICE_STOP_TIMEOUT": ".5", "TMUX_FAIL": str(int(tmux_fail)),
                            "SS_HIDE_PID": str(int(hide_pid)), "PATH": f"{bindir}:{os.environ['PATH']}"}
        return subprocess.run([SCRIPT, "--worktree", wt, "--session", "EVERY-1", "--now"], env=env, capture_output=True, text=True, timeout=5)
    try:
        children.append(start(HTTP, wt, base + 1, 200)); result = run()
        assert result.returncode == 0 and "stopped controller" in result.stdout
        children[-2].wait(timeout=2); assert run().returncode == 0
        result = run(tmux_fail=True); assert result.returncode != 0 and "removal failed" in result.stdout
        base = free_port(7); (wt / ".devenv/state/wt-base-port").write_text(str(base))
        children.append(start(HTTP, tmp_path, base + 1, 200)); result = run(hide_pid=True)
        assert result.returncode != 0 and "unknown/shared ownership" in result.stdout
        result = run(); assert result.returncode != 0 and "belongs to" in result.stdout
        children[-2].terminate(); children[-2].wait(timeout=2)
        base = free_port(7); (wt / ".devenv/state/wt-base-port").write_text(str(base))
        children.append(start(HTTP, wt, base + 1, 500)); result = run()
        assert result.returncode != 0 and "stop failed" in result.stdout
        base = free_port(7); (wt / ".devenv/state/wt-base-port").write_text(str(base))
        children.append(start(HTTP, wt, base + 1, 299)); result = run()
        assert result.returncode != 0 and "shutdown unconfirmed" in result.stdout
    finally:
        for child in children:
            child.terminate(); child.wait(timeout=2)
