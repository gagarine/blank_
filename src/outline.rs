use blank_document::{BlockKind, Document};
use eframe::egui::{self, Color32};

struct Heading {
    paragraph: usize,
    title: String,
    byte: usize,
    level: usize,
}

pub fn show(ui: &mut egui::Ui, document: &Document, bookmark: usize) -> Option<(usize, usize)> {
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
    egui::ScrollArea::vertical()
        .id_salt("outline")
        .show(ui, |ui| {
            branches(ui, &headings, active, &mut selected);
        });
    selected
}

fn label(
    ui: &mut egui::Ui,
    heading: &Heading,
    active: Option<usize>,
    selected: &mut Option<(usize, usize)>,
) {
    let mut text = egui::RichText::new(&heading.title).size(12.0);
    if active == Some(heading.paragraph) {
        text = text.strong().color(Color32::from_rgb(52, 58, 55));
    } else {
        text = text.color(Color32::from_rgb(147, 149, 141));
    }
    if ui
        .add_sized(
            [ui.available_width(), 28.0],
            egui::Button::new(text)
                .frame(false)
                .truncate()
                .right_text(""),
        )
        .on_hover_text(&heading.title)
        .clicked()
    {
        *selected = Some((heading.paragraph, heading.byte));
    }
}

fn branches(
    ui: &mut egui::Ui,
    headings: &[Heading],
    active: Option<usize>,
    selected: &mut Option<(usize, usize)>,
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
                .show_header(ui, |ui| label(ui, heading, active, selected))
                .body(|ui| branches(ui, &headings[index + 1..end], active, selected));
        } else {
            ui.horizontal(|ui| {
                ui.add_space(ui.spacing().indent);
                label(ui, heading, active, selected);
            });
        }
        index = end;
    }
}
