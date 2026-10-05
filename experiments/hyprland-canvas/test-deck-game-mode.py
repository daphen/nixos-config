#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ROOT / "dotfiles/hyprland/.config/hypr/scripts/deck-gaming-mode"
MOCK = r'''
import json, os, pathlib, re, sys, time
root = pathlib.Path(os.environ['FIXTURE'])
state = json.loads((root / 'state').read_text())
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')

def client(address):
    return next((item for item in state['clients'] if item['address'] == address), None)

def active():
    return client(state.get('active')) or {}

def save():
    (root / 'state').write_text(json.dumps(state))

if name == 'hyprctl':
    if args == ['-j', 'activeworkspace']:
        print(json.dumps(state['workspace']))
    elif args in (['-j', 'clients'], ['clients', '-j']):
        print(json.dumps(state['clients']))
    elif args == ['-j', 'activewindow']:
        print(json.dumps(active()))
    elif args[:2] == ['-j', 'getoption']:
        print(json.dumps({'int': 1}))
    elif args[:1] == ['eval']:
        print('ok')
    elif args[:1] == ['dispatch']:
        command = args[-1]
        if 'steam://open/bigpicture' in command:
            if state.get('fail') == 'launch':
                print('error: launch rejected')
                save()
                sys.exit(0)
            if not client('0x99'):
                state['clients'].append({
                    'address': '0x99', 'pid': 99, 'class': 'steam',
                    'title': 'Steam Big Picture Mode', 'workspace': state['workspace'].copy(),
                    'mapped': True, 'hidden': False, 'floating': False, 'pinned': False,
                    'fullscreen': 0, 'fullscreenClient': 0, 'tags': []})
        elif 'hl.dsp.focus({window=' in command:
            if state.get('fail') == 'focus':
                print('error: focus rejected')
                save()
                sys.exit(0)
            match = re.search(r'address:(0x[0-9a-f]+)', command)
            if match and client(match.group(1)):
                state['active'] = match.group(1)
        elif 'hl.dsp.window.tag' in command:
            address = re.search(r'address:(0x[0-9a-f]+)', command).group(1)
            tag = re.search(r'tag="([+-]?[^"}]+)', command).group(1)
            item = client(address)
            value = tag.lstrip('+-')
            if tag.startswith('-'):
                item['tags'] = [existing for existing in item['tags'] if existing != value]
            elif value not in item['tags']:
                item['tags'].append(value)
        elif 'hl.dsp.window.move' in command:
            address = re.search(r'address:(0x[0-9a-f]+)', command).group(1)
            client(address)['workspace'] = state['workspace'].copy()
        elif 'hl.dsp.window.fullscreen_state' in command:
            address = re.search(r'address:(0x[0-9a-f]+)', command).group(1)
            internal = int(re.search(r'internal=(\d+)', command).group(1))
            requested = int(re.search(r'client=(\d+)', command).group(1))
            client(address)['fullscreen'] = internal
            client(address)['fullscreenClient'] = requested
        print('ok')
    else:
        print('ok')
elif name == 'readlink':
    assert args[0] == '-f' and pathlib.Path(args[-1]).parent == pathlib.Path('/etc/inputplumber/profiles')
    print(root / 'profiles' / pathlib.Path(args[-1]).name)
elif name == 'inputplumber':
    if args[3] == 'path':
        print("Current profile path: '%s'" % state['profile'])
    else:
        if state.get('fail') == args[-1]:
            sys.exit(1)
        time.sleep(float(os.environ.get('PROFILE_DELAY', '0')))
        state['profile'] = args[-1]
elif name == 'systemctl':
    args = args[1:] if args[:1] == ['--user'] else args
    action = args[0]
    if action == 'whoami':
        unit = state.get('pids', {}).get(args[1])
        if not unit:
            sys.exit(1)
        print(unit)
    else:
        unit = args[1]
        units = state.setdefault('units', {})
        if unit not in units:
            if action == 'show' and 'LoadState' in args:
                print('not-found')
            else:
                sys.exit(1)
        elif action == 'show':
            prop = args[args.index('-p') + 1]
            print(units[unit].get(prop, ''))
        elif action in ('freeze', 'thaw'):
            if unit != 'deck-work.slice' and not unit.startswith('app-org.chromium.Chromium-fixture'):
                sys.exit(90)
            if state.get('fail') == action + ':' + unit:
                sys.exit(1)
            units[unit]['FreezerState'] = 'frozen' if action == 'freeze' else 'running'
            save()
            if action == 'freeze' and state.get('fail') == 'timeout:' + unit:
                time.sleep(4)
save()
'''


class ModeCommandTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="deck-mode-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = dict(
            os.environ,
            FIXTURE=str(self.root),
            XDG_RUNTIME_DIR=str(self.root),
            PATH=f'{self.root}:{os.environ["PATH"]}',
        )
        for name in (
            "hyprctl",
            "inputplumber",
            "busctl",
            "systemctl",
            "notify-send",
            "readlink",
            "pkill",
            "sleep",
        ):
            path = self.root / name
            path.write_text(f"#!{sys.executable}\n" + MOCK)
            path.chmod(0o755)
        self.configure()

    def window(self, address, class_name, title, *, pid=0, tags=None, workspace=None):
        return {
            "address": address,
            "pid": pid,
            "class": class_name,
            "title": title,
            "workspace": (workspace or self.workspace()).copy(),
            "mapped": True,
            "hidden": False,
            "floating": False,
            "pinned": False,
            "fullscreen": 0,
            "fullscreenClient": 0,
            "tags": list(tags or []),
        }

    def workspace(self, name="1"):
        return {"address": name, "type": "numbered", "name": name, "tiledLayout": "lua:canvas"}

    def configure(self, profile="canvas", fail=None):
        desktop = self.window("0x1", "deck-fixture-desktop", "Deck desktop fixture")
        self.write_state(
            {
                "workspace": self.workspace(),
                "active": desktop["address"],
                "profile": self.profile(profile),
                "fail": fail,
                "clients": [desktop],
                "pids": {},
                "units": {
                    "deck-work.slice": {
                        "LoadState": "loaded",
                        "FreezerState": "running",
                        "Slice": "",
                    }
                },
            }
        )
        (self.root / "calls").write_text("")
        (self.root / "deck-gaming-mode.frozen").unlink(missing_ok=True)
        (self.root / "deck-gaming-mode.return").unlink(missing_ok=True)

    def profile(self, name):
        return str(self.root / "profiles" / f"hyprland-{name}.yaml")

    def write_state(self, state):
        (self.root / "state").write_text(json.dumps(state))

    def state(self):
        return json.loads((self.root / "state").read_text())

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]

    def add_client(self, pid, workspace, unit, slice_name="app.slice", freezer="running", tags=None):
        data = self.state()
        address = f"0x{pid:x}"
        client = self.window(address, "browser-personal", f"Fixture {pid}", pid=pid, tags=tags)
        client["workspace"] = self.workspace(workspace)
        data["clients"].append(client)
        data["pids"][str(pid)] = unit
        data["units"][unit] = {
            "LoadState": "loaded",
            "FreezerState": freezer,
            "Slice": slice_name,
        }
        self.write_state(data)
        return address

    def add_game(self, *, address="0x99", class_name="steam", title="Steam Big Picture Mode", active=True):
        data = self.state()
        game = self.window(address, class_name, title, pid=99, tags=["deck-game", "deck-game-mode"])
        game["fullscreenClient"] = 2
        data["clients"].append(game)
        if active:
            data["active"] = address
        self.write_state(data)
        return address

    def run_mode(self, *args, success=True):
        result = subprocess.run(
            ["bash", str(COMMAND), *args],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=8,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr + result.stdout)

    def test_enter_and_return_keep_one_canvas_workspace(self):
        self.run_mode("enter")
        state = self.state()
        self.assertEqual(state["workspace"]["name"], "1")
        self.assertEqual(state["active"], "0x99")
        self.assertEqual(state["profile"], self.profile("gaming"))
        game = next(client for client in state["clients"] if client["address"] == "0x99")
        self.assertEqual(game["workspace"]["name"], "1")
        self.assertIn("deck-game-mode", game["tags"])
        self.run_mode("return")
        state = self.state()
        self.assertEqual(state["workspace"]["name"], "1")
        self.assertEqual(state["active"], "0x1")
        self.assertEqual(state["profile"], self.profile("canvas"))
        self.assertNotIn("deck-game-mode", game := next(c for c in state["clients"] if c["address"] == "0x99")["tags"])

    def test_enter_orders_fullscreen_move_focus_and_camera(self):
        self.run_mode("enter")
        calls = [str(call) for call in self.calls()]
        launch = next(i for i, call in enumerate(calls) if "steam://open/bigpicture" in call)
        clear = next(i for i, call in enumerate(calls) if "internal=0,client=0" in call)
        move = next(i for i, call in enumerate(calls) if "hl.dsp.window.move" in call)
        first_focus = next(i for i, call in enumerate(calls) if "address:0x99" in call and "hl.dsp.focus" in call)
        fullscreen = next(i for i, call in enumerate(calls) if "internal=0,client=2" in call)
        desktop_focus = next(i for i, call in enumerate(calls) if "address:0x1" in call and "hl.dsp.focus" in call)
        pan_begin = next(i for i, call in enumerate(calls) if 'layout("pan-begin")' in call)
        overview = next(i for i, call in enumerate(calls) if 'layout("overview")' in call)
        mode_tag = next(i for i, call in enumerate(calls) if "+deck-game-mode" in call)
        final_focus = max(i for i, call in enumerate(calls) if "address:0x99" in call and "hl.dsp.focus" in call)
        pan_end = next(i for i, call in enumerate(calls) if 'layout("pan-end")' in call)
        order = [launch, clear, move, first_focus, fullscreen, desktop_focus, pan_begin, overview, mode_tag, final_focus, pan_end]
        self.assertEqual(order, sorted(set(order)))
        self.assertFalse(any("name:gaming" in call or "game-mode-" in call for call in calls))

    def test_existing_big_picture_returns_to_desktop(self):
        self.add_game()
        self.run_mode("enter")
        self.run_mode("return")
        self.assertEqual(self.state()["active"], "0x1")
        self.assertEqual(self.state()["profile"], self.profile("canvas"))

    def test_gaming_tap_forwards_one_guide_chord(self):
        self.add_game()
        self.configure_game_profile()
        self.run_mode("tap")
        calls = [call for call in self.calls() if call[0] == "busctl"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-4:], ["SendButtonChord", "as", "1", "Gamepad:Button:Guide"])
        self.assertFalse(any(call[0] == "inputplumber" for call in self.calls()))

    def configure_game_profile(self):
        data = self.state()
        data["profile"] = self.profile("gaming")
        self.write_state(data)

    def test_return_from_desktop_does_nothing(self):
        self.run_mode("return")
        self.assertEqual(self.state()["active"], "0x1")
        self.assertFalse(any(call[:2] == ["hyprctl", "dispatch"] for call in self.calls()))

    def test_profile_failure_does_not_launch_or_move(self):
        self.configure(fail=self.profile("gaming"))
        self.run_mode("enter", success=False)
        calls = [str(call) for call in self.calls()]
        self.assertEqual(self.state()["profile"], self.profile("canvas"))
        self.assertFalse(any("steam://open/bigpicture" in call or "hl.dsp.window.move" in call for call in calls))

        self.configure(profile="gaming", fail=self.profile("canvas"))
        self.add_game()
        self.run_mode("return", success=False)
        self.assertEqual(self.state()["profile"], self.profile("gaming"))
        self.assertEqual(self.state()["active"], "0x99")

    def test_focus_failure_restores_input_profile(self):
        self.configure(fail="focus")
        self.run_mode("enter", success=False)
        self.assertEqual(self.state()["profile"], self.profile("canvas"))
        self.assertEqual(self.state()["workspace"]["name"], "1")

        self.configure(profile="gaming", fail="focus")
        self.add_game()
        self.run_mode("return", success=False)
        self.assertEqual(self.state()["profile"], self.profile("gaming"))
        self.assertEqual(self.state()["workspace"]["name"], "1")

    def test_rejected_launch_restores_work(self):
        self.configure(fail="launch")
        self.run_mode("enter", success=False)
        self.assertEqual(self.state()["active"], "0x1")
        self.assertEqual(self.state()["profile"], self.profile("canvas"))
        self.assertEqual(self.state()["units"]["deck-work.slice"]["FreezerState"], "running")

    def test_browser_scopes_freeze_but_tagged_game_browser_is_excluded(self):
        browser = "app-org.chromium.Chromium-fixture-browser.scope"
        self.add_client(10, "1", browser)
        self.run_mode("enter")
        self.assertEqual(self.state()["units"][browser]["FreezerState"], "frozen")
        self.run_mode("return")
        self.assertEqual(self.state()["units"][browser]["FreezerState"], "running")

        self.configure()
        self.add_client(10, "1", browser)
        self.add_client(11, "1", browser, tags=["deck-game"])
        self.run_mode("enter")
        self.assertEqual(self.state()["units"][browser]["FreezerState"], "running")

    def test_legacy_gaming_workspace_scope_is_still_excluded(self):
        browser = "app-org.chromium.Chromium-fixture-legacy.scope"
        self.add_client(10, "1", browser)
        self.add_client(11, "gaming", browser)
        self.run_mode("enter")
        self.assertEqual(self.state()["units"][browser]["FreezerState"], "running")

    def test_game_window_in_work_slice_blocks_entry(self):
        self.add_client(12, "1", "fixture-work.scope", "deck-work.slice", tags=["deck-game"])
        self.run_mode("enter", success=False)
        self.assertEqual(self.state()["units"]["deck-work.slice"]["FreezerState"], "running")
        self.assertEqual(self.state()["active"], "0x1")

    def test_pre_frozen_unit_is_not_owned_or_thawed(self):
        data = self.state()
        data["units"]["deck-work.slice"]["FreezerState"] = "frozen"
        self.write_state(data)
        self.run_mode("enter")
        self.run_mode("return")
        self.assertEqual(self.state()["units"]["deck-work.slice"]["FreezerState"], "frozen")

    def test_partial_failure_and_timeout_roll_back_owned_units(self):
        browser = "app-org.chromium.Chromium-fixture-fail.scope"
        for failure in ("freeze:" + browser, "timeout:" + browser):
            with self.subTest(failure=failure):
                self.configure(fail=failure)
                self.add_client(13, "1", browser)
                self.run_mode("enter", success=False)
                units = self.state()["units"]
                self.assertEqual(units["deck-work.slice"]["FreezerState"], "running")
                self.assertEqual(units[browser]["FreezerState"], "running")
                self.assertFalse((self.root / "deck-gaming-mode.frozen").exists())

    def test_cleanup_thaws_without_compositor_or_input(self):
        data = self.state()
        data["units"]["deck-work.slice"]["FreezerState"] = "frozen"
        self.write_state(data)
        (self.root / "deck-gaming-mode.frozen").write_text(
            "deck-work.slice\napp-org.chromium.Chromium-fixture-gone.scope\n"
        )
        (self.root / "hyprctl").unlink()
        (self.root / "inputplumber").unlink()
        self.run_mode("cleanup")
        self.assertEqual(self.state()["units"]["deck-work.slice"]["FreezerState"], "running")
        self.assertFalse((self.root / "deck-gaming-mode.frozen").exists())

    def test_return_waits_for_an_in_progress_entry(self):
        self.env["PROFILE_DELAY"] = "0.3"
        with subprocess.Popen(["bash", str(COMMAND), "enter"], env=self.env) as entering:
            for _ in range(100):
                if any(call[-1] == self.profile("gaming") for call in self.calls()):
                    break
                time.sleep(0.01)
            else:
                self.fail("entry never began loading the gaming profile")
            self.run_mode("return")
            self.assertEqual(entering.wait(timeout=5), 0)
        self.assertEqual(self.state()["active"], "0x1")
        self.assertEqual(self.state()["profile"], self.profile("canvas"))

    def test_desktop_sync_loads_canvas_once_and_clears_mode_tags(self):
        self.configure(profile="gaming")
        data = self.state()
        data["clients"][0]["tags"] = ["deck-game-mode"]
        self.write_state(data)
        self.run_mode("sync")
        self.run_mode("sync")
        loads = [call for call in self.calls() if call[0] == "inputplumber" and call[4] == "load"]
        self.assertEqual(len(loads), 1)
        self.assertEqual(self.state()["profile"], self.profile("canvas"))
        self.assertNotIn("deck-game-mode", self.state()["clients"][0]["tags"])

    def test_osk_sync_preserves_game_mode_with_marker(self):
        self.add_game(active=False)
        data = self.state()
        osk = self.window("0x77", "steam", "Steam Input On-screen Keyboard")
        osk["floating"] = True
        data["clients"].append(osk)
        data["active"] = "0x77"
        data["profile"] = self.profile("gaming")
        self.write_state(data)
        self.run_mode("sync")
        self.assertEqual(self.state()["profile"], self.profile("gaming"))
        game = next(client for client in self.state()["clients"] if client["address"] == "0x99")
        self.assertIn("deck-game-mode", game["tags"])

    def test_desktop_with_osk_uses_keyboard_profile(self):
        data = self.state()
        osk = self.window("0x77", "steam", "Steam Input On-screen Keyboard")
        osk["floating"] = True
        data["clients"].append(osk)
        self.write_state(data)
        self.run_mode("sync")
        self.assertEqual(self.state()["profile"], self.profile("keyboard"))


if __name__ == "__main__":
    unittest.main()
