mod commands;
mod editor;
#[cfg(target_os = "macos")]
mod menus;
mod preview;
mod source_editor;
mod typography;

use blank_document::{Block, BlockKind, Document};
use commands::{Command, Picker};
use editor::{EditorModel, editor_position, position};
use eframe::egui::{self, Color32, Id, Key, KeyboardShortcut, Modifiers, Sense, vec2};
use egui_richedit::{Laid, Mark, RichEdit, Selection};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

const DEMO: &str = include_str!("../examples/Tutorial.typ");
const SOURCE_ID: &str = "typst-source";
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Write,
    Source,
    Preview,
}

struct App {
    model: EditorModel,
    editor: RichEdit<usize>,
    source_buffer: String,
    path: Option<PathBuf>,
    disk_text: String,
    mode: Mode,
    home: bool,
    contents: bool,
    bookmark: usize,
    source_focus: bool,
    source_new_step: bool,
    last_edit: Instant,
    seen_revision: u64,
    compiler: preview::Compiler,
    request_id: u64,
    requested_revision: Option<u64>,
    compiling: bool,
    pages: Vec<egui::TextureHandle>,
    pdf: Vec<u8>,
    preview_revision: Option<u64>,
    page_revision: Option<u64>,
    pending_export: Option<PathBuf>,
    diagnostics: Vec<String>,
    source_map: Vec<serde_json::Value>,
    reveal_page: bool,
    zoom: f32,
    error: Option<String>,
    conflict: bool,
    confirm_close: bool,
    screenshot: Option<PathBuf>,
    window_title: String,
    picker: Picker,
    pending_events: Vec<egui::Event>,
    restore_focus: bool,
    last_input: Instant,
    reading_faces: bool,
    source_layout: Option<(String, egui::text::LayoutJob)>,
    slash_start: Option<blank_document::Position>,
    caret_anchor: Option<egui::Pos2>,
    dragging_block: Option<usize>,
    block_menu: Option<(usize, egui::Pos2)>,
    #[cfg(test)]
    block_rects: Vec<egui::Rect>,
    #[cfg(target_os = "macos")]
    menus: Option<menus::NativeMenus>,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let ctx = &cc.egui_ctx;
        ctx.set_theme(egui::Theme::Light);
        let mut style = (*ctx.global_style()).clone();
        style.visuals = egui::Visuals::light();
        style.visuals.panel_fill = Color32::WHITE;
        style.visuals.window_fill = Color32::WHITE;
        style.visuals.override_text_color = Some(Color32::from_rgb(52, 58, 55));
        style.visuals.selection.bg_fill = Color32::from_rgb(218, 229, 216);
        // Standard egui components with the app's quiet palette.
        ctx.set_global_style(style);
        let reading_faces = typography::install(ctx);
        let mut app = Self {
            model: EditorModel {
                document: Document::new(""),
                error: None,
            },
            editor: RichEdit::new(Id::new("writer")),
            source_buffer: String::new(),
            path: None,
            disk_text: String::new(),
            mode: Mode::Write,
            home: true,
            contents: true,
            bookmark: 0,
            source_focus: false,
            source_new_step: true,
            last_edit: Instant::now(),
            seen_revision: 0,
            compiler: preview::Compiler::new(ctx.clone()),
            request_id: 0,
            requested_revision: None,
            compiling: false,
            pages: vec![],
            pdf: vec![],
            preview_revision: None,
            page_revision: None,
            pending_export: None,
            diagnostics: vec![],
            source_map: vec![],
            reveal_page: false,
            zoom: 1.0,
            error: None,
            conflict: false,
            confirm_close: false,
            screenshot: None,
            window_title: String::new(),
            picker: Picker::default(),
            pending_events: vec![],
            restore_focus: false,
            last_input: Instant::now(),
            reading_faces,
            source_layout: None,
            slash_start: None,
            caret_anchor: None,
            dragging_block: None,
            block_menu: None,
            #[cfg(test)]
            block_rects: vec![],
            #[cfg(target_os = "macos")]
            menus: None,
        };
        let args: Vec<String> = std::env::args().skip(1).collect();
        if args.iter().any(|a| a == "--demo") {
            app.load(DEMO.to_owned(), None);
        } else if let Some(path) = args.iter().find(|a| !a.starts_with("--")) {
            let path = PathBuf::from(path);
            match path
                .canonicalize()
                .and_then(|p| std::fs::read_to_string(&p).map(|text| (p, text)))
            {
                Ok((path, text)) => app.load(text, Some(path)),
                Err(e) => app.error = Some(e.to_string()),
            }
        }
        if args.iter().any(|a| a == "--source") {
            app.mode = Mode::Source;
        }
        if args.iter().any(|a| a == "--preview") {
            app.mode = Mode::Preview;
        }
        #[cfg(target_os = "macos")]
        if cc.winit_window().is_some() {
            match menus::NativeMenus::new(ctx.clone()) {
                Ok(menus) => app.menus = Some(menus),
                Err(e) => app.error = Some(format!("Cannot install native menus: {e}")),
            }
        }
        app.screenshot = std::env::var_os("BLANK_NATIVE_SCREENSHOT").map(PathBuf::from);
        app
    }
    fn load(&mut self, text: String, path: Option<PathBuf>) {
        self.disk_text = text.clone();
        self.source_buffer = text.clone();
        self.model.document = Document::new(text);
        self.model.error = None;
        self.path = path;
        self.home = false;
        self.editor = RichEdit::new(Id::new("writer"));
        self.editor
            .select(Selection::caret(egui_richedit::Position::new(0, 0)));
        self.seen_revision = 0;
        self.bookmark = 0;
        self.source_focus = true;
        self.source_new_step = true;
        self.pages.clear();
        self.pdf.clear();
        self.preview_revision = None;
        self.page_revision = None;
        self.pending_export = None;
        self.diagnostics.clear();
        self.source_map.clear();
        self.requested_revision = None;
        self.request_id += 1;
        self.last_edit = Instant::now() - Duration::from_secs(1);
        self.compiling = false;
        self.conflict = false;
    }
    fn dirty(&self) -> bool {
        self.model.document.text() != self.disk_text
    }
    fn changed(&mut self) {
        if self.seen_revision != self.model.document.revision {
            self.seen_revision = self.model.document.revision;
            self.last_edit = Instant::now();
            self.source_buffer = self.model.document.text().to_owned();
        }
    }
    fn switch_mode(&mut self, mode: Mode, _ctx: &egui::Context) {
        if self.mode == mode {
            return;
        }
        if self.mode == Mode::Write
            && let Some(s) = self.editor.selection()
        {
            self.bookmark = self.model.document.source_offset(position(&s.focus));
        }
        if self.mode == Mode::Preview {
            self.pages.clear();
            self.page_revision = None;
        }
        self.mode = mode;
        self.source_new_step = true;
        self.editor.document_replaced();
        match mode {
            Mode::Write => self.editor.select(Selection::caret(editor_position(
                self.model.document.position_at(self.bookmark),
            ))),
            Mode::Source => {
                self.source_focus = true;
            }
            Mode::Preview => {
                self.reveal_page = true;
                if self.page_revision != Some(self.model.document.revision) {
                    self.compile(true);
                }
            }
        }
    }
    fn compile(&mut self, render: bool) {
        let (root, entry) = if let Some(path) = &self.path {
            (
                path.parent()
                    .unwrap_or(std::path::Path::new("."))
                    .to_path_buf(),
                path.file_name().unwrap().to_string_lossy().into_owned(),
            )
        } else {
            (
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("examples"),
                "main.typ".into(),
            )
        };
        self.request_id += 1;
        let request = preview::Request {
            revision: self.request_id,
            root,
            entry,
            text: self.model.document.text().to_owned(),
            render,
        };
        if self.compiler.tx.send(request).is_ok() {
            self.requested_revision = Some(self.model.document.revision);
            self.compiling = true;
        } else {
            self.error =
                Some("Compiler is unavailable. Restart with scripts/dev-native.sh.".into());
        }
    }
    fn poll_compile(&mut self, ctx: &egui::Context) {
        while let Ok(result) = self.compiler.rx.try_recv() {
            match result {
                Ok(result) if result.revision == self.request_id => {
                    self.compiling = false;
                    if self.requested_revision != Some(self.model.document.revision) {
                        if self.pending_export.take().is_some() {
                            self.error = Some("The document changed during PDF export. Export again to use the latest text.".into());
                        }
                        continue;
                    }
                    self.diagnostics = result.diagnostics;
                    if !result.pdf.is_empty() {
                        self.pdf = result.pdf;
                        self.source_map = result.source_map;
                        self.preview_revision = self.requested_revision;
                        if let Some(path) = self.pending_export.take()
                            && let Err(e) = std::fs::write(path, &self.pdf)
                        {
                            self.error = Some(e.to_string());
                        }
                    } else if self.pending_export.take().is_some() {
                        self.error =
                            Some("PDF export failed. Resolve the typesetting errors first.".into());
                    }
                    if !result.pages.is_empty() && self.mode == Mode::Preview {
                        self.pages = result
                            .pages
                            .into_iter()
                            .enumerate()
                            .map(|(i, page)| {
                                ctx.load_texture(
                                    format!("page-{}-{i}", result.revision),
                                    egui::ColorImage::from_rgba_unmultiplied(page.size, &page.rgba),
                                    egui::TextureOptions::LINEAR,
                                )
                            })
                            .collect();
                        self.page_revision = self.requested_revision;
                    }
                }
                Ok(_) => {}
                Err(e) => {
                    self.compiling = false;
                    self.pending_export = None;
                    self.error = Some(e);
                }
            }
        }
    }
    fn save(&mut self, save_as: bool) -> bool {
        let path = if save_as || self.path.is_none() {
            let mut dialog = rfd::FileDialog::new()
                .add_filter("Typst document", &["typ"])
                .set_file_name(
                    self.path
                        .as_ref()
                        .and_then(|p| p.file_name())
                        .and_then(|s| s.to_str())
                        .unwrap_or("main.typ"),
                );
            if let Some(parent) = self.path.as_ref().and_then(|p| p.parent()) {
                dialog = dialog.set_directory(parent);
            }
            let Some(path) = dialog.save_file() else {
                return false;
            };
            path
        } else {
            self.path.clone().unwrap()
        };
        let result = (|| -> Result<(), String> {
            if self.path.as_ref() == Some(&path) {
                let disk = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
                if disk != self.disk_text {
                    self.conflict = true;
                    return Err("This file changed on disk. Your edits are kept in memory; use Save As to save a separate copy.".into());
                }
            }
            let mut file =
                tempfile::NamedTempFile::new_in(path.parent().unwrap_or(std::path::Path::new(".")))
                    .map_err(|e| e.to_string())?;
            use std::io::Write;
            file.write_all(self.model.document.text().as_bytes())
                .map_err(|e| e.to_string())?;
            file.as_file().sync_all().map_err(|e| e.to_string())?;
            if let Ok(metadata) = std::fs::metadata(&path) {
                file.as_file()
                    .set_permissions(metadata.permissions())
                    .map_err(|e| e.to_string())?;
            }
            file.persist(&path).map_err(|e| e.to_string())?;
            Ok(())
        })();
        match result {
            Ok(()) => {
                self.path = Some(path);
                self.disk_text = self.model.document.text().to_owned();
                self.conflict = false;
                true
            }
            Err(e) => {
                self.error = Some(e);
                self.conflict = true;
                false
            }
        }
    }
    fn protect_unsaved(&mut self) -> bool {
        if !self.dirty() {
            return true;
        }
        let answer = rfd::MessageDialog::new()
            .set_title("Save your writing?")
            .set_description("Save changes before opening another document.")
            .set_buttons(rfd::MessageButtons::YesNoCancel)
            .show();
        match answer {
            rfd::MessageDialogResult::Yes => self.save(false),
            rfd::MessageDialogResult::No => true,
            _ => false,
        }
    }
    fn open(&mut self) {
        if !self.protect_unsaved() {
            return;
        }
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Typst document", &["typ"])
            .pick_file()
        {
            match path
                .canonicalize()
                .and_then(|path| std::fs::read_to_string(&path).map(|text| (path, text)))
            {
                Ok((path, text)) => self.load(text, Some(path)),
                Err(e) => self.error = Some(e.to_string()),
            }
        }
    }
    fn new_document(&mut self) {
        if self.protect_unsaved() {
            self.load(String::new(), None);
        }
    }
    fn history(&mut self, redo: bool) {
        self.picker.open = false;
        self.slash_start = None;
        self.block_menu = None;
        self.dragging_block = None;
        let changed = if redo {
            self.model.document.redo()
        } else {
            self.model.document.undo()
        };
        if changed {
            self.editor.document_replaced();
            self.source_new_step = true;
            self.changed();
            self.source_focus = self.mode == Mode::Source;
            if self.mode == Mode::Write {
                self.editor.select(Selection::caret(editor_position(
                    self.model.document.position_at(self.bookmark),
                )));
            }
        }
    }
    fn enabled(&self, command: Command) -> bool {
        use Command::*;
        match command {
            New | Open | Close | Quit | Palette | Tutorial | Contents => true,
            Undo => !self.home && self.model.document.can_undo(),
            Redo => !self.home && self.model.document.can_redo(),
            Bold | Italic | Paragraph | Heading1 | Heading2 | Heading3 | Bullet | Numbered => {
                !self.home && self.mode == Mode::Write
            }
            Refresh | ZoomIn | ZoomOut | ActualSize => !self.home && self.mode == Mode::Preview,
            Cut | Copy | Paste | SelectAll => !self.home && self.mode != Mode::Preview,
            _ => !self.home,
        }
    }
    fn execute(&mut self, command: Command, ctx: &egui::Context) {
        if !self.enabled(command) {
            return;
        }
        self.last_input = Instant::now();
        use Command::*;
        match command {
            New => self.new_document(),
            Open => self.open(),
            Save => {
                self.save(false);
            }
            SaveAs => {
                self.save(true);
            }
            Export => self.export(),
            Close | Quit => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            Undo => self.history(false),
            Redo => self.history(true),
            Bold | Italic => {
                self.editor.toggle(
                    &mut self.model,
                    if command == Bold {
                        Mark::Bold
                    } else {
                        Mark::Italic
                    },
                );
            }
            Paragraph | Heading1 | Heading2 | Heading3 | Bullet | Numbered => {
                if let Some(selection) = self.editor.selection() {
                    let pos = position(&selection.focus);
                    if let Err(error) = self.model.document.set_kind(pos, command.block().unwrap())
                    {
                        self.error = Some(error);
                    }
                    self.editor.document_replaced();
                    self.editor.select(Selection::caret(editor_position(pos)));
                }
            }
            Write => self.switch_mode(Mode::Write, ctx),
            Source => self.switch_mode(Mode::Source, ctx),
            Preview => self.switch_mode(Mode::Preview, ctx),
            Contents => self.contents = !self.contents,
            Refresh => self.compile(true),
            ZoomIn => self.zoom = (self.zoom + 0.1).min(2.0),
            ZoomOut => self.zoom = (self.zoom - 0.1).max(0.25),
            ActualSize => self.zoom = 1.0,
            Palette => self.picker.show(false),
            Tutorial => {
                if self.protect_unsaved() {
                    self.load(DEMO.into(), None);
                }
            }
            Copy => self.pending_events.push(egui::Event::Copy),
            Cut => self.pending_events.push(egui::Event::Cut),
            SelectAll => self.pending_events.push(egui::Event::Key {
                key: Key::A,
                physical_key: None,
                pressed: true,
                repeat: false,
                modifiers: Modifiers::COMMAND,
            }),
            Paste => {
                #[cfg(target_os = "macos")]
                match arboard::Clipboard::new().and_then(|mut clipboard| clipboard.get_text()) {
                    Ok(text) => self.pending_events.push(egui::Event::Paste(text)),
                    Err(e) => self.error = Some(e.to_string()),
                }
            }
        }
        if command != Palette {
            self.restore_editor_focus(ctx);
        }
        ctx.request_repaint();
    }
    fn restore_editor_focus(&mut self, ctx: &egui::Context) {
        // Picker actions run after the document UI. Its destination must
        // appear in the next accessibility tree before receiving focus.
        self.restore_focus = true;
        ctx.request_repaint();
    }
    fn matching_commands(&self) -> Vec<Command> {
        let words: Vec<_> = self
            .picker
            .query
            .to_lowercase()
            .split_whitespace()
            .map(str::to_owned)
            .collect();
        Command::ALL
            .iter()
            .copied()
            .filter(|&c| {
                self.enabled(c)
                    && c != Command::Palette
                    && (!self.picker.slash || c.block().is_some())
                    && words.iter().all(|w| c.label().to_lowercase().contains(w))
            })
            .collect()
    }
    fn choose_slash(&mut self, command: Command, ctx: &egui::Context) {
        self.picker.open = false;
        if let Some(from) = self.slash_start.take()
            && let Some(selection) = self.editor.selection()
        {
            let to = position(&selection.focus);
            let result = self
                .model
                .document
                .replace(from, to, "", false)
                .and_then(|pos| {
                    self.model
                        .document
                        .set_kind_step(pos, command.block().unwrap(), false)?;
                    Ok(pos)
                });
            match result {
                Ok(pos) => {
                    self.editor.document_replaced();
                    self.editor.select(Selection::caret(editor_position(pos)));
                }
                Err(e) => self.error = Some(e),
            }
        }
        self.restore_editor_focus(ctx);
    }
    fn slash_trigger(&mut self, ctx: &egui::Context) {
        if self.picker.open {
            if self.picker.slash {
                let commands = self.matching_commands();
                if ctx.input_mut(|i| i.consume_key(Modifiers::NONE, Key::ArrowDown)) {
                    self.picker.index =
                        (self.picker.index + 1).min(commands.len().saturating_sub(1));
                }
                if ctx.input_mut(|i| i.consume_key(Modifiers::NONE, Key::ArrowUp)) {
                    self.picker.index = self.picker.index.saturating_sub(1);
                }
                if ctx.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Escape)) {
                    self.picker.open = false;
                    self.slash_start = None;
                } else if ctx.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Enter))
                    && let Some(&command) = commands.get(self.picker.index)
                {
                    self.choose_slash(command, ctx);
                }
            }
            return;
        }
        if self.home || self.mode != Mode::Write {
            return;
        }
        if let Some(selection) = self.editor.selection()
            && selection.anchor == selection.focus
            && ctx.memory(|m| m.has_focus(Id::new("writer")))
            && ctx.input(|i| {
                i.events
                    .iter()
                    .any(|e| matches!(e, egui::Event::Text(t) if t == "/"))
            })
        {
            self.slash_start = Some(position(&selection.focus));
            self.editor.document_replaced();
            self.picker.show(true);
            self.picker.focus = false;
        }
    }
    fn command_picker(&mut self, ctx: &egui::Context) {
        if !self.picker.open {
            return;
        }
        if self.picker.slash {
            let Some(from) = self.slash_start else {
                self.picker.open = false;
                return;
            };
            let Some(selection) = self.editor.selection() else {
                self.picker.open = false;
                return;
            };
            let to = position(&selection.focus);
            if to.paragraph != from.paragraph || to.offset <= from.offset || !selection.is_caret() {
                self.picker.open = false;
                return;
            }
            let text: String = self.model.document.paragraphs[from.paragraph].glyphs
                [from.offset..to.offset]
                .iter()
                .map(|g| g.text)
                .collect();
            if !text.starts_with('/')
                || text[1..].contains(['/', '\n'])
                || text.chars().count() > 51
            {
                self.picker.open = false;
                return;
            }
            if self.picker.query != text[1..] {
                self.picker.query = text[1..].to_owned();
                self.picker.index = 0;
            }
        }
        let mut chosen = None;
        let mut open = true;
        let frame = egui::Frame::popup(&ctx.global_style())
            .fill(Color32::WHITE)
            .stroke(egui::Stroke::new(1.0, Color32::from_rgb(230, 229, 223)))
            .corner_radius(9);
        if self.picker.slash {
            let anchor = self.caret_anchor.unwrap_or(egui::pos2(250.0, 150.0));
            egui::Popup::new(
                Id::new("slash-picker"),
                ctx.clone(),
                egui::Rect::from_pos(anchor),
                egui::LayerId::background(),
            )
            .open_bool(&mut open)
            .width(280.0)
            .frame(frame)
            .show(|ui| {
                ui.horizontal(|ui| {
                    ui.weak("Insert or turn into");
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.weak("esc");
                    });
                });
                let commands = self.matching_commands();
                self.picker.index = self.picker.index.min(commands.len().saturating_sub(1));
                for (index, command) in commands.into_iter().enumerate() {
                    if command_row(ui, command, index == self.picker.index).clicked() {
                        chosen = Some(command);
                    }
                }
            });
        } else {
            let response = egui::Modal::new(Id::new("command-picker"))
                .backdrop_color(Color32::from_black_alpha(25))
                .frame(frame.inner_margin(20))
                .show(ctx, |ui| {
                    ui.set_width(420.0);
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new("Commands").font(egui::FontId::new(
                            25.0,
                            egui::FontFamily::Name("reading".into()),
                        )));
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui.button("×").clicked() {
                                open = false;
                            }
                        });
                    });
                    ui.add_space(12.0);
                    let response = ui.add(
                        egui::TextEdit::singleline(&mut self.picker.query)
                            .id(Id::new("command-query"))
                            .frame(egui::Frame::NONE)
                            .hint_text("Search commands…")
                            .desired_width(f32::INFINITY),
                    );
                    if self.picker.focus {
                        response.request_focus();
                        self.picker.focus = false;
                    }
                    if response.changed() {
                        self.picker.index = 0;
                    }
                    ui.add_space(8.0);
                    ui.separator();
                    ui.add_space(8.0);
                    let commands = self.matching_commands();
                    if ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::ArrowDown)) {
                        self.picker.index =
                            (self.picker.index + 1).min(commands.len().saturating_sub(1));
                    }
                    if ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::ArrowUp)) {
                        self.picker.index = self.picker.index.saturating_sub(1);
                    }
                    self.picker.index = self.picker.index.min(commands.len().saturating_sub(1));
                    if ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Enter)) {
                        chosen = commands.get(self.picker.index).copied();
                    }
                    egui::ScrollArea::vertical()
                        .max_height(420.0)
                        .show(ui, |ui| {
                            for (index, command) in commands.into_iter().enumerate() {
                                let response = command_row(ui, command, index == self.picker.index);
                                if index == self.picker.index {
                                    response.scroll_to_me(None);
                                }
                                if response.clicked() {
                                    chosen = Some(command);
                                }
                            }
                        });
                });
            if response.should_close() {
                open = false;
            }
        }
        if let Some(command) = chosen {
            if self.picker.slash {
                self.choose_slash(command, ctx);
            } else {
                self.picker.open = false;
                self.execute(command, ctx);
            }
        } else if !open {
            self.picker.open = false;
            self.slash_start = None;
            self.restore_editor_focus(ctx);
        }
    }
    fn shortcuts(&mut self, ctx: &egui::Context) {
        // AppKit normally handles accelerators. If it forwards a command
        // key to the content view, retain the same keyboard behavior here;
        // menu-dispatched keys were removed from this frame above.
        let consumed = |key, modifiers| {
            ctx.input_mut(|i| i.consume_shortcut(&KeyboardShortcut::new(modifiers, key)))
        };
        if consumed(Key::K, Modifiers::COMMAND) {
            self.picker.show(false);
        }
        if consumed(Key::O, Modifiers::COMMAND) {
            self.open();
        }
        if consumed(Key::N, Modifiers::COMMAND) {
            self.new_document();
        }
        if consumed(Key::S, Modifiers::COMMAND.plus(Modifiers::SHIFT)) {
            self.save(true);
        } else if consumed(Key::S, Modifiers::COMMAND) {
            self.save(false);
        }
        if consumed(Key::Z, Modifiers::COMMAND.plus(Modifiers::SHIFT)) {
            self.history(true);
        } else if consumed(Key::Z, Modifiers::COMMAND) {
            self.history(false);
        }
        for (key, mode) in [
            (Key::Num1, Mode::Write),
            (Key::Num2, Mode::Source),
            (Key::Num3, Mode::Preview),
        ] {
            if consumed(key, Modifiers::COMMAND) {
                self.switch_mode(mode, ctx);
            }
        }
    }
    fn export(&mut self) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("PDF", &["pdf"])
            .set_file_name("manuscript.pdf")
            .save_file()
        else {
            return;
        };
        if !self.pdf.is_empty() && self.preview_revision == Some(self.model.document.revision) {
            if let Err(e) = std::fs::write(path, &self.pdf) {
                self.error = Some(e.to_string());
            }
        } else {
            self.pending_export = Some(path);
            if !self.compiling || self.requested_revision != Some(self.model.document.revision) {
                self.compile(false);
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    fn toolbar(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        egui::MenuBar::new().ui(ui, |ui| {
            for (label, commands) in [
                (
                    "File",
                    &[
                        Command::New,
                        Command::Open,
                        Command::Save,
                        Command::SaveAs,
                        Command::Export,
                    ][..],
                ),
                (
                    "Edit",
                    &[Command::Undo, Command::Redo, Command::Palette][..],
                ),
                (
                    "Format",
                    &[
                        Command::Bold,
                        Command::Italic,
                        Command::Paragraph,
                        Command::Heading1,
                        Command::Heading2,
                        Command::Heading3,
                        Command::Bullet,
                        Command::Numbered,
                    ][..],
                ),
                (
                    "View",
                    &[
                        Command::Write,
                        Command::Source,
                        Command::Preview,
                        Command::Contents,
                        Command::Refresh,
                        Command::ZoomIn,
                        Command::ZoomOut,
                        Command::ActualSize,
                    ][..],
                ),
                ("Help", &[Command::Tutorial][..]),
            ] {
                ui.menu_button(label, |ui| {
                    for &command in commands {
                        if ui
                            .add_enabled(self.enabled(command), egui::Button::new(command.label()))
                            .clicked()
                        {
                            ui.close();
                            self.execute(command, ctx);
                        }
                    }
                });
            }
        });
    }
    fn finish_block_action(
        &mut self,
        result: Result<blank_document::Position, String>,
        ctx: &egui::Context,
    ) {
        match result {
            Ok(pos) => {
                self.editor.document_replaced();
                self.editor.select(Selection::caret(editor_position(pos)));
                self.restore_editor_focus(ctx);
            }
            Err(error) => self.error = Some(error),
        }
        self.block_menu = None;
        self.dragging_block = None;
    }
    fn block_picker(&mut self, ctx: &egui::Context) {
        let Some((index, anchor)) = self.block_menu else {
            return;
        };
        let mut open = true;
        let mut action = None;
        let mut close_menu = false;
        egui::Popup::new(
            Id::new("block-menu"),
            ctx.clone(),
            egui::Rect::from_pos(anchor),
            egui::LayerId::background(),
        )
        .open_bool(&mut open)
        .width(190.0)
        .kind(egui::PopupKind::Menu)
        .style(egui::containers::menu::menu_style)
        .frame(
            egui::Frame::popup(&ctx.global_style())
                .fill(Color32::WHITE)
                .corner_radius(9),
        )
        .show(|ui| {
            ui.set_width(190.0);
            ui.spacing_mut().interact_size.y = 30.0;
            ui.menu_button("Turn into…", |ui| {
                for command in [
                    Command::Paragraph,
                    Command::Heading1,
                    Command::Heading2,
                    Command::Heading3,
                    Command::Bullet,
                    Command::Numbered,
                ] {
                    if ui.button(command.label()).clicked() {
                        action = Some(command);
                        ui.close();
                    }
                }
            });
            if ui.button("Duplicate").clicked() {
                let result = self.model.document.duplicate_block(index);
                self.finish_block_action(result, ctx);
                close_menu = true;
            }
            if ui.button("Delete").clicked() {
                let result = self.model.document.delete_block(index);
                self.finish_block_action(result, ctx);
                close_menu = true;
            }
        });
        if let Some(command) = action {
            let pos = blank_document::Position::new(index, 0);
            let result = self
                .model
                .document
                .set_kind(pos, command.block().unwrap())
                .map(|()| pos);
            self.finish_block_action(result, ctx);
            open = false;
        }
        if !open || close_menu {
            self.block_menu = None;
        }
    }
    fn block_shortcuts(&mut self, ctx: &egui::Context) {
        if self.home || self.mode != Mode::Write || self.picker.open {
            return;
        }
        if let Some(selection) = self.editor.selection() {
            let from = selection.focus.paragraph;
            let target = if ctx.input_mut(|i| i.consume_key(Modifiers::ALT, Key::ArrowUp)) {
                from.checked_sub(1).map(|to| (to, false))
            } else if ctx.input_mut(|i| i.consume_key(Modifiers::ALT, Key::ArrowDown)) {
                (from + 1 < self.model.document.paragraphs.len()).then_some((from + 1, true))
            } else {
                None
            };
            if let Some((to, after)) = target {
                let result = self.model.document.move_block(from, to, after);
                self.finish_block_action(result, ctx);
            }
        }
    }
    fn writing(&mut self, ui: &mut egui::Ui) {
        let mut drop_target = None;
        #[cfg(test)]
        self.block_rects.clear();
        egui::ScrollArea::vertical()
            .id_salt("writing")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                self.editor.input(ui, &mut self.model);
                let width = (ui.available_width() - 48.0).clamp(100.0, 700.0);
                let margin = ((ui.available_width() - width) / 2.0).max(12.0);
                ui.horizontal(|ui| {
                    ui.add_space(margin);
                    ui.vertical(|ui| {
                        ui.set_width(width);
                        ui.add_space(48.0);
                        for block in self.model.document.blocks.clone() {
                            match block {
                                Block::Source { range, kind } => {
                                    let raw = self.model.document.text()[range.clone()].to_owned();
                                    ui.horizontal(|ui| {
                                        egui::CollapsingHeader::new(kind)
                                            .id_salt(range.start)
                                            .show(ui, |ui| {
                                                ui.monospace(raw);
                                            })
                                            .header_response
                                            .double_clicked()
                                            .then(|| {
                                                self.bookmark = range.start;
                                                self.mode = Mode::Source;
                                                self.source_focus = true;
                                                self.source_new_step = true;
                                            });
                                    });
                                    ui.add_space(8.0);
                                }
                                Block::Editable(index) => {
                                    let p = &self.model.document.paragraphs[index];
                                    if index > 0 && matches!(p.kind, BlockKind::Heading(_)) {
                                        ui.add_space(18.0);
                                    }
                                    let number = 1 + self.model.document.paragraphs[..index]
                                        .iter()
                                        .rev()
                                        .take_while(|p| matches!(p.kind, BlockKind::Numbered))
                                        .count();
                                    let job = typography::paragraph(
                                        p,
                                        width - 24.0,
                                        self.reading_faces,
                                        number,
                                    );
                                    let (job, map) = job.into_parts();
                                    let galley = ui.fonts_mut(|fonts| fonts.layout_job(job));
                                    let (rect, response) = ui.allocate_exact_size(
                                        vec2(width, galley.size().y),
                                        Sense::click_and_drag(),
                                    );
                                    if let Some(selection) = self.editor.selection()
                                        && selection.focus.paragraph == index
                                    {
                                        let cursor =
                                            egui::text::CCursor::new(egui::text::CharIndex(
                                                map.to_galley(
                                                    self.slash_start
                                                        .filter(|from| {
                                                            self.picker.open
                                                                && self.picker.slash
                                                                && from.paragraph == index
                                                        })
                                                        .map_or(selection.focus.offset, |from| {
                                                            from.offset
                                                        }),
                                                ),
                                            ));
                                        let caret = galley
                                            .pos_from_cursor(cursor)
                                            .translate(rect.min.to_vec2());
                                        self.caret_anchor =
                                            Some(caret.left_bottom() + vec2(0.0, 6.0));
                                    }
                                    self.editor.paragraph(
                                        ui,
                                        &response,
                                        &index,
                                        Laid {
                                            galley,
                                            map,
                                            origin: rect.min,
                                        },
                                    );
                                    let handle_rect = egui::Rect::from_min_size(
                                        rect.min - vec2(24.0, 0.0),
                                        vec2(20.0, 30.0),
                                    );
                                    #[cfg(test)]
                                    self.block_rects.push(rect);
                                    // Gutter controls must not participate in paragraph layout.
                                    // Including their rect in ui.put shifts the text column as
                                    // the handle appears, invalidating the drag hit target.
                                    let handle = ui.interact(
                                        handle_rect,
                                        Id::new(("block-handle", index)),
                                        Sense::click_and_drag(),
                                    );
                                    let hovering = ui.input(|i| {
                                        i.pointer.hover_pos().is_some_and(|pos| {
                                            rect.union(handle_rect).contains(pos)
                                        })
                                    });
                                    if hovering
                                        || self.dragging_block == Some(index)
                                        || self.block_menu.is_some_and(|(i, _)| i == index)
                                    {
                                        handle.widget_info(|| {
                                            egui::WidgetInfo::labeled(
                                                egui::WidgetType::Button,
                                                true,
                                                "Block commands",
                                            )
                                        });
                                        let center = handle_rect.center();
                                        for x in [-2.0, 2.0] {
                                            for y in [-4.0, 0.0, 4.0] {
                                                ui.painter().circle_filled(
                                                    center + vec2(x, y),
                                                    1.2,
                                                    Color32::from_rgb(147, 149, 141),
                                                );
                                            }
                                        }
                                    }
                                    if handle.drag_started() {
                                        self.dragging_block = Some(index);
                                        self.block_menu = None;
                                    }
                                    if handle.clicked() {
                                        self.block_menu = Some((index, handle_rect.left_bottom()));
                                    }
                                    if self.dragging_block.is_some() && hovering {
                                        let after = ui.input(|i| {
                                            i.pointer
                                                .hover_pos()
                                                .is_some_and(|pos| pos.y > rect.center().y)
                                        });
                                        let y = if after {
                                            rect.bottom() + 8.0
                                        } else {
                                            rect.top() - 8.0
                                        };
                                        ui.painter().line_segment(
                                            [
                                                egui::pos2(rect.left(), y),
                                                egui::pos2(rect.right(), y),
                                            ],
                                            egui::Stroke::new(
                                                2.0,
                                                Color32::from_rgb(134, 153, 124),
                                            ),
                                        );
                                        drop_target = Some((index, after));
                                    }
                                    ui.add_space(if matches!(p.kind, BlockKind::Heading(_)) {
                                        22.0
                                    } else {
                                        23.0
                                    });
                                }
                            }
                        }
                        ui.add_space(200.0);
                    });
                });
            });
        if ui.input(|i| i.pointer.any_released())
            && let Some(from) = self.dragging_block.take()
            && let Some((to, after)) = drop_target
        {
            let result = self.model.document.move_block(from, to, after);
            self.finish_block_action(result, ui.ctx());
        }
        if self.mode == Mode::Write
            && let Some(selection) = self.editor.selection()
        {
            self.bookmark = self
                .model
                .document
                .source_offset(position(&selection.focus));
        }
    }
    fn source(&mut self, ui: &mut egui::Ui) {
        let errors = self.model.document.errors();
        if !errors.is_empty() {
            ui.colored_label(
                Color32::from_rgb(150, 82, 32),
                format!(
                    "{} syntax issue(s) · incomplete source is kept",
                    errors.len()
                ),
            );
        }
        egui::ScrollArea::both()
            .id_salt("source-scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                let id = Id::new(SOURCE_ID);
                if self.source_focus {
                    {
                        let mut state =
                            egui::TextEdit::load_state(ui.ctx(), id).unwrap_or_default();
                        let byte = self.bookmark.min(self.source_buffer.len());
                        let char_index = self
                            .source_buffer
                            .char_indices()
                            .take_while(|(i, _)| *i < byte)
                            .count();
                        state
                            .cursor
                            .set_char_range(Some(egui::text::CCursorRange::one(
                                egui::text::CCursor::new(egui::text::CharIndex(char_index)),
                            )));
                        state.store(ui.ctx(), id);
                    }
                    ui.memory_mut(|m| m.request_focus(id));
                    self.source_focus = false;
                }
                let paired = if self.picker.open {
                    None
                } else {
                    source_editor::pairs(ui.ctx(), id, &self.source_buffer)
                };
                let available = ui.available_size();
                let cache = &mut self.source_layout;
                let mut layouter = |ui: &egui::Ui, text: &dyn egui::TextBuffer, width: f32| {
                    let text = text.as_str();
                    if cache.as_ref().is_none_or(|(previous, _)| previous != text) {
                        *cache = Some((text.to_owned(), source_editor::layout(text)));
                    }
                    let mut job = cache.as_ref().unwrap().1.clone();
                    job.wrap.max_width = width;
                    ui.fonts_mut(|fonts| fonts.layout_job(job))
                };
                let mut output = egui::TextEdit::multiline(&mut self.source_buffer)
                    .id(id)
                    .font(egui::TextStyle::Monospace)
                    .desired_width(f32::INFINITY)
                    .min_size(available)
                    .frame(egui::Frame::NONE.inner_margin(24))
                    .layouter(&mut layouter)
                    .code_editor()
                    .show(ui);
                if let Some(cursor) = paired {
                    output.state.cursor.set_char_range(Some(cursor));
                    output.state.clone().store(ui.ctx(), id);
                    output.cursor_range = Some(cursor);
                    ui.ctx().request_repaint();
                }
                if let Some(cursor) = output.cursor_range {
                    self.bookmark = self
                        .source_buffer
                        .char_indices()
                        .nth(cursor.primary.index.0)
                        .map_or(self.source_buffer.len(), |(i, _)| i);
                }
                if output.response.changed() {
                    let new_step =
                        self.source_new_step || self.last_edit.elapsed() > Duration::from_secs(1);
                    self.model
                        .document
                        .replace_source(&self.source_buffer, new_step);
                    self.source_new_step = false;
                    self.editor.document_replaced();
                }
            });
    }
    fn preview(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if self.compiling {
                ui.spinner();
                ui.label("Typesetting…");
            } else {
                ui.label(format!("{} page(s)", self.pages.len()));
            }
            if self.page_revision != Some(self.model.document.revision) && !self.pages.is_empty() {
                ui.weak("Last successful preview");
            }
        });
        for diagnostic in &self.diagnostics {
            ui.colored_label(Color32::from_rgb(150, 82, 32), diagnostic);
        }
        if self.pages.is_empty() && !self.compiling {
            ui.label("Preview will appear after a successful compile.");
        }
        let target_page = self
            .source_map
            .iter()
            .filter(|a| {
                a["start"]
                    .as_u64()
                    .is_some_and(|s| s as usize <= self.bookmark)
            })
            .max_by_key(|a| a["start"].as_u64())
            .and_then(|a| a["page"].as_u64())
            .unwrap_or(1) as usize;
        egui::ScrollArea::both()
            .id_salt("preview-scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                for (index, page) in self.pages.iter().enumerate() {
                    let width = 720.0 * self.zoom;
                    let height = width * page.size()[1] as f32 / page.size()[0] as f32;
                    let response = ui.add(
                        egui::Image::new(page)
                            .fit_to_exact_size(vec2(width, height))
                            .sense(Sense::click()),
                    );
                    if self.reveal_page && index + 1 == target_page {
                        response.scroll_to_me(Some(egui::Align::TOP));
                    }
                    if response.clicked()
                        && let Some(pointer) = response.interact_pointer_pos()
                    {
                        let y = (pointer.y - response.rect.top()) / response.rect.height();
                        if let Some(anchor) = self
                            .source_map
                            .iter()
                            .filter(|a| a["page"].as_u64() == Some(index as u64 + 1))
                            .min_by(|a, b| {
                                (a["y"].as_f64().unwrap_or(0.0) - y as f64)
                                    .abs()
                                    .total_cmp(&(b["y"].as_f64().unwrap_or(0.0) - y as f64).abs())
                            })
                        {
                            self.bookmark = anchor["start"].as_u64().unwrap_or(0) as usize;
                        }
                    }
                    ui.add_space(20.0);
                }
            });
        self.reveal_page = false;
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if ctx.input(|i| {
            i.events.iter().any(|event| {
                matches!(
                    event,
                    egui::Event::Key { .. }
                        | egui::Event::Text(_)
                        | egui::Event::Paste(_)
                        | egui::Event::PointerButton { .. }
                        | egui::Event::MouseWheel { .. }
                        | egui::Event::Ime(_)
                )
            })
        }) {
            self.last_input = Instant::now();
        }
        // Keep a visible caret, but stop redrawing the whole GPU surface for
        // its blink after four seconds without typing or selection changes.
        let blinking = self.last_input.elapsed() < Duration::from_secs(4);
        ui.style_mut().visuals.text_cursor.blink = blinking;
        ctx.global_style_mut(|style| style.visuals.text_cursor.blink = blinking);
        #[cfg(target_os = "macos")]
        if let Some(mut menus) = self.menus.take() {
            let commands: Vec<_> = menus.rx.try_iter().collect();
            if !commands.is_empty() {
                // AppKit may also forward the accelerator's key event to winit.
                ctx.input_mut(|i| {
                    i.events.retain(
                        |e| !matches!(e, egui::Event::Key { modifiers, .. } if modifiers.command),
                    )
                });
            }
            for command in commands {
                self.execute(command, &ctx);
            }
            menus.sync(|command| self.enabled(command));
            self.menus = Some(menus);
        }
        if self.restore_focus {
            self.restore_focus = false;
            if !self.home && self.mode != Mode::Preview {
                ctx.memory_mut(|m| {
                    m.request_focus(Id::new(if self.mode == Mode::Write {
                        "writer"
                    } else {
                        SOURCE_ID
                    }))
                });
            }
        }
        self.shortcuts(&ctx);
        self.block_shortcuts(&ctx);
        self.slash_trigger(&ctx);
        if self.picker.focus && !self.picker.slash {
            ctx.memory_mut(|m| m.request_focus(Id::new("command-query")));
        }
        if !self.pending_events.is_empty() {
            ctx.input_mut(|i| i.events.append(&mut self.pending_events));
        }
        self.poll_compile(&ctx);
        if ctx.input(|i| i.viewport().close_requested()) && self.dirty() {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.confirm_close = true;
        }
        if self.confirm_close {
            egui::Window::new("Save your writing?")
                .collapsible(false)
                .resizable(false)
                .show(&ctx, |ui| {
                    ui.label("This document has unsaved changes.");
                    ui.horizontal(|ui| {
                        if ui.button("Save and close").clicked() && self.save(false) {
                            self.confirm_close = false;
                            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                        }
                        if ui.button("Discard and close").clicked() {
                            self.disk_text = self.model.document.text().to_owned();
                            self.confirm_close = false;
                            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                        }
                        if ui.button("Keep writing").clicked() {
                            self.confirm_close = false;
                        }
                    });
                });
        }
        if let Some(error) = self.model.error.take() {
            self.error = Some(error);
        }
        #[cfg(not(target_os = "macos"))]
        egui::Panel::top("toolbar").show(ui, |ui| self.toolbar(ui, &ctx));
        if let Some(error) = self.error.clone() {
            egui::Panel::top("errors").show(ui, |ui| {
                ui.horizontal_wrapped(|ui| {
                    ui.colored_label(Color32::from_rgb(150, 60, 32), error);
                    if ui.small_button("Dismiss").clicked() {
                        self.error = None;
                    }
                });
            });
        }
        egui::Panel::bottom("status")
            .show_separator_line(false)
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.weak(format!(
                        "{} words",
                        self.model
                            .document
                            .paragraphs
                            .iter()
                            .map(|p| p.text().split_whitespace().count())
                            .sum::<usize>()
                    ));
                    if self.path.is_some() && self.dirty() {
                        ui.weak(if self.conflict {
                            "Disk conflict · Save As"
                        } else {
                            "Saving…"
                        });
                    } else if self.path.is_none() {
                        ui.weak("Unsaved document");
                    } else {
                        ui.weak("Saved");
                    }
                });
            });
        if self.contents && !self.home {
            egui::Panel::left("contents")
                .show_separator_line(false)
                .default_size(200.0)
                .frame(
                    egui::Frame::NONE
                        .fill(Color32::WHITE)
                        .inner_margin(egui::Margin::symmetric(20, 28)),
                )
                .show(ui, |ui| {
                    ui.add_space(18.0);
                    let headings: Vec<_> = self
                        .model
                        .document
                        .paragraphs
                        .iter()
                        .enumerate()
                        .filter(|(i, p)| {
                            matches!(p.kind, BlockKind::Heading(_))
                                && !(*i == 0 && p.text() == "Tutorial")
                        })
                        .map(|(i, p)| (i, p.text(), p.range.start))
                        .collect();
                    let active = headings
                        .iter()
                        .rfind(|(_, _, byte)| *byte <= self.bookmark)
                        .map(|(i, _, _)| *i)
                        .or_else(|| headings.first().map(|(i, _, _)| *i));
                    for (i, text, byte) in headings {
                        let label =
                            egui::RichText::new(text)
                                .size(12.0)
                                .color(if active == Some(i) {
                                    Color32::from_rgb(52, 58, 55)
                                } else {
                                    Color32::from_rgb(147, 149, 141)
                                });
                        if ui.add(egui::Button::new(label).frame(false)).clicked() {
                            self.bookmark = byte;
                            match self.mode {
                                Mode::Write => self
                                    .editor
                                    .select(Selection::caret(egui_richedit::Position::new(i, 0))),
                                Mode::Source => self.source_focus = true,
                                Mode::Preview => self.reveal_page = true,
                            }
                        }
                        ui.add_space(10.0);
                    }
                });
        }
        egui::CentralPanel::default()
            .frame(egui::Frame::central_panel(ui.style()).inner_margin(0))
            .show(ui, |ui| {
                if self.home {
                    ui.vertical_centered(|ui| {
                        ui.add_space(110.0);
                        ui.heading("A quiet place to write.");
                        ui.add_space(20.0);
                        #[cfg(target_os = "macos")]
                        ui.weak("⌘N to start · ⌘O to open · ⌘K for commands");
                        #[cfg(not(target_os = "macos"))]
                        if ui.button("New document").clicked() {
                            self.new_document();
                        }
                        #[cfg(not(target_os = "macos"))]
                        if ui.button("Open Typst document…").clicked() {
                            self.open();
                        }
                        #[cfg(not(target_os = "macos"))]
                        if ui.button("Tutorial").clicked() {
                            self.load(DEMO.into(), None);
                        }
                    });
                } else {
                    match self.mode {
                        Mode::Write => self.writing(ui),
                        Mode::Source => self.source(ui),
                        Mode::Preview => self.preview(ui),
                    }
                }
            });
        self.block_picker(&ctx);
        self.command_picker(&ctx);
        self.changed();
        if !self.home && self.last_edit.elapsed() >= Duration::from_millis(650) {
            if self.mode == Mode::Preview
                && self.requested_revision != Some(self.model.document.revision)
            {
                self.compile(true);
            }
            if self.path.is_some() && self.dirty() && !self.conflict {
                self.save(false);
            }
        }
        if !self.home && self.last_edit.elapsed() < Duration::from_millis(650) {
            ctx.request_repaint_after(
                Duration::from_millis(650)
                    - self.last_edit.elapsed().min(Duration::from_millis(650)),
            );
        }
        let title = format!(
            "{}{} — blank_",
            self.path
                .as_ref()
                .and_then(|p| p.file_name())
                .and_then(|s| s.to_str())
                .unwrap_or(if self.disk_text == DEMO {
                    "Tutorial.typ"
                } else {
                    "Untitled"
                }),
            if self.dirty() { " •" } else { "" }
        );
        // Cocoa's setTitle can produce a window event. Sending it on every
        // frame feeds that event back into another repaint, even while idle.
        if title != self.window_title {
            self.window_title = title.clone();
            ctx.send_viewport_cmd(egui::ViewportCommand::Title(title));
        }
        if self.screenshot.is_some() && (self.mode != Mode::Preview || !self.pages.is_empty()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::UserData::default()));
        }
        let screenshots: Vec<_> = ctx.input(|i| {
            i.events
                .iter()
                .filter_map(|e| {
                    if let egui::Event::Screenshot { image, .. } = e {
                        Some(image.clone())
                    } else {
                        None
                    }
                })
                .collect()
        });
        if let Some(image) = screenshots.first()
            && let Some(path) = self.screenshot.take()
        {
            let bytes: Vec<u8> = image.pixels.iter().flat_map(|c| c.to_array()).collect();
            if let Err(e) = image::save_buffer_with_format(
                path,
                &bytes,
                image.width() as u32,
                image.height() as u32,
                image::ColorType::Rgba8,
                image::ImageFormat::Png,
            ) {
                self.error = Some(e.to_string());
            } else {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
    }
}

fn command_row(ui: &mut egui::Ui, command: Command, selected: bool) -> egui::Response {
    let (symbol, hint) = match command {
        Command::Paragraph => ("¶", "Plain text"),
        Command::Heading1 => ("H₁", "Chapter title"),
        Command::Heading2 => ("H₂", "Section"),
        Command::Heading3 => ("H₃", "Subsection"),
        Command::Bullet => ("•", "Unordered items"),
        Command::Numbered => ("1.", "Ordered items"),
        _ => ("", ""),
    };
    let fill = if selected {
        Color32::from_rgb(234, 236, 229)
    } else {
        Color32::TRANSPARENT
    };
    let response = egui::Frame::NONE
        .fill(fill)
        .corner_radius(5)
        .inner_margin(8)
        .show(ui, |ui| {
            ui.set_min_width(ui.available_width());
            ui.horizontal(|ui| {
                if !symbol.is_empty() {
                    ui.add_sized(
                        [30.0, 26.0],
                        egui::Label::new(
                            egui::RichText::new(symbol)
                                .size(17.0)
                                .color(Color32::from_rgb(147, 149, 141)),
                        ),
                    );
                }
                ui.vertical(|ui| {
                    ui.label(command.label());
                    if !hint.is_empty() {
                        ui.label(
                            egui::RichText::new(hint)
                                .size(11.0)
                                .color(Color32::from_rgb(147, 149, 141)),
                        );
                    }
                });
            });
        })
        .response;
    let response = ui.interact(response.rect, response.id.with("command"), Sense::click());
    response
        .widget_info(|| egui::WidgetInfo::labeled(egui::WidgetType::Button, true, command.label()));
    response
}

fn main() -> eframe::Result {
    eframe::run_native(
        "blank_",
        eframe::NativeOptions {
            viewport: egui::ViewportBuilder::default()
                .with_inner_size([1100.0, 800.0])
                .with_min_inner_size([680.0, 480.0]),
            ..Default::default()
        },
        Box::new(|cc| Ok(Box::new(App::new(cc)))),
    )
}

#[cfg(test)]
mod app_tests {
    use super::*;
    fn setup(text: &str) -> (egui::Context, App) {
        let ctx = egui::Context::default();
        ctx.enable_accesskit();
        let mut app = App::new(&eframe::CreationContext::_new_kittest(ctx.clone()));
        app.load(text.into(), None);
        (ctx, app)
    }
    fn frame(ctx: &egui::Context, app: &mut App, events: Vec<egui::Event>) -> egui::FullOutput {
        let mut output = ctx.run_ui(
            egui::RawInput {
                events,
                ..Default::default()
            },
            |ui| {
                eframe::App::ui(app, ui, &mut eframe::Frame::_new_kittest());
            },
        );
        output.textures_delta.clear();
        if let Some(update) = &output.platform_output.accesskit_update {
            assert!(
                update.nodes.iter().any(|(id, _)| *id == update.focus),
                "accessibility focus must refer to a node in the rendered tree"
            );
        }
        output
    }
    fn key(key: Key) -> egui::Event {
        egui::Event::Key {
            key,
            physical_key: None,
            pressed: true,
            repeat: false,
            modifiers: Modifiers::NONE,
        }
    }
    #[test]
    fn idle_frames_do_not_repeat_native_title_or_compile_while_writing() {
        let (ctx, mut app) = setup("Hello");
        let first = frame(&ctx, &mut app, vec![]);
        assert!(first.viewport_output.values().any(|o| {
            o.commands
                .iter()
                .any(|c| matches!(c, egui::ViewportCommand::Title(_)))
        }));
        for _ in 0..4 {
            let next = frame(&ctx, &mut app, vec![]);
            assert!(!next.viewport_output.values().any(|o| {
                o.commands
                    .iter()
                    .any(|c| matches!(c, egui::ViewportCommand::Title(_)))
            }));
            assert_eq!(app.requested_revision, None);
        }
    }
    #[test]
    fn tutorial_opens_from_palette_and_draws_the_sidebar() {
        let (ctx, mut app) = setup("");
        app.home = true;
        frame(&ctx, &mut app, vec![]);
        app.execute(Command::Palette, &ctx);
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![egui::Event::Text("tutorial".into())]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![]);
        assert_eq!(app.model.document.text(), DEMO);
        assert!(app.contents);
        app.execute(Command::Palette, &ctx);
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![egui::Event::Text("source".into())]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![]);
        assert!(app.mode == Mode::Source);
    }
    #[test]
    fn idle_caret_stops_blinking_and_typing_restarts_it() {
        let (ctx, mut app) = setup("Hello");
        app.last_input = Instant::now() - Duration::from_secs(10);
        frame(&ctx, &mut app, vec![]);
        assert!(!ctx.global_style().visuals.text_cursor.blink);
        frame(&ctx, &mut app, vec![egui::Event::Text("a".into())]);
        assert!(ctx.global_style().visuals.text_cursor.blink);
    }
    #[test]
    fn leaving_preview_releases_page_textures() {
        let (ctx, mut app) = setup("Hello");
        app.mode = Mode::Preview;
        app.pages.push(ctx.load_texture(
            "test-page",
            egui::ColorImage::new([1, 1], vec![Color32::WHITE]),
            Default::default(),
        ));
        app.page_revision = Some(0);
        app.switch_mode(Mode::Write, &ctx);
        assert!(app.pages.is_empty());
        assert_eq!(app.page_revision, None);
        assert_eq!(app.requested_revision, None);
    }
    #[test]
    fn palette_and_slash_execute_the_shared_block_commands() {
        let (ctx, mut app) = setup("Hello");
        frame(&ctx, &mut app, vec![]);
        app.execute(Command::Palette, &ctx);
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![egui::Event::Text("Heading 3".into())]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        assert!(!app.picker.open);
        assert_eq!(app.model.document.text(), "=== Hello");
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![egui::Event::Text("/".into())]);
        assert!(app.picker.open && app.picker.slash);
        frame(&ctx, &mut app, vec![egui::Event::Text("number".into())]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        assert_eq!(app.model.document.text(), "+ Hello");
        assert!(!app.picker.open);
        app.history(false);
        assert_eq!(app.model.document.text(), "=== Hello");
    }
    #[test]
    fn dismissing_slash_keeps_a_literal_slash_and_search_does_not_edit_source() {
        let (ctx, mut app) = setup("Hello");
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![egui::Event::Text("/".into())]);
        frame(&ctx, &mut app, vec![key(Key::Escape)]);
        assert_eq!(app.model.document.paragraphs[0].text(), "/Hello");
        app.switch_mode(Mode::Source, &ctx);
        frame(&ctx, &mut app, vec![]);
        app.execute(Command::Palette, &ctx);
        frame(&ctx, &mut app, vec![egui::Event::Text("preview".into())]);
        assert_eq!(app.model.document.paragraphs[0].text(), "/Hello");
        assert_eq!(app.picker.query, "preview");
    }
    #[test]
    fn typing_return_repeated_return_and_join_keep_caret_and_following_blocks() {
        let (ctx, mut app) = setup("First\n\nLast");
        app.editor
            .select(Selection::caret(egui_richedit::Position::new(0, 5)));
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![egui::Event::Text("Middle ".into())]);
        frame(&ctx, &mut app, vec![egui::Event::Text("words".into())]);
        assert_eq!(
            app.model
                .document
                .paragraphs
                .iter()
                .map(|p| p.text())
                .collect::<Vec<_>>(),
            ["First", "Middle words", "Last"]
        );
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![egui::Event::Text("Again".into())]);
        assert_eq!(
            app.model
                .document
                .paragraphs
                .iter()
                .map(|p| p.text())
                .collect::<Vec<_>>(),
            ["First", "Middle words", "", "Again", "Last"]
        );
        app.editor
            .select(Selection::caret(egui_richedit::Position::new(3, 0)));
        frame(&ctx, &mut app, vec![key(Key::Backspace)]);
        assert_eq!(
            app.model
                .document
                .paragraphs
                .iter()
                .map(|p| p.text())
                .collect::<Vec<_>>(),
            ["First", "Middle words", "Again", "Last"]
        );
        assert!(app.model.error.is_none());
    }
    #[test]
    fn real_return_continues_list_and_empty_return_exits() {
        let (ctx, mut app) = setup("- One\n\nAfter");
        app.editor
            .select(Selection::caret(egui_richedit::Position::new(0, 3)));
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![egui::Event::Text("Two".into())]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        frame(&ctx, &mut app, vec![egui::Event::Text("Outside".into())]);
        let ps = &app.model.document.paragraphs;
        assert_eq!(
            ps.iter().map(|p| p.text()).collect::<Vec<_>>(),
            ["One", "Two", "Outside", "After"]
        );
        assert_eq!(ps[1].kind, BlockKind::Bullet);
        assert_eq!(ps[2].kind, BlockKind::Paragraph);
    }
    #[test]
    fn typing_shortcuts_transform_blocks_and_inline_marks() {
        let (ctx, mut app) = setup("");
        frame(&ctx, &mut app, vec![]);
        for text in ["=", " ", "Title"] {
            frame(&ctx, &mut app, vec![egui::Event::Text(text.into())]);
        }
        assert_eq!(app.model.document.text(), "= Title");
        frame(&ctx, &mut app, vec![key(Key::Enter)]);
        for text in ["*", "bold", "*", " ", "_", "italic", "_"] {
            frame(&ctx, &mut app, vec![egui::Event::Text(text.into())]);
        }
        assert_eq!(app.model.document.paragraphs[1].text(), "bold italic");
        assert!(
            app.model.document.paragraphs[1].glyphs[..4]
                .iter()
                .all(|g| g.bold)
        );
        assert!(
            app.model.document.paragraphs[1].glyphs[5..]
                .iter()
                .all(|g| g.italic)
        );
        assert!(app.model.document.errors().is_empty());
    }
    #[test]
    fn option_arrows_move_a_block_and_share_document_undo() {
        let (ctx, mut app) = setup("First\n\nSecond");
        app.editor
            .select(Selection::caret(egui_richedit::Position::new(1, 0)));
        frame(&ctx, &mut app, vec![]);
        let mut event = key(Key::ArrowUp);
        if let egui::Event::Key { modifiers, .. } = &mut event {
            *modifiers = Modifiers::ALT;
        }
        frame(&ctx, &mut app, vec![event]);
        assert_eq!(app.model.document.paragraphs[0].text(), "Second");
        app.history(false);
        assert_eq!(app.model.document.text(), "First\n\nSecond");
    }
    #[test]
    fn source_copy_keeps_plain_typst_across_heading_sizes_and_nested_marks() {
        let text = "// note\n= Héading\n\n*bold _nested_* and #strong[call]\n";
        let (ctx, mut app) = setup(text);
        app.switch_mode(Mode::Source, &ctx);
        frame(&ctx, &mut app, vec![]);
        let from = text.find('H').unwrap();
        let to = text.find(" and").unwrap();
        let start = text[..from].chars().count();
        let end = text[..to].chars().count();
        let id = Id::new(SOURCE_ID);
        let mut state = egui::TextEdit::load_state(&ctx, id).unwrap();
        state
            .cursor
            .set_char_range(Some(egui::text::CCursorRange::two(
                egui::text::CCursor::new(egui::text::CharIndex(start)),
                egui::text::CCursor::new(egui::text::CharIndex(end)),
            )));
        state.store(&ctx, id);
        let output = frame(&ctx, &mut app, vec![egui::Event::Copy]);
        assert!(output.platform_output.commands.iter().any(|command| {
            matches!(command, egui::OutputCommand::CopyText(copied) if copied == &text[from..to])
        }));
        assert_eq!(app.model.document.text(), text);

        frame(
            &ctx,
            &mut app,
            vec![egui::Event::Text("Replacement".into())],
        );
        assert_eq!(
            app.model.document.text(),
            format!("{}Replacement{}", &text[..from], &text[to..])
        );
        app.history(false);
        assert_eq!(app.model.document.text(), text);
    }

    #[test]
    fn source_pair_insertion_skip_and_backspace_use_shared_history() {
        let (ctx, mut app) = setup("#let x = ");
        app.mode = Mode::Source;
        app.bookmark = app.source_buffer.len();
        frame(&ctx, &mut app, vec![]);
        frame(&ctx, &mut app, vec![egui::Event::Text("(".into())]);
        assert_eq!(app.model.document.text(), "#let x = ()");
        frame(&ctx, &mut app, vec![key(Key::Backspace)]);
        assert_eq!(app.model.document.text(), "#let x = ");
        frame(&ctx, &mut app, vec![egui::Event::Text("[".into())]);
        frame(&ctx, &mut app, vec![egui::Event::Text("]".into())]);
        assert_eq!(app.model.document.text(), "#let x = []");
        let state = egui::TextEdit::load_state(&ctx, Id::new(SOURCE_ID)).unwrap();
        assert_eq!(state.cursor.char_range().unwrap().primary.index.0, 11);
        app.history(false);
        assert_eq!(app.model.document.text(), "#let x = ");
    }
    #[test]
    fn character_by_character_heading_and_list_typing_preserves_spaces() {
        for source in ["= \n\nFollowing", "- \n\nFollowing", "+ \n\nFollowing"] {
            let (ctx, mut app) = setup(source);
            frame(&ctx, &mut app, vec![]);
            for c in "A new heading".chars() {
                frame(&ctx, &mut app, vec![egui::Event::Text(c.to_string())]);
            }
            assert_eq!(
                app.model.document.paragraphs[0].text(),
                "A new heading",
                "{source:?}"
            );
            assert_eq!(app.model.document.paragraphs[1].text(), "Following");
            let mut event = key(Key::Z);
            if let egui::Event::Key { modifiers, .. } = &mut event {
                *modifiers = Modifiers::COMMAND;
            }
            frame(&ctx, &mut app, vec![event]);
            assert_eq!(app.model.document.text(), source);
        }
    }
    #[test]
    fn pointer_drag_moves_block_without_shifting_the_text_column() {
        let (ctx, mut app) = setup("First\n\nSecond\n\nThird");
        frame(&ctx, &mut app, vec![]);
        let original = app.block_rects.clone();
        let handle = original[1].left_top() + vec2(-14.0, 15.0);
        frame(&ctx, &mut app, vec![egui::Event::PointerMoved(handle)]);
        assert_eq!(
            app.block_rects, original,
            "hover handles must not change paragraph layout"
        );
        frame(
            &ctx,
            &mut app,
            vec![egui::Event::PointerButton {
                pos: handle,
                button: egui::PointerButton::Primary,
                pressed: true,
                modifiers: Modifiers::NONE,
            }],
        );
        let destination = original[0].left_top() + vec2(10.0, 2.0);
        frame(&ctx, &mut app, vec![egui::Event::PointerMoved(destination)]);
        assert_eq!(app.dragging_block, Some(1));
        frame(
            &ctx,
            &mut app,
            vec![egui::Event::PointerButton {
                pos: destination,
                button: egui::PointerButton::Primary,
                pressed: false,
                modifiers: Modifiers::NONE,
            }],
        );
        assert_eq!(
            app.model
                .document
                .paragraphs
                .iter()
                .map(|p| p.text())
                .collect::<Vec<_>>(),
            ["Second", "First", "Third"]
        );
        app.history(false);
        assert_eq!(app.model.document.text(), "First\n\nSecond\n\nThird");
    }
}
