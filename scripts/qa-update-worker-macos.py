#!/usr/bin/env python3
"""Exercise real updater replacement and rollback using isolated signed stub apps."""
import json, pathlib, plistlib, shutil, subprocess, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
HELPER=ROOT/'.build/debug/AppUpdater'
def run(*args): subprocess.run(args,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
with tempfile.TemporaryDirectory(prefix='gptproxy-update-qa-') as temp:
    root=pathlib.Path(temp)
    source=root/'stub.c'
    source.write_text('#include <stdio.h>\n#include <string.h>\nint main(int n,char**v){if(n==3){char p[4096];snprintf(p,sizeof p,"%s.healthy",v[2]);FILE*f=fopen(p,"w");if(f)fclose(f);}return 0;}')
    binaries=[]
    for arch in ['arm64','x86_64']:
        binary=root/arch;run('xcrun','clang','-arch',arch,str(source),'-o',str(binary));binaries.append(str(binary))
    universal=root/'launcher';run('/usr/bin/lipo','-create',*binaries,'-output',str(universal))
    def bundle(path,version,fail=False):
        (path/'Contents/MacOS').mkdir(parents=True);(path/'Contents/Resources').mkdir()
        shutil.copy(universal,path/'Contents/MacOS/ChatGPTProxyLauncher')
        if fail:
            # Valid universal executable with an invalid entrypoint at runtime isn't needed:
            # a signed executable that exits without acknowledging health exercises rollback.
            source.write_text('int main(){return 1;}')
            for arch in ['arm64','x86_64']:run('xcrun','clang','-arch',arch,str(source),'-o',str(root/arch))
            run('/usr/bin/lipo','-create',*binaries,'-output',str(path/'Contents/MacOS/ChatGPTProxyLauncher'))
        shutil.copy(HELPER,path/'Contents/Resources/AppUpdater')
        (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.alex.chatgpt-proxy','CFBundleShortVersionString':version,'CFBundleExecutable':'ChatGPTProxyLauncher'}))
        files=[str(p.relative_to(path)) for p in path.rglob('*') if p.is_file()]
        (path/'Contents/Resources/update-manifest.json').write_text(json.dumps({'format':1,'version':version,'platform':'macos-universal','files':files}))
        run('/usr/bin/codesign','--force','--deep','--sign','-',str(path))
    for fail in [False,True]:
        case=root/('rollback' if fail else 'success');case.mkdir()
        target=case/'ChatGPT Proxy.app';stage=case/'stage'/'ChatGPT Proxy.app'
        bundle(target,'2.3.9');bundle(stage,'2.4.0',fail)
        parent=subprocess.Popen(['/bin/sleep','0.01']);parent.wait()
        tx=case/'transaction.json';tx.write_text(json.dumps({'target':str(target),'stage':str(stage),'version':'2.4.0','parent':parent.pid}))
        (case/'transaction.json.commit').touch()
        subprocess.run([str(HELPER),'coordinate',str(tx)],check=True,timeout=90)
        phase=pathlib.Path(str(tx)+'.phase').read_text()
        assert phase==('rolled-back' if fail else 'complete'),phase
        actual=plistlib.loads((target/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        assert actual==('2.3.9' if fail else '2.4.0'),actual
        print(case.name,phase,actual)

    case=root/'recovery';case.mkdir()
    target=case/'ChatGPT Proxy.app';backup=pathlib.Path(str(target)+'.update-backup')
    bundle(backup,'2.3.9')
    parent=subprocess.Popen(['/bin/sleep','0.01']);parent.wait()
    tx=case/'transaction.json';tx.write_text(json.dumps({'target':str(target),'stage':str(case/'missing-stage'),'version':'2.4.0','parent':parent.pid}))
    pathlib.Path(str(tx)+'.phase').write_text('replacing')
    subprocess.run([str(HELPER),'recover',str(tx)],check=True,timeout=90)
    assert target.exists() and not backup.exists()
    assert pathlib.Path(str(tx)+'.phase').read_text()=='rolled-back'
    print('recovery rolled-back 2.3.9')
