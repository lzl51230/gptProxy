#!/usr/bin/env python3
"""Run packaged Windows worker transactions in disposable directories."""
import argparse,json,pathlib,shutil,subprocess,tempfile,time
p=argparse.ArgumentParser();p.add_argument('--app',required=True);p.add_argument('--output',required=True);a=p.parse_args()
app=pathlib.Path(a.app).resolve();out=pathlib.Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
helper=app/'Updater/ChatGPTProxy.Updater.exe'
manifest=json.loads((app/'update-manifest.json').read_text(encoding='utf-8-sig'))
results={}
for scenario in ['success','rollback','recovery','cancel']:
 with tempfile.TemporaryDirectory(prefix='gptproxy-update-worker-') as directory:
  root=pathlib.Path(directory);target=root/'installed';stage=root/'stage'
  shutil.copytree(app,target);shutil.copytree(app,stage)
  (target/'Data').mkdir(exist_ok=True);(target/'Data/settings.json').write_text('{"theme":"kept"}')
  (target/'user-extra.txt').write_text('preserved')
  tx=root/'transaction.json';tx.write_text(json.dumps(dict(Target=str(target),Stage=str(stage),Backup=str(target)+'.update-backup',Parent=2147483647,Running=False,Version=manifest['Version'])))
  process=subprocess.Popen([str(helper),'worker',str(tx)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  def wait(suffix):
   until=time.monotonic()+90
   while not pathlib.Path(str(tx)+suffix).exists():
    if process.poll() is not None or time.monotonic()>until:
     if process.poll() is None:process.kill()
     raise RuntimeError(process.communicate()[0].decode(errors='replace')+(pathlib.Path(str(tx)+'.error').read_text() if pathlib.Path(str(tx)+'.error').exists() else 'timeout'))
    time.sleep(.1)
  wait('.ready')
  if scenario=='cancel':
   pathlib.Path(str(tx)+'.abort').touch();process.communicate(timeout=30)
   assert process.returncode!=0 and not pathlib.Path(str(target)+'.update-backup').exists()
   assert not pathlib.Path(str(target)+'.update-next').exists()
   results[scenario]='old application retained';continue
  # Data changed after preparation must survive the final swap and rollback.
  (target/'Data/settings.json').write_text('{"theme":"latest"}')
  pathlib.Path(str(tx)+'.commit').touch();wait('.installed')
  if scenario=='recovery':
   process.kill();process.communicate()
   for suffix in ['.ready','.commit','.installed']:pathlib.Path(str(tx)+suffix).unlink()
   pathlib.Path(str(tx)+'.recover').touch()
   process=subprocess.Popen([str(helper),'worker',str(tx)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   wait('.ready');pathlib.Path(str(tx)+'.commit').touch();wait('.installed')
  else:pathlib.Path(str(tx)+'.decision').write_text(scenario)
  output=process.communicate(timeout=60)[0]
  if process.returncode:raise RuntimeError(output.decode(errors='replace'))
  phase=pathlib.Path(str(tx)+'.phase').read_text()
  assert phase==('complete' if scenario=='success' else 'rolled-back'),phase
  assert (target/'user-extra.txt').read_text()=='preserved'
  assert (target/'Data/settings.json').read_text()=='{"theme":"latest"}'
  results[scenario]=phase
(out/'result.json').write_text(json.dumps(results,indent=2));print(json.dumps(results))
