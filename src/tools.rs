use crate::{App, Mode, commands::Command, editor::editor_position, search, storage};
use eframe::egui::{self, Color32, Id, Key, Modifiers};
use egui_richedit::Selection;

impl App {
    pub(crate) fn find_bar(&mut self, ui: &mut egui::Ui) {
        if !self.find.open {
            return;
        }
        let ctx = ui.ctx().clone();
        let mut navigate = 0isize;
        let mut replace = false;
        let mut replace_all = false;
        egui::Panel::top("find").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label("Find");
                let response = ui.add(
                    egui::TextEdit::singleline(&mut self.find.query)
                        .id(Id::new("find-query"))
                        .desired_width(220.0),
                );
                if self.find.focus {
                    response.request_focus();
                    self.find.focus = false;
                }
                if response.changed() {
                    self.find.index = usize::MAX;
                    navigate = 1;
                }
                if response.has_focus()
                    && ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Enter))
                {
                    navigate = 1;
                }
                if ui.small_button("↑").clicked() {
                    navigate = -1;
                }
                if ui.small_button("↓").clicked() {
                    navigate = 1;
                }
                ui.weak(format!("{} matches", self.find.matches.len()));
                ui.checkbox(&mut self.find.case_sensitive, "Aa");
                ui.checkbox(&mut self.find.replace, "Replace");
                if ui.small_button("×").clicked()
                    || ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Escape))
                {
                    self.find.open = false;
                    self.restore_editor_focus(&ctx);
                }
            });
            if self.find.replace {
                ui.horizontal(|ui| {
                    ui.label("With");
                    ui.add(
                        egui::TextEdit::singleline(&mut self.find.replacement).desired_width(220.0),
                    );
                    replace = ui.button("Replace").clicked();
                    replace_all = ui.button("Replace all").clicked();
                });
            }
        });
        let key = (
            self.model.document.revision,
            self.find.query.clone(),
            self.find.case_sensitive,
            self.mode == Mode::Source,
        );
        if self.find.cache.as_ref() != Some(&key) {
            self.find.matches = search::hits(
                &self.model.document,
                &self.find.query,
                self.find.case_sensitive,
                self.mode == Mode::Source,
            );
            self.find.cache = Some(key);
        }
        let hits = self.find.matches.clone();
        if hits.is_empty() {
            return;
        }
        if replace_all {
            for (n, hit) in hits.iter().rev().enumerate() {
                if self.mode == Mode::Source {
                    let result = self.model.document.edit_source(
                        hit.bytes.clone(),
                        &self.find.replacement,
                        n == 0,
                    );
                    if let Err(error) = result {
                        self.error = Some(error);
                        break;
                    }
                } else {
                    let result = self.model.document.replace(
                        hit.from,
                        hit.to,
                        &self.find.replacement,
                        n == 0,
                    );
                    if let Err(error) = result {
                        self.error = Some(error);
                        break;
                    }
                }
            }
            self.editor.document_replaced();
            self.changed();
            return;
        }
        self.find.index = self.find.index.min(hits.len() - 1);
        if replace {
            let hit = &hits[self.find.index];
            if self.mode == Mode::Source {
                let result = self.model.document.edit_source(
                    hit.bytes.clone(),
                    &self.find.replacement,
                    true,
                );
                if let Err(error) = result {
                    self.error = Some(error);
                    return;
                }
            } else {
                let result =
                    self.model
                        .document
                        .replace(hit.from, hit.to, &self.find.replacement, true);
                if let Err(error) = result {
                    self.error = Some(error);
                    return;
                }
            }
            self.editor.document_replaced();
            self.changed();
            return;
        }
        if navigate != 0 {
            self.find.index =
                (self.find.index as isize + navigate).rem_euclid(hits.len() as isize) as usize;
            let hit = &hits[self.find.index];
            self.bookmark = hit.bytes.start;
            if self.mode == Mode::Source {
                self.source_history_selection = Some(blank_document::SourceSelection {
                    anchor: hit.bytes.start,
                    focus: hit.bytes.end,
                });
            } else {
                self.editor.select(Selection {
                    anchor: editor_position(hit.from),
                    focus: editor_position(hit.to),
                });
            }
        }
    }
    pub(crate) fn tools_dialog(&mut self, ctx: &egui::Context) {
        let Some(command) = self.dialog else {
            return;
        };
        let old_preferences = self.preferences.clone();
        let mut close = false;
        let mut recover = None;
        let mut discard = None;
        let response = egui::Modal::new(Id::new("document-tools"))
            .frame(
                egui::Frame::popup(&ctx.global_style())
                    .fill(Color32::WHITE)
                    .inner_margin(24)
                    .corner_radius(12),
            )
            .show(ctx, |ui| {
                ui.set_width(410.0);
                ui.horizontal(|ui| {
                    ui.heading(command.label().trim_end_matches('…'));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        close = ui.button("×").clicked()
                    });
                });
                ui.add_space(18.0);
                match command {
                    Command::Settings => {
                        egui::Grid::new("appearance")
                            .spacing([24.0, 16.0])
                            .show(ui, |ui| {
                                ui.label("Editor font");
                                egui::ComboBox::from_id_salt("editor-font")
                                    .selected_text(&self.preferences.font)
                                    .width(210.0)
                                    .show_ui(ui, |ui| {
                                        if let Some(database) = &self.font_database {
                                            let families: std::collections::BTreeSet<_> = database
                                                .faces()
                                                .flat_map(|face| {
                                                    face.families.iter().map(|(name, _)| name)
                                                })
                                                .collect();
                                            for name in families {
                                                ui.selectable_value(
                                                    &mut self.preferences.font,
                                                    name.clone(),
                                                    name,
                                                );
                                            }
                                        }
                                    });
                                ui.end_row();
                                ui.label("Text size");
                                ui.add(
                                    egui::Slider::new(&mut self.preferences.size, 12.0..=32.0)
                                        .suffix(" pt"),
                                );
                                ui.end_row();
                                ui.label("Page color");
                                ui.color_edit_button_srgb(&mut self.preferences.background);
                                ui.end_row();
                                ui.label("Text color");
                                ui.color_edit_button_srgb(&mut self.preferences.ink);
                                ui.end_row();
                            });
                        ui.add_space(20.0);
                        ui.weak(
                            "These preferences affect Write. Typst controls the PDF typography.",
                        );
                        if ui.button("Restore defaults").clicked() {
                            self.preferences = storage::Preferences::default();
                        }
                    }
                    Command::Statistics => {
                        let text = self
                            .model
                            .document
                            .paragraphs
                            .iter()
                            .map(|p| p.text())
                            .collect::<Vec<_>>()
                            .join("\n\n");
                        let words = text.split_whitespace().count();
                        let selected = self
                            .editor
                            .selection()
                            .map(|s| {
                                let a = self
                                    .model
                                    .document
                                    .source_offset(crate::editor::position(&s.anchor));
                                let b = self
                                    .model
                                    .document
                                    .source_offset(crate::editor::position(&s.focus));
                                self.model.document.text()[a.min(b)..a.max(b)]
                                    .chars()
                                    .count()
                            })
                            .unwrap_or(0);
                        egui::Grid::new("statistics")
                            .spacing([40.0, 14.0])
                            .show(ui, |ui| {
                                for (label, value) in [
                                    ("Words", words.to_string()),
                                    ("Characters", text.chars().count().to_string()),
                                    (
                                        "Paragraphs",
                                        self.model.document.paragraphs.len().to_string(),
                                    ),
                                    ("Reading time", format!("{} min", words.div_ceil(200))),
                                    ("Selected characters", selected.to_string()),
                                    (
                                        "File size",
                                        format!("{} bytes", self.model.document.text().len()),
                                    ),
                                    (
                                        "Undo payload",
                                        format!("{} bytes", self.model.document.history_bytes()),
                                    ),
                                ] {
                                    ui.label(label);
                                    ui.label(value);
                                    ui.end_row();
                                }
                            });
                        ui.add_space(16.0);
                        if let Some(path) = &self.path {
                            ui.label(path.display().to_string());
                            if let Ok(metadata) = std::fs::metadata(path) {
                                ui.weak(format!("On disk: {} bytes", metadata.len()));
                            }
                        }
                    }
                    Command::Recovery => {
                        if self.recovery.is_empty() {
                            ui.weak("No unsaved documents to recover.");
                        }
                        for (index, (_, draft)) in self.recovery.iter().enumerate() {
                            ui.horizontal(|ui| {
                                ui.vertical(|ui| {
                                    ui.label(
                                        draft
                                            .path
                                            .as_ref()
                                            .and_then(|p| p.file_name())
                                            .and_then(|p| p.to_str())
                                            .unwrap_or("Untitled"),
                                    );
                                    ui.weak(
                                        draft
                                            .text
                                            .chars()
                                            .take(70)
                                            .collect::<String>()
                                            .replace('\n', " "),
                                    );
                                });
                                if ui.button("Recover").clicked() {
                                    recover = Some(index);
                                }
                                if ui.button("Discard").clicked() {
                                    discard = Some(index);
                                }
                            });
                            ui.add_space(8.0);
                        }
                    }
                    _ => {}
                }
            });
        if old_preferences.font != self.preferences.font {
            self.apply_reading_font(ctx);
        }
        if command == Command::Settings
            && old_preferences != self.preferences
            && let Err(error) = self.storage.save_preferences(&self.preferences)
        {
            self.error = Some(error);
        }
        if let Some(index) = recover
            && self.protect_unsaved()
        {
            let (journal, draft) = self.recovery.remove(index);
            self.load(draft.text.clone(), draft.path.clone());
            self.disk_text = draft.disk_text.clone();
            self.bookmark = draft.bookmark;
            self.restore_draft(&draft, ctx);
            self.conflict = self.path.as_ref().is_some_and(|path| {
                std::fs::read_to_string(path).ok().as_deref() != Some(&self.disk_text)
            });
            storage::Storage::discard_recovery(&journal);
            close = true;
        }
        if let Some(index) = discard {
            let (journal, _) = self.recovery.remove(index);
            storage::Storage::discard_recovery(&journal);
        }
        if close || response.should_close() {
            self.dialog = None;
            self.restore_editor_focus(ctx);
        }
    }
    pub(crate) fn apply_reading_font(&mut self, ctx: &egui::Context) {
        let id = Id::new("reading-font-version");
        ctx.data_mut(|data| {
            let version = data.get_temp::<u64>(id).unwrap_or(0) + 1;
            data.insert_temp(id, version);
        });
        if self.preferences.font == "Iowan Old Style" {
            self.reading_faces = crate::typography::install(ctx);
            return;
        }
        if self.font_database.is_none() {
            let mut db = fontdb::Database::new();
            db.load_system_fonts();
            self.font_database = Some(db);
        }
        let database = self.font_database.as_ref().unwrap();
        let mut definitions = ctx.fonts(|fonts| fonts.definitions().clone());
        for (name, weight, style) in [
            ("reading", fontdb::Weight::NORMAL, fontdb::Style::Normal),
            ("reading-bold", fontdb::Weight::BOLD, fontdb::Style::Normal),
            (
                "reading-italic",
                fontdb::Weight::NORMAL,
                fontdb::Style::Italic,
            ),
            (
                "reading-bold-italic",
                fontdb::Weight::BOLD,
                fontdb::Style::Italic,
            ),
        ] {
            if let Some(id) = database.query(&fontdb::Query {
                families: &[fontdb::Family::Name(&self.preferences.font)],
                weight,
                style,
                ..Default::default()
            }) && let Some(data) = database.with_face_data(id, |bytes, index| {
                let mut data = egui::FontData::from_owned(bytes.to_vec());
                data.index = index;
                data
            }) {
                definitions.font_data.insert(name.into(), data.into());
            }
        }
        ctx.set_fonts(definitions);
        self.reading_faces = true;
    }
    pub(crate) fn paragraph_layout(
        &mut self,
        index: usize,
        width: f32,
        ctx: &egui::Context,
    ) -> (std::sync::Arc<egui::Galley>, egui_richedit::OffsetMap) {
        let paragraph = &self.model.document.paragraphs[index];
        let version = ctx.data(|data| {
            data.get_temp::<u64>(Id::new("reading-font-version"))
                .unwrap_or(0)
        });
        let key = (
            width.to_bits(),
            self.preferences.size.to_bits(),
            self.preferences.ink,
            version,
        );
        if let Some(layout) = self.layouts.get(&paragraph.id)
            && layout.key == key
        {
            return (layout.galley.clone(), layout.map.clone());
        }
        {
            let (mut job, map) =
                crate::typography::paragraph(paragraph, width, self.reading_faces).into_parts();
            let scale = self.preferences.size / 18.0;
            for section in &mut job.sections {
                section.format.font_id.size *= scale;
                section.format.line_height =
                    section.format.line_height.map(|height| height * scale);
                if section.format.background == Color32::TRANSPARENT {
                    section.format.color = Color32::from_rgb(
                        self.preferences.ink[0],
                        self.preferences.ink[1],
                        self.preferences.ink[2],
                    );
                }
            }
            self.layouts.insert(
                paragraph.id,
                crate::typography::CachedParagraph {
                    galley: ctx.fonts_mut(|fonts| fonts.layout_job(job)),
                    map,
                    key,
                },
            );
        }
        let layout = &self.layouts[&paragraph.id];
        (layout.galley.clone(), layout.map.clone())
    }
}
