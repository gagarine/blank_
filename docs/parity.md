# Go reference audit

Reference: `codex/legacy-go`, inspected from a Git archive. Evidence comes from `frontend/src/App.tsx`, `RichEditor.tsx`, `SourceEditor.tsx`, `projection.ts`, `blockCommands.ts`, `ContentsSidebar.tsx`, `Settings.tsx`, `Statistics.tsx`, `sectionEditing.ts`, `internal/document`, `internal/zotero`, `cmd/blank_`, the original tutorial and acceptance notes. Rust README was not used as the feature specification.

| Go feature | Swift state | Verification/gap |
|---|---|---|
| Home/New/Open/recent files | Empty focused editor replaces Home intentionally; native New/Open | Native startup and focus passed; recent list pending |
| Iowan Old Style reading, full-width Source, white appearance | Native system fonts/real faces and TextKit 2 | Visual typography under inspection |
| Typing, selections, Unicode, shared history | Native NSTextView + source transactions | Native acceptance and model checks; real keyboard whitespace regression being retested |
| Bold/italic typing and shortcuts | Inline AST formatting, native commands | Native selected bold passed; toggle/prefix cases need expanded checks |
| Slash beside caret, filtering, arrows, Return/Escape | NSPopover + SwiftUI | Implemented; pointer/keyboard inspection pending |
| Application commands | Native SwiftUI sheet | Implemented; arrow navigation pending |
| Paragraph splitting/joining/list continuation/exit | Source-backed edits | Model checks passed |
| Structured clipboard, RTF, exact Source copy | Native NSPasteboard | Internal fragment/native copy passed; external RTF checks pending |
| Hover handles, Turn into/Duplicate/Delete, drag ghost/one line | Native drawing and NSMenu | Implemented; drag and chapter-boundary checks pending |
| Heading hierarchy, collapse, title elision, section moves | Native sidebar | Model movement checked; pointer inspection pending |
| Native scroller outside text padding | NSScrollView | Implemented; long-document scroll checks pending |
| Source colors, styling, delimiters | Native attributed text, Typst syntax | Exact Source copy passed; expanded style/navigation checks pending |
| Compile/Preview/navigation/PDF export, last good result | Rust helper + native PDFKit | Build passed; compile/export checks pending |
| Tables, cell Tab/final Tab adds row, dimensions | Native editing sheet | Inline cell editing/Tab pending |
| Images, PDF figures, width/alt/caption, drop/paste | Native importing/insertion + source block | Native visual figure display/drop/paste pending |
| Link/footnote/equation/label/reference insertion | Native sheets and Typst source | Implemented; compile checks pending |
| Zotero libraries/search/citations/offline metadata/refresh, CSL styles | Local API and bibliography files | Implemented; live Zotero/group picker/custom CSL verification pending |
| Multi-file manuscripts, continuous/all/current chapters, includes movement | Literal include loading and file switching; section movement | Continuous view/include movement and live include refresh pending |
| Find/replace/case matching | Native search bar, active file | Implemented; replacement grouping/project-wide search pending |
| Font family/size/colors, dark theme, focus/typewriter | Settings/focus/typewriter | Font/size persistence; color persistence/dark theme pending |
| Word/statistics info/disk dates/project counts | Active-file counts and undo storage | Project counts and filesystem dates pending |
| Native document windows and Window menu | NSWindow + SwiftUI hosting | Native independent windows under inspection |
| Autosave/recovery/conflicts/Save As dependencies | Native source recovery and guarded disk writes | Implemented; deletion/conflict/relaunch checks pending |
| Templates (paper/thesis), rename, recents | Not yet implemented | Actual Go features from app.go/recents.go |
| Agent access/MCP/selective agent undo | Not yet implemented | Actual Go feature; requires explicit integration work |

This is an implementation audit, not an assertion of full parity. Checked native input does not prove IME candidate-window, VoiceOver, or bidirectional acceptance.
