from pathlib import Path
text=Path(__file__).with_name('popup-test.py').read_text()
exec(text.split("actions='''")[0])
import ast
setup=ast.literal_eval(next(node.value for node in ast.parse(text).body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='actions' for t in node.targets))).split("    launch_window('File dialog fixture'",1)[0]
actions=setup+'''
    image=case/'orange.png'
    subprocess.run(['magick','-size','640x440','xc:rgb(255,128,0)',str(image)],check=True)
    launch(['satty','--config','/home/daphen/nixos/dotfiles/satty/.config/satty/config.toml','--filename',str(image),'--output-filename',str(case/'output.png')],dict(app_env,GSK_RENDERER='gl',GDK_DISABLE='dmabuf'),'satty.log')
    wait(lambda:active().get('class')=='com.gabm.satty','real Satty');time.sleep(1.5)
    assert active()['floating'],active()
    after={'active':active(),'image':screenshot('satty')}
    assert after['image']['center_rgb']==[255,128,0],after
    ctl('dispatch','hl.dsp.layout("overview")');time.sleep(.8)
    overview=screenshot('satty-overview')
    assert overview['center_rgb']==[255,128,0],overview
    ctl('dispatch','hl.dsp.layout("pan 120 80")');time.sleep(.8)
    panned=screenshot('satty-pan')
    assert panned['center_rgb']==[255,128,0],panned
    result={'after':after,'overview':overview,'panned':panned,'config_sha256':hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
    (case/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
    assert not ctl('configerrors').strip(),ctl('configerrors')
'''
exec(compile(prefix+actions+cleanup,str(root/'satty-test.py'),'exec'))
