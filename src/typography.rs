use blank_document::{BlockKind, Paragraph};
use eframe::egui::{self, Color32, FontId, TextFormat, text::LayoutJob};
use egui_richedit::ParagraphJob;
use std::sync::OnceLock;

// All faces in a collection share its immutable bytes, across editor contexts.
static READING_COLLECTION: OnceLock<Option<Vec<u8>>> = OnceLock::new();
static SOURCE_COLLECTION: OnceLock<Option<Vec<u8>>> = OnceLock::new();

pub fn install(ctx: &egui::Context) -> bool {
    let mut fonts = egui::FontDefinitions::default();
    let names = [
        "reading",
        "reading-bold",
        "reading-italic",
        "reading-bold-italic",
    ];
    let faces = if let Some(bytes) = READING_COLLECTION.get_or_init(|| {
        std::fs::read("/System/Library/Fonts/Supplemental/Iowan Old Style.ttc").ok()
    }) {
        Some(
            (0..4)
                .map(|index| {
                    let mut data = egui::FontData::from_static(bytes);
                    data.index = index;
                    data
                })
                .collect::<Vec<_>>(),
        )
    } else {
        [
            [
                "/System/Library/Fonts/Supplemental/Georgia.ttf",
                "/System/Library/Fonts/Supplemental/Georgia Bold.ttf",
                "/System/Library/Fonts/Supplemental/Georgia Italic.ttf",
                "/System/Library/Fonts/Supplemental/Georgia Bold Italic.ttf",
            ],
            [
                "C:/Windows/Fonts/georgia.ttf",
                "C:/Windows/Fonts/georgiab.ttf",
                "C:/Windows/Fonts/georgiai.ttf",
                "C:/Windows/Fonts/georgiaz.ttf",
            ],
            [
                "/usr/share/fonts/truetype/liberation2/LiberationSerif-Regular.ttf",
                "/usr/share/fonts/truetype/liberation2/LiberationSerif-Bold.ttf",
                "/usr/share/fonts/truetype/liberation2/LiberationSerif-Italic.ttf",
                "/usr/share/fonts/truetype/liberation2/LiberationSerif-BoldItalic.ttf",
            ],
        ]
        .iter()
        .find_map(|paths| {
            paths
                .iter()
                .map(|path| std::fs::read(path).map(egui::FontData::from_owned))
                .collect::<Result<Vec<_>, _>>()
                .ok()
        })
    };
    let real_faces = faces.is_some();
    if let Ok(bytes) = std::fs::read("/System/Library/Fonts/Apple Symbols.ttf") {
        fonts
            .font_data
            .insert("symbols".into(), egui::FontData::from_owned(bytes).into());
        for family in fonts.families.values_mut() {
            family.push("symbols".into());
        }
    }
    let fallback = fonts.families[&egui::FontFamily::Proportional].clone();
    for (index, name) in names.into_iter().enumerate() {
        let mut family = fallback.clone();
        if let Some(faces) = &faces {
            fonts
                .font_data
                .insert(name.into(), faces[index].clone().into());
            family.insert(0, name.into());
        }
        fonts
            .families
            .insert(egui::FontFamily::Name(name.into()), family);
    }
    if let Ok(bytes) = std::fs::read("/System/Library/Fonts/Supplemental/Arial.ttf") {
        fonts
            .font_data
            .insert("interface".into(), egui::FontData::from_owned(bytes).into());
        fonts
            .families
            .get_mut(&egui::FontFamily::Proportional)
            .unwrap()
            .insert(0, "interface".into());
    }
    install_source_faces(&mut fonts);
    ctx.set_fonts(fonts);
    real_faces
}

fn install_source_faces(fonts: &mut egui::FontDefinitions) {
    let faces = if let Some(bytes) =
        SOURCE_COLLECTION.get_or_init(|| std::fs::read("/System/Library/Fonts/Menlo.ttc").ok())
    {
        Some(
            (0..4)
                .map(|index| {
                    let mut data = egui::FontData::from_static(bytes);
                    data.index = index;
                    data
                })
                .collect::<Vec<_>>(),
        )
    } else {
        [
            [
                "C:/Windows/Fonts/consola.ttf",
                "C:/Windows/Fonts/consolab.ttf",
                "C:/Windows/Fonts/consolai.ttf",
                "C:/Windows/Fonts/consolaz.ttf",
            ],
            [
                "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf",
                "/usr/share/fonts/truetype/liberation2/LiberationMono-Bold.ttf",
                "/usr/share/fonts/truetype/liberation2/LiberationMono-Italic.ttf",
                "/usr/share/fonts/truetype/liberation2/LiberationMono-BoldItalic.ttf",
            ],
            [
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Oblique.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-BoldOblique.ttf",
            ],
        ]
        .iter()
        .find_map(|paths| {
            paths
                .iter()
                .map(|path| std::fs::read(path).map(egui::FontData::from_owned))
                .collect::<Result<Vec<_>, _>>()
                .ok()
        })
    };
    let fallback = fonts.families[&egui::FontFamily::Monospace].clone();
    for (index, name) in [
        "source",
        "source-bold",
        "source-italic",
        "source-bold-italic",
    ]
    .into_iter()
    .enumerate()
    {
        let mut family = fallback.clone();
        if let Some(faces) = &faces {
            fonts
                .font_data
                .insert(name.into(), faces[index].clone().into());
            family.insert(0, name.into());
        }
        fonts
            .families
            .insert(egui::FontFamily::Name(name.into()), family);
    }
}

/// Space between blocks belongs to the document, not the toolkit's widget spacing.
pub fn block_gap(previous: Option<&BlockKind>, current: Option<&BlockKind>) -> f32 {
    match (previous, current) {
        (_, Some(BlockKind::Heading(1))) => 36.0,
        (_, Some(BlockKind::Heading(2))) => 30.0,
        (_, Some(BlockKind::Heading(_))) => 24.0,
        (Some(BlockKind::Heading(1)), _) => 22.0,
        (Some(BlockKind::Heading(_)), _) => 14.0,
        (Some(BlockKind::Bullet), Some(BlockKind::Bullet))
        | (Some(BlockKind::Numbered), Some(BlockKind::Numbered)) => 4.0,
        (None, None) => 10.0,
        _ => 18.0,
    }
}

pub fn list_marker(kind: &BlockKind, number: usize) -> Option<String> {
    match kind {
        BlockKind::Bullet => Some("•".into()),
        BlockKind::Numbered => Some(format!("{number}.")),
        _ => None,
    }
}

pub fn paragraph(p: &Paragraph, width: f32, real_faces: bool) -> ParagraphJob {
    let (size, line_height, tracking) = match p.kind {
        BlockKind::Heading(1) => (34.0, 42.0, -0.45),
        BlockKind::Heading(2) => (25.0, 33.0, -0.2),
        BlockKind::Heading(_) => (20.0, 28.0, 0.0),
        _ => (18.0, 30.0, 0.0),
    };
    let mut base = TextFormat::simple(
        FontId::new(size, egui::FontFamily::Name("reading".into())),
        Color32::from_rgb(52, 58, 55),
    );
    base.line_height = Some(line_height);
    base.extra_letter_spacing = tracking;
    let mut job = ParagraphJob::new(LayoutJob {
        wrap: egui::text::TextWrapping {
            max_width: width,
            ..Default::default()
        },
        ..Default::default()
    });
    let mut run = String::new();
    let mut run_format: Option<TextFormat> = None;
    for glyph in &p.glyphs {
        let mut format = base.clone();
        let bold = glyph.bold || matches!(p.kind, BlockKind::Heading(level) if level >= 3);
        format.font_id.family = egui::FontFamily::Name(
            match (bold, glyph.italic) {
                (false, false) => "reading",
                (true, false) => "reading-bold",
                (false, true) => "reading-italic",
                (true, true) => "reading-bold-italic",
            }
            .into(),
        );
        format.italics = glyph.italic && !real_faces;
        if (glyph.atom.is_some()
            || run_format
                .as_ref()
                .is_some_and(|previous| previous != &format))
            && !run.is_empty()
        {
            job.text(&run, run_format.take().unwrap());
            run.clear();
        }
        if let Some(atom) = &glyph.atom {
            format.color = Color32::from_rgb(66, 104, 84);
            format.background = Color32::from_rgb(238, 241, 234);
            job.atom(atom, 1, format);
        } else {
            run.push(glyph.text);
            run_format = Some(format);
        }
    }
    if !run.is_empty() {
        job.text(&run, run_format.unwrap());
    }
    if job.is_empty() {
        job.atom(" ", 0, base);
    }
    job
}

/// Use the editor's cursor position but the font's height, independent of line spacing.
pub fn paint_caret(
    ui: &egui::Ui,
    galley: &egui::Galley,
    origin: egui::Pos2,
    row_rect: egui::Rect,
    since_input: f32,
) {
    let style = &ui.visuals().text_cursor;
    if style.blink {
        let cycle = style.on_duration + style.off_duration;
        let phase = since_input % cycle;
        let visible = phase < style.on_duration;
        ui.request_repaint_after_secs(if visible {
            style.on_duration - phase
        } else {
            cycle - phase
        });
        if !visible {
            return;
        }
    }
    let caret = caret_rect(galley, origin, row_rect, style.stroke.width);
    ui.painter().rect_filled(caret, 1, style.stroke.color);
}

pub fn caret_rect(
    galley: &egui::Galley,
    origin: egui::Pos2,
    row_rect: egui::Rect,
    width: f32,
) -> egui::Rect {
    let mut top = row_rect.top();
    let mut height = row_rect.height();
    if let Some(row) = galley.rows.iter().min_by(|a, b| {
        (origin.y + a.pos.y - row_rect.top())
            .abs()
            .total_cmp(&(origin.y + b.pos.y - row_rect.top()).abs())
    }) && let Some(glyph) = row
        .glyphs
        .iter()
        .rev()
        .find(|g| origin.x + row.pos.x + g.pos.x <= row_rect.center().x)
        .or_else(|| row.glyphs.first())
    {
        top = origin.y + row.pos.y + glyph.pos.y - glyph.font_ascent;
        height = glyph.font_height;
    }
    egui::Rect::from_min_size(
        egui::pos2(row_rect.center().x - width / 2.0, top),
        egui::vec2(width, height),
    )
}
