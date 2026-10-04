use blank_document::{
    BlockKind, Document, Mark as DocumentMark, Position as DocumentPosition, SourceSelection,
};
use egui_richedit::{Edit, Fragment, Mark, Model, Position};

pub struct EditorModel {
    pub document: Document,
    pub error: Option<String>,
    pub visible: Option<std::ops::Range<usize>>,
}

pub fn position(p: &Position<usize>) -> DocumentPosition {
    DocumentPosition::new(p.paragraph, p.offset)
}
pub fn editor_position(p: DocumentPosition) -> Position<usize> {
    Position::new(p.paragraph, p.offset)
}
fn mark(m: Mark) -> Option<DocumentMark> {
    match m {
        Mark::Bold => Some(DocumentMark::Bold),
        Mark::Italic => Some(DocumentMark::Italic),
        _ => None,
    }
}

impl EditorModel {
    fn input_rule(
        &mut self,
        at: DocumentPosition,
        inserted: &str,
    ) -> Result<DocumentPosition, String> {
        let p = &self.document.paragraphs[at.paragraph];
        if inserted.ends_with(' ') && p.kind == BlockKind::Paragraph {
            let prefix: String = p.glyphs[..at.offset].iter().map(|g| g.text).collect();
            let kind = match prefix.as_str() {
                "= " => Some(BlockKind::Heading(1)),
                "== " => Some(BlockKind::Heading(2)),
                "=== " => Some(BlockKind::Heading(3)),
                "- " => Some(BlockKind::Bullet),
                "+ " | "1. " => Some(BlockKind::Numbered),
                _ => None,
            };
            if let Some(kind) = kind {
                let start = DocumentPosition::new(at.paragraph, 0);
                self.document.replace(start, at, "", false)?;
                self.document.set_kind_step(start, kind, false)?;
                return Ok(start);
            }
        }
        if inserted == "*" || inserted == "_" {
            let delimiter = inserted.chars().next().unwrap();
            let end = at.offset.saturating_sub(1);
            if let Some(start) = p.glyphs[..end]
                .iter()
                .rposition(|g| g.text == delimiter && g.atom.is_none())
                && start + 1 < end
                && (start == 0 || !p.glyphs[start - 1].text.is_alphanumeric())
                && !p.glyphs[start + 1].text.is_whitespace()
                && !p.glyphs[end - 1].text.is_whitespace()
                && p.glyphs[start..=end].iter().all(|g| g.atom.is_none())
            {
                let pos = |offset| DocumentPosition::new(at.paragraph, offset);
                self.document.replace(pos(end), at, "", false)?;
                self.document
                    .replace(pos(start), pos(start + 1), "", false)?;
                self.document.format(
                    pos(start),
                    pos(end - 1),
                    if delimiter == '*' {
                        DocumentMark::Bold
                    } else {
                        DocumentMark::Italic
                    },
                    true,
                    false,
                )?;
                return Ok(pos(end - 1));
            }
        }
        Ok(at)
    }
}

impl Model for EditorModel {
    type Paragraph = usize;
    fn text(&self, p: &usize) -> Option<String> {
        self.document.paragraphs.get(*p).map(|p| p.text())
    }
    fn first(&self) -> Option<usize> {
        Some(self.visible.as_ref().map_or(0, |range| range.start))
    }
    fn last(&self) -> Option<usize> {
        self.visible
            .as_ref()
            .map_or(self.document.paragraphs.len(), |range| range.end)
            .checked_sub(1)
    }
    fn previous(&self, p: &usize) -> Option<usize> {
        p.checked_sub(1).filter(|index| {
            self.visible
                .as_ref()
                .is_none_or(|range| range.contains(index))
        })
    }
    fn next(&self, p: &usize) -> Option<usize> {
        (p + 1 < self.document.paragraphs.len()
            && self
                .visible
                .as_ref()
                .is_none_or(|range| range.contains(&(p + 1))))
        .then_some(p + 1)
    }
    fn marked(&self, from: &Position<usize>, to: &Position<usize>, m: Mark) -> Option<bool> {
        mark(m)
            .and_then(|m| self.document.marked(position(from), position(to), m))
            .or(Some(false))
    }
    fn fragment(&self, from: &Position<usize>, to: &Position<usize>) -> Option<Fragment> {
        self.document
            .fragment(position(from), position(to))
            .ok()
            .map(Fragment::new)
    }
    fn paste_fragment(
        &mut self,
        at: &Position<usize>,
        fragment: &Fragment,
        new_step: bool,
    ) -> Option<Position<usize>> {
        let fragment = fragment.get::<blank_document::Fragment>()?;
        let byte = self.document.source_offset(position(at));
        let before = SourceSelection {
            anchor: byte,
            focus: byte,
        };
        match self
            .document
            .paste_fragment(position(at), fragment, new_step)
        {
            Ok(at) => {
                let byte = self.document.source_offset(at);
                self.document.record_selection(
                    before,
                    SourceSelection {
                        anchor: byte,
                        focus: byte,
                    },
                );
                Some(editor_position(at))
            }
            Err(error) => {
                self.error = Some(error);
                None
            }
        }
    }
    fn apply(&mut self, edit: Edit<'_, usize>, new_step: bool) -> Option<Position<usize>> {
        let before = match &edit {
            Edit::Replace { from, to, .. } | Edit::Format { from, to, .. } => SourceSelection {
                anchor: self.document.source_offset(position(from)),
                focus: self.document.source_offset(position(to)),
            },
            Edit::Split { at } => {
                let byte = self.document.source_offset(position(at));
                SourceSelection {
                    anchor: byte,
                    focus: byte,
                }
            }
        };
        let formatting_from = match &edit {
            Edit::Format { from, .. } => Some(position(from)),
            _ => None,
        };
        let revision = self.document.revision;
        let result = match edit {
            Edit::Replace { from, to, text } => self
                .document
                .replace(position(&from), position(&to), text, new_step)
                .and_then(|at| self.input_rule(at, text)),
            Edit::Split { at } => self.document.split(position(&at), new_step),
            Edit::Format {
                from,
                to,
                mark: m,
                on,
            } => {
                let Some(m) = mark(m) else {
                    self.error = Some("The prototype supports bold and italic. Other styles can be written in Source.".into());
                    return None;
                };
                self.document
                    .format(position(&from), position(&to), m, on, new_step)
            }
        };
        match result {
            Ok(p) => {
                if revision != self.document.revision {
                    let byte = self.document.source_offset(p);
                    let after = if let Some(from) = formatting_from {
                        SourceSelection {
                            anchor: self.document.source_offset(from),
                            focus: byte,
                        }
                    } else {
                        SourceSelection {
                            anchor: byte,
                            focus: byte,
                        }
                    };
                    self.document.record_selection(before, after);
                }
                Some(editor_position(p))
            }
            Err(e) => {
                self.error = Some(e);
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use eframe::egui::{
        self, Event, FontId, Id, RawInput, Sense, TextFormat, text::LayoutJob, vec2,
    };
    use egui_richedit::{Laid, ParagraphJob, RichEdit, Selection};

    #[test]
    fn real_editor_input_updates_typst_and_groups_typing_into_one_undo_step() {
        let ctx = egui::Context::default();
        let mut model = EditorModel {
            visible: None,
            document: Document::new("Hello *world*"),
            error: None,
        };
        let mut editor = RichEdit::new(Id::new("test-editor"));
        editor.select(Selection::caret(Position::new(0, 11)));
        for events in [
            vec![],
            vec![Event::Text("!".into())],
            vec![Event::Text("?".into())],
        ] {
            let mut output = ctx.run_ui(
                RawInput {
                    events,
                    ..Default::default()
                },
                |root| {
                    egui::CentralPanel::default().show(root, |ui| {
                        editor.input(ui, &mut model);
                        for (index, p) in model.document.paragraphs.iter().enumerate() {
                            let mut job = ParagraphJob::new(LayoutJob::default());
                            job.text(
                                &p.text(),
                                TextFormat::simple(
                                    FontId::proportional(16.0),
                                    egui::Color32::BLACK,
                                ),
                            );
                            let (job, map) = job.into_parts();
                            let galley = ui.fonts_mut(|fonts| fonts.layout_job(job));
                            let (rect, response) = ui.allocate_exact_size(
                                vec2(500.0, galley.size().y),
                                Sense::click_and_drag(),
                            );
                            editor.paragraph(
                                ui,
                                &response,
                                &index,
                                Laid {
                                    galley,
                                    map,
                                    origin: rect.min,
                                },
                            );
                        }
                    });
                },
            );
            output.textures_delta.clear();
        }
        assert_eq!(model.document.paragraphs[0].text(), "Hello world!?");
        assert!(model.error.is_none());
        assert!(model.document.undo());
        assert_eq!(model.document.text(), "Hello *world*");
    }
}
