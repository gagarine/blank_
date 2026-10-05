#set page(paper: "a5", margin: (inside: 20mm, outside: 15mm, y: 20mm))
#set text(size: 11pt)
#set par(justify: true, first-line-indent: 1em)
#set align(center)
#set heading(outlined: false)
#v(25mm)

= Book title

Subtitle

Author name

#pagebreak()
#set align(left)
#set heading(outlined: true)
#outline()
#pagebreak()
#counter(page).update(1)
#set page(numbering: "1")

= Chapter One

Begin your story here.

The next paragraph continues the story. Replace this text with your own writing.

#pagebreak()

= Chapter Two

Continue here.
