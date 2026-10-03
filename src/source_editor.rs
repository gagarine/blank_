use blank_document::{HighlightTag as Tag, source_highlights};
use eframe::egui::{
    self, Color32, FontId, Id, Key, Modifiers, TextFormat,
    text::{CCursor, CCursorRange, CharIndex, LayoutJob},
};

pub fn layout(text: &str) -> LayoutJob {
    let base = TextFormat::simple(
        FontId::new(14.0, egui::FontFamily::Name("source".into())),
        Color32::from_rgb(52, 58, 55),
    );
    let mut job = LayoutJob::default();
    let mut at = 0;
    for run in source_highlights(text) {
        let range = run.range;
        if range.start > at {
            job.append(&text[at..range.start], 0.0, base.clone());
        }
        let mut format = base.clone();
        format.font_id.size = match run.style.heading {
            0 => 14.0,
            1 => 24.0,
            2 => 20.0,
            3 => 17.0,
            _ => 15.0,
        };
        format.font_id.family = egui::FontFamily::Name(
            match (run.style.bold || run.style.heading > 0, run.style.italic) {
                (false, false) => "source",
                (true, false) => "source-bold",
                (false, true) => "source-italic",
                (true, true) => "source-bold-italic",
            }
            .into(),
        );
        format.color = match run.tag {
            Some(Tag::Comment) => Color32::from_rgb(142, 149, 136),
            Some(Tag::Keyword | Tag::Error) => Color32::from_rgb(151, 83, 71),
            Some(Tag::Number | Tag::MathDelimiter) => Color32::from_rgb(114, 97, 139),
            Some(Tag::String | Tag::Function | Tag::Heading | Tag::Strong | Tag::Emph) => {
                Color32::from_rgb(66, 104, 84)
            }
            Some(Tag::Ref | Tag::Label | Tag::Link | Tag::Interpolated) => {
                Color32::from_rgb(69, 105, 129)
            }
            _ => base.color,
        };
        job.append(&text[range.clone()], 0.0, format);
        at = range.end;
    }
    if at < text.len() {
        job.append(&text[at..], 0.0, base);
    }
    job
}

/// Pair insertion, wrapping, closing-skip and paired backspace are all
/// expressed as ordinary TextEdit transactions, sharing the source history.
pub fn pairs(ctx: &egui::Context, id: Id, text: &str) -> Option<CCursorRange> {
    if !ctx.memory(|m| m.has_focus(id)) {
        return None;
    }
    let mut state = egui::TextEdit::load_state(ctx, id)?;
    let cursor = state.cursor.char_range()?;
    let selection = cursor.as_sorted_char_range();
    let chars: Vec<char> = text.chars().collect();
    let start = selection.start.0.min(chars.len());
    let end = selection.end.0.min(chars.len());
    let mut afterward = None;
    ctx.input_mut(|i| {
        if let Some(index) = i.events.iter().position(|e| matches!(e, egui::Event::Text(t) if t.chars().count() == 1)) {
            let egui::Event::Text(typed) = &i.events[index] else { return; };
            let c = typed.chars().next().unwrap();
            if start == end && matches!(c, ')' | ']' | '}' | '"') && chars.get(start) == Some(&c) {
                i.events.remove(index);
                state.cursor.set_char_range(Some(CCursorRange::one(CCursor::new(CharIndex(start + 1)))));
            } else if let Some(close) = match c { '(' => Some(')'), '[' => Some(']'), '{' => Some('}'), '"' => Some('"'), _ => None }
                && (start == 0 || chars[start - 1] != '\\')
            {
                let selected: String = chars[start..end].iter().collect();
                i.events[index] = egui::Event::Text(format!("{c}{selected}{close}"));
                afterward = Some(if start == end { CCursorRange::one(CCursor::new(CharIndex(start + 1))) }
                    else { CCursorRange::two(CCursor::new(CharIndex(start + 1)), CCursor::new(CharIndex(end + 1))) });
            }
        } else if start == end && start > 0 && start < chars.len()
            && matches!((chars[start - 1], chars[start]), ('(', ')') | ('[', ']') | ('{', '}') | ('"', '"'))
            && i.events.iter().any(|e| matches!(e, egui::Event::Key {key: Key::Backspace, pressed: true, modifiers, ..} if *modifiers == Modifiers::NONE))
        {
            state.cursor.set_char_range(Some(CCursorRange::two(CCursor::new(CharIndex(start - 1)), CCursor::new(CharIndex(start + 1)))));
        }
    });
    state.store(ctx, id);
    afterward
}

#[cfg(test)]
mod tests {
    use super::*;
    fn format_at<'a>(job: &'a LayoutJob, needle: &str) -> &'a TextFormat {
        let byte = job.text.find(needle).unwrap();
        &job.sections
            .iter()
            .find(|section| section.byte_range.contains(&egui::text::ByteIndex(byte)))
            .unwrap()
            .format
    }

    #[test]
    fn source_typography_follows_nested_markup_without_styling_code_literals() {
        let text = "= Title *bold _nested_*\n== Section\n=== Detail\n\nPlain *bold* _italic_ #strong[call #emph[both]]\n`*literal*`\n// *comment*\n#let x = \"*string*\"";
        let job = layout(text);
        assert_eq!(job.text, text);
        for (needle, size) in [("Title", 24.0), ("Section", 20.0), ("Detail", 17.0)] {
            assert_eq!(format_at(&job, needle).font_id.size, size);
        }
        for (needle, family) in [
            ("Plain", "source"),
            ("bold", "source-bold"),
            ("italic", "source-italic"),
            ("nested", "source-bold-italic"),
            ("call", "source-bold"),
            ("both", "source-bold-italic"),
            ("literal", "source"),
            ("comment", "source"),
            ("string", "source"),
        ] {
            assert_eq!(
                format_at(&job, needle).font_id.family,
                egui::FontFamily::Name(family.into()),
                "{needle}"
            );
        }
        assert_eq!(format_at(&job, "Plain").font_id.size, 14.0);
        // Syntax delimiters remain visible and present in the exact source.
        assert_eq!(format_at(&job, "= Title").font_id.size, 24.0);
    }

    #[test]
    fn highlighting_preserves_unicode_and_every_source_byte() {
        let text = "// café\n#set text(size: 11pt)\n= Heading\n*bold* and $x + 2$";
        let job = layout(text);
        assert_eq!(job.text, text);
        assert!(
            job.sections
                .iter()
                .any(|s| s.format.color == Color32::from_rgb(142, 149, 136))
        );
        assert!(
            job.sections
                .iter()
                .any(|s| s.format.color == Color32::from_rgb(114, 97, 139))
        );
        assert!(
            job.sections
                .iter()
                .any(|s| s.format.color == Color32::from_rgb(66, 104, 84))
        );
    }
}
