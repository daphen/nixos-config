#!/usr/bin/env python3
"""The launch placeholder tiles like an app, keeps a resize, and hands its exact slot to the app's first window."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
spec = importlib.util.spec_from_file_location('rendering', ROOT / 'test-canvas-rendering.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--parent-instance', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    runtime = Path(tempfile.mkdtemp(prefix='c', dir=os.environ['XDG_RUNTIME_DIR']))
    runtime.chmod(0o700)
    live = lambda command: r.ipc(args.parent_instance, command)
    env = {k: v for k, v in os.environ.items() if k not in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'NOTIFY_SOCKET')}
    env.update(XDG_RUNTIME_DIR=str(runtime), HYPR_CANVAS_REAL='1', HYPR_CANVAS_PROFILE='workstation', AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none')
    rule = 'launch_placeholder_test_' + str(os.getpid())
    processes, logs = [], []

    def launch(command, environment, name):
        log = (args.output / name).open('w')
        logs.append(log)
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        return process

    assert live('eval ' + rule + '=hl.window_rule({name="' + rule + '",match={class="^aquamarine$"},workspace="special:' + rule
                + ' silent",float=true,no_initial_focus=true,no_focus=true})').strip() == 'ok'
    try:
        d = args.output
        config = d / 'hyprland.lua'
        config.write_text('package.path=' + json.dumps(str(r.CONFIG.resolve().parent) + '/?.lua;') + '..package.path\nlocal on=hl.on\nhl.on=function(event,cb) if event~="hyprland.start" then return on(event,cb) end end\n'
                          + 'dofile(' + json.dumps(str(r.CONFIG.resolve())) + ')\nhl.on=on\nhl.config({misc={disable_splash_rendering=true}})\n')
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(runtime / 'nested'))
        listener.listen(16)
        child_env = dict(env, XDG_STATE_HOME=str(d / 'state'), XDG_CONFIG_HOME=str(d / 'config'),
                         WAYLAND_DISPLAY=str(Path(os.environ['XDG_RUNTIME_DIR']) / os.environ['WAYLAND_DISPLAY']))
        log = (d / 'compositor.log').open('w'); logs.append(log)
        compositor = subprocess.Popen([str(args.binary), '--socket', 'nested', '--wayland-fd', str(listener.fileno()), '--config', str(config)],
                                      env=child_env, stdout=log, stderr=subprocess.STDOUT, pass_fds=(listener.fileno(),))
        processes.append(compositor)
        instance = r.wait(lambda: next((p for p in (runtime / 'hypr').glob('*') if (p / '.socket.sock').exists()), None)
                          if (runtime / 'hypr').exists() else None, [compositor])
        ctl = lambda command: r.ipc(instance, command)
        assert not ctl('configerrors').strip(), ctl('configerrors')
        assert ctl('eval hl.monitor({output="HEADLESS-1",mode="1920x1080@60",position="0x0",scale=1})').strip() == 'ok'
        assert ctl('output create headless HEADLESS-1').strip() == 'ok'
        r.wait(lambda: any(m['name'] == 'HEADLESS-1' for m in json.loads(ctl('j/monitors'))), [compositor])
        assert ctl('eval hl.monitor({output="WAYLAND-1",disabled=true})').strip() == 'ok'
        r.wait(lambda: [m['name'] for m in json.loads(ctl('j/monitors'))] == ['HEADLESS-1'], [compositor])
        app = dict(child_env, WAYLAND_DISPLAY='nested', HYPRLAND_INSTANCE_SIGNATURE=instance.name, QT_QPA_PLATFORM='wayland')
        clients = lambda: {w['title']: w for w in json.loads(ctl('j/clients'))}
        box = lambda w: (tuple(w['at']), tuple(w['size']))

        launch(['kitty', '-T', 'Editor', '--config', 'NONE', '-o', 'background=#334455'], app, 'editor.log')
        r.wait(lambda: 'Editor' in clients(), [compositor])
        shell = d / 'config' / 'quickshell'; shell.mkdir(parents=True, exist_ok=True)
        (shell / 'LaunchPlaceholder.qml').write_bytes((REPO / 'dotfiles/quickshell/.config/quickshell/modules/LaunchPlaceholder.qml').read_bytes())
        (shell / 'shell.qml').write_text('import Quickshell\nShellRoot { LaunchPlaceholder {} }\n')
        launch(['qs'], app, 'qs.log')
        r.wait(lambda: 'Configuration Loaded' in (d / 'qs.log').read_text(), [compositor])
        bin_dir = d / 'bin'; bin_dir.mkdir(exist_ok=True)
        app['PATH'] = f"{bin_dir}:{app['PATH']}"
        desktop_launch = str(REPO / 'dotfiles/hyprland/.config/hypr/scripts/desktop-launch')
        fake = bin_dir / 'slack'
        fake.write_text('#!/bin/sh\nsleep 0.3\n'); fake.chmod(0o755)
        subprocess.run([desktop_launch, 'slack'], env=app, check=True, timeout=10)
        seen = False
        for _ in range(20):
            seen = seen or 'qs-launch · Slack' in clients(); time.sleep(.05)
        assert 'qs-launch · Slack' not in clients(), 'a launch that exits without a window left its placeholder'
        print('PASS focus-only launch dropped its placeholder (briefly shown: %s)' % seen)
        launch(['kitty', '-T', 'Other', '--config', 'NONE'], app, 'other.log')
        r.wait(lambda: clients().get('Other', {}).get('focusHistoryID') == 0, [compositor])
        focus = REPO / 'dotfiles/hyprland/.config/hypr/scripts/hypr-dispatch'
        fake.write_text(f'#!/bin/sh\nsleep 0.1\n{focus} focuswindow title:Editor\nsleep 5\n'); fake.chmod(0o755)
        started = time.monotonic()
        focusing = subprocess.Popen([desktop_launch, 'slack'], env=app)
        processes.append(focusing)
        seen = False
        while time.monotonic() - started < 1.5:
            seen = seen or 'qs-launch · Slack' in clients(); time.sleep(.03)
        assert focusing.poll() is None and not seen, 'a launch that focused an open window showed a placeholder'
        print('PASS launch that focused an open window never showed a placeholder')
        focusing.kill()
        fake.write_text('#!/bin/sh\nread _ < /proc/self/fd/0 2>/dev/null; sleep 30\n'); fake.chmod(0o755)
        slow = subprocess.Popen([desktop_launch, 'slack'], env=app, stdin=subprocess.PIPE)
        processes.append(slow)
        placeholder = r.wait(lambda: clients().get('qs-launch · Slack'), [compositor])
        assert not placeholder['floating'], placeholder
        assert ctl('dispatch hl.dsp.focus({window=' + json.dumps('address:' + placeholder['address']) + '})').strip() == 'ok'
        before = box(clients()['qs-launch · Slack'])
        for _ in range(2):
            assert ctl('dispatch hl.dsp.layout("resize l")').strip() == 'ok'
        time.sleep(1.2)
        resized = box(clients()['qs-launch · Slack'])
        assert resized[1] != before[1], ('placeholder did not resize', before, resized)
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(d / 'loading.png')], env=app, check=True, timeout=10)

        launch(['kitty', '-T', 'Slack', '--config', 'NONE', '-o', 'background=#552233'], app, 'slack.log')
        r.wait(lambda: 'Slack' in clients(), [compositor])
        time.sleep(.1)
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(d / 'crossfade.png')], env=app, check=True, timeout=10)
        r.wait(lambda: 'qs-launch · Slack' not in clients(), [compositor])
        time.sleep(1.2)
        final = clients()
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(d / 'loaded.png')], env=app, check=True, timeout=10)
        assert box(final['Slack']) == resized, ('app did not take the placeholder slot', resized, box(final['Slack']))
        assert box(final['Editor']) == box(clients()['Editor'])
        print('PASS placeholder', resized, '-> app', box(final['Slack']))
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
        r.wait(lambda: not any(w['workspace']['name'] == 'special:' + rule for w in json.loads(live('j/clients'))), [])
        assert live('eval ' + rule + ':set_enabled(false);' + rule + '=nil').strip() == 'ok'
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
