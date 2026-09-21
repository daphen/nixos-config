#!/usr/bin/env python3
"""Public-entry regression test for canvas xdg_popup constraint placement."""
import ctypes as c
import hashlib
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import time

ROOT = pathlib.Path("/home/daphen/.cache/canvas-popup-position")
GTK = "/nix/store/yl5yl395iqx88kd1m7lx7p7b65n0jfx9-gtk+3-3.24.51/lib/libgtk-3.so.0"
SOURCE_CONFIG = pathlib.Path("/home/daphen/nixos/dotfiles/hyprland/.config/hypr/hyprland.lua")
ANCHOR = (200, 150)


def client():
    gtk = c.CDLL(GTK)
    p, i = c.c_void_p, c.c_int

    def fn(name, result, *args):
        value = getattr(gtk, name)
        value.restype, value.argtypes = result, list(args)
        return value

    fn("g_set_prgname", None, c.c_char_p)(os.environ["POPUP_CLASS"].encode())
    assert fn("gtk_init_check", i, p, p)(None, None)
    window = fn("gtk_window_new", p, i)(0)
    fn("gtk_window_set_title", None, p, c.c_char_p)(window, os.environ["POPUP_TITLE"].encode())
    fn("gtk_window_set_default_size", None, p, i, i)(window, 760, 480)
    area = fn("gtk_drawing_area_new", p)()
    fn("gtk_container_add", None, p, p)(window, area)
    fn("gtk_widget_show_all", None, p)(window)
    state = {"requested": False, "menu": None}

    @c.CFUNCTYPE(i, p)
    def poll(_):
        command = pathlib.Path(os.environ["POPUP_COMMAND"])
        if command.exists() and not state["requested"]:
            state["requested"] = True
            menu = fn("gtk_menu_new", p)()
            item = fn("gtk_menu_item_new_with_label", p, c.c_char_p)(b"Native xdg_popup regression")
            fn("gtk_widget_set_size_request", None, p, i, i)(item, 220, 90)
            fn("gtk_menu_shell_append", None, p, p)(menu, item)
            fn("gtk_widget_show_all", None, p)(menu)
            gdk_window = fn("gtk_widget_get_window", p, p)(area)

            class Rect(c.Structure):
                _fields_ = [("x", i), ("y", i), ("width", i), ("height", i)]

            rect = Rect(ANCHOR[0], ANCHOR[1], 1, 1)
            print(f"POPUP_REQUEST anchor={ANCHOR[0]},{ANCHOR[1]}", file=sys.stderr, flush=True)
            # GDK_GRAVITY_SOUTH_WEST -> NORTH_WEST, with flip/slide/resize hints.
            fn("gtk_menu_popup_at_rect", None, p, p, c.POINTER(Rect), i, i, p)(
                menu, gdk_window, c.byref(rect), 7, 1, None
            )
            state["menu"] = menu
            pathlib.Path(os.environ["POPUP_SHOWN"]).write_text("shown\n")
        return 1

    fn("g_timeout_add", c.c_uint, c.c_uint, p, p)(50, c.cast(poll, p), None)
    pathlib.Path(os.environ["POPUP_READY"]).write_text("ready\n")
    fn("gtk_main", None)()


def wait(predicate, label, processes=(), seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        dead = [proc.args for proc in processes if proc.poll() is not None]
        if dead:
            raise RuntimeError(f"{label}: process exited: {dead}")
        time.sleep(0.1)
    raise TimeoutError(label)


def run_inside(binary, label):
    case = ROOT / label
    case.mkdir(parents=True, exist_ok=True)
    runtime = pathlib.Path(f"/tmp/cp-{os.getpid()}")
    runtime.mkdir(exist_ok=True)
    runtime.chmod(0o700)
    config_dir = case / "config"
    config_dir.mkdir(exist_ok=True)
    helper = case / "canvas-state.lua"
    if not helper.exists():
        helper.symlink_to(SOURCE_CONFIG.with_name("canvas-state.lua"))
    wrapper = case / "hyprland.lua"
    wrapper.write_text(
        "local on = hl.on\n"
        "hl.on = function(event, callback) if event ~= 'hyprland.start' then return on(event, callback) end end\n"
        f"dofile({json.dumps(str(SOURCE_CONFIG))})\n"
        "hl.on = on\n"
    )
    for name in ("ready", "shown", "show"):
        (case / name).unlink(missing_ok=True)

    env = os.environ.copy()
    for key in ("DISPLAY", "WAYLAND_DISPLAY", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE", "NIRI_SOCKET"):
        env.pop(key, None)
    env.update(
        HOME=str(case / "home"), XDG_CONFIG_HOME=str(config_dir), XDG_STATE_HOME=str(case / "state"),
        XDG_CACHE_HOME=str(case / "cache"), XDG_RUNTIME_DIR=str(runtime),
    )
    pathlib.Path(env["HOME"]).mkdir(exist_ok=True)
    processes, logs = [], []

    def launch(args, child_env, log_name, **kwargs):
        log = (case / log_name).open("w")
        logs.append(log)
        proc = subprocess.Popen(args, env=child_env, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        processes.append(proc)
        return proc

    listener = None
    parent_ctl = None
    try:
        ctl = pathlib.Path("/home/daphen/.cache/hyprland-canvas-dev/validated/bin/hyprctl")
        lock = max(pathlib.Path("/run/user/1000/hypr").glob("*/hyprland.lock"), key=lambda p: p.stat().st_mtime)
        parent_pid, parent_display = lock.read_text().splitlines()
        if not pathlib.Path("/proc", parent_pid).exists():
            raise RuntimeError("live parent Hyprland lock is stale")
        parent_env = dict(os.environ, XDG_RUNTIME_DIR="/run/user/1000", HYPRLAND_INSTANCE_SIGNATURE=lock.parent.name)

        def parent_ctl(*args):
            return subprocess.check_output([str(ctl), *args], env=parent_env, text=True, timeout=5)

        focus_before = json.loads(parent_ctl("-j", "activewindow"))
        rule_name = f"canvas_popup_position_rule_{os.getpid()}"
        rule = (rule_name + " = hl.window_rule({name=" + json.dumps(rule_name) +
                ",match={class='^aquamarine$'},workspace='special:canvas-popup-position silent',float=true,"
                "size='1280 720',no_initial_focus=true,no_focus=true,render_unfocused=true})")
        answer = parent_ctl("eval", rule)
        if answer.startswith("error"):
            raise RuntimeError(answer)
        child_env = env.copy()
        child_env.pop("WLR_BACKENDS", None)
        child_env.pop("WLR_HEADLESS_OUTPUTS", None)
        child_env.update(
            WAYLAND_DISPLAY=str(pathlib.Path("/run/user/1000") / parent_display), AQ_DRM_DEVICES="/dev/null",
            LIBSEAT_BACKEND="none", LIBGL_ALWAYS_SOFTWARE="0", WLR_RENDERER="gles2",
            WLR_RENDER_DRM_DEVICE="/dev/dri/by-path/pci-0000:65:00.0-render",
            HYPR_CANVAS_REAL="1", HYPR_CANVAS_PROFILE="workstation",
            PATH=str(binary.parent) + ":" + child_env["PATH"],
        )
        display = "wayland-canvas-popup"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(runtime / display))
        listener.listen(16)
        hypr = launch(
            [str(binary), "--socket", display, "--wayland-fd", str(listener.fileno()), "--config", str(wrapper)],
            child_env, "hyprland.log", pass_fds=(listener.fileno(),),
        )
        instance = wait(lambda: next((p for p in (runtime / "hypr").glob("*") if (p / ".socket.sock").exists()), None), "Hyprland IPC", [hypr], 25)
        nested = wait(lambda: next((w for w in json.loads(parent_ctl("-j", "clients")) if w["pid"] == hypr.pid), None), "hidden nested compositor", [hypr])
        if not nested["floating"] or nested["workspace"]["address"] != "special:canvas-popup-position":
            raise AssertionError(f"nested compositor was not hidden: {nested}")
        if json.loads(parent_ctl("-j", "activewindow")) != focus_before:
            raise AssertionError("nested compositor changed live focus")
        app_env = child_env.copy()
        app_env.update(
            WAYLAND_DISPLAY=display, HYPRLAND_INSTANCE_SIGNATURE=instance.name, GDK_BACKEND="wayland",
            WAYLAND_DEBUG="1", POPUP_CLASS="canvas-popup-test", POPUP_TITLE="Canvas popup parent",
            POPUP_READY=str(case / "ready"), POPUP_SHOWN=str(case / "shown"), POPUP_COMMAND=str(case / "show"),
        )
        def hyprctl(*args):
            return subprocess.check_output([str(ctl), *args], env=app_env, text=True, timeout=5)

        app = launch([sys.executable, str(pathlib.Path(__file__).resolve()), "--client"], app_env, "client.log")
        wait(lambda: (case / "ready").exists() and json.loads(hyprctl("-j", "clients")), "GTK canvas parent", [hypr, app])
        # Additional tiles push the first window deeply negative in canvas world space.
        dummies = []
        for number in range(5):
            dummy_env = dict(app_env, POPUP_CLASS=f"canvas-popup-dummy-{number}", POPUP_TITLE=f"Canvas popup dummy {number}",
                             POPUP_READY=str(case / f"dummy-{number}-ready"), POPUP_SHOWN=str(case / f"dummy-{number}-shown"),
                             POPUP_COMMAND=str(case / "never"), WAYLAND_DEBUG="0")
            dummies.append(launch([sys.executable, str(pathlib.Path(__file__).resolve()), "--client"], dummy_env, f"dummy-{number}.log"))
        wait(lambda: len(json.loads(hyprctl("-j", "clients"))) >= 6, "six canvas windows", [hypr, app, *dummies])
        time.sleep(0.5)
        parent = next(w for w in json.loads(hyprctl("-j", "clients")) if w["title"] == "Canvas popup parent")
        hyprctl("dispatch", f"hl.dsp.focus({{ window = 'address:{parent['address']}' }})")
        time.sleep(1.0)
        hyprctl("dispatch", 'hl.dsp.layout("pan 900 0")')
        time.sleep(1.0)
        parent = next(w for w in json.loads(hyprctl("-j", "clients")) if w["title"] == "Canvas popup parent")
        (case / "show").write_text("show\n")
        wait(lambda: (case / "shown").exists(), "native popup request", [hypr, app, *dummies])
        time.sleep(1)
        def popup_configure(log_name):
            text = (case / log_name).read_text(errors="replace")
            tail = text[text.rfind("POPUP_REQUEST"):]
            matches = re.findall(r"xdg_popup[#@]\d+\.configure\((-?\d+), (-?\d+), (\d+), (\d+)\)", tail)
            if not matches:
                raise AssertionError(f"{log_name} contained no xdg_popup.configure after request")
            return list(map(int, matches[-1]))

        x, y, width, height = popup_configure("client.log")
        error = abs(x - ANCHOR[0])
        if y != ANCHOR[1] + 1:
            raise AssertionError(f"canvas popup vertical configure was {y}, expected {ANCHOR[1] + 1}")

        app.terminate()
        app.wait(timeout=4)
        wait(lambda: all(w["title"] != "Canvas popup parent" for w in json.loads(hyprctl("-j", "clients"))), "canvas parent close", [hypr, *dummies])
        for name in ("ready", "shown", "show"):
            (case / name).unlink(missing_ok=True)
        floating_env = dict(app_env, POPUP_CLASS="file-chooser", POPUP_TITLE="Floating popup control")
        floating = launch([sys.executable, str(pathlib.Path(__file__).resolve()), "--client"], floating_env, "floating-client.log")
        wait(lambda: (case / "ready").exists() and any(w["title"] == "Floating popup control" for w in json.loads(hyprctl("-j", "clients"))),
             "floating GTK parent", [hypr, floating, *dummies])
        floating_parent = next(w for w in json.loads(hyprctl("-j", "clients")) if w["title"] == "Floating popup control")
        if not floating_parent["floating"]:
            raise AssertionError("floating control parent was tiled")
        (case / "show").write_text("show\n")
        wait(lambda: (case / "shown").exists(), "floating native popup request", [hypr, floating, *dummies])
        time.sleep(1)
        floating_configure = popup_configure("floating-client.log")
        expected = [ANCHOR[0], ANCHOR[1] + 1]
        if floating_configure[:2] != expected:
            raise AssertionError(f"floating popup configure was {floating_configure[:2]}, expected {expected}")

        result = {
            "label": label, "binary": str(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "source_config_sha256": hashlib.sha256(SOURCE_CONFIG.read_bytes()).hexdigest(),
            "parent": {"at": parent["at"], "size": parent["size"], "floating": parent["floating"], "monitor": parent["monitor"]},
            "requested_anchor": list(ANCHOR), "popup_configure": [x, y, width, height], "horizontal_error": error,
            "floating_control": {"parent_floating": floating_parent["floating"], "popup_configure": floating_configure,
                                 "expected_position": expected, "pass": True},
            "pass": error <= 4,
        }
        (case / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2), flush=True)
        return result
    finally:
        for proc in reversed(processes):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        if listener:
            listener.close()
        if parent_ctl:
            parent_ctl("eval", f"if {rule_name} then {rule_name}:set_enabled(false); {rule_name}=nil end")
        for log in logs:
            log.close()
        internal_logs = list((runtime / "hypr").glob("*/hyprland.log"))
        if internal_logs:
            shutil.copy2(internal_logs[-1], case / "hyprland-internal.log")
        shutil.rmtree(runtime, ignore_errors=True)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--client":
        client()
        return
    binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "before-Hyprland").resolve()
    label = sys.argv[2] if len(sys.argv) > 2 else binary.name
    private = ROOT / label
    private.mkdir(parents=True, exist_ok=True)
    if os.environ.get("CANVAS_POPUP_PRIVATE_DBUS") != "1":
        env = os.environ.copy()
        env.update(CANVAS_POPUP_PRIVATE_DBUS="1", HOME=str(private / "home"), XDG_CONFIG_HOME=str(private / "config"),
                   XDG_STATE_HOME=str(private / "state"), XDG_CACHE_HOME=str(private / "cache"))
        completed = subprocess.run(["dbus-run-session", "--", sys.executable, str(pathlib.Path(__file__).resolve()), str(binary), label], env=env)
        raise SystemExit(completed.returncode)
    result = run_inside(binary, label)
    raise SystemExit(0 if result["pass"] else 1)


if __name__ == "__main__":
    main()
