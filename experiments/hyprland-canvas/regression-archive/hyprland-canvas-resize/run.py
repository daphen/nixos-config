import hashlib, json, os, pathlib, signal, socket, subprocess, sys, tempfile, time
root = pathlib.Path(__file__).parent
label = sys.argv[1]
scenario = sys.argv[3] if len(sys.argv) > 3 else 'grow'
case = root / label
case.mkdir(exist_ok=True)
runtime = pathlib.Path(tempfile.mkdtemp(prefix='cr-'))
binary = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else '/home/daphen/.cache/hyprland-canvas-dev/validated/bin/Hyprland')
ctlbin = '/home/daphen/.cache/hyprland-canvas-dev/validated/bin/hyprctl'
env = os.environ.copy()
for key in ('HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY', 'DISPLAY', 'SWAYSOCK', 'NOTIFY_SOCKET', 'XDG_SESSION_ID', 'HYPR_CANVAS_REAL'):
    env.pop(key, None)
env.update(XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(case/'state'), XDG_CONFIG_HOME=str(case/'config'), WLR_BACKENDS='headless', WLR_RENDERER='gles2', WLR_RENDER_DRM_DEVICE='/dev/dri/by-path/pci-0000:65:00.0-render', WLR_LIBINPUT_NO_DEVICES='1', LIBGL_ALWAYS_SOFTWARE='0')
(case/'sway.conf').write_text('output * mode 1280x720\n')
config = '/home/daphen/nixos/dotfiles/hyprland/.config/hypr/hyprland.lua'
helper = case/'canvas-state.lua'
if not helper.exists(): helper.symlink_to(pathlib.Path(config).with_name('canvas-state.lua'))
(case/'arm').unlink(missing_ok=True)
(case/'client-size').unlink(missing_ok=True)
(case/'delayed').unlink(missing_ok=True)
(case/'frame-ready').unlink(missing_ok=True)
(case/'result.json').unlink(missing_ok=True)
(case/'hyprland.lua').write_text('local on = hl.on\nhl.on = function(event, callback) if event ~= "hyprland.start" then return on(event, callback) end end\ndofile('+json.dumps(config)+')\nhl.on = on\n')
if scenario == 'fractional':
    with (case/'hyprland.lua').open('a') as config_file:
        config_file.write('\nhl.monitor({output="WAYLAND-1",mode="1296x720@60",scale=1.5})\n')
processes = []
logs = []
listener = None
def launch(args, environment, filename):
    log = open(case/filename, 'w'); logs.append(log)
    process = subprocess.Popen(args, env=environment, stdout=log, stderr=subprocess.STDOUT)
    processes.append(process)
    return process
def wait(test, description):
    for _ in range(100):
        value = test()
        if value: return value
        assert all(p.poll() is None for p in processes), description + ': a process exited'
        time.sleep(.1)
    raise AssertionError(description)
try:
    lock = max(pathlib.Path('/run/user/1000/hypr').glob('*/hyprland.lock'), key=lambda p: p.stat().st_mtime)
    parent_pid, parent_socket = lock.read_text().splitlines()
    assert pathlib.Path('/proc', parent_pid).exists()
    parent_env = dict(os.environ, XDG_RUNTIME_DIR='/run/user/1000', HYPRLAND_INSTANCE_SIGNATURE=lock.parent.name)
    def parent_ctl(*args):
        return subprocess.check_output([ctlbin, *args], env=parent_env, text=True, timeout=5)
    rule = 'canvas_resize_test_rule = hl.window_rule({name="canvas-resize-test",match={class="^aquamarine$"},workspace="special:canvas-resize-test silent",float=true,size="1280 720",no_initial_focus=true,no_focus=true,render_unfocused=true})'
    if scenario == 'fractional':
        rule = rule.replace('size="1280 720"', 'size="1296 720"')
    if scenario == 'preview':
        preview_workspace = json.loads(parent_ctl('-j', 'activewindow'))['workspace']['address']
        rule = rule.replace('workspace="special:canvas-resize-test silent"', 'workspace='+json.dumps(preview_workspace+' silent'))
    answer = parent_ctl('eval', rule)
    assert not answer.startswith('error'), answer
    parent = pathlib.Path('/run/user/1000') / parent_socket
    name = 'wayland-resize'
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(runtime/name)); listener.listen(16)
    child_env = dict(env, WAYLAND_DISPLAY=str(parent), AQ_DRM_DEVICES='/dev/null', LIBSEAT_BACKEND='none')
    log = open(case/'hyprland.log', 'w'); logs.append(log)
    hypr = subprocess.Popen([str(binary), '--socket', name, '--wayland-fd', str(listener.fileno()), '--config', str(case/'hyprland.lua')], env=child_env, pass_fds=(listener.fileno(),), stdout=log, stderr=subprocess.STDOUT)
    processes.append(hypr)
    instance = wait(lambda: next((p for p in (runtime/'hypr').glob('*') if (p/'.socket.sock').exists()), None), 'test compositor IPC')
    child_env.update(WAYLAND_DISPLAY=name, HYPRLAND_INSTANCE_SIGNATURE=instance.name)
    test_window = wait(lambda: next((w for w in json.loads(parent_ctl('-j', 'clients')) if w['pid'] == hypr.pid), None), 'hidden test window')
    assert test_window['floating'] and test_window['workspace']['address'] == (preview_workspace if scenario == 'preview' else 'special:canvas-resize-test'), test_window
    preview_deadline = time.monotonic() + 30
    assert json.loads(parent_ctl('-j', 'activewindow')).get('pid') != hypr.pid, 'test stole focus'
    def ctl(*args):
        return subprocess.check_output([ctlbin, *args], env=child_env, text=True, timeout=5)
    time.sleep(.5)
    errors = ctl('configerrors').strip()
    assert not errors, errors
    if scenario == 'fractional':
        assert json.loads(ctl('-j', 'monitors'))[0]['scale'] == 1.5, 'fractional output scale was not applied'
    app_env = dict(child_env, GDK_BACKEND='wayland')
    if scenario.startswith('slow'): app_env['RESIZE_DELAY'] = '.8' if scenario == 'slow-otherlayout' else '.35'
    if scenario in ('slow-hidden', 'slow-otherlayout'): app_env['RESIZE_NO_REPAINT'] = '1'
    if scenario in ('transparent', 'transparent-rapid'): app_env['RESIZE_ALPHA'] = '1'
    app_command = ['dbus-run-session', '--', '/nix/store/x4yjfzaslrwhk26qp242mnwdzidap7c8-gtk+3-3.24.51-dev/bin/gtk3-demo'] if scenario in ('gtk-demo', 'preview') else [sys.executable, str(root/'client.py'), str(case)]
    if scenario == 'qt-demo':
        app_command = ['quickshell', '-p', str(root/'qt.qml')]
    app = launch(app_command, app_env, 'client.log')
    wait(lambda: (scenario in ('gtk-demo', 'qt-demo', 'preview') or (case/'client-size').exists()) and json.loads(ctl('-j', 'clients')), 'test app')
    time.sleep(1)
    if scenario == 'preview':
        print('canvas-resize-preview: visible; automatic live resizing for 30 seconds', flush=True)
        step = 0
        while time.monotonic() < preview_deadline:
            ctl('dispatch', 'hl.dsp.layout("resize '+('l' if (step//3)%2 == 0 else 'h')+'")')
            step += 1
            time.sleep(min(.8, max(0, preview_deadline-time.monotonic())))
        print('canvas-resize-preview: complete; closing only the isolated test', flush=True)
        sys.exit(0)
    if scenario in ('gtk-demo', 'qt-demo'):
        (case/'client-size').write_text(' '.join(map(str, json.loads(ctl('-j', 'activewindow'))['size'])))
    if scenario in ('fullscreen', 'float'):
        ctl('dispatch', 'hl.dsp.window.'+scenario+'()')
        time.sleep(.5)
    original_workspace = json.dumps(json.loads(ctl('-j', 'activewindow'))['workspace']['address'])
    if scenario == 'offscreen':
        for _ in range(20): ctl('dispatch', 'hl.dsp.layout("resize l")')
        time.sleep(.7)
    (case/'arm').write_text((case/'client-size').read_text())
    frames = case/'frames'; frames.mkdir(exist_ok=True)
    subprocess.run(['grim', str(frames/'before.png')], env=child_env, check=True, timeout=5)
    subprocess.run(['grim', '-t', 'ppm', str(frames/'before.ppm')], env=child_env, check=True, timeout=5)
    t = time.monotonic()
    direction = {'shrink': 'h', 'vertical': 'j', 'offscreen': 'h'}.get(scenario, 'l')
    for _ in range(12 if scenario == 'offscreen' else 1):
        ctl('dispatch', 'hl.dsp.window.resize({x=64,y=0,relative=true})' if scenario == 'float' else f'hl.dsp.layout("resize {direction}")')
    times = []
    for frame in range(35):
        if scenario in ('slow-hidden', 'slow-otherlayout') and frame == (7 if scenario == 'slow-otherlayout' else 1):
            if scenario == 'slow-otherlayout':
                ctl('eval', 'hl.workspace_rule({workspace="2",layout="dwindle"})')
            ctl('dispatch', 'hl.dsp.focus({workspace=2})')
            time.sleep(.7)
            initial = list(map(int, (case/'arm').read_text().split()))
            assert list(map(int, (case/'client-size').read_text().split())) == [initial[0]+64, initial[1]], 'final redraw not produced while hidden'
            app.send_signal(signal.SIGSTOP)
            ctl('dispatch', f'hl.dsp.focus({{workspace={original_workspace}}})')
            time.sleep(.4)
        if scenario in ('rapid', 'transparent-rapid', 'slow-rapid') and frame in (1, 2, 3, 4):
            ctl('dispatch', 'hl.dsp.layout("resize '+('h' if frame % 2 else 'l')+'")')
        if scenario in ('stress', 'slow-stress') and frame < 30:
            ctl('dispatch', 'hl.dsp.layout("resize '+('l' if frame % 2 else 'h')+'")')
        if scenario == 'sequential' and frame == 10:
            (case/'arm').write_text((case/'client-size').read_text())
            time.sleep(.25)
            subprocess.run(['grim', '-t', 'ppm', str(frames/'second-before.ppm')], env=child_env, check=True, timeout=5)
            ctl('dispatch', 'hl.dsp.layout("resize l")')
        if scenario in ('close', 'slow-close') and frame == 1:
            app.terminate(); app.wait(timeout=5)
        subprocess.run(['grim', '-t', 'ppm', str(frames/f'{frame:03}.ppm')], env=child_env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        times.append(time.monotonic()-t)
        time.sleep(.005)
    def center_color(path):
        magic, dimensions, maximum, pixels = path.read_bytes().split(b'\n', 3)
        assert magic == b'P6' and maximum == b'255'
        width, height = map(int, dimensions.split())
        offset = ((height // 2) * width + width // 2) * 3
        return tuple(pixels[offset:offset+3])
    def body_size(path):
        _, dimensions, _, pixels = path.read_bytes().split(b'\n', 3)
        w, h = map(int, dimensions.split())
        sizes = []
        for positions in ([((h//2)*w+x)*3 for x in range(w)], [(y*w+w//2)*3 for y in range(h)]):
            body = [n for n, p in enumerate(positions) if pixels[p+1] < 15 and pixels[p]+pixels[p+2] > 100]
            sizes.append(max(body)-min(body)+1 if body else 0)
        return sizes
    colors = [center_color(frames/f'{frame:03}.ppm') for frame in range(35)]
    mixed = [n for n, (r,g,b) in enumerate(colors) if r > 20 and b > 20 and g < 12]
    bar_errors = []
    energy_errors = []
    for frame in range(35):
        _, dimensions, _, pixels = (frames/f'{frame:03}.ppm').read_bytes().split(b'\n', 3)
        width, height = map(int, dimensions.split())
        row = pixels[(height//2)*width*3:(height//2+1)*width*3]
        body = [x for x in range(width) if row[x*3+1] < 15 and row[x*3]+row[x*3+2] > 100]
        whites = {x for x in range(width) if min(row[x*3:x*3+3]) > 230}
        starts = sorted(x for x in whites if x-1 not in whites)
        if body:
            core = [x for x in body if min(body)+8 < x < max(body)-8]
            energy_errors.append(max((abs(row[x*3]+row[x*3+2]-row[x*3+1]-255) for x in core), default=0))
        if body and len(starts) == 2:
            bar_errors.append(max(abs((x-min(body))/(max(body)-min(body)+1)-fraction) for x, fraction in zip(starts, (.25,.75))))
    result = dict(scenario=scenario, initial_size=body_size(frames/'before.ppm'), sizes=[body_size(frames/f'{n:03}.ppm') for n in range(35)], client_ready_after=float((case/'frame-ready').read_text())-t if (case/'frame-ready').exists() else None, source_patch_sha256=os.environ.get('RESIZE_PATCH_SHA'), binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), config_sha256=hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest(), client_sha256=hashlib.sha256((root/'client.py').read_bytes()).hexdigest(), runner_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(), times=times, center_colors=colors, mixed_frames=mixed, bar_errors=bar_errors, energy_errors=energy_errors, monitor=json.loads(ctl('-j','monitors')), window=json.loads(ctl('-j','activewindow')))
    (case/'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(dict(label=label, mixed_frames=mixed, colors=colors[:15], final_color=colors[-1])), flush=True)
finally:
    if scenario in ('slow-hidden', 'slow-otherlayout') and 'app' in globals() and app.poll() is None:
        app.send_signal(signal.SIGCONT)
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
    if listener: listener.close()
    if 'parent_ctl' in globals():
        parent_ctl('eval', 'if canvas_resize_test_rule then canvas_resize_test_rule:set_enabled(false); canvas_resize_test_rule=nil end')
    for log in logs: log.close()
