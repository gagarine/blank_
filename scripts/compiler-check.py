#!/usr/bin/env python3
"""Protocol/integration checks against the actual bundled official compiler."""
import base64
import json
import pathlib
import subprocess
import tempfile
import time

repo = pathlib.Path(__file__).resolve().parent.parent
helper = repo / 'helper/target/release/writer-helper'
with tempfile.TemporaryDirectory(prefix='blank-compiler-', dir='/tmp') as temp:
    root = pathlib.Path(temp)
    process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    seq = 0
    def call(method, params):
        global seq
        seq += 1
        process.stdin.write(json.dumps({'jsonrpc':'2.0','protocolVersion':1,'id':seq,'method':method,'params':params})+'\n')
        process.stdin.flush()
        reply = json.loads(process.stdout.readline())
        assert reply['id'] == seq and 'error' not in reply, reply
        return reply['result']
    try:
        assert call('initialize', {})['typstVersion'] == '0.15.1'
        tutorial = (repo/'examples/Tutorial.typ').read_text()
        start = time.monotonic()
        result = call('compile', {'root':str(root),'entry':'Tutorial.typ','files':{'Tutorial.typ':tutorial},'revision':1})
        assert not result['diagnostics'], result
        data = base64.b64decode(result['pdf']); assert data.startswith(b'%PDF-')
        assert result['pages'] >= 2 and result['sourceMap']
        (root/'tutorial.pdf').write_bytes(data)
        print(f"PASS: exact Go tutorial → {result['pages']} PDF pages, {len(data)} bytes, {time.monotonic()-start:.3f}s cold compile")
        files = {'main.typ':'#set text(size: 11pt)\n#include "chapters/one.typ"\n\n#link("https://typst.app")[Typst]\n#footnote[An explanation]\n\n$ x^2 + y^2 $\n',
                 'chapters/one.typ':'= Café 日本語 👋\n\nA *bold* and _italic_ sentence.\n\n#table(columns: 2, [Idea], [Step], [Write], [Review])\n'}
        start = time.monotonic()
        result = call('compile',{'root':str(root),'entry':'main.typ','files':files,'revision':2})
        assert not result['diagnostics'], result
        assert any(a['path'] == 'chapters/one.typ' for a in result['sourceMap'])
        assert all(0 <= a['y'] <= 1 for a in result['sourceMap'])
        print(f"PASS: in-memory includes, Unicode, table, link, footnote, math, source mapping; {time.monotonic()-start:.3f}s warm compile")
        result = call('compile',{'root':str(root),'entry':'main.typ','files':{'main.typ':'#nonexistent()'},'revision':3})
        assert result['diagnostics'] and 'pdf' not in result
        print('PASS: invalid Typst returns diagnostics without a replacement PDF')
    finally:
        process.terminate(); process.wait(timeout=5)
