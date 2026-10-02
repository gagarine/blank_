#!/usr/bin/env python3
import json, pathlib, subprocess, time, statistics, argparse
p=argparse.ArgumentParser();p.add_argument('project',nargs='?',default='.tools/thesis-fixture');p.add_argument('--helper',default='helper/target/release/writer-helper');args=p.parse_args()
root=pathlib.Path(args.project).resolve();files={str(f.relative_to(root)):f.read_text() for f in root.rglob('*') if f.suffix in ['.typ','.bib']}
proc=subprocess.Popen([args.helper],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
def request(method,params):
    start=time.perf_counter();proc.stdin.write(json.dumps({'id':1,'method':method,'params':params})+'\n');proc.stdin.flush();response=json.loads(proc.stdout.readline());return time.perf_counter()-start,response
times=[];pages=0
for revision in range(3):
    if revision: files['chapters/01.typ']=files['chapters/01.typ'].replace('Careful','Thoughtful',1) if revision==1 else files['chapters/01.typ'].replace('Thoughtful','Considered',1)
    duration,result=request('compile',{'root':str(root),'entry':'main.typ','files':files,'revision':revision+1});times.append(round(duration,3));pages=result.get('result',{}).get('pages',0)
    if 'pdf' not in result.get('result',{}):print(json.dumps(result));raise SystemExit(1)
parse_time,_=request('parse',{'path':'chapter','text':files['chapters/01.typ'],'revision':3})
proc.terminate();proc.wait()
print(json.dumps({'compileSeconds':times,'pages':pages,'chapterParseMs':round(parse_time*1000,2)},indent=2))
