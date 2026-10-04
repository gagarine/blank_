//! Each document owns its editor, history, recovery journal and compiler.
use crate::{App, confirmation};
use eframe::egui::{self, ViewportId};
pub struct Desktop {
    root: App,
    children: Vec<(ViewportId, App)>,
    next_id: u64,
    reading_faces: bool,
}
impl Desktop {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let root = App::new(cc);
        Self {
            reading_faces: root.reading_faces,
            root,
            children: vec![],
            next_id: 1,
        }
    }
}
impl eframe::App for Desktop {
    fn ui(&mut self, ui: &mut egui::Ui, frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if self.root.closed && self.children.is_empty() {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            return;
        }
        self.root.ui(ui, frame);
        let mut requests = std::mem::take(&mut self.root.windows);
        for (id, child) in &mut self.children {
            ctx.show_viewport_immediate(
                *id,
                egui::ViewportBuilder::default()
                    .with_title(&child.window_title)
                    .with_inner_size([1100.0, 800.0])
                    .with_min_inner_size([680.0, 480.0]),
                |ui, _| {
                    ui.push_id(*id, |ui| child.ui(ui, frame));
                },
            );
            requests.append(&mut child.windows);
        }
        if self.root.quit || self.children.iter().any(|(_, child)| child.quit) {
            self.root.quit = false;
            for (_, child) in &mut self.children {
                child.quit = false;
            }
            if self.root.protect_unsaved()
                && self
                    .children
                    .iter_mut()
                    .all(|(_, child)| child.closed || child.protect_unsaved())
            {
                self.root.storage.clear();
                for (_, child) in &self.children {
                    child.storage.clear();
                }
                self.children.clear();
                ctx.send_viewport_cmd_to(ViewportId::ROOT, egui::ViewportCommand::Close);
                self.root.closed = true;
            }
        }
        self.children.retain(|(_, child)| !child.closed);
        if self.root.closed {
            if let Some((_, mut next)) = self.children.pop() {
                next.confirmation = self.root.confirmation.clone();
                next.file_dialog = self.root.file_dialog.clone();
                next.scrollbar = std::mem::take(&mut self.root.scrollbar);
                next.window_title.clear();
                next.restore_focus = true;
                self.root = next;
                ctx.request_repaint();
            } else {
                ctx.send_viewport_cmd_to(ViewportId::ROOT, egui::ViewportCommand::Close);
            }
        }
        for (text, path) in requests {
            let mut child = App::empty(
                &ctx,
                self.reading_faces,
                confirmation::Confirmation::active_window(),
                rfd::FileDialog::new(),
            );
            child.load(text, path);
            #[cfg(target_os = "macos")]
            {
                child.menus = self.root.menus.clone();
            }
            self.children
                .push((ViewportId::from_hash_of(("document", self.next_id)), child));
            self.next_id += 1;
            ctx.request_repaint();
        }
    }
}
