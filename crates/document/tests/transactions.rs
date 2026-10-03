use blank_document::{BlockKind, Document, Mark, Position as P, minimal_patch};

#[test]
fn visual_typing_preserves_custom_code_comments_and_exact_spacing() {
    let source = "// Keep this comment\n#set page(margin: 23mm)\n\n= Title\n\nHello *world*.\n\n#figure(rect(), caption: [Custom])\n";
    let mut d = Document::new(source);
    assert_eq!(d.paragraphs[0].text(), "Title");
    assert_eq!(d.paragraphs[1].text().trim(), "Hello world.");
    d.replace(P::new(1, 6), P::new(1, 6), "beautiful ", true)
        .unwrap();
    assert_eq!(d.text(), source.replace("*world*", "*beautiful world*"));
    assert!(d.errors().is_empty(), "{:?}", d.errors());
    let patch = d.last_patch.as_ref().unwrap();
    assert_eq!(patch.replaced.start, patch.replaced.end);
    assert_eq!(patch.inserted, "beautiful ");
    assert!(d.undo());
    assert_eq!(d.text(), source);
    assert!(d.redo());
    assert!(d.text().contains("beautiful"));
}

#[test]
fn unicode_edits_do_not_split_utf8_or_escaped_literals() {
    let mut d = Document::new("Café 🦀 \\#tag");
    assert_eq!(d.paragraphs[0].text(), "Café 🦀 #tag");
    d.replace(P::new(0, 5), P::new(0, 6), "λ", true).unwrap();
    assert_eq!(d.text(), "Café λ \\#tag");
    d.replace(P::new(0, 7), P::new(0, 8), "@", true).unwrap();
    assert_eq!(d.text(), "Café λ \\@tag");
    assert!(d.errors().is_empty());
}

#[test]
fn crossing_nested_marks_balances_the_remaining_source() {
    let mut d = Document::new("A *bold _nested_* tail.");
    assert_eq!(d.paragraphs[0].text(), "A bold nested tail.");
    d.replace(P::new(0, 4), P::new(0, 16), "X", true).unwrap();
    assert_eq!(d.paragraphs[0].text(), "A boXil.");
    assert!(d.errors().is_empty(), "{} {:?}", d.text(), d.errors());
}

#[test]
fn deleting_all_marked_text_removes_empty_delimiters() {
    let mut d = Document::new("Before *bold* after");
    d.replace(P::new(0, 7), P::new(0, 11), "", true).unwrap();
    assert_eq!(d.text(), "Before  after");
}

#[test]
fn formatting_round_trips_and_partial_removal_preserves_other_runs() {
    let mut d = Document::new("Hello world");
    d.format(P::new(0, 6), P::new(0, 11), Mark::Bold, true, true)
        .unwrap();
    assert_eq!(d.text(), "Hello #strong[world]");
    assert_eq!(
        d.marked(P::new(0, 6), P::new(0, 11), Mark::Bold),
        Some(true)
    );
    d.format(P::new(0, 7), P::new(0, 10), Mark::Bold, false, true)
        .unwrap();
    assert_eq!(d.text(), "Hello #strong[w]orl#strong[d]");
    assert_eq!(d.paragraphs[0].text(), "Hello world");
    assert!(d.errors().is_empty());
}

#[test]
fn splitting_formatted_text_keeps_both_halves_formatted() {
    let mut d = Document::new("*Hello world*");
    let pos = d.split(P::new(0, 6), true).unwrap();
    assert_eq!(d.text(), "#strong[Hello ]\n\n#strong[world]");
    assert_eq!(pos, P::new(1, 0));
    assert!(d.errors().is_empty());
    d.replace(P::new(0, 6), P::new(1, 0), "", true).unwrap();
    assert_eq!(d.paragraphs[0].text(), "Hello world");
    assert!(d.errors().is_empty());
}

#[test]
fn empty_document_and_trailing_paragraph_can_be_edited() {
    let mut d = Document::new("");
    let p = d
        .replace(P::new(0, 0), P::new(0, 0), "Hello", true)
        .unwrap();
    assert_eq!(p, P::new(0, 5));
    let p = d.split(p, true).unwrap();
    assert_eq!(p, P::new(1, 0));
    d.replace(p, p, "World", true).unwrap();
    assert_eq!(d.text(), "Hello\n\nWorld");
}

#[test]
fn source_and_visual_changes_share_history_and_allow_invalid_source() {
    let mut d = Document::new("Hello");
    d.replace_source("Hello *", true);
    assert_eq!(d.text(), "Hello *");
    assert!(!d.errors().is_empty());
    d.replace_source("Hello *world*", false);
    d.replace(P::new(0, 11), P::new(0, 11), "!", true).unwrap();
    assert!(d.undo());
    assert_eq!(d.text(), "Hello *world*");
    assert!(d.undo());
    assert_eq!(d.text(), "Hello");
}

#[test]
fn opaque_expressions_survive_and_cannot_be_partially_deleted() {
    let mut d = Document::new("Cite @key and $x^2$ here");
    let original = d.text().to_owned();
    assert!(d.replace(P::new(0, 5), P::new(0, 6), "", true).is_err());
    assert_eq!(d.text(), original);
    d.replace(P::new(0, 0), P::new(0, 0), "Please ", true)
        .unwrap();
    assert!(d.text().contains("@key and $x^2$"));
}

#[test]
fn joins_cannot_delete_intervening_source_blocks() {
    let mut d = Document::new("One\n\n#set text(12pt)\n\nTwo");
    assert!(d.replace(P::new(0, 3), P::new(1, 0), "", true).is_err());
    assert!(d.text().contains("#set text(12pt)"));
}

#[test]
fn heading_and_list_commands_change_only_the_prefix() {
    let mut d = Document::new("A title\n\nA paragraph");
    d.set_kind(P::new(0, 0), BlockKind::Heading(2)).unwrap();
    assert_eq!(d.text(), "== A title\n\nA paragraph");
    d.set_kind(P::new(1, 0), BlockKind::Bullet).unwrap();
    assert_eq!(d.text(), "== A title\n\n- A paragraph");
}

#[test]
fn smallest_patch_has_utf8_boundaries() {
    let (range, insertion) = minimal_patch("🦀 café", "🦀 caffè").unwrap();
    let mut old = "🦀 café".to_owned();
    old.replace_range(range, &insertion);
    assert_eq!(old, "🦀 caffè");
}

#[test]
fn all_selection_boundaries_keep_visible_text_and_valid_syntax() {
    for source in [
        "A *bold* end",
        "A *bold _nested_* tail",
        "Café 🦀 \\#tag",
        "A #strong[bold] word",
    ] {
        let original = Document::new(source).paragraphs[0].text();
        let chars: Vec<_> = original.chars().collect();
        for start in 0..=chars.len() {
            for end in start..=chars.len() {
                let mut d = Document::new(source);
                d.replace(P::new(0, start), P::new(0, end), "X", true)
                    .unwrap();
                let expected: String = chars[..start]
                    .iter()
                    .chain(['X'].iter())
                    .chain(chars[end..].iter())
                    .collect();
                assert_eq!(
                    d.paragraphs[0].text(),
                    expected,
                    "source={source:?}, selection={start}..{end}, result={:?}",
                    d.text()
                );
                assert!(d.errors().is_empty(), "{} {:?}", d.text(), d.errors());
            }
        }
    }
}

#[test]
fn return_at_paragraph_boundaries_keeps_empty_slots_before_following_text() {
    for source in [
        "One\n\nTwo",
        "= One\n\nTwo",
        "One\n\n#figure(rect())\n\nTwo",
    ] {
        let mut d = Document::new(source);
        let at = d.split(P::new(0, 3), true).unwrap();
        assert_eq!(d.paragraphs[at.paragraph].text(), "");
        let at = d.split(at, true).unwrap();
        assert_eq!(d.paragraphs[at.paragraph].text(), "");
        d.replace(at, at, "New", true).unwrap();
        assert_eq!(d.paragraphs[at.paragraph].text(), "New");
        assert_eq!(d.paragraphs.last().unwrap().text(), "Two");
        assert!(d.errors().is_empty(), "{} {:?}", d.text(), d.errors());
    }
    let mut d = Document::new("One\n\nTwo");
    let at = d.split(P::new(1, 0), true).unwrap();
    assert_eq!(at, P::new(2, 0));
    d.replace(P::new(1, 0), P::new(1, 0), "Before ", true)
        .unwrap();
    assert_eq!(d.paragraphs[1].text(), "Before ");
    assert_eq!(d.paragraphs[2].text(), "Two");
}

#[test]
fn list_return_continues_and_empty_item_exits_the_list() {
    for prefix in ["- ", "+ "] {
        let mut d = Document::new(format!("{prefix}One\n{prefix}Two"));
        let at = d.split(P::new(0, 3), true).unwrap();
        assert_eq!(at, P::new(1, 0), "{} {:?}", d.text(), d.paragraphs);
        assert!(matches!(
            d.paragraphs[1].kind,
            BlockKind::Bullet | BlockKind::Numbered
        ));
        let at = d.split(at, true).unwrap();
        assert!(matches!(
            d.paragraphs[at.paragraph].kind,
            BlockKind::Paragraph
        ));
        d.replace(at, at, "Outside", true).unwrap();
        assert_eq!(d.paragraphs[at.paragraph].text(), "Outside");
        assert_eq!(d.paragraphs.last().unwrap().text(), "Two");
        assert!(d.errors().is_empty(), "{} {:?}", d.text(), d.errors());
        let mut d = Document::new(format!("{prefix}One"));
        let at = d.split(P::new(0, 3), true).unwrap();
        let at = d.split(at, true).unwrap();
        assert!(matches!(
            d.paragraphs[at.paragraph].kind,
            BlockKind::Paragraph
        ));
        d.replace(at, at, "Outside", true).unwrap();
        assert_eq!(d.paragraphs.last().unwrap().text(), "Outside");
    }
}

#[test]
fn consecutive_source_lines_are_one_preserved_block_and_leading_spaces_are_editable() {
    let source = "// Comment\n#set page(margin: 24mm)\n#set text(size: 11pt)\n\n= Title\n\n#let x = 1\n#let y = 2\n\nText";
    let d = Document::new(source);
    let blocks: Vec<_> = d
        .blocks
        .iter()
        .filter_map(|b| match b {
            blank_document::Block::Source { range, .. } => Some(&d.text()[range.clone()]),
            _ => None,
        })
        .collect();
    assert_eq!(blocks.len(), 2);
    assert_eq!(
        blocks[0],
        "// Comment\n#set page(margin: 24mm)\n#set text(size: 11pt)"
    );
    assert_eq!(d.text(), source);
    let mut d = Document::new("");
    let at = d.replace(P::new(0, 0), P::new(0, 0), "  ", true).unwrap();
    assert_eq!(at.offset, 2);
    d.replace(at, at, "Hello", true).unwrap();
    assert_eq!(d.paragraphs[0].text(), "  Hello");
}

#[test]
fn block_move_duplicate_delete_are_undoable_and_keep_custom_source() {
    let original = "= Title\n\nFirst\n\nSecond\n\n#set text(12pt)\n\nLast";
    let mut d = Document::new(original);
    let at = d.move_block(2, 1, false).unwrap();
    assert_eq!(d.paragraphs[at.paragraph].text(), "Second");
    assert!(d.text().find("Second").unwrap() < d.text().find("First").unwrap());
    assert!(d.text().contains("#set text(12pt)"));
    assert!(d.undo());
    assert_eq!(d.text(), original);
    let at = d.duplicate_block(2).unwrap();
    assert_eq!(d.paragraphs[at.paragraph].text(), "Second");
    assert_eq!(d.text().matches("Second").count(), 2);
    d.delete_block(at.paragraph).unwrap();
    assert_eq!(d.text(), original);
    let at = d.move_block(1, 3, true).unwrap();
    assert_eq!(d.paragraphs[at.paragraph].text(), "First");
    assert!(d.errors().is_empty());
    assert!(d.text().contains("#set text(12pt)"));
}
