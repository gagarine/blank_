//! Conservative, syntax-backed object editing. Dynamic content remains source.
use std::ops::Range;
use typst_syntax::{Source, SyntaxKind, SyntaxNode};

#[derive(Clone, Debug)]
pub struct Table {
    pub columns: usize,
    pub cells: Vec<Range<usize>>,
    pub options: Vec<String>,
}
impl Table {
    pub fn source(&self, cells: &[String], columns: usize) -> String {
        let options = self
            .options
            .iter()
            .map(|option| format!("  {option},\n"))
            .collect::<String>();
        let cells = cells
            .iter()
            .map(|cell| format!("  [{cell}],\n"))
            .collect::<String>();
        format!("#table(columns: {columns},\n{options}{cells})")
    }
}
#[derive(Clone, Debug)]
pub enum Object {
    Table(Table),
    Image {
        path: String,
        caption: Option<Range<usize>>,
        alt: Option<Range<usize>>,
    },
    Quote {
        body: Range<usize>,
    },
}
fn nodes(
    node: &SyntaxNode,
    offset: usize,
    kind: SyntaxKind,
    out: &mut Vec<(SyntaxNode, Range<usize>)>,
) {
    if node.kind() == kind {
        out.push((node.clone(), offset..offset + node.len()));
        return;
    }
    let mut at = offset;
    for child in node.children() {
        nodes(child, at, kind, out);
        at += child.len();
    }
}
fn content_range(node: &SyntaxNode, start: usize) -> Option<Range<usize>> {
    let mut found = vec![];
    nodes(node, start, SyntaxKind::Markup, &mut found);
    found.first().map(|(_, range)| range.clone())
}
fn direct(node: &SyntaxNode, offset: usize) -> Vec<(&SyntaxNode, usize)> {
    let mut at = offset;
    node.children()
        .map(|child| {
            let start = at;
            at += child.len();
            (child, start)
        })
        .collect()
}
fn arguments(call: &SyntaxNode, offset: usize) -> Option<Vec<(&SyntaxNode, usize)>> {
    let (args, at) = direct(call, offset)
        .into_iter()
        .find(|(n, _)| n.kind() == SyntaxKind::Args)?;
    Some(direct(args, at))
}
pub fn parse(raw: &str, start: usize) -> Option<Object> {
    let source = Source::detached(raw);
    if !source.root().errors_and_warnings().0.is_empty() {
        return None;
    }
    let mut call = None;
    for (node, at) in direct(source.root(), start) {
        match node.kind() {
            SyntaxKind::Hash | SyntaxKind::Space => {}
            SyntaxKind::FuncCall if call.is_none() => call = Some((node, at)),
            _ => return None,
        }
    }
    let (call, offset) = call?;
    let name = call.children().next()?.full_text();
    let args = arguments(call, offset)?;
    let named = |name: &str| {
        args.iter()
            .find(|(n, _)| {
                n.kind() == SyntaxKind::Named
                    && n.children().next().is_some_and(|n| n.full_text() == name)
            })
            .copied()
    };
    match name.as_str() {
        "table" => {
            let mut columns = 1;
            let mut options = vec![];
            let mut cells = vec![];
            for (node, at) in args {
                match node.kind() {
                    SyntaxKind::Named => {
                        let text = node.full_text();
                        let (name, value) = text.split_once(':')?;
                        if name.trim() == "columns" {
                            columns = value.trim().parse::<usize>().ok()?;
                        } else {
                            options.push(text.to_string());
                        }
                    }
                    SyntaxKind::ContentBlock => cells.push(content_range(node, at)?),
                    SyntaxKind::LeftParen
                    | SyntaxKind::RightParen
                    | SyntaxKind::Comma
                    | SyntaxKind::Space => {}
                    _ => return None,
                }
            }
            if columns == 0 || columns > 100 || cells.is_empty() {
                return None;
            }
            Some(Object::Table(Table {
                columns,
                cells,
                options,
            }))
        }
        "image" | "figure" => {
            let (image, image_at) = if name == "image" {
                (call, offset)
            } else {
                args.iter().copied().find(|(n, _)| {
                    n.kind() == SyntaxKind::FuncCall
                        && n.children()
                            .next()
                            .is_some_and(|n| n.full_text() == "image")
                })?
            };
            let image_args = arguments(image, image_at)?;
            let (path, _) = image_args
                .iter()
                .find(|(n, _)| n.kind() == SyntaxKind::Str)?;
            let path = serde_json_string(path.full_text().as_str())?;
            let caption = named("caption").and_then(|(n, at)| content_range(n, at));
            let alt = image_args
                .iter()
                .find(|(n, _)| {
                    n.kind() == SyntaxKind::Named
                        && n.children().next().is_some_and(|n| n.full_text() == "alt")
                })
                .and_then(|(n, at)| {
                    direct(n, *at)
                        .into_iter()
                        .find(|(n, _)| n.kind() == SyntaxKind::Str)
                        .map(|(n, at)| at..at + n.len())
                });
            Some(Object::Image { path, caption, alt })
        }
        "quote" => {
            let (body, at) = args
                .iter()
                .copied()
                .find(|(n, _)| n.kind() == SyntaxKind::ContentBlock)?;
            content_range(body, at).map(|body| Object::Quote { body })
        }
        _ => None,
    }
}
fn serde_json_string(raw: &str) -> Option<String> {
    use typst_syntax::ast;
    Source::detached(format!("#{raw}"))
        .root()
        .children()
        .find_map(|node| {
            node.cast::<ast::Str>()
                .map(|string| string.get().to_string())
        })
}
pub fn includes(text: &str) -> Vec<(Range<usize>, String)> {
    use typst_syntax::ast;
    let source = Source::detached(text);
    direct(source.root(), 0)
        .into_iter()
        .filter_map(|(node, offset)| {
            let include = node.cast::<ast::ModuleInclude>()?;
            let ast::Expr::Str(path) = include.source() else {
                return None;
            };
            Some((
                offset.saturating_sub(1)..offset + node.len(),
                path.get().to_string(),
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cells_and_captions_have_exact_utf8_ranges() {
        let raw = "#table(columns: 2, stroke: 0.5pt, [Café], [*Second*])";
        let Object::Table(table) = parse(raw, 20).unwrap() else {
            panic!()
        };
        assert_eq!(table.columns, 2);
        assert_eq!(
            &raw[table.cells[0].start - 20..table.cells[0].end - 20],
            "Café"
        );
        assert_eq!(table.options, ["stroke: 0.5pt"]);
        let raw = "#figure(image(\"assets/é.png\", alt: \"Diagram\"), caption: [My figure])";
        let Object::Image { path, caption, alt } = parse(raw, 0).unwrap() else {
            panic!()
        };
        assert_eq!(path, "assets/é.png");
        assert_eq!(&raw[caption.unwrap()], "My figure");
        assert_eq!(&raw[alt.unwrap()], "\"Diagram\"");
        assert!(parse("#table(columns: n, ..data)", 0).is_none());
    }
    #[test]
    fn nested_cell_calls_and_program_prefixes_are_not_reinterpreted() {
        let raw = "#table(columns: 1, [#strong[Only cell]])";
        let Object::Table(table) = parse(raw, 0).unwrap() else {
            panic!()
        };
        assert_eq!(table.cells.len(), 1);
        assert_eq!(&raw[table.cells[0].clone()], "#strong[Only cell]");
        assert!(parse("#set text(12pt)\n#table(columns:1,[Cell])", 0).is_none());
        assert!(parse("#table(columns:1, ..data)", 0).is_none());
        assert!(
            includes("#let chapter() = {include \"hidden.typ\"}\n#include \"visible.typ\"")
                .iter()
                .all(|(_, path)| path == "visible.typ")
        );
    }
}
