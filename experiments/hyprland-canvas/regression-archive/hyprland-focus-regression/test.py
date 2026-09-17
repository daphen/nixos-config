from pathlib import Path
root=Path(__file__).parent
base=Path('/home/daphen/.cache/hyprland-canvas-resize/run.py').read_text()
prefix=base.split("    app = launch(app_command, app_env, 'client.log')")[0]
prefix=prefix.replace('root = pathlib.Path(__file__).parent','root = pathlib.Path('+repr(str(root))+')')
prefix=prefix.replace("(case/'sway.conf').write_text", "env.update(HYPR_CANVAS_REAL='1',HYPR_CANVAS_PROFILE='workstation',HOME=str(case/'home'),PATH=str(binary.parent)+':'+env['PATH'])\n(case/'home/Pictures/Screenshots').mkdir(parents=True,exist_ok=True)\n(case/'sway.conf').write_text")
prefix=prefix.replace('scale=1.5}', 'scale=1.5,position="-2560x0"}')
prefix=prefix.replace('canvas-resize-test','camera-focus-test').replace('canvas_resize_test_rule','camera_focus_test_rule')
cleanup=base[base.rindex('\nfinally:'):].replace('canvas_resize_test_rule','camera_focus_test_rule')
actions='''
    def clients(): return json.loads(ctl('-j','clients'))
    def active(): return json.loads(ctl('-j','activewindow'))
    def command(direction):
        result=ctl('dispatch','hl.dsp.layout("focus '+direction+'")'); assert result.strip()=='ok',result
    def pixel(data):
        magic, dimensions, maximum, pixels=data.split(b'\\n',3)
        w,h=map(int,dimensions.split()); p=((h//2)*w+w//2)*3
        return tuple(pixels[p:p+3]),[w,h]
    colors={'Canvas 1.1':(255,0,0),'Canvas 1.2':(0,255,0),'Canvas 1.3':(0,0,255)}
    for index,(title,color) in enumerate(colors.items()):
        folder=case/str(index);folder.mkdir(exist_ok=True)
        appclass='browser-work' if index==2 else 'camera-focus-fixture'
        launch([sys.executable,str(root/'client.py'),str(folder)],dict(app_env,FIXTURE_TITLE=title,FIXTURE_CLASS=appclass,FIXTURE_COLOR=','.join(str(c/255) for c in color)),'client-'+str(index)+'.log')
        wait(lambda:len(clients())==index+1,'fixture '+title);time.sleep(.5)
    def check(label):
        time.sleep(.8)
        a=active();data=subprocess.check_output(['grim','-t','ppm','-'],env=child_env,timeout=5)
        rgb,dimensions=pixel(data);print(label,a['title'],rgb,a['at'],flush=True)
        subprocess.run(['grim',str(case/(label+'.png'))],env=child_env,check=True,timeout=5)
        assert rgb==colors[a['title']],(label,'camera/focus mismatch',a['title'],rgb)
        return a
    right=check('rightmost')
    full=subprocess.check_output(['grim','-T',right['stableId'],'-t','ppm','-'],env=child_env,timeout=5)
    assert pixel(full)[0]==colors[right['title']],('toplevel capture',pixel(full))
    print('toplevel capture',pixel(full),flush=True)
    import re
    shell=json.loads(re.search(r'bind_exec\\("SUPER \\+ SHIFT \\+ e", (".*")\\)',pathlib.Path(config).read_text()).group(1))
    subprocess.run(['bash','-c',shell],env=dict(child_env,DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent'),timeout=10)
    wait(lambda:list((case/'home/Pictures/Screenshots').glob('*.png')),'screenshot shortcut')
    screenshot=max((case/'home/Pictures/Screenshots').glob('*.png'),key=lambda p:p.stat().st_mtime)
    decoded=subprocess.check_output(['magick',str(screenshot),'-depth','8','ppm:-'],timeout=5)
    assert pixel(decoded)[0]==colors[right['title']],pixel(decoded)
    print('screenshot command PASS',pixel(decoded),flush=True)
    results=[]
    for n,d in enumerate(['h','h','l','l','l','h','h','l','l','h']):
        before=active()['title'];command(d);after=check(str(n)+'-'+d)
        results.append([before,d,after['title']])
        if d=='h' and before=='Canvas 1.3': assert after['title']=='Canvas 1.2',results
    assert not ctl('configerrors').strip(),ctl('configerrors')
    (case/'result.json').write_text(json.dumps({'navigation':results,'config_sha256':hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()},indent=2))
'''
exec(compile(prefix+actions+cleanup,str(root/'test.py'),'exec'))
