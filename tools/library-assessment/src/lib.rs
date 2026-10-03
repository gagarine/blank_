//! Small, reproducible probes of the alternative rich-document engine.

#[cfg(test)]
mod tests {
    use text_document::{DocumentEvent, MoveMode, TextDocument, TextFormat};

    #[test]
    fn unicode_cursor_edit_emits_a_change_and_undo_restores_text() {
        let doc = TextDocument::new();
        doc.set_plain_text("Café 🦀").unwrap();
        doc.poll_events();
        doc.cursor_at(6).insert_text("!").unwrap();
        assert_eq!(doc.to_plain_text().unwrap(), "Café 🦀!");
        assert!(
            doc.poll_events()
                .iter()
                .any(|e| matches!(e, DocumentEvent::ContentsChanged { .. }))
        );
        doc.undo().unwrap();
        assert_eq!(doc.to_plain_text().unwrap(), "Café 🦀");
    }

    #[test]
    fn formatting_and_tables_are_model_operations_with_undo() {
        let doc = TextDocument::new();
        doc.set_plain_text("Hello world").unwrap();
        let cursor = doc.cursor_at(6);
        cursor.set_position(11, MoveMode::KeepAnchor);
        cursor
            .set_char_format(&TextFormat {
                font_bold: Some(true),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(
            doc.cursor_at(7).char_format().unwrap().font_bold,
            Some(true)
        );
        doc.undo().unwrap();
        assert_ne!(
            doc.cursor_at(7).char_format().unwrap().font_bold,
            Some(true)
        );
        let table = doc.cursor_at(11).insert_table(2, 3).unwrap();
        assert_eq!((table.rows(), table.columns()), (2, 3));
        doc.undo().unwrap();
        assert_eq!(doc.to_plain_text().unwrap(), "Hello world");
    }
}
