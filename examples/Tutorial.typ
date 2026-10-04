= Tutorial

Learn by trying. This is your own editable copy of the guide. Press ⌘S to keep it; Tutorial in ⌘K opens a fresh copy in another window.

== 1. Switch views

- *⌘1 — Write:* edit text and structure.
- *⌘2 — Source:* edit the underlying Typst file.
- *⌘3 — Preview:* see the typeset pages.

Try ⌘2, then ⌘3, then ⌘1 to come back here. These are three views of the same document. In Preview, enter a page number to jump to it.

== 2. Write and format

Click at the end of this paragraph, press Return, and write a sentence.

On a new line, type = followed by a space to make a heading; == and a space makes a subsection. Type `*bold*` for *bold* and `_italic_` for _italic_. These are Typst’s own shortcuts.

Type / to open the insert panel. Try /heading, choose with the arrow keys, and press Return. Escape closes it.

== 3. Move an idea

First idea: write the thought before polishing it.

Second idea: a draft can change its order.

Hover over “Second idea”, then drag the dots on its left above “First idea”. The line shows where it will land. Press ⌘Z to undo. You can also move a block with ⌥↑ or ⌥↓.

Move farther into the left margin to reveal the table of contents. Click a heading to jump there, or drag a heading to move its section. Press ⌘⇧L to pin or unpin it, or find “Pin table of contents” in ⌘K.

== 4. Add your research

- *Image:* type /image, choose a file, and add a caption. You can also drop an image into the editor.
- *Citation:* open Zotero, then go to *Settings → Advanced* and enable *“Allow other applications on this computer to communicate with Zotero”*. This enables its local HTTP API. Keep Zotero open, type /citation, and search for a reference. Cited metadata is saved locally for offline use.
- *Footnote or equation:* find either in the / panel. Preview shows the typeset result.

Use *Refresh Zotero references* in ⌘K to sync saved citation metadata. Zotero must be open with the local HTTP API enabled for insertion and refresh. If Zotero is unavailable, you’ll see setup instructions when you try either action. You can keep writing and previewing with saved citations while Zotero is closed.

Click a cell below and replace its text. Tab moves to the next cell; Tab in the final cell adds a row. The table controls let you add or remove rows and columns.

#table(columns: 2,
  [Idea], [Next step],
  [A question worth asking], [Find one source],
  [An observation], [Explain why it matters],
)

== 5. Make yourself comfortable

Press ⌘K and search for *Paragraph focus*, *Typewriter scrolling*, or *Statistics & info*. Open *Settings* with ⌘, to change the editor’s font, size, and colors.

Press ⌘S to choose where to save this copy. After that, changes autosave. Your document is an ordinary .typ file; external edits appear here too. For a finished PDF, choose *Export PDF* in ⌘K.

Ready for a blank page? Press ⌘N for a new document in another window.
