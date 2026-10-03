use blank_document::{HighlightTag as Tag, highlights};
use eframe::egui::{
    self, Color32, FontId, Id, Key, Modifiers, TextFormat,
    text::{CCursor, CCursorRange, CharIndex, LayoutJob},
};

pub fn layout(text: &str) -> LayoutJob {
    let base = TextFormat::simple(FontId::monospace(14.0), Color32::from_rgb(52, 58, 55));
    let mut job = LayoutJob::default();
    let mut at = 0;
    for (range, tag) in highlights(text) {
        if range.start > at {
            job.append(&text[at..range.start], 0.0, base.clone());
        }
        let mut format = base.clone();
        format.color = match tag {
            Tag::Comment => Color32::from_rgb(142, 149, 136),
            Tag::Keyword | Tag::Error => Color32::from_rgb(151, 83, 71),
            Tag::Number | Tag::MathDelimiter => Color32::from_rgb(114, 97, 139),
            Tag::String | Tag::Function | Tag::Heading | Tag::Strong | Tag::Emph => {
                Color32::from_rgb(66, 104, 84)
            }
            Tag::Ref | Tag::Label | Tag::Link | Tag::Interpolated => {
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
