from pathlib import Path
root=Path(__file__).parent
base=Path('/home/daphen/.cache/hyprland-canvas-resize/run.py').read_text()
prefix=base.split("    app = launch(app_command, app_env, 'client.log')")[0]
prefix=prefix.replace('root = pathlib.Path(__file__).parent','root = pathlib.Path('+repr(str(root))+')')
prefix=prefix.replace("(case/'sway.conf').write_text", "env.update(HYPR_CANVAS_REAL='1',HYPR_CANVAS_PROFILE='workstation',HOME=str(case/'home'),PATH=str(binary.parent)+':'+env['PATH'])\n(case/'home/Pictures/Screenshots').mkdir(parents=True,exist_ok=True)\n(case/'sway.conf').write_text")
prefix=prefix.replace('scale=1.5}', 'scale=1.5,position="-2560x0"}')
prefix=prefix.replace('canvas-resize-test','right_edge_probe_917').replace('canvas_resize_test_rule','right_edge_probe_917_rule')
cleanup=base[base.rindex('\nfinally:'):].replace('canvas_resize_test_rule','right_edge_probe_917_rule')
actions='''
    def clients(): return json.loads(ctl('-j','clients'))
    def active(): return json.loads(ctl('-j','activewindow'))
    def command(direction):
        result=ctl('dispatch','hl.dsp.layout("focus '+direction+'")'); assert result.strip()=='ok',result
    def pixel(data):
        magic, dimensions, maximum, pixels=data.split(b'\\n',3)
        w,h=map(int,dimensions.split()); p=((h//2)*w+w//2)*3
        return tuple(pixels[p:p+3]),[w,h]
    # Add a second logical output to reproduce the live topology without touching the parent desktop.
    before_outputs={m['name'] for m in json.loads(ctl('-j','monitors','all'))}
    ctl('output','create','headless')
    second=wait(lambda: next((m for m in json.loads(ctl('-j','monitors','all')) if m['name'] not in before_outputs),None),'second output')
    first=next(m for m in json.loads(ctl('-j','monitors','all')) if m['name'] in before_outputs)
    ctl('eval', 'hl.monitor({output='+json.dumps(first['name'])+',mode="preferred",position="-853x0",scale=1.5})')
    ctl('eval', 'hl.monitor({output='+json.dumps(second['name'])+',mode="preferred",position="0x0",scale=1.6})')
    wait(lambda:len(json.loads(ctl('-j','monitors')))==2,'configured outputs');time.sleep(.5)
    colors={
      'Canvas 1.1':(255,0,0),'Canvas 1.2':(0,255,0),'Canvas 1.3':(0,0,255),
      'Canvas 2.1':(255,255,0),'Canvas 2.2':(255,0,255),'Canvas 2.3':(0,255,255),
    }
    for index,(title,color) in enumerate(colors.items()):
        folder=case/str(index);folder.mkdir(exist_ok=True)
        appclass='browser-work' if title.endswith('.3') else 'right-edge-fixture'
        launch([sys.executable,str(root/'client.py'),str(folder)],dict(app_env,FIXTURE_TITLE=title,FIXTURE_CLASS=appclass,FIXTURE_COLOR=','.join(str(c/255) for c in color)),'client-'+str(index)+'.log')
        wait(lambda:len(clients())==index+1,'fixture '+title);time.sleep(.25)
    def title(): return active()['title']
    def focus(name):
        w=next(w for w in clients() if w['title']==name)
        ctl('dispatch','hl.dsp.focus({window="address:'+w['address']+'"})');time.sleep(.3)
        assert title()==name,(name,title())
    # Match the live rows' unequal normalized widths (scaled topology, same layout ratios).
    grow_steps={'Canvas 1.1':7,'Canvas 1.2':7,'Canvas 1.3':5,'Canvas 2.1':2,'Canvas 2.2':3,'Canvas 2.3':7}
    for name,steps in grow_steps.items():
        focus(name)
        for _ in range(steps): ctl('dispatch','hl.dsp.layout("resize l")')
    time.sleep(.8)
    initial_geometry={w['title']:w['at']+w['size'] for w in clients()}
    def focused_monitor(): return next(m['name'] for m in json.loads(ctl('-j','monitors')) if m['focused'])
    probes=[]
    for source,directions in [('Canvas 1.3',['h','j','k']),('Canvas 2.3',['h','j','k'])]:
        for direction in directions:
            focus(source); before=title(); routed=focused_monitor(); command(direction); time.sleep(.35); after=title()
            probes.append({'source':before,'direction':direction,'routed_monitor':routed,'after':after})
    moves=[]
    for source,direction in [('Canvas 1.3','h'),('Canvas 1.3','j'),('Canvas 2.3','h'),('Canvas 2.3','k')]:
        focus(source); order_before=[(w['title'],w['at']) for w in sorted(clients(),key=lambda w:w['title'])]
        ctl('dispatch','hl.dsp.layout("move '+direction+'")');time.sleep(.35)
        order_after=[(w['title'],w['at']) for w in sorted(clients(),key=lambda w:w['title'])]
        moves.append({'source':source,'direction':direction,'routed_monitor':focused_monitor(),'changed':order_before!=order_after,'active':title()})
    result={'initial_geometry':initial_geometry,'probes':probes,'moves':moves,'monitors':json.loads(ctl('-j','monitors')),'clients':clients(),'config_sha256':hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
    print(json.dumps(result,indent=2),flush=True)
    assert not ctl('configerrors').strip(),ctl('configerrors')
    (case/'result.json').write_text(json.dumps(result,indent=2))
'''
exec(compile(prefix+actions+cleanup,str(root/'test.py'),'exec'))
