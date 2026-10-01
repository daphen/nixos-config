#!/usr/bin/env python3
"""Exercise real Xwayland input in an isolated canvas compositor."""

import ctypes as c
import hashlib
import json
import os
import pathlib
import socket
import struct
import subprocess
import sys
import time

ROOT = pathlib.Path.home() / ".cache/canvas-x11-input"
GTK = "/nix/store/yl5yl395iqx88kd1m7lx7p7b65n0jfx9-gtk+3-3.24.51/lib/libgtk-3.so.0"
CONFIG = (
    pathlib.Path(__file__).resolve().parents[2]
    / "dotfiles/hyprland/.config/hypr/hyprland.lua"
)


def client():
    gtk = c.CDLL(GTK)
    p = c.c_void_p
    i = c.c_int

    def fn(name, result, *args):
        f = getattr(gtk, name)
        f.restype = result
        f.argtypes = list(args)
        return f

    fn("g_set_prgname", None, c.c_char_p)(b"canvas-x11-input")
    assert fn("gtk_init_check", i, p, p)(None, None)
    win = fn("gtk_window_new", p, i)(0)
    fn("gtk_window_set_title", None, p, c.c_char_p)(win, b"Canvas X11 input test")
    fn("gtk_window_set_default_size", None, p, i, i)(win, 760, 480)
    fn("gtk_widget_add_events", None, p, i)(win, 1 << 8)

    class Button(c.Structure):
        _fields_ = [
            ("type", i),
            ("window", p),
            ("send_event", c.c_byte),
            ("time", c.c_uint),
            ("x", c.c_double),
            ("y", c.c_double),
            ("axes", p),
            ("state", c.c_uint),
            ("button", c.c_uint),
            ("device", p),
            ("root_x", c.c_double),
            ("root_y", c.c_double),
        ]

    @c.CFUNCTYPE(None, p, p)
    def selected(widget, data):
        with open(os.environ["CLICK_LOG"], "a") as log:
            log.write(json.dumps({"menu_selected": True}) + "\n")

    @c.CFUNCTYPE(i, p, p, p)
    def click(widget, event, data):
        e = c.cast(event, c.POINTER(Button)).contents
        if e.type != 4:
            return 1
        with open(os.environ["CLICK_LOG"], "a") as log:
            log.write(
                json.dumps(
                    {
                        "button": e.button,
                        "local": [e.x, e.y],
                        "root": [e.root_x, e.root_y],
                    }
                )
                + "\n"
            )
        if e.button == 3:
            menu = fn("gtk_menu_new", p)()
            item = fn("gtk_menu_item_new_with_label", p, c.c_char_p)(
                b"Canvas input menu"
            )
            fn("gtk_menu_shell_append", None, p, p)(menu, item)
            fn("g_signal_connect_data", c.c_ulong, p, c.c_char_p, p, p, p, i)(
                item, b"activate", c.cast(selected, p), None, None, 0
            )
            fn("gtk_widget_show_all", None, p)(menu)
            fn("gtk_menu_popup_at_pointer", None, p, p)(menu, event)
        return 1

    fn("g_signal_connect_data", c.c_ulong, p, c.c_char_p, p, p, p, i)(
        win, b"button-press-event", c.cast(click, p), None, None, 0
    )
    fn("gtk_widget_show_all", None, p)(win)
    fn("gtk_main", None)()


class Pointer:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(path))
        self.sock.settimeout(3)
        self.pending = b""
        self.callback = 2
        self.globals = {}
        self.send(1, 1, struct.pack("I", 2))
        self.sync()
        name, version = self.globals["zwlr_virtual_pointer_manager_v1"]
        iface = b"zwlr_virtual_pointer_manager_v1\0"
        string = struct.pack("I", len(iface)) + iface + b"\0" * ((-len(iface)) % 4)
        self.send(
            2,
            0,
            struct.pack("I", name) + string + struct.pack("II", min(version, 2), 4),
        )
        self.send(4, 0, struct.pack("II", 0, 5))
        self.callback = 5
        self.sync()

    def send(self, obj, op, data=b""):
        self.sock.sendall(struct.pack("II", obj, ((len(data) + 8) << 16) | op) + data)

    def sync(self):
        self.callback += 1
        self.send(1, 0, struct.pack("I", self.callback))
        while True:
            while len(self.pending) < 8:
                self.pending += self.sock.recv(65536)
            obj, header = struct.unpack("II", self.pending[:8])
            size, op = header >> 16, header & 65535
            while len(self.pending) < size:
                self.pending += self.sock.recv(65536)
            data, self.pending = self.pending[8:size], self.pending[size:]
            if obj == 1 and op == 0:
                raise RuntimeError(repr(data))
            if obj == 2 and op == 0:
                name, n = struct.unpack("II", data[:8])
                iface = data[8 : 8 + n - 1].decode()
                version = struct.unpack_from("I", data, 8 + (n + 3) // 4 * 4)[0]
                self.globals[iface] = (name, version)
            if obj == self.callback and op == 0:
                return

    def now(self):
        return int(time.monotonic() * 1000) & 0xFFFFFFFF

    def move(self, x, y):
        self.send(5, 1, struct.pack("IIIII", self.now(), x, y, 1280, 720))
        self.send(5, 4)
        self.sync()

    def click(self, button=272):
        for state in [1, 0]:
            self.send(5, 2, struct.pack("III", self.now(), button, state))
            self.send(5, 4)
            self.sync()
            time.sleep(0.05)


def main(binary, label):
    case = ROOT / label
    case.mkdir(parents=True, exist_ok=True)
    scale = float(os.environ.get("CANVAS_TEST_SCALE", "1"))
    if os.environ.get("CANVAS_X11_PRIVATE") != "1":
        lock = next(
            p
            for p in pathlib.Path("/run/user/1000/hypr").glob("*/hyprland.lock")
            if pathlib.Path("/proc", p.read_text().splitlines()[0]).exists()
        )
        os.environ["CANVAS_X11_PARENT_LOCK"] = str(lock)
        command = [
            "/nix/store/dk9qhjgg469lv6mriys7v4c59igarmvx-bubblewrap-0.11.1/bin/bwrap",
            "--die-with-parent",
            "--unshare-net",
            "--unshare-pid",
            "--ro-bind",
            "/",
            "/",
            "--proc",
            "/proc",
            "--dev-bind",
            "/dev",
            "/dev",
            "--bind",
            str(ROOT),
            str(ROOT),
            "--tmpfs",
            "/tmp",
            "--setenv",
            "CANVAS_X11_PRIVATE",
            "1",
            "dbus-run-session",
            "--",
            sys.executable,
            str(pathlib.Path(__file__).resolve()),
            binary,
            label,
        ]
        return subprocess.run(command).returncode
    runtime = pathlib.Path("/tmp/canvas-x11-runtime")
    runtime.mkdir(mode=0o700)
    processes = []
    logs = []
    listener = None
    pointer = None
    rule = None
    parent_lock = pathlib.Path(os.environ["CANVAS_X11_PARENT_LOCK"])
    parent_env = dict(
        os.environ,
        XDG_RUNTIME_DIR="/run/user/1000",
        HYPRLAND_INSTANCE_SIGNATURE=parent_lock.parent.name,
    )
    ctlbin = "/home/daphen/.cache/hyprland-canvas-dev/validated/bin/hyprctl"

    def parent(*args):
        return subprocess.check_output(
            [ctlbin, *args], env=parent_env, text=True, timeout=5
        )

    def launch(args, env, name, **kwargs):
        log = (case / name).open("w")
        logs.append(log)
        proc = subprocess.Popen(
            args, env=env, stdout=log, stderr=subprocess.STDOUT, **kwargs
        )
        processes.append(proc)
        return proc

    def wait(fn, label):
        for _ in range(200):
            value = fn()
            if value:
                return value
            assert all(p.poll() is None for p in processes), label + " process exited"
            time.sleep(0.05)
        raise TimeoutError(label)

    env = os.environ.copy()
    for key in [
        "WAYLAND_DISPLAY",
        "DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "SWAYSOCK",
        "NOTIFY_SOCKET",
    ]:
        env.pop(key, None)
    env.update(
        HOME=str(case / "home"),
        XDG_RUNTIME_DIR=str(runtime),
        XDG_CONFIG_HOME=str(case / "config"),
        XDG_STATE_HOME=str(case / "state"),
        XDG_CACHE_HOME=str(case / "cache"),
        HYPR_CANVAS_PROFILE="workstation",
        GIO_USE_VFS="local",
        GSETTINGS_BACKEND="memory",
        NO_AT_BRIDGE="1",
    )
    for key in ["HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]:
        pathlib.Path(env[key]).mkdir(exist_ok=True)
    (case / "canvas-state.lua").write_bytes(
        CONFIG.with_name("canvas-state.lua").read_bytes()
    )
    (case / "hyprland.lua").write_text(
        'local on=hl.on\nhl.on=function(event,callback) if event~="hyprland.start" then return on(event,callback) end end\ndofile('
        + json.dumps(str(CONFIG))
        + ')\nhl.on=on\nhl.monitor({output="WAYLAND-1",mode="1280x720@60",scale='
        + str(scale)
        + "})\nhl.config({xwayland={force_zero_scaling="
        + ("true" if os.environ.get("CANVAS_TEST_ZERO_SCALING") == "1" else "false")
        + "}})\n"
    )
    click_log = case / "clicks.jsonl"
    click_log.write_text("")
    try:
        before_windows = {w["address"] for w in json.loads(parent("-j", "clients"))}
        before_focus = json.loads(parent("-j", "activewindow")).get("address")
        rule = "canvas_x11_input_test_rule"
        assert (
            parent(
                "eval",
                rule
                + '=hl.window_rule({name="canvas-x11-input-test",match={class="^aquamarine$"},workspace="special:canvas-x11-input-test silent",float=true,size="1280 720",no_initial_focus=true,no_focus=true,render_unfocused=true})',
            ).strip()
            == "ok"
        )
        display = "wayland-canvas-x11"
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(runtime / display))
        listener.listen(16)
        parent_display = parent_lock.read_text().splitlines()[1]
        child_env = dict(
            env,
            WAYLAND_DISPLAY="/run/user/1000/" + parent_display,
            AQ_DRM_DEVICES="/dev/null",
            LIBSEAT_BACKEND="none",
        )
        proc = launch(
            [
                binary,
                "--socket",
                display,
                "--wayland-fd",
                str(listener.fileno()),
                "--config",
                str(case / "hyprland.lua"),
            ],
            child_env,
            "compositor.log",
            pass_fds=(listener.fileno(),),
        )
        instance = wait(
            lambda: next(
                (
                    p
                    for p in (runtime / "hypr").glob("*")
                    if (p / ".socket.sock").exists()
                ),
                None,
            ),
            "IPC",
        )

        def ctl(command):
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(5)
                s.connect(str(instance / ".socket.sock"))
                s.sendall(command.encode())
                data = b""
                while b := s.recv(65536):
                    data += b
                return data.decode()

        def evaluate(code):
            answer = ctl("eval " + code)
            assert answer.strip() == "ok", answer

        assert not ctl("configerrors").strip(), ctl("configerrors")
        outer = wait(
            lambda: next(
                (
                    w
                    for w in json.loads(parent("-j", "clients"))
                    if w["address"] not in before_windows and w["class"] == "aquamarine"
                ),
                None,
            ),
            "hidden nested output",
        )
        assert outer["workspace"]["address"] == "special:canvas-x11-input-test", outer
        assert json.loads(parent("-j", "activewindow")).get("address") == before_focus
        appenv = dict(
            env,
            WAYLAND_DISPLAY=display,
            DISPLAY=":0",
            GDK_BACKEND=os.environ.get("CANVAS_TEST_BACKEND", "x11"),
            CLICK_LOG=str(click_log),
        )
        launch(
            [sys.executable, str(pathlib.Path(__file__).resolve()), "--client"],
            appenv,
            "client.log",
        )
        wait(lambda: len(json.loads(ctl("j/clients"))) == 1, "X11 client")
        pointer = Pointer(runtime / display)
        time.sleep(1)
        window = json.loads(ctl("j/clients"))[0]
        evaluate('hl.dispatch(hl.dsp.layout("camera-center"))')
        time.sleep(0.5)
        results = []

        def check(name, x=640, y=400):
            before = len(click_log.read_text().splitlines())
            pointer.move(x - 8, y - 8)
            pointer.move(x, y)
            time.sleep(0.2)
            pointer.click()
            time.sleep(0.3)
            events = [json.loads(line) for line in click_log.read_text().splitlines()]
            result = {
                "case": name,
                "window": next(
                    w
                    for w in json.loads(ctl("j/clients"))
                    if w["address"] == window["address"]
                ),
                "clicks": events[before:],
            }
            results.append(result)
            print(json.dumps(result), flush=True)

        check("tiled")
        evaluate(
            'hl.dispatch(hl.dsp.layout("move j"));hl.dispatch(hl.dsp.layout("camera-center"))'
        )
        time.sleep(0.6)
        check("lower-row")
        if results[-1]["clicks"] and appenv["GDK_BACKEND"] == "x11":
            pointer.click(273)
            time.sleep(0.4)
            popups = [w for w in json.loads(ctl("j/clients")) if w["floating"]]
            assert len(popups) == 1, popups
            popup = popups[0]
            assert (
                abs(popup["at"][0] - 640 / scale) < 30
                and abs(popup["at"][1] - 400 / scale) < 30
            ), popup
            pointer.move(
                round((popup["at"][0] + 40) * scale),
                round((popup["at"][1] + 14) * scale),
            )
            pointer.click()
            time.sleep(0.3)
            assert any(
                json.loads(line).get("menu_selected")
                for line in click_log.read_text().splitlines()
            ), "native X11 menu did not receive click"
            results.append({"case": "native-popup", "at": popup["at"], "pass": True})
        evaluate(
            'hl.dispatch(hl.dsp.layout("pan-begin"));hl.dispatch(hl.dsp.layout("pan-overview"))'
        )
        time.sleep(0.4)
        evaluate('hl.dispatch(hl.dsp.layout("pan-end"))')
        time.sleep(0.7)
        check("after-overview")
        evaluate('hl.dispatch(hl.dsp.focus({workspace="2"}))')
        time.sleep(0.3)
        evaluate(
            'hl.dispatch(hl.dsp.focus({workspace="1"}));hl.dispatch(hl.dsp.layout("camera-center"))'
        )
        time.sleep(0.7)
        check("after-workspace-return")
        for n in range(3):
            launch(
                [sys.executable, str(pathlib.Path(__file__).resolve()), "--client"],
                dict(appenv, CLICK_LOG=str(case / ("dummy-" + str(n) + ".jsonl"))),
                "dummy-" + str(n) + ".log",
            )
            wait(
                lambda: len(json.loads(ctl("j/clients"))) == n + 2,
                "additional canvas window",
            )
        evaluate(
            'hl.dispatch(hl.dsp.focus({window="address:'
            + window["address"]
            + '"}));hl.dispatch(hl.dsp.layout("camera-center"))'
        )
        time.sleep(0.8)
        assert (
            next(
                w
                for w in json.loads(ctl("j/clients"))
                if w["address"] == window["address"]
            )["at"][0]
            < 0
        ), "did not reproduce negative canvas coordinates"
        check("negative-column")
        evaluate(
            'hl.dispatch(hl.dsp.layout("pan-begin"));hl.dispatch(hl.dsp.layout("pan 75 0"))'
        )
        time.sleep(0.7)
        check("panned")
        evaluate('hl.dispatch(hl.dsp.layout("pan-end"))')
        time.sleep(0.7)
        check("after-pan")
        evaluate(
            'hl.dispatch(hl.dsp.window.float({action="enable"}));hl.dispatch(hl.dsp.window.resize({x=760,y=480}));hl.dispatch(hl.dsp.window.move({x=64,y=64}))'
        )
        time.sleep(0.6)
        check("floating", 400, 300)
        result = {
            "binary_sha256": hashlib.sha256(
                pathlib.Path(binary).read_bytes()
            ).hexdigest(),
            "config_sha256": hashlib.sha256(CONFIG.read_bytes()).hexdigest(),
            "test_sha256": hashlib.sha256(
                pathlib.Path(__file__).read_bytes()
            ).hexdigest(),
            "backend": appenv["GDK_BACKEND"],
            "scale": scale,
            "zero_scaling": os.environ.get("CANVAS_TEST_ZERO_SCALING") == "1",
            "cases": results,
        }
        result["pass"] = all(bool(r.get("clicks", r.get("pass"))) for r in results)
        (case / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        return 0 if result["pass"] else 1
    finally:
        if pointer:
            pointer.sock.close()
        for proc in reversed(processes):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        if listener:
            listener.close()
        if rule:
            parent("eval", rule + ":set_enabled(false);" + rule + "=nil")
        for log in logs:
            log.close()


if __name__ == "__main__":
    if sys.argv[1] == "--client":
        client()
    else:
        sys.exit(main(*sys.argv[1:3]))
