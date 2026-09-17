from pathlib import Path
root=Path(__file__).parent
base=Path('/home/daphen/.cache/hyprland-canvas-resize/run.py').read_text()
prefix=base.split("    app = launch(app_command, app_env, 'client.log')")[0]
prefix=prefix.replace('root = pathlib.Path(__file__).parent','root = pathlib.Path('+repr(str(root))+')')
prefix=prefix.replace("(case/'sway.conf').write_text", "env.update(HYPR_CANVAS_REAL='1',HYPR_CANVAS_PROFILE='workstation',HOME=str(case/'home'),PATH=str(binary.parent)+':'+env['PATH'])\n(case/'sway.conf').write_text")
prefix=prefix.replace('canvas-resize-test','camera-popup-test').replace('canvas_resize_test_rule','camera_popup_test_rule')
cleanup=base[base.rindex('\nfinally:'):].replace('canvas_resize_test_rule','camera_popup_test_rule')
actions='''
    def clients(): return json.loads(ctl('-j','clients'))
    def active(): return json.loads(ctl('-j','activewindow'))
    def launch_window(title,appclass,color):
        folder=case/title.replace(' ','-');folder.mkdir(exist_ok=True)
        launch([sys.executable,str(root/'client.py'),str(folder)],dict(app_env,FIXTURE_TITLE=title,FIXTURE_CLASS=appclass,FIXTURE_COLOR=color,FIXTURE_INPUT='1',WAYLAND_DEBUG='client'),'client-'+title.replace(' ','-')+'.log')
        wait(lambda:any(w['title']==title for w in clients()),title);time.sleep(.8)
    first=json.loads(ctl('-j','monitors'))[0]
    if 'two' in label:
        ctl('output','create','headless')
        second=wait(lambda:next((m for m in json.loads(ctl('-j','monitors','all')) if m['name']!=first['name']),None),'second output')
        ctl('eval','hl.monitor({output='+json.dumps(first['name'])+',position="-864x0",scale=1.5})')
        ctl('eval','hl.monitor({output='+json.dumps(second['name'])+',position="0x0",scale=1.6})')
        time.sleep(.5)
    launch_window('Canvas 1.1','popup-parent-fixture','0,0,1')
    launch_window('Canvas 2.1','popup-parent-fixture','0,1,0')
    def screenshot(name):
        data=subprocess.check_output(['grim','-o',first['name'],'-t','ppm','-'],env=child_env,timeout=5)
        magic, dimensions, maximum, pixels=data.split(b'\\n',3)
        w,h=map(int,dimensions.split());p=((h//2)*w+w//2)*3
        orange=sum(1 for i in range(0,len(pixels),3) if pixels[i:i+3]==bytes((255,128,0)))
        subprocess.run(['grim','-o',first['name'],str(case/(name+'.png'))],env=child_env,check=True,timeout=5)
        return {'center_rgb':list(pixels[p:p+3]),'orange_pixels':orange,'dimensions':[w,h]}
    before={'active':active(),'image':screenshot('before-dialog')}
    launch_window('File dialog fixture','file-chooser','1,0.5,0')
    after={'active':active(),'image':screenshot('dialog')}
    assert after['active']['floating'],after['active']
    assert before['active']['title']=='Canvas 2.1',before['active']
    assert after['image']['center_rgb']==[255,128,0],after
    sys.path.insert(0,'/home/daphen/.cache/hyprland-horizontal-scroll')
    from pointer import Pointer
    import struct
    pointer=Pointer(runtime/name)
    folder=case/'File-dialog-fixture'
    def check_input(stage):
        for file in ['keys','click','scroll']: (folder/file).unlink(missing_ok=True)
        a=active(); x=a['at'][0]+a['size'][0]/2;y=a['at'][1]+a['size'][1]/2
        monitors=json.loads(ctl('-j','monitors'))
        left=min(m['x'] for m in monitors);top=min(m['y'] for m in monitors)
        width=max(m['x']+m['width']/m['scale'] for m in monitors)-left
        height=max(m['y']+m['height']/m['scale'] for m in monitors)-top
        pointer.move(0,0);time.sleep(.05)
        pointer.move(round((x-left)/width*1280),round((y-top)/height*720));time.sleep(.1)
        for state in [1,0]:
            pointer.send(5,2,struct.pack('III',pointer.now(),272,state));pointer.send(5,4);pointer.sync()
        wait(lambda:(folder/'click').exists(),'dialog click '+stage)
        local=list(map(float,(folder/'click').read_text().split()))
        assert all(abs(v-size/2)<3 for v,size in zip(local,a['size'])),(stage,local,a['size'],a['at'],active()['at'],ctl('-j','cursorpos'))
        pointer.axis(0,8,1);wait(lambda:(folder/'scroll').exists(),'dialog scroll '+stage)
        subprocess.run(['wtype','hjkl'],env=child_env,check=True,timeout=5)
        wait(lambda:(folder/'keys').exists(),'dialog keyboard '+stage)
        keys=list(map(int,(folder/'keys').read_text().split()))
        assert keys==[104,106,107,108],(stage,keys)
        assert active()['title']=='File dialog fixture',active()
        return {'click':local,'keys':keys,'scroll':True}
    inputs={'normal':check_input('normal')}
    ctl('dispatch','hl.dsp.layout("overview")');time.sleep(.8)
    overview=screenshot('overview-dialog')
    assert overview['center_rgb']==[255,128,0],overview
    inputs['overview']=check_input('overview')
    ctl('dispatch','hl.dsp.layout("pan 120 80")');time.sleep(.8)
    assert screenshot('panned-dialog')['center_rgb']==[255,128,0]
    ctl('dispatch','hl.dsp.layout("overview")');time.sleep(.8)
    assert active()['title']=='File dialog fixture',active()
    inputs['after_overview']=check_input('after-overview')
    pointer.close()
    result={'before':before,'after':after,'overview':overview,'inputs':inputs,'config_sha256':hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
    (case/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({name:{'active':v['active']['title'],'at':v['active']['at'],'image':v['image']} for name,v in [('before',before),('after',after)]},indent=2))
    assert not ctl('configerrors').strip(),ctl('configerrors')
'''
exec(compile(prefix+actions+cleanup,str(root/'popup-test.py'),'exec'))
