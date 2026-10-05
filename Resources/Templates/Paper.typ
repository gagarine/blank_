#set page(paper: "a4", margin: 20mm, numbering: "1")
#set text(size: 10pt)
#set par(justify: true)

= Paper title

Author name · Affiliation

== Abstract

Summarize the question, approach, and key findings in one paragraph.

*Keywords:* topic, method, field

#counter(heading).update(0)
#set heading(numbering: "1.1")
#show: body => columns(2, gutter: 7mm, body)

= Introduction

Introduce the problem and related work.

= Methods

Explain how you conducted the research.

= Results

Present the evidence.

= Discussion

Interpret your findings and describe their limitations.

= Conclusion

State the main contribution and next steps.
