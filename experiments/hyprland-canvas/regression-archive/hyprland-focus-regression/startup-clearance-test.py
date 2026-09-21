from pathlib import Path
root=Path(__file__).parent
base=Path('/home/daphen/.cache/hyprland-canvas-resize/run.py').read_text()
prefix=base.split("    app = launch(app_command, app_env, 'client.log')")[0]
prefix=prefix.replace('root = pathlib.Path(__file__).parent','root = pathlib.Path('+repr(str(root))+')')
prefix=prefix.replace("env.update(XDG_RUNTIME_DIR=", "env.update(HYPR_CANVAS_REAL='1',HYPR_CANVAS_PROFILE='workstation',HOME=str(case/'home'),PATH=str(binary.parent)+':'+env['PATH'])\nenv.update(XDG_RUNTIME_DIR=")
prefix=prefix.replace('if event ~= "hyprland.start" then return on(event, callback) end end', 'if event == "hyprland.start" then startup_probe = callback else return on(event, callback) end end')
prefix=prefix.replace("config = '/home/daphen/nixos/dotfiles/hyprland/.config/hypr/hyprland.lua'", "config = sys.argv[4] if len(sys.argv)>4 else '/home/daphen/.cache/hyprland-focus-regression/startup-clearance.lua'")
prefix=prefix.replace("pathlib.Path(config).with_name('canvas-state.lua')", "pathlib.Path('/home/daphen/nixos/dotfiles/hyprland/.config/hypr/canvas-state.lua')")
prefix=prefix.replace('canvas-resize-test','startup-clearance-test').replace('canvas_resize_test_rule','startup_clearance_test_rule')
cleanup=base[base.rindex('\nfinally:'):].replace('canvas_resize_test_rule','startup_clearance_test_rule')
actions='''
    def monitors(): return json.loads(ctl('-j','monitors'))
    def focused(): return next(m['name'] for m in monitors() if m['focused'])
    def cursor(): return json.loads(ctl('-j','cursorpos'))
    def clients(): return json.loads(ctl('-j','clients'))
    def focus(title):
        window=next(w for w in clients() if w['title']==title)
        ctl('dispatch','hl.dsp.focus({window="address:'+window['address']+'"})');time.sleep(.7)
    def configure(name,mode,scale,pos,reserved=0):
        answer=ctl('eval','hl.monitor({output='+json.dumps(name)+',mode='+json.dumps(mode)+',scale='+str(scale)+',position='+json.dumps(pos)+',reserved={top='+str(reserved)+'}})')
        assert answer.strip()=='ok',answer
    original=monitors()[0]['name']
    configure('eDP-1','1080x720@60',1,'0x0')
    ctl('output','create','headless','eDP-1');time.sleep(.4)
    ctl('output','remove',original);time.sleep(.4)
    ctl('eval','hl.exec_cmd = function(command) end')
    ctl('dispatch','hl.dsp.cursor.move({x=80,y=120})')
    before=cursor()
    ctl('eval','startup_probe()');time.sleep(.4)
    assert focused()=='eDP-1' and cursor()==before,(focused(),cursor(),before)
    configure('DP-99','800x600@60',1,'1080x0')
    ctl('output','create','headless','DP-99');time.sleep(.4)
    configure('HDMI-A-99','960x540@60',1.5,'-640x0')
    ctl('output','create','headless','HDMI-A-99');time.sleep(.4)
    ctl('dispatch','hl.dsp.cursor.move({x=80,y=120})')
    ctl('eval','startup_probe()');time.sleep(.5)
    if 'baseline' not in label:
        assert focused()=='HDMI-A-99',(focused(),monitors())
        assert cursor()=={'x':-320,'y':180},cursor()
    ctl('dispatch','hl.dsp.focus({monitor="HDMI-A-99"})')
    ctl('dispatch','hl.dsp.cursor.move({x=-320,y=180})')
    configure('HDMI-A-99','960x540@60',1.5,'-640x0',52);time.sleep(.4)
    for index in range(2):
        folder=case/str(index);folder.mkdir(exist_ok=True)
        launch([sys.executable,str(root/'client.py'),str(folder)],dict(app_env,FIXTURE_TITLE='Canvas '+str(index+1)+'.1',FIXTURE_CLASS='clearance-fixture',FIXTURE_COLOR='1,0,0' if index==0 else '0,1,0'),'client-'+str(index)+'.log')
        wait(lambda:len(clients())==index+1,'fixture');time.sleep(.3)
    def geometry(): return {w['title']:w['at']+w['size'] for w in clients()}
    focus('Canvas 1.1');upper=geometry()
    focus('Canvas 2.1');lower=geometry()
    image=subprocess.check_output(['grim','-o','HDMI-A-99','-t','ppm','-'],env=child_env,timeout=5)
    (case/'bar.ppm').write_bytes(image)
    _,dims,_,pixels=image.split(b'\\n',3);width,height=map(int,dims.split())
    p=(39*width+width//2)*3;bar=list(pixels[p:p+3])
    shift=lower['Canvas 2.1'][1]-upper['Canvas 2.1'][1]
    if 'baseline' not in label:
        assert shift==52,(upper,lower)
        assert bar!=[255,0,0],bar
    else:
        assert shift==0 and bar==[255,0,0],(shift,bar)
    assert all(upper[k][2:]==lower[k][2:] for k in upper),(upper,lower)
    focus('Canvas 1.1');assert geometry()==upper,(geometry(),upper)
    assert not ctl('configerrors').strip(),ctl('configerrors')
    result={'upper':upper,'lower':lower,'bar_pixel':bar,'row_shift':shift,'monitors':monitors(),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'config_sha256':hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest()}
    (case/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
'''
exec(compile(prefix+actions+cleanup,str(root/'startup-clearance-test.py'),'exec'))
