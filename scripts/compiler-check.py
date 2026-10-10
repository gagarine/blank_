#!/usr/bin/env python3
"""Protocol/integration checks against the actual bundled official compiler."""
import argparse
import base64
import json
import pathlib
import re
import subprocess
import tempfile
import time

repo = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', nargs='?', type=pathlib.Path, default=repo/'build/blank_.app')
app = parser.parse_args().app.resolve()
compiler = app / 'Contents/MacOS/typst-compiler'
with tempfile.TemporaryDirectory(prefix='blank-compiler-', dir='/tmp') as temp:
    root = pathlib.Path(temp)
    process = subprocess.Popen([str(compiler)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=root)
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
        tutorial = (app/'Contents/Resources/Tutorial.typ').read_text()
        start = time.monotonic()
        result = call('compile', {'root':str(root),'entry':'Tutorial.typ','files':{'Tutorial.typ':tutorial},'revision':1})
        assert not result['diagnostics'], result
        data = base64.b64decode(result['pdf']); assert data.startswith(b'%PDF-')
        assert result['pages'] >= 2 and result['sourceMap']
        (root/'tutorial.pdf').write_bytes(data)
        print(f"PASS: bundled tutorial → {result['pages']} PDF pages, {len(data)} bytes, {time.monotonic()-start:.3f}s cold compile")
        files = {'main.typ':'#set text(size: 11pt)\n#include "chapters/one.typ"\n\n#link("https://typst.app")[Typst]\n#footnote[An explanation]\n\n$ x^2 + y^2 $\n',
                 'chapters/one.typ':'= Café 日本語 👋\n\nA *bold* and _italic_ sentence.\n\n#table(columns: 2, [Idea], [Step], [Write], [Review])\n'}
        start = time.monotonic()
        result = call('compile',{'root':str(root),'entry':'main.typ','files':files,'revision':2})
        assert not result['diagnostics'], result
        assert any(a['path'] == 'chapters/one.typ' for a in result['sourceMap'])
        assert all(0 <= a['y'] <= 1 for a in result['sourceMap'])
        print(f"PASS: in-memory includes, Unicode, table, link, footnote, math, source mapping; {time.monotonic()-start:.3f}s warm compile")
        typography = 'Regular café text. *Bold text.* _Italic text._\n\n#underline[Underlined café.] #strike[Struck text.] #strike[#underline[*_Combined styles._*]]\n\n#table(columns: 1, [#underline[Decorated cell]])\n\n$ integral_0^infinity e^(-x^2) dif x = sqrt(pi) / 2 $'
        result = call('compile', {'root':str(root),'entry':'fonts.typ','files':{'fonts.typ':typography},'revision':3})
        assert not result['diagnostics'], result
        pdf = base64.b64decode(result['pdf'])
        font_names = {name.split(b'+')[-1].removesuffix(b'-Identity-H') for name in re.findall(rb'/BaseFont\s*/([^\s/<>]+)', pdf)}
        expected = {b'LibertinusSerif-Regular', b'LibertinusSerif-Bold', b'LibertinusSerif-Italic', b'NewCMMath-Book'}
        assert expected <= font_names, font_names
        assert not any(b'LastResort' in name for name in font_names), font_names
        print('PASS: PDF compiles underline/strikethrough and combined styles, using bundled regular/bold/italic text and math fonts without LastResort glyph fallback')
        styles = '#align(center)[= Centered heading]\n\n#par(justify: true)[Justified paragraph. Another sentence to demonstrate alignment.]\n\n#super[1] #sub[2] #text(fill: rgb("#247cb7"))[Blue] #highlight(fill: rgb("#fff2a6"))[Yellow] #link("https://example.com")[Link] `#let x = 2`\n\n```\n#let literal = 2\n```'
        result = call('compile',{'root':str(root),'entry':'styles.typ','files':{'styles.typ':styles},'revision':4})
        assert not result['diagnostics'] and result['pages'] >= 1, result
        print('PASS: alignment, justification, superscript/subscript, text/highlight colors, links and displayed code compile to PDF')
        result = call('compile',{'root':str(root),'entry':'main.typ','files':{'main.typ':'#nonexistent()'},'revision':4})
        assert result['diagnostics'] and 'pdf' not in result
        print('PASS: invalid Typst returns diagnostics without a replacement PDF')
    finally:
        process.terminate(); process.wait(timeout=5)
