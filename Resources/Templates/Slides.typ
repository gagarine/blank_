// HD projector format: 16:9. Each top-level heading starts a slide.
#set page(width: 13.333333in, height: 7.5in, margin: 0.6in)
#set text(size: 28pt)
#set par(leading: 0.7em)
#set heading(numbering: none)
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  text(size: 42pt, weight: "bold", it.body)
  v(0.5em)
}

= Presentation title

Your name · Event or date

= Main idea

- Keep one clear message on each slide.
- Use short, readable points.
- Add a figure or example when it helps.

= Next steps

Summarize the takeaway and what happens next.
