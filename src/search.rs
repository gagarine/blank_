use blank_document::{Document, Position};
use std::ops::Range;

#[derive(Default)]
pub struct Find {
    pub open: bool,
    pub focus: bool,
    pub query: String,
    pub replacement: String,
    pub replace: bool,
    pub case_sensitive: bool,
    pub index: usize,
    pub matches: Vec<Hit>,
    pub cache: Option<(u64, String, bool, bool)>,
}
#[derive(Clone)]
pub struct Hit {
    pub bytes: Range<usize>,
    pub from: Position,
    pub to: Position,
}
pub fn hits(document: &Document, query: &str, case_sensitive: bool, source: bool) -> Vec<Hit> {
    if query.is_empty() {
        return vec![];
    }
    let Ok(pattern) = regex::RegexBuilder::new(&regex::escape(query))
        .case_insensitive(!case_sensitive)
        .build()
    else {
        return vec![];
    };
    if source {
        return pattern
            .find_iter(document.text())
            .map(|hit| Hit {
                bytes: hit.range(),
                from: document.position_at(hit.start()),
                to: document.position_at(hit.end()),
            })
            .collect();
    }
    document
        .paragraphs
        .iter()
        .enumerate()
        .flat_map(|(index, p)| {
            let text = p.text();
            pattern
                .find_iter(&text)
                .map(|hit| {
                    let from = Position::new(index, text[..hit.start()].chars().count());
                    let to = Position::new(index, text[..hit.end()].chars().count());
                    Hit {
                        bytes: document.source_offset(from)..document.source_offset(to),
                        from,
                        to,
                    }
                })
                .collect::<Vec<_>>()
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rich_search_maps_unicode_across_formatting_without_matching_markup() {
        let document = Document::new("== Café *naïve*\n\n#let café = 2");
        let found = hits(&document, "CAFÉ naïve", false, false);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].from, Position::new(0, 0));
        assert_eq!(found[0].to, Position::new(0, 10));
        assert_eq!(hits(&document, "café", false, true).len(), 2);
    }
}
