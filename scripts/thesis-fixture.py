#!/usr/bin/env python3
"""Create deterministic synthetic data; never touches a real manuscript."""
from pathlib import Path
import argparse, json
p=argparse.ArgumentParser();p.add_argument('output',nargs='?',default='.tools/thesis-fixture');args=p.parse_args()
root=Path(args.output);root.mkdir(parents=True,exist_ok=True);(root/'chapters').mkdir(exist_ok=True)
words='Careful research connects observation evidence interpretation and theory through a clear argument that remains open to revision and invites further questions'.split()
paragraph=' '.join(words[i%len(words)] for i in range(100))+'.'
for chapter in range(20):
    pages=[]
    for page in range(25):
        citation=2*(chapter*25+page)
        pages.append('\n\n'.join([paragraph,paragraph,paragraph])+f' @ref{citation:04d} @ref{citation+1:04d}\n')
    (root/'chapters'/f'{chapter+1:02d}.typ').write_text(f'= Chapter {chapter+1}\n\n'+'\n#pagebreak()\n\n'.join(pages)+'\n#pagebreak()\n')
(root/'references.bib').write_text('\n'.join('@article{ref%04d, author={Researcher, A.}, title={Study %d}, year={2026}, journal={Evidence}}'%(i,i) for i in range(1000)))
(root/'main.typ').write_text('#set page(paper: "a4", margin: 2.3cm)\n#set text(size: 10pt)\n#set heading(numbering: "1")\n\n'+'\n'.join(f'#include "chapters/{i+1:02d}.typ"' for i in range(20))+'\n#bibliography("references.bib", style: "ieee")\n')
(root/'writer.json').write_text(json.dumps({'entry':'main.typ'}))
print(json.dumps({'root':str(root.resolve()),'bodyWords':150000,'chapters':20,'citations':1000,'explicitBodyPages':500}))
