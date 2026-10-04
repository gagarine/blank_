use blank_document::{BlockKind, Document};
use eframe::egui::{self, Color32};

struct Heading {
    paragraph: usize,
    title: String,
    byte: usize,
    level: usize,
}
pub enum Action {
    Jump(usize, usize),
    Move(usize, usize, bool),
}

pub fn show(ui: &mut egui::Ui, document: &Document, bookmark: usize) -> Option<Action> {
    let headings: Vec<_> = document
        .paragraphs
        .iter()
        .enumerate()
        .filter_map(|(paragraph, p)| {
            let BlockKind::Heading(level) = p.kind else {
                return None;
            };
            Some(Heading {
                paragraph,
                title: p.text(),
                byte: p.range.start,
                level,
            })
        })
        .collect();
    let active = headings
        .iter()
        .rfind(|h| h.byte <= bookmark)
        .or_else(|| headings.first())
        .map(|h| h.paragraph);
    let mut selected = None;
    let mut rows = vec![];
    egui::ScrollArea::vertical()
        .id_salt("outline")
        .show(ui, |ui| {
            branches(ui, &headings, active, &mut selected, &mut rows);
        });
    let id = egui::Id::new(("outline-drag", ui.ctx().viewport_id()));
    let dragged = ui.data(|data| data.get_temp::<usize>(id));
    if let Some(from) = dragged
        && let Some(pointer) = ui.input(|input| input.pointer.hover_pos())
    {
        ui.ctx().set_cursor_icon(egui::CursorIcon::Grabbing);
        if let Some(&(to, rect)) =
            rows.iter()
                .filter(|(index, _)| *index != from)
                .min_by(|(_, a), (_, b)| {
                    a.center()
                        .distance(pointer)
                        .total_cmp(&b.center().distance(pointer))
                })
        {
            let after = pointer.y > rect.center().y;
            let y = if after { rect.bottom() } else { rect.top() };
            ui.painter().line_segment(
                [egui::pos2(rect.left(), y), egui::pos2(rect.right(), y)],
                egui::Stroke::new(2.0, ui.visuals().selection.bg_fill),
            );
            if ui.input(|input| input.pointer.any_released()) {
                selected = Some(Action::Move(from, to, after));
            }
        }
        if ui.input(|input| input.pointer.any_released()) {
            ui.data_mut(|data| data.remove::<usize>(id));
        }
    }
    selected
}

fn label(
    ui: &mut egui::Ui,
    heading: &Heading,
    active: Option<usize>,
    selected: &mut Option<Action>,
    rows: &mut Vec<(usize, egui::Rect)>,
) {
    let mut text = egui::RichText::new(&heading.title).size(12.0);
    if active == Some(heading.paragraph) {
        text = text.strong().color(Color32::from_rgb(52, 58, 55));
    } else {
        text = text.color(Color32::from_rgb(147, 149, 141));
    }
    let response = ui
        .add_sized(
            [ui.available_width(), 28.0],
            egui::Button::new(text)
                .frame(false)
                .truncate()
                .sense(egui::Sense::click_and_drag())
                .right_text(""),
        )
        .on_hover_text(&heading.title);
    rows.push((heading.paragraph, response.rect));
    if response.drag_started() {
        let id = egui::Id::new(("outline-drag", ui.ctx().viewport_id()));
        ui.data_mut(|data| data.insert_temp(id, heading.paragraph));
    }
    if response.clicked() {
        *selected = Some(Action::Jump(heading.paragraph, heading.byte));
    }
}

fn branches(
    ui: &mut egui::Ui,
    headings: &[Heading],
    active: Option<usize>,
    selected: &mut Option<Action>,
    rows: &mut Vec<(usize, egui::Rect)>,
) {
    let mut index = 0;
    while index < headings.len() {
        let heading = &headings[index];
        let end = (index + 1..headings.len())
            .find(|&next| headings[next].level <= heading.level)
            .unwrap_or(headings.len());
        // The parent UI's ID gives repeated titles in different chapters separate state.
        let occurrence = headings[..index]
            .iter()
            .filter(|h| h.title == heading.title && h.level == heading.level)
            .count();
        let id = ui.make_persistent_id((&heading.title, heading.level, occurrence));
        if end > index + 1 {
            egui::collapsing_header::CollapsingState::load_with_default_open(ui.ctx(), id, true)
                .show_header(ui, |ui| label(ui, heading, active, selected, rows))
                .body(|ui| branches(ui, &headings[index + 1..end], active, selected, rows));
        } else {
            ui.horizontal(|ui| {
                ui.add_space(ui.spacing().indent);
                label(ui, heading, active, selected, rows);
            });
        }
        index = end;
    }
}
