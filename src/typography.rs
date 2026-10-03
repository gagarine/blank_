use blank_document::{BlockKind, Paragraph};
use eframe::egui::{self, Color32, FontId, TextFormat, text::LayoutJob};
use egui_richedit::ParagraphJob;

pub fn install(ctx: &egui::Context) -> bool {
    let mut fonts = egui::FontDefinitions::default();
    let names = [
        "reading",
        "reading-bold",
        "reading-italic",
        "reading-bold-italic",
    ];
    let faces = if let Ok(bytes) =
        std::fs::read("/System/Library/Fonts/Supplemental/Iowan Old Style.ttc")
    {
        Some(
            (0..4)
                .map(|index| {
                    let mut data = egui::FontData::from_owned(bytes.clone());
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
    ctx.set_fonts(fonts);
    real_faces
}

pub fn paragraph(p: &Paragraph, width: f32, real_faces: bool, number: usize) -> ParagraphJob {
    let (size, line_height) = match p.kind {
        BlockKind::Heading(1) => (34.0, 44.2),
        BlockKind::Heading(2) => (24.0, 33.6),
        BlockKind::Heading(_) => (19.0, 30.4),
        _ => (18.0, 34.56),
    };
    let mut base = TextFormat::simple(
        FontId::new(size, egui::FontFamily::Name("reading".into())),
        Color32::from_rgb(52, 58, 55),
    );
    base.line_height = Some(line_height);
    let mut job = ParagraphJob::new(LayoutJob {
        wrap: egui::text::TextWrapping {
            max_width: width,
            ..Default::default()
        },
        ..Default::default()
    });
    match p.kind {
        BlockKind::Bullet => job.atom("•  ", 0, base.clone()),
        BlockKind::Numbered => job.atom(&format!("{number}.  "), 0, base.clone()),
        _ => {}
    }
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
