//! Grapheme movement, composition, and accessibility selections share rich positions.
use crate::{App, editor::editor_position};
use eframe::egui::{self, Id, Key};
use egui_richedit::{Position, Selection};
use unicode_segmentation::UnicodeSegmentation;

fn boundaries(text: &str) -> Vec<usize> {
    let mut result = vec![0];
    let mut offset = 0;
    for grapheme in text.graphemes(true) {
        offset += grapheme.chars().count();
        result.push(offset);
    }
    result
}
impl App {
    pub(crate) fn rich_input(&mut self, ctx: &egui::Context) {
        let focused = ctx.memory(|m| m.has_focus(Id::new("writer")));
        let events = ctx.input(|i| i.events.clone());
        let mut retained = vec![];
        for event in events {
            match &event {
                egui::Event::Ime(egui::ImeEvent::Preedit { text, .. }) => {
                    self.composition = text.clone();
                    continue;
                }
                egui::Event::Ime(egui::ImeEvent::Commit(_)) => self.composition.clear(),
                egui::Event::AccessKitActionRequest(request) => {
                    if let Some(egui::accesskit::ActionData::SetTextSelection(selection)) =
                        &request.data
                    {
                        let at = |p: &egui::accesskit::TextPosition| {
                            self.access_positions
                                .get(&p.node)
                                .and_then(|positions| positions.get(p.character_index))
                                .cloned()
                        };
                        if let (Some(anchor), Some(focus)) =
                            (at(&selection.anchor), at(&selection.focus))
                        {
                            self.editor.select(Selection { anchor, focus });
                            ctx.memory_mut(|m| m.request_focus(Id::new("writer")));
                            continue;
                        }
                    }
                }
                _ => {}
            }
            if !focused {
                retained.push(event);
                continue;
            }
            if let Some(selection) = self.editor.selection().cloned() {
                let caret = selection.focus.clone();
                if let Some(p) = self.model.document.paragraphs.get(caret.paragraph) {
                    let stops = boundaries(&p.text());
                    if let egui::Event::Key {
                        key,
                        pressed: true,
                        modifiers,
                        ..
                    } = &event
                        && !modifiers.alt
                        && !modifiers.ctrl
                        && !modifiers.command
                        && (selection.anchor == selection.focus
                            || modifiers.shift && matches!(key, Key::ArrowLeft | Key::ArrowRight))
                    {
                        let left = stops.iter().copied().rfind(|&offset| offset < caret.offset);
                        let right = stops.iter().copied().find(|&offset| offset > caret.offset);
                        if matches!(key, Key::ArrowLeft | Key::ArrowRight) {
                            let next = if *key == Key::ArrowLeft { left } else { right };
                            if let Some(offset) = next {
                                self.editor.select(Selection {
                                    anchor: if modifiers.shift {
                                        selection.anchor
                                    } else {
                                        Position::new(caret.paragraph, offset)
                                    },
                                    focus: Position::new(caret.paragraph, offset),
                                });
                                continue;
                            }
                        }
                        if matches!(key, Key::Backspace | Key::Delete) {
                            let range = if *key == Key::Backspace {
                                left.map(|start| (start, caret.offset))
                            } else {
                                right.map(|end| (caret.offset, end))
                            };
                            if let Some((from, to)) = range
                                && to - from > 1
                            {
                                self.replace_grapheme(caret.paragraph, from, to);
                                continue;
                            }
                        }
                    }
                    if let egui::Event::Ime(egui::ImeEvent::DeleteSurrounding {
                        before_chars,
                        after_chars,
                    }) = &event
                    {
                        let start = caret.offset.saturating_sub(*before_chars);
                        let end = (caret.offset + after_chars).min(p.glyphs.len());
                        let from = stops
                            .iter()
                            .copied()
                            .rfind(|&offset| offset <= start)
                            .unwrap_or(0);
                        let to = stops
                            .iter()
                            .copied()
                            .find(|&offset| offset >= end)
                            .unwrap_or(p.glyphs.len());
                        self.replace_grapheme(caret.paragraph, from, to);
                        continue;
                    }
                }
            }
            retained.push(event);
        }
        ctx.input_mut(|i| i.events = retained);
    }
    fn replace_grapheme(&mut self, paragraph: usize, from: usize, to: usize) {
        let from = blank_document::Position::new(paragraph, from);
        let to = blank_document::Position::new(paragraph, to);
        let before = blank_document::SourceSelection {
            anchor: self
                .editor
                .selection()
                .map_or(self.model.document.source_offset(to), |s| {
                    self.model
                        .document
                        .source_offset(crate::editor::position(&s.anchor))
                }),
            focus: self
                .editor
                .selection()
                .map_or(self.model.document.source_offset(to), |s| {
                    self.model
                        .document
                        .source_offset(crate::editor::position(&s.focus))
                }),
        };
        if let Ok(at) = self.model.document.replace(from, to, "", true) {
            let byte = self.model.document.source_offset(at);
            self.model.document.record_selection(
                before,
                blank_document::SourceSelection {
                    anchor: byte,
                    focus: byte,
                },
            );
            self.editor.document_replaced();
            self.editor.select(Selection::caret(editor_position(at)));
        }
    }
    pub(crate) fn expose_paragraph(
        &mut self,
        ui: &egui::Ui,
        id: Id,
        index: usize,
        galley: &egui::Galley,
        map: &egui_richedit::OffsetMap,
    ) {
        ui.ctx().accesskit_node_builder(id, |node| {
            node.add_action(egui::accesskit::Action::SetTextSelection);
        });
        let mut offset = 0;
        for (row_index, row) in galley.rows.iter().enumerate() {
            let len = row.glyphs.len() + usize::from(row.ends_with_newline);
            for chunk in 0..len.max(1).div_ceil(255) {
                let from = chunk * 255;
                let end = (from + 255).min(len);
                let positions = (from..=end)
                    .map(|column| Position::new(index, map.to_model(offset + column)))
                    .collect();
                self.access_positions
                    .insert(id.with(row_index).with(chunk).accesskit_id(), positions);
            }
            offset += len;
        }
        if let Some(selection) = self.editor.selection()
            && selection.focus.paragraph == index
            && let Some(caret) = ui.output(|o| o.ime.as_ref().map(|ime| ime.cursor_rect))
            && !self.composition.is_empty()
        {
            let text = ui.fonts_mut(|fonts| {
                fonts.layout_no_wrap(
                    self.composition.clone(),
                    egui::FontId::new(
                        self.preferences.size,
                        egui::FontFamily::Name("reading".into()),
                    ),
                    ui.visuals().text_color(),
                )
            });
            let rect = egui::Rect::from_min_size(caret.min, text.size());
            ui.painter().rect_filled(rect, 0, ui.visuals().panel_fill);
            ui.painter()
                .galley(caret.min, text, ui.visuals().text_color());
            ui.painter().line_segment(
                [rect.left_bottom(), rect.right_bottom()],
                egui::Stroke::new(1.0, ui.visuals().text_color()),
            );
        }
    }
    pub(crate) fn normalize_graphemes(&mut self) {
        if let Some(mut selection) = self.editor.selection().cloned() {
            for at in [&mut selection.anchor, &mut selection.focus] {
                if let Some(p) = self.model.document.paragraphs.get(at.paragraph) {
                    let stops = boundaries(&p.text());
                    at.offset = stops
                        .into_iter()
                        .min_by_key(|&offset| offset.abs_diff(at.offset))
                        .unwrap_or(0);
                }
            }
            if self.editor.selection() != Some(&selection) {
                self.editor.select(selection);
            }
        }
    }
}
