#!/usr/bin/env python3
"""Black-box CLI/MCP check using only isolated synthetic project data."""
import pathlib, json, os, subprocess, tempfile, time, urllib.request, socket
repo=pathlib.Path(__file__).resolve().parents[1]
root=pathlib.Path(tempfile.mkdtemp(prefix='still-rpc-'))
(root/'main.typ').write_text('#include "chapter.typ"\n')
(root/'chapter.typ').write_text('Alpha beta.\n')
env=os.environ.copy();env['WRITER_SOCKET']=str(root/'rpc.sock');env['WRITER_DATA_DIR']=str(root/'.recovery')
probe=socket.socket();busy=probe.connect_ex(('127.0.0.1',3415))==0;probe.close()
if busy: raise SystemExit('Stop the development server on port 3415 before running this isolated check.')
binary=str(repo/'build/bin/blank_.app/Contents/MacOS/blank_');app=subprocess.Popen([binary,'serve','--project',str(root)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
adapter=None
try:
    line=app.stdout.readline()
    if 'http://127.0.0.1:3415' not in line: raise RuntimeError('dev server failed: '+line)
    def ui(method,args={}):
        req=urllib.request.Request('http://127.0.0.1:3415/api',data=json.dumps({'id':1,'method':method,'params':args}).encode(),headers={'Content-Type':'application/json'})
        result=json.load(urllib.request.urlopen(req));assert 'error' not in result,result;return result['result']
    adapter=subprocess.Popen([binary,'mcp'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    def rpc(method,args={}):
        adapter.stdin.write(json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':args})+'\n');adapter.stdin.flush();r=json.loads(adapter.stdout.readline());assert 'error' not in r,r;return r['result']
    assert rpc('initialize',{'protocolVersion':'2025-06-18'})['protocolVersion']=='2025-06-18'
    assert len(rpc('tools/list')['tools'])==10
    denied=rpc('tools/call',{'name':'project_read','arguments':{}});assert denied['isError']
    ui('project.agent',{'enabled':True})
    def tool(name,args={}):
        r=rpc('tools/call',{'name':name,'arguments':args});assert not r.get('isError'),r;return json.loads(r['content'][0]['text'])
    p=tool('project_read');tx={'projectId':p['id'],'expected':{'main.typ':1,'chapter.typ':1},'edits':[{'path':'main.typ','start':0,'end':0,'text':'// agent\n'},{'path':'chapter.typ','start':0,'end':5,'text':'Gamma'}]}
    p=tool('document_applyEdits',tx);assert p['lastOrigin']=='agent'
    stale=rpc('tools/call',{'name':'document_applyEdits','arguments':tx});assert stale['isError']
    ui('document.applyEdits',{'projectId':p['id'],'expected':{'chapter.typ':p['files']['chapter.typ']['revision']},'edits':[{'path':'chapter.typ','start':11,'end':11,'text':' User addition.'}]})
    p=tool('document_undo');assert p['files']['chapter.typ']['text']=='Alpha beta. User addition.\n';assert p['files']['main.typ']['text']=='#include "chapter.typ"\n'
    out=tool('preview_exportPDF',{'path':'result.pdf'});assert (root/'result.pdf').read_bytes().startswith(b'%PDF');assert out['revision']>=p['revision']
    print(json.dumps({'mcp':'passed','tools':10,'staleRevision':'rejected','selectiveUndo':'passed','pdfExport':'passed','fixture':str(root)}))
finally:
    if adapter: adapter.terminate();adapter.wait()
    app.terminate();app.wait()
