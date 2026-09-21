from pathlib import Path
import ast
p=Path(__file__).with_name('two-output-test.py')
s=p.read_text()
exec(s.split("actions='''")[0])
setup=ast.literal_eval(next(n.value for n in ast.parse(s).body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='actions' for t in n.targets))).split('    probes=[]')[0]
setup=setup.replace("appclass='browser-work' if title.endswith('.3') else 'right-edge-fixture'", "appclass='right-edge-fixture'")
setup=setup.replace("{'Canvas 1.1':7,'Canvas 1.2':7,'Canvas 1.3':5,'Canvas 2.1':2,'Canvas 2.2':3,'Canvas 2.3':7}","{'Canvas 1.1':2,'Canvas 1.2':1,'Canvas 2.1':1,'Canvas 2.3':1}")
prefix=prefix.replace("config = '/home/daphen/nixos/dotfiles/hyprland/.config/hypr/hyprland.lua'", "config = sys.argv[4] if len(sys.argv)>4 else '/home/daphen/nixos/dotfiles/hyprland/.config/hypr/hyprland.lua'")
prefix=prefix.replace("pathlib.Path(config).with_name('canvas-state.lua')", "pathlib.Path('/home/daphen/nixos/dotfiles/hyprland/.config/hypr/canvas-state.lua')")
actions=setup+'''
    def sample(color):
        data=subprocess.check_output(['grim','-o',first['name'],'-t','ppm','-'],env=child_env,timeout=5)
        _,dims,_,pixels=data.split(b'\\n',3);w,h=map(int,dims.split())
        c=bytes(color);row=pixels[(h//2)*w*3:(h//2+1)*w*3]
        xs=[x for x in range(w) if row[x*3:x*3+3]==c]
        ys=[y for y in range(h) if pixels[(y*w+w//2)*3:(y*w+w//2)*3+3]==c]
        return [(min(xs)+max(xs))/2 if xs else None,(min(ys)+max(ys))/2 if ys else None]
    probes=[]
    for name,direction in [('Canvas 1.3','h'),('Canvas 1.3','l'),('Canvas 1.3','j'),('Canvas 1.3','k')]:
        focus(name);time.sleep(.4)
        before=sample(colors[name]);start=time.monotonic()
        answer=ctl('dispatch','hl.dsp.layout("move '+direction+'")');assert answer.strip()=='ok',answer
        frames=[]
        for i in range(24):
            pos=sample(colors[name]);frames.append([round(time.monotonic()-start,4),*pos]);time.sleep(.003)
        assert title()==name,(name,title())
        drift=max(abs(f[1]-before[0]) for f in frames if f[1] is not None)
        probes.append({'direction':direction,'before':before,'max_horizontal_drift':drift,'frames':frames})
    result={'probes':probes,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'config_sha256':hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest()}
    (case/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
    assert not ctl('configerrors').strip(),ctl('configerrors')
'''
exec(compile(prefix+actions+cleanup,str(root/'move-motion-test.py'),'exec'))
