use crate::{App, commands::Command, preview, storage, zotero};
use blank_document::objects::{self, Object};
use eframe::egui::{self, Color32, Id, Key, Sense, vec2};
use std::{
    hash::{Hash, Hasher},
    ops::Range,
    path::{Path, PathBuf},
    sync::mpsc,
    time::{Duration, Instant},
};
type BibResult = Result<(zotero::Item, String), String>;
pub type RefreshResult = (PathBuf, Result<Vec<(zotero::Item, String)>, String>);
pub struct Insertion {
    command: Command,
    range: Range<usize>,
    fields: [String; 3],
    focus: bool,
    error: Option<String>,
    changed: Instant,
    queried: String,
    references: Vec<zotero::Item>,
    search: Option<mpsc::Receiver<Result<Vec<zotero::Item>, String>>>,
    bibliography: Option<mpsc::Receiver<BibResult>>,
}
fn escape(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            if "\\#[]*_@$<>`".contains(c) {
                vec!['\\', c]
            } else {
                vec![c]
            }
        })
        .collect()
}
fn quote(text: &str) -> String {
    serde_json::to_string(text).unwrap()
}
impl App {
    pub(crate) fn project_root(&self) -> PathBuf {
        self.path
            .as_ref()
            .and_then(|path| path.parent())
            .map(Path::to_owned)
            .unwrap_or_else(|| self.assets.path().to_owned())
    }
    pub(crate) fn start_insertion(&mut self, command: Command) {
        let range = self
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
                a.min(b)..a.max(b)
            })
            .unwrap_or(self.bookmark..self.bookmark);
        let text = self.model.document.text()[range.clone()].to_owned();
        let mut fields = std::array::from_fn(|_| String::new());
        match command {
            Command::Image => {
                let Some(path) = self
                    .file_dialog
                    .clone()
                    .add_filter(
                        "Images and figures",
                        &["png", "jpg", "jpeg", "svg", "webp", "gif", "pdf"],
                    )
                    .pick_file()
                else {
                    return;
                };
                match self.import_asset(&path) {
                    Ok(path) => fields[0] = path,
                    Err(error) => {
                        self.error = Some(error);
                        return;
                    }
                }
            }
            Command::Link => fields[1] = text,
            Command::Table => {
                fields[0] = "2".into();
                fields[1] = "3".into();
            }
            Command::Citation => fields[1] = "users/0".into(),
            _ => fields[0] = text,
        }
        self.insertion = Some(Insertion {
            command,
            range,
            fields,
            focus: true,
            error: None,
            changed: Instant::now() - Duration::from_secs(1),
            queried: "\0".into(),
            references: vec![],
            search: None,
            bibliography: None,
        });
    }
    fn import_asset(&self, path: &Path) -> Result<String, String> {
        let folder = self.project_root().join("assets");
        std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("image");
        let extension = path.extension().and_then(|s| s.to_str()).unwrap_or("png");
        let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
        if bytes.len() > 32 * 1024 * 1024 {
            return Err("Images must be at most 32 MB.".into());
        }
        for counter in 0..10000 {
            let filename = if counter == 0 {
                format!("{stem}.{extension}")
            } else {
                format!("{stem}-{counter}.{extension}")
            };
            let target = folder.join(&filename);
            if target.exists() {
                if std::fs::read(&target).ok().as_deref() == Some(&bytes) {
                    return Ok(format!("assets/{filename}"));
                }
                continue;
            }
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&target)
                .map_err(|e| e.to_string())?;
            use std::io::Write;
            file.write_all(&bytes)
                .and_then(|()| file.sync_all())
                .map_err(|e| e.to_string())?;
            return Ok(format!("assets/{filename}"));
        }
        Err("Could not choose an unused image filename".into())
    }
    pub(crate) fn promote_assets(&self, destination: &Path) -> Result<(), String> {
        fn copy(source: &Path, target: &Path) -> Result<(), String> {
            for entry in std::fs::read_dir(source).map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                let next = target.join(entry.file_name());
                if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
                    std::fs::create_dir_all(&next).map_err(|e| e.to_string())?;
                    copy(&entry.path(), &next)?;
                } else {
                    let bytes = std::fs::read(entry.path()).map_err(|e| e.to_string())?;
                    if next.exists() {
                        if std::fs::read(&next).ok().as_deref() != Some(&bytes) {
                            return Err(format!(
                                "{} already contains a different asset. Choose another folder.",
                                next.display()
                            ));
                        }
                    } else {
                        storage::atomic_write(&next, &bytes)?;
                    }
                }
            }
            Ok(())
        }
        copy(self.assets.path(), destination)
    }
    fn insert_source(
        &mut self,
        range: Range<usize>,
        source: &str,
        block: bool,
        ctx: &egui::Context,
    ) -> Result<(), String> {
        let prefix = if block
            && range.start > 0
            && !self.model.document.text()[..range.start].ends_with("\n\n")
        {
            "\n\n"
        } else {
            ""
        };
        let suffix = if block { "\n\n" } else { "" };
        self.model.document.edit_source(
            range.clone(),
            &format!("{prefix}{source}{suffix}"),
            true,
        )?;
        self.bookmark = range.start + prefix.len() + source.len() + suffix.len();
        self.editor.document_replaced();
        self.editor.select(egui_richedit::Selection::caret(
            crate::editor::editor_position(self.model.document.position_at(self.bookmark)),
        ));
        self.changed();
        self.restore_editor_focus(ctx);
        Ok(())
    }
    pub(crate) fn dropped_image(&mut self, path: &Path, ctx: &egui::Context) {
        if !path
            .extension()
            .and_then(|s| s.to_str())
            .is_some_and(|extension| {
                matches!(
                    extension.to_ascii_lowercase().as_str(),
                    "png" | "jpg" | "jpeg" | "svg" | "pdf" | "webp" | "gif"
                )
            })
        {
            return;
        }
        let result = self.import_asset(path).and_then(|asset| {
            self.insert_source(
                self.bookmark..self.bookmark,
                &format!("#figure(image({}), caption: [])", quote(&asset)),
                true,
                ctx,
            )
        });
        if let Err(error) = result {
            self.error = Some(error);
        }
    }
    pub(crate) fn insertion_dialog(&mut self, ctx: &egui::Context) {
        let Some(mut dialog) = self.insertion.take() else {
            return;
        };
        let mut citation = None;
        if let Some(receiver) = &dialog.search
            && let Ok(result) = receiver.try_recv()
        {
            dialog.search = None;
            match result {
                Ok(items) => dialog.references = items,
                Err(error) => dialog.error = Some(error),
            };
        }
        if let Some(receiver) = &dialog.bibliography
            && let Ok(result) = receiver.try_recv()
        {
            dialog.bibliography = None;
            match result {
                Ok(value) => citation = Some(value),
                Err(error) => dialog.error = Some(error),
            };
        }
        let mut insert = false;
        let mut cancel = false;
        let response = egui::Modal::new(Id::new("insert-object"))
            .frame(
                egui::Frame::popup(&ctx.global_style())
                    .fill(Color32::WHITE)
                    .corner_radius(12)
                    .inner_margin(24),
            )
            .show(ctx, |ui| {
                ui.set_width(430.0);
                ui.heading(dialog.command.label());
                ui.add_space(16.0);
                let labels: &[&str] = match dialog.command {
                    Command::Image => &["Image file", "Caption", "Alternative text"],
                    Command::Table => &["Columns", "Rows"],
                    Command::Link => &["URL", "Text"],
                    Command::Citation => &["Search references", "Library (users/0 or groups/ID)"],
                    Command::Footnote => &["Note"],
                    Command::Equation => &["Typst mathematics"],
                    Command::Label | Command::Reference => &["Label name"],
                    _ => &["Quotation"],
                };
                for (index, label) in labels.iter().enumerate() {
                    ui.label(*label);
                    let response = if matches!(
                        dialog.command,
                        Command::Footnote | Command::Quote | Command::Equation
                    ) {
                        ui.add(
                            egui::TextEdit::multiline(&mut dialog.fields[index])
                                .desired_width(f32::INFINITY)
                                .desired_rows(4),
                        )
                    } else {
                        ui.add(
                            egui::TextEdit::singleline(&mut dialog.fields[index])
                                .desired_width(f32::INFINITY),
                        )
                    };
                    if dialog.focus && index == usize::from(dialog.command == Command::Image) {
                        response.request_focus();
                        dialog.focus = false;
                    }
                    if response.changed() {
                        dialog.changed = Instant::now();
                        dialog.error = None;
                    }
                    ui.add_space(8.0);
                }
                if dialog.command == Command::Citation {
                    if dialog.search.is_some() || dialog.bibliography.is_some() {
                        ui.spinner();
                    }
                    egui::ScrollArea::vertical()
                        .max_height(300.0)
                        .show(ui, |ui| {
                            for item in &dialog.references {
                                if ui
                                    .add(
                                        egui::Button::new(format!(
                                            "{}\n{} · {}",
                                            item.title, item.author, item.year
                                        ))
                                        .wrap()
                                        .frame(false),
                                    )
                                    .clicked()
                                {
                                    let item = item.clone();
                                    let (tx, rx) = mpsc::channel();
                                    let ctx = ctx.clone();
                                    std::thread::spawn(move || {
                                        let result =
                                            zotero::bibliography(&item).map(|bib| (item, bib));
                                        let _ = tx.send(result);
                                        ctx.request_repaint();
                                    });
                                    dialog.bibliography = Some(rx);
                                }
                            }
                        });
                }
                if let Some(error) = &dialog.error {
                    ui.colored_label(Color32::from_rgb(150, 60, 32), error);
                }
                ui.add_space(16.0);
                ui.horizontal(|ui| {
                    cancel = ui.button("Cancel").clicked();
                    if dialog.command != Command::Citation {
                        insert = ui.button("Insert").clicked();
                    }
                });
            });
        if dialog.command == Command::Citation
            && dialog.queried != format!("{}:{}", dialog.fields[1], dialog.fields[0])
        {
            if dialog.changed.elapsed() >= Duration::from_millis(300) {
                let library = dialog.fields[1].clone();
                let query = dialog.fields[0].clone();
                dialog.queried = format!("{library}:{query}");
                let (tx, rx) = mpsc::channel();
                let ctx = ctx.clone();
                std::thread::spawn(move || {
                    let _ = tx.send(zotero::search(&library, &query));
                    ctx.request_repaint();
                });
                dialog.search = Some(rx);
            } else {
                ctx.request_repaint_after(Duration::from_millis(300));
            }
        }
        if let Some((item, bib)) = citation {
            match self.store_citation(&item, &bib).and_then(|()| {
                self.insert_source(
                    dialog.range.clone(),
                    &format!("@{}", item.cite_key),
                    false,
                    ctx,
                )
            }) {
                Ok(()) => {
                    if !self.model.document.text().contains("#bibliography(") {
                        let end = self.model.document.text().len();
                        let _ = self.model.document.edit_source(
                            end..end,
                            "\n\n#bibliography(\"references.bib\")",
                            false,
                        );
                    }
                    return;
                }
                Err(error) => dialog.error = Some(error),
            }
        }
        if insert {
            let [a, b, c] = &dialog.fields;
            let raw = match dialog.command {
                Command::Image => Ok(format!(
                    "#figure(image({}, alt: {}), caption: [{}])",
                    quote(a),
                    quote(c),
                    escape(b)
                )),
                Command::Table => match (a.parse::<usize>(), b.parse::<usize>()) {
                    (Ok(columns), Ok(rows))
                        if (1..=20).contains(&columns) && (1..=100).contains(&rows) =>
                    {
                        Ok(format!(
                            "#table(columns: {columns},\n{})",
                            "  [],\n".repeat(rows * columns)
                        ))
                    }
                    _ => Err("Use 1–20 columns and 1–100 rows.".into()),
                },
                Command::Quote => Ok(format!("#quote(block: true)[{}]", escape(a))),
                Command::Footnote => Ok(format!("#footnote[{}]", escape(a))),
                Command::Equation => Ok(format!("$ {} $", a)),
                Command::Link if !a.trim().is_empty() => Ok(format!(
                    "#link({})[{}]",
                    quote(a),
                    escape(if b.is_empty() { a } else { b })
                )),
                Command::Label | Command::Reference
                    if !a.is_empty()
                        && a.chars().all(|c| c.is_alphanumeric() || "-_:".contains(c)) =>
                {
                    Ok(if dialog.command == Command::Label {
                        format!("<{a}>")
                    } else {
                        format!("@{a}")
                    })
                }
                _ => Err("Enter a value to insert.".into()),
            };
            let block = matches!(
                dialog.command,
                Command::Image | Command::Table | Command::Quote | Command::Equation
            );
            match raw.and_then(|raw| self.insert_source(dialog.range.clone(), &raw, block, ctx)) {
                Ok(()) => return,
                Err(error) => dialog.error = Some(error),
            }
        }
        if !cancel && !response.should_close() {
            self.insertion = Some(dialog);
        } else {
            self.restore_editor_focus(ctx);
        }
    }
    fn store_citation(&self, item: &zotero::Item, bib: &str) -> Result<(), String> {
        let root = self.project_root();
        let file = root.join("references.bib");
        let old = match std::fs::read_to_string(&file) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(e.to_string()),
        };
        let updated = zotero::upsert(&old, &item.cite_key, bib)?;
        storage::atomic_write(&file, updated.as_bytes())?;
        let manifest = root.join(".blank-references.json");
        let mut items: Vec<zotero::Item> = match std::fs::read(&manifest) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string())?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => vec![],
            Err(e) => return Err(e.to_string()),
        };
        items.retain(|old| old.cite_key != item.cite_key);
        items.push(item.clone());
        storage::atomic_write(
            &manifest,
            &serde_json::to_vec(&items).map_err(|e| e.to_string())?,
        )
    }
    pub(crate) fn refresh_zotero(&mut self, ctx: &egui::Context) {
        let root = self.project_root();
        let items: Vec<zotero::Item> = std::fs::read(root.join(".blank-references.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        if items.is_empty() {
            self.error = Some("This document has no saved Zotero references to refresh.".into());
            return;
        }
        let (tx, rx) = mpsc::channel();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result = items
                .into_iter()
                .map(|item| zotero::bibliography(&item).map(|bib| (item, bib)))
                .collect::<Result<Vec<_>, _>>();
            let _ = tx.send((root, result));
            ctx.request_repaint();
        });
        self.zotero_refresh = Some(rx);
    }
    pub(crate) fn poll_zotero(&mut self) {
        if let Some(receiver) = &self.zotero_refresh
            && let Ok((root, result)) = receiver.try_recv()
        {
            self.zotero_refresh = None;
            if root != self.project_root() {
                return;
            }
            match result {
                Ok(entries) => {
                    for (item, bib) in entries {
                        if let Err(error) = self.store_citation(&item, &bib) {
                            self.error = Some(error);
                            break;
                        }
                    }
                    self.requested_revision = None;
                    self.preview_revision = None;
                    self.page_revision = None;
                }
                Err(error) => self.error = Some(error),
            }
        }
    }
    pub(crate) fn object_ui(&mut self, ui: &mut egui::Ui, range: Range<usize>) -> bool {
        let raw = self.model.document.text()[range.clone()].to_owned();
        let Some(object) = objects::parse(&raw, range.start) else {
            return false;
        };
        match object {
            Object::Table(table) => {
                let mut cells = table
                    .cells
                    .iter()
                    .map(|range| self.model.document.text()[range.clone()].to_owned())
                    .collect::<Vec<_>>();
                let mut changed = None;
                let mut columns = table.columns;
                let mut structural = false;
                let active_id = Id::new(("active-table-cell", range.start));
                let mut active = ui
                    .ctx()
                    .data(|data| data.get_temp::<usize>(active_id))
                    .unwrap_or(0);
                let mut add_row = false;
                let last = cells.len().saturating_sub(1);
                let focused_cell = (0..cells.len()).find(|&index| {
                    ui.memory(|m| m.has_focus(Id::new(("table-cell", range.start, index))))
                });
                if let Some(index) = focused_cell {
                    active = index;
                }
                let tab = focused_cell.is_some()
                    && ui.input(|i| i.key_pressed(Key::Tab) && !i.modifiers.shift);
                let cell_width = (ui.available_width() / columns as f32 - 10.0).max(70.0);
                egui::Grid::new(("table", range.start))
                    .num_columns(columns)
                    .spacing(vec2(10.0, 8.0))
                    .show(ui, |ui| {
                        for (index, cell) in cells.iter_mut().enumerate() {
                            let response = ui.add(
                                egui::TextEdit::multiline(cell)
                                    .id(Id::new(("table-cell", range.start, index)))
                                    .desired_width(cell_width)
                                    .desired_rows(1),
                            );
                            if let Some(mut state) =
                                egui::TextEdit::load_state(ui.ctx(), response.id)
                            {
                                state.clear_undoer();
                                state.store(ui.ctx(), response.id);
                            }
                            if response.has_focus() {
                                active = index;
                            }
                            if response.changed() {
                                changed = Some(index);
                            }
                            if (index + 1) % columns == 0 {
                                ui.end_row();
                            }
                        }
                    });
                if tab && active == last {
                    add_row = true;
                }
                ui.ctx()
                    .data_mut(|data| data.insert_temp(active_id, active));
                ui.horizontal(|ui| {
                    if ui.small_button("+ Row").clicked() {
                        add_row = true;
                    }
                    if ui.small_button("− Row").clicked() && cells.len() > columns {
                        let row = active / columns;
                        cells.drain(row * columns..((row + 1) * columns).min(cells.len()));
                        structural = true;
                    }
                    if ui.small_button("+ Column").clicked() {
                        let mut next = vec![];
                        for row in cells.chunks(columns) {
                            next.extend_from_slice(row);
                            next.push(String::new());
                        }
                        cells = next;
                        columns += 1;
                        structural = true;
                    }
                    if ui.small_button("− Column").clicked() && columns > 1 {
                        let column = active % columns;
                        cells = std::mem::take(&mut cells)
                            .into_iter()
                            .enumerate()
                            .filter_map(|(index, cell)| (index % columns != column).then_some(cell))
                            .collect();
                        columns -= 1;
                        structural = true;
                    }
                });
                if add_row {
                    cells.extend(vec![String::new(); columns]);
                    structural = true;
                }
                if structural {
                    let source = table.source(&cells, columns);
                    let _ = self
                        .model
                        .document
                        .edit_source(range.clone(), &source, true);
                    if tab {
                        self.object_focus = Some(Id::new(("table-cell", range.start, last + 1)));
                    }
                    self.editor.document_replaced();
                } else if let Some(index) = changed {
                    let _ = self.model.document.edit_source(
                        table.cells[index].clone(),
                        &cells[index],
                        self.last_edit.elapsed() > Duration::from_secs(1),
                    );
                    self.editor.document_replaced();
                }
            }
            Object::Quote { body } => {
                let mut text = self.model.document.text()[body.clone()].to_owned();
                let response = ui.add(
                    egui::TextEdit::multiline(&mut text)
                        .font(egui::FontId::new(
                            self.preferences.size,
                            egui::FontFamily::Name("reading-italic".into()),
                        ))
                        .frame(egui::Frame::NONE)
                        .desired_width(f32::INFINITY),
                );
                if response.changed() {
                    let _ = self.model.document.edit_source(
                        body,
                        &text,
                        self.last_edit.elapsed() > Duration::from_secs(1),
                    );
                    self.editor.document_replaced();
                }
            }
            Object::Image { path, caption, alt } => {
                let source = format!(
                    "#image({}, width: 100%, height: 360pt, fit: \"contain\")",
                    quote(&path)
                );
                let root = self.project_root();
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                source.hash(&mut hasher);
                root.hash(&mut hasher);
                std::fs::metadata(root.join(&path))
                    .and_then(|m| m.modified())
                    .ok()
                    .hash(&mut hasher);
                let key = hasher.finish();
                if let Some(texture) = self.objects.get(&key) {
                    ui.add(
                        egui::Image::new(texture)
                            .max_width(ui.available_width())
                            .sense(Sense::click()),
                    );
                } else {
                    let (_, placeholder) = ui.allocate_space(vec2(ui.available_width(), 180.0));
                    if !ui.is_rect_visible(placeholder) {
                        return true;
                    }
                    if self.failed_objects.contains(&key) {
                        ui.weak("Image could not be rendered. Check its source or file path.");
                    } else if self.pending_objects.insert(key) {
                        let _ = self.compiler.tx.send(preview::Request {
                            object: Some((key, source)),
                            page: None,
                            root,
                            entry: String::new(),
                            revision: key,
                            render: true,
                            files: Default::default(),
                        });
                    }
                }
                for (label, range, string) in
                    [("Caption", caption, false), ("Alternative text", alt, true)]
                {
                    if let Some(range) = range {
                        let raw = &self.model.document.text()[range.clone()];
                        let mut text = if string {
                            serde_json::from_str(raw).unwrap_or_else(|_| raw.to_owned())
                        } else {
                            raw.to_owned()
                        };
                        let response = ui.add(
                            egui::TextEdit::singleline(&mut text)
                                .hint_text(label)
                                .frame(egui::Frame::NONE)
                                .desired_width(f32::INFINITY),
                        );
                        if response.changed() {
                            let value = if string { quote(&text) } else { text };
                            let _ = self.model.document.edit_source(
                                range,
                                &value,
                                self.last_edit.elapsed() > Duration::from_secs(1),
                            );
                            self.editor.document_replaced();
                            break;
                        }
                    }
                }
            }
        }
        true
    }
}
