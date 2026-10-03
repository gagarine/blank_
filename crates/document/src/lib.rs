//! Source-backed document state. GUI types deliberately stay out of this crate.

use std::ops::Range;
use typst_syntax::{
    Source, SyntaxKind, SyntaxNode,
    ast::{self},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mark {
    Bold,
    Italic,
}

impl Mark {
    fn wrap(self, text: &str) -> String {
        match self {
            Self::Bold => format!("#strong[{text}]"),
            Self::Italic => format!("#emph[{text}]"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BlockKind {
    Paragraph,
    Heading(usize),
    Bullet,
    Numbered,
}

#[derive(Clone, Debug)]
pub struct Glyph {
    pub text: char,
    pub source: Range<usize>,
    pub bold: bool,
    pub italic: bool,
    pub atom: Option<String>,
}

#[derive(Clone, Debug)]
enum InlineKind {
    Text(Vec<Glyph>),
    Styled(Mark, Vec<Inline>, Range<usize>),
    Atom(String),
}

#[derive(Clone, Debug)]
struct Inline {
    range: Range<usize>,
    kind: InlineKind,
    len: usize,
}

#[derive(Clone, Debug)]
pub struct Paragraph {
    pub kind: BlockKind,
    /// Editable body; heading/list prefixes are outside this range.
    pub range: Range<usize>,
    pub glyphs: Vec<Glyph>,
    nodes: Vec<Inline>,
}

impl Paragraph {
    pub fn text(&self) -> String {
        self.glyphs.iter().map(|g| g.text).collect()
    }
    pub fn source_offset(&self, offset: usize) -> usize {
        if offset == 0 {
            self.glyphs
                .first()
                .map_or(self.range.start, |g| g.source.start)
        } else {
            self.glyphs
                .get(offset - 1)
                .map_or(self.range.end, |g| g.source.end)
        }
    }
}

#[derive(Clone, Debug)]
pub enum Block {
    Editable(usize),
    Source { range: Range<usize>, kind: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Position {
    pub paragraph: usize,
    pub offset: usize,
}

impl Position {
    pub fn new(paragraph: usize, offset: usize) -> Self {
        Self { paragraph, offset }
    }
}

#[derive(Clone, Debug)]
pub struct Patch {
    pub replaced: Range<usize>,
    pub inserted: String,
    pub reparsed: Range<usize>,
}

pub struct Document {
    source: Source,
    pub paragraphs: Vec<Paragraph>,
    pub blocks: Vec<Block>,
    pub revision: u64,
    pub last_patch: Option<Patch>,
    undo: Vec<Source>,
    redo: Vec<Source>,
}

impl Document {
    pub fn new(text: impl Into<String>) -> Self {
        let mut doc = Self {
            source: Source::detached(text),
            paragraphs: vec![],
            blocks: vec![],
            revision: 0,
            last_patch: None,
            undo: vec![],
            redo: vec![],
        };
        doc.project();
        doc
    }
    pub fn text(&self) -> &str {
        self.source.text()
    }
    pub fn errors(&self) -> Vec<String> {
        self.source
            .root()
            .errors_and_warnings()
            .0
            .iter()
            .map(|e| e.message.to_string())
            .collect()
    }
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }
    pub fn position_at(&self, byte: usize) -> Position {
        let index = self
            .paragraphs
            .iter()
            .position(|p| byte <= p.range.end)
            .unwrap_or(self.paragraphs.len() - 1);
        let p = &self.paragraphs[index];
        Position::new(
            index,
            p.glyphs.iter().take_while(|g| g.source.end <= byte).count(),
        )
    }
    pub fn source_offset(&self, pos: Position) -> usize {
        self.paragraphs
            .get(pos.paragraph)
            .map_or(self.text().len(), |p| p.source_offset(pos.offset))
    }
    pub fn replace_source(&mut self, text: &str, new_step: bool) -> bool {
        let Some((range, insert)) = minimal_patch(self.text(), text) else {
            return false;
        };
        self.patch(range, &insert, new_step);
        true
    }
    fn patch(&mut self, range: Range<usize>, insert: &str, new_step: bool) {
        if new_step || self.undo.is_empty() {
            self.undo.push(self.source.clone());
            // A bounded history makes prototype memory use predictable.
            if self.undo.len() > 200 {
                self.undo.remove(0);
            }
        }
        self.redo.clear();
        let reparsed = self.source.edit(range.clone(), insert);
        self.last_patch = Some(Patch {
            replaced: range,
            inserted: insert.to_owned(),
            reparsed,
        });
        self.revision += 1;
        self.project();
    }
    pub fn undo(&mut self) -> bool {
        let Some(source) = self.undo.pop() else {
            return false;
        };
        self.redo.push(self.source.clone());
        self.restore(source);
        true
    }
    pub fn redo(&mut self) -> bool {
        let Some(source) = self.redo.pop() else {
            return false;
        };
        self.undo.push(self.source.clone());
        self.restore(source);
        true
    }
    fn restore(&mut self, source: Source) {
        self.source = source;
        self.revision += 1;
        self.last_patch = None;
        self.project();
    }
    fn valid(&self, pos: Position) -> Result<&Paragraph, String> {
        self.paragraphs
            .get(pos.paragraph)
            .filter(|p| pos.offset <= p.glyphs.len())
            .ok_or_else(|| "The selection is outside the document.".into())
    }
    fn selected(&self, from: Position, to: Position) -> Result<(), String> {
        self.valid(from)?;
        self.valid(to)?;
        if (from.paragraph, from.offset) > (to.paragraph, to.offset) {
            return Err("Selection is reversed.".into());
        }
        for index in from.paragraph..=to.paragraph {
            let p = &self.paragraphs[index];
            let start = if index == from.paragraph {
                from.offset
            } else {
                0
            };
            let end = if index == to.paragraph {
                to.offset
            } else {
                p.glyphs.len()
            };
            if p.glyphs[start..end].iter().any(|g| g.atom.is_some()) {
                return Err("Edit this Typst expression in Source; the prototype preserves it as a source object.".into());
            }
        }
        Ok(())
    }
    pub fn replace(
        &mut self,
        from: Position,
        to: Position,
        text: &str,
        new_step: bool,
    ) -> Result<Position, String> {
        self.selected(from, to)?;
        let first = &self.paragraphs[from.paragraph];
        let last = &self.paragraphs[to.paragraph];
        let mut insertion = escape(text);
        // Inserted newlines are soft line breaks; paragraph splits are a separate transaction.
        insertion = insertion.replace('\n', "\\\n");
        let body = if from.paragraph == to.paragraph {
            edit_nodes(
                &first.nodes,
                self.text(),
                from.offset,
                to.offset,
                &insertion,
            )
        } else {
            if !self.adjacent_editable(from.paragraph, to.paragraph) {
                return Err(
                    "A source block separates these paragraphs. Edit across it in Source.".into(),
                );
            }
            format!(
                "{}{}{}",
                slice(&first.nodes, self.text(), 0, from.offset, None),
                insertion,
                slice(&last.nodes, self.text(), to.offset, last.glyphs.len(), None)
            )
        };
        let start = first.range.start;
        let end = last.range.end;
        let caret = Position::new(from.paragraph, from.offset + text.chars().count());
        self.patch_body(start..end, &body, new_step);
        // Heading/list/empty-paragraph projections can change paragraph indices.
        Ok(Position::new(
            caret.paragraph.min(self.paragraphs.len() - 1),
            caret.offset.min(
                self.paragraphs[caret.paragraph.min(self.paragraphs.len() - 1)]
                    .glyphs
                    .len(),
            ),
        ))
    }
    fn adjacent_editable(&self, first: usize, last: usize) -> bool {
        let mut inside = false;
        for block in &self.blocks {
            match block {
                Block::Editable(i) if *i == first => inside = true,
                Block::Editable(i) if *i == last => return true,
                Block::Source { .. } if inside => return false,
                _ => {}
            }
        }
        true
    }
    pub fn split(&mut self, at: Position, new_step: bool) -> Result<Position, String> {
        let p = self.valid(at)?;
        if matches!(p.kind, BlockKind::Bullet | BlockKind::Numbered) && p.text().trim().is_empty() {
            let line_start = self.text()[..p.range.start]
                .rfind('\n')
                .map_or(0, |i| i + 1);
            let end = self.text()[line_start..]
                .find('\n')
                .map_or(self.text().len(), |i| line_start + i);
            // Leave a real insertion slot outside the list, including at EOF.
            self.patch(line_start..end, "\n", new_step);
            return Ok(Position::new(
                at.paragraph.min(self.paragraphs.len() - 1),
                0,
            ));
        }
        let prefix = match p.kind {
            BlockKind::Bullet => "- ",
            BlockKind::Numbered => "+ ",
            _ => "",
        };
        let separator = if prefix.is_empty() { "\n\n" } else { "\n" };
        let body = format!(
            "{}{}{}{}",
            slice(&p.nodes, self.text(), 0, at.offset, None),
            separator,
            prefix,
            slice(&p.nodes, self.text(), at.offset, p.glyphs.len(), None)
        );
        let range = p.range.clone();
        // Record the second paragraph's source start, even when either half is empty.
        let second_byte = range.start
            + slice(&p.nodes, self.text(), 0, at.offset, None).len()
            + separator.len()
            + prefix.len();
        self.patch_body(range, &body, new_step);
        if prefix.is_empty() {
            Ok(self.position_at(second_byte))
        } else {
            Ok(Position::new(
                (at.paragraph + 1).min(self.paragraphs.len() - 1),
                0,
            ))
        }
    }
    pub fn format(
        &mut self,
        from: Position,
        to: Position,
        mark: Mark,
        on: bool,
        new_step: bool,
    ) -> Result<Position, String> {
        self.selected(from, to)?;
        if from == to {
            return Ok(to);
        }
        // Each touched paragraph stays a separate block. One history step covers all patches.
        let mut replacements = vec![];
        for index in from.paragraph..=to.paragraph {
            let p = &self.paragraphs[index];
            let start = if index == from.paragraph {
                from.offset
            } else {
                0
            };
            let end = if index == to.paragraph {
                to.offset
            } else {
                p.glyphs.len()
            };
            if start == end {
                continue;
            }
            let selected = slice(&p.nodes, self.text(), start, end, Some(mark));
            let selected = if on { mark.wrap(&selected) } else { selected };
            replacements.push((
                p.range.clone(),
                format!(
                    "{}{}{}",
                    slice(&p.nodes, self.text(), 0, start, None),
                    selected,
                    slice(&p.nodes, self.text(), end, p.glyphs.len(), None)
                ),
            ));
        }
        for (i, (range, body)) in replacements.into_iter().rev().enumerate() {
            self.patch_body(range, &body, new_step && i == 0);
        }
        Ok(to)
    }
    pub fn marked(&self, from: Position, to: Position, mark: Mark) -> Option<bool> {
        let mut values = vec![];
        for i in from.paragraph..=to.paragraph {
            let p = self.paragraphs.get(i)?;
            let start = if i == from.paragraph { from.offset } else { 0 };
            let end = if i == to.paragraph {
                to.offset
            } else {
                p.glyphs.len()
            };
            if from == to {
                if let Some(g) = p
                    .glyphs
                    .get(start.saturating_sub(1))
                    .or_else(|| p.glyphs.first())
                {
                    values.push(match mark {
                        Mark::Bold => g.bold,
                        Mark::Italic => g.italic,
                    });
                }
            } else {
                for g in p.glyphs.get(start..end)? {
                    values.push(match mark {
                        Mark::Bold => g.bold,
                        Mark::Italic => g.italic,
                    });
                }
            }
        }
        let value = values.first().copied().unwrap_or(false);
        values.iter().all(|v| *v == value).then_some(value)
    }
    fn block_range(&self, paragraph: usize) -> Result<Range<usize>, String> {
        let p = self
            .paragraphs
            .get(paragraph)
            .ok_or("This block no longer exists.")?;
        let start_of = |block: &Block| match block {
            Block::Source { range, .. } => range.start,
            Block::Editable(index) => {
                let p = &self.paragraphs[*index];
                self.text()[..p.range.start]
                    .rfind('\n')
                    .map_or(0, |i| i + 1)
            }
        };
        let index = self
            .blocks
            .iter()
            .position(|b| matches!(b, Block::Editable(i) if *i == paragraph))
            .ok_or("This block no longer exists.")?;
        let start = start_of(&self.blocks[index]);
        if !self.text()[start..p.range.start]
            .chars()
            .all(|c| c.is_whitespace() || matches!(c, '=' | '-' | '+' | '.' | '0'..='9'))
        {
            return Err("Move this embedded block in Source.".into());
        }
        let end = self
            .blocks
            .get(index + 1)
            .map_or(self.text().len(), start_of);
        Ok(start..end)
    }
    pub fn delete_block(&mut self, paragraph: usize) -> Result<Position, String> {
        let range = self.block_range(paragraph)?;
        let byte = range.start;
        self.patch(range, "", true);
        Ok(self.position_at(byte))
    }
    pub fn duplicate_block(&mut self, paragraph: usize) -> Result<Position, String> {
        let range = self.block_range(paragraph)?;
        let raw = self.text()[range.clone()].trim_end_matches('\n');
        let insertion = if range.end == self.text().len() {
            format!("\n\n{raw}")
        } else {
            format!("{raw}\n\n")
        };
        self.patch(range.end..range.end, &insertion, true);
        Ok(self.position_at(range.end + if insertion.starts_with('\n') { 2 } else { 0 }))
    }
    pub fn move_block(&mut self, from: usize, to: usize, after: bool) -> Result<Position, String> {
        if from == to {
            return Ok(Position::new(from, 0));
        }
        let source = self.block_range(from)?;
        let target = self.block_range(to)?;
        let destination = if after { target.end } else { target.start };
        if destination >= source.start && destination <= source.end {
            return Ok(Position::new(from, 0));
        }
        let raw = self.text()[source.clone()]
            .trim_end_matches('\n')
            .to_owned();
        let mut text = self.text().to_owned();
        text.replace_range(source.clone(), "");
        let destination = if destination > source.start {
            destination - source.len()
        } else {
            destination
        };
        let before = if destination > 0 && !text[..destination].ends_with("\n\n") {
            "\n\n"
        } else {
            ""
        };
        let after = if destination < text.len() { "\n\n" } else { "" };
        text.insert_str(destination, &format!("{before}{raw}{after}"));
        self.replace_source(&text, true);
        Ok(self.position_at(destination + before.len()))
    }
    pub fn set_kind(&mut self, at: Position, kind: BlockKind) -> Result<(), String> {
        self.set_kind_step(at, kind, true)
    }
    pub fn set_kind_step(
        &mut self,
        at: Position,
        kind: BlockKind,
        new_step: bool,
    ) -> Result<(), String> {
        let p = self.valid(at)?;
        let body_start = p.range.start;
        let line_start = self.text()[..body_start].rfind('\n').map_or(0, |i| i + 1);
        let prefix = match kind {
            BlockKind::Paragraph => String::new(),
            BlockKind::Heading(level) => format!("{} ", "=".repeat(level.clamp(1, 6))),
            BlockKind::Bullet => "- ".into(),
            BlockKind::Numbered => "+ ".into(),
        };
        // A normal paragraph can begin after a source expression on the same line.
        if !self.text()[line_start..body_start]
            .chars()
            .all(|c| c.is_whitespace() || matches!(c, '=' | '-' | '+' | '.' | '0'..='9'))
        {
            return Err("Change this block in Source.".into());
        }
        self.patch(line_start..body_start, &prefix, new_step);
        Ok(())
    }
    fn patch_body(&mut self, range: Range<usize>, new: &str, new_step: bool) {
        if let Some((local, insert)) = minimal_patch(&self.text()[range.clone()], new) {
            self.patch(
                range.start + local.start..range.start + local.end,
                &insert,
                new_step,
            );
        }
    }
    fn project(&mut self) {
        let (paragraphs, blocks) = project(&self.source);
        self.paragraphs = paragraphs;
        self.blocks = blocks;
    }
}

/// Smallest single UTF-8-boundary patch. Does not split a multibyte character.
pub fn minimal_patch(old: &str, new: &str) -> Option<(Range<usize>, String)> {
    if old == new {
        return None;
    }
    let prefix = old
        .chars()
        .zip(new.chars())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum::<usize>();
    let suffix = old[prefix..]
        .chars()
        .rev()
        .zip(new[prefix..].chars().rev())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum::<usize>();
    Some((
        prefix..old.len() - suffix,
        new[prefix..new.len() - suffix].to_owned(),
    ))
}

fn escape(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        if matches!(
            c,
            '\\' | '*'
                | '_'
                | '#'
                | '$'
                | '@'
                | '['
                | ']'
                | '<'
                | '>'
                | '`'
                | '='
                | '-'
                | '+'
                | '/'
                | '~'
                | '"'
                | '\''
        ) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

fn slice(nodes: &[Inline], source: &str, from: usize, to: usize, remove: Option<Mark>) -> String {
    let mut out = String::new();
    let mut at = 0;
    for node in nodes {
        let end = at + node.len;
        if from < end && to > at {
            let start = from.saturating_sub(at);
            let stop = (to - at).min(node.len);
            let boundary_style =
                matches!(node.kind, InlineKind::Styled(..)) && (from == at || to == end);
            if start == 0 && stop == node.len && remove.is_none() && !boundary_style {
                out.push_str(&source[node.range.clone()]);
            } else {
                match &node.kind {
                    InlineKind::Text(glyphs) => out
                        .push_str(&source[glyphs[start].source.start..glyphs[stop - 1].source.end]),
                    InlineKind::Atom(_) => out.push_str(&source[node.range.clone()]),
                    InlineKind::Styled(mark, children, _) => {
                        let inner = slice(children, source, start, stop, remove);
                        if remove == Some(*mark) {
                            out.push_str(&inner)
                        } else {
                            out.push_str(&mark.wrap(&inner));
                        }
                    }
                }
            }
        }
        at = end;
    }
    out
}

fn edit_nodes(nodes: &[Inline], source: &str, from: usize, to: usize, insert: &str) -> String {
    // Choose the narrowest styled container that contains the entire edit. This
    // preserves its original delimiters and makes typing inherit its formatting.
    let mut at = 0;
    for node in nodes {
        let end = at + node.len;
        if let InlineKind::Styled(_mark, children, body_range) = &node.kind
            && from >= at
            && to <= end
            && (from < end || from == to && from == end)
        {
            let inner = edit_nodes(children, source, from - at, to - at, insert);
            let replacement = if inner.is_empty() {
                String::new()
            } else {
                format!(
                    "{}{}{}",
                    &source[node.range.start..body_range.start],
                    inner,
                    &source[body_range.end..node.range.end]
                )
            };
            let first = nodes.first().map_or(node.range.start, |n| n.range.start);
            let last = nodes.last().map_or(node.range.end, |n| n.range.end);
            return format!(
                "{}{}{}",
                &source[first..node.range.start],
                replacement,
                &source[node.range.end..last]
            );
        }
        at = end;
    }
    // Preserve exact source within untouched subtrees, balance containers at
    // selection boundaries, and let the source diff reduce this to a small patch.
    let len = nodes.iter().map(|n| n.len).sum();
    format!(
        "{}{}{}",
        slice(nodes, source, 0, from, None),
        insert,
        slice(nodes, source, to, len, None)
    )
}

// Recognize only literal strong/emph content calls. Dynamic calls stay opaque.
fn static_style(node: &SyntaxNode, start: usize) -> Option<Inline> {
    if node.kind() != SyntaxKind::FuncCall {
        return None;
    }
    let text = node.full_text();
    let mark = if text.starts_with("strong[") {
        Mark::Bold
    } else if text.starts_with("emph[") {
        Mark::Italic
    } else {
        return None;
    };
    fn body(node: &SyntaxNode, start: usize) -> Option<(&SyntaxNode, usize)> {
        if node.kind() == SyntaxKind::Markup {
            return Some((node, start));
        }
        let mut at = start;
        for child in node.children() {
            if let Some(found) = body(child, at) {
                return Some(found);
            }
            at += child.len();
        }
        None
    }
    let (body, offset) = body(node, start)?;
    let prefix = if mark == Mark::Bold {
        "strong["
    } else {
        "emph["
    };
    if offset != start + prefix.len() || offset + body.len() + 1 != start + node.len() {
        return None;
    }
    let children = collect_inline(body, offset);
    let len = children.iter().map(|n| n.len).sum();
    Some(Inline {
        range: start..start + node.len(),
        kind: InlineKind::Styled(mark, children, offset..offset + body.len()),
        len,
    })
}

fn collect_inline(node: &SyntaxNode, start: usize) -> Vec<Inline> {
    let mut children = node.children().peekable();
    let mut at = start;
    let mut out = vec![];
    while let Some(child) = children.next() {
        if child.kind() == SyntaxKind::Hash
            && children
                .peek()
                .is_some_and(|n| static_style(n, at + child.len()).is_some())
        {
            let next = children.next().unwrap();
            let mut styled = static_style(next, at + child.len()).unwrap();
            styled.range.start = at;
            at += child.len() + next.len();
            out.push(styled);
        } else {
            out.push(inline(child, at));
            at += child.len();
        }
    }
    out
}

fn inline(node: &SyntaxNode, start: usize) -> Inline {
    let range = start..start + node.len();
    let kind = match node.kind() {
        SyntaxKind::Markup | SyntaxKind::Strong | SyntaxKind::Emph => {
            let mark = if node.kind() == SyntaxKind::Strong {
                Mark::Bold
            } else {
                Mark::Italic
            };
            let mut children = vec![];
            let mut at = start;
            let mut body = range.clone();
            for child in node.children() {
                if child.kind() == SyntaxKind::Markup {
                    body = at..at + child.len();
                    children = collect_inline(child, at);
                }
                at += child.len();
            }
            InlineKind::Styled(mark, children, body)
        }
        SyntaxKind::Text
        | SyntaxKind::Space
        | SyntaxKind::SmartQuote
        | SyntaxKind::Escape
        | SyntaxKind::Shorthand
        | SyntaxKind::Linebreak => {
            let text = if let Some(escape) = node.cast::<ast::Escape>() {
                escape.get().to_string()
            } else if let Some(short) = node.cast::<ast::Shorthand>() {
                short.get().to_string()
            } else if node.kind() == SyntaxKind::Linebreak {
                "\n".into()
            } else if node.kind() == SyntaxKind::Space && node.leaf_text().contains('\n') {
                " ".into()
            } else {
                node.leaf_text().to_string()
            };
            let literal = text == node.leaf_text().as_str();
            InlineKind::Text(
                text.char_indices()
                    .map(|(i, c)| Glyph {
                        text: c,
                        source: if literal {
                            start + i..start + i + c.len_utf8()
                        } else {
                            range.clone()
                        },
                        bold: false,
                        italic: false,
                        atom: None,
                    })
                    .collect(),
            )
        }
        _ => InlineKind::Atom(match node.kind() {
            SyntaxKind::Ref => node.full_text().to_string(),
            SyntaxKind::Equation => node.full_text().to_string(),
            SyntaxKind::Raw => node
                .cast::<ast::Raw>()
                .map(|raw| {
                    raw.lines()
                        .map(|line| line.get().to_string())
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_else(|| node.full_text().to_string()),
            SyntaxKind::LineComment | SyntaxKind::BlockComment => "Comment".into(),
            _ => format!("{:?}", node.kind()),
        }),
    };
    let len = match &kind {
        InlineKind::Text(g) => g.len(),
        InlineKind::Styled(_, children, _) => children.iter().map(|n| n.len).sum(),
        InlineKind::Atom(_) => 1,
    };
    Inline { range, kind, len }
}

fn glyphs(nodes: &[Inline], bold: bool, italic: bool, out: &mut Vec<Glyph>) {
    for n in nodes {
        match &n.kind {
            InlineKind::Text(gs) => {
                for g in gs {
                    let mut g = g.clone();
                    g.bold = bold;
                    g.italic = italic;
                    out.push(g);
                }
            }
            InlineKind::Styled(mark, children, _) => glyphs(
                children,
                bold || *mark == Mark::Bold,
                italic || *mark == Mark::Italic,
                out,
            ),
            InlineKind::Atom(label) => out.push(Glyph {
                text: '\u{fffc}',
                source: n.range.clone(),
                bold,
                italic,
                atom: Some(label.clone()),
            }),
        }
    }
}

fn project(source: &Source) -> (Vec<Paragraph>, Vec<Block>) {
    let mut ps = vec![];
    let mut blocks = vec![];
    let mut pending = vec![];
    let mut at = 0;
    fn flush(
        ps: &mut Vec<Paragraph>,
        blocks: &mut Vec<Block>,
        nodes: &mut Vec<Inline>,
        kind: BlockKind,
        empty_at: Option<usize>,
    ) {
        if nodes.is_empty() && empty_at.is_none() {
            return;
        }
        // Formatting syntax may contain no glyphs; keep its source as an object.
        let start = nodes
            .first()
            .map_or(empty_at.unwrap_or(0), |n| n.range.start);
        let end = nodes.last().map_or(start, |n| n.range.end);
        let nodes = std::mem::take(nodes);
        let mut gs = vec![];
        glyphs(&nodes, false, false, &mut gs);
        blocks.push(Block::Editable(ps.len()));
        ps.push(Paragraph {
            kind,
            range: start..end,
            glyphs: gs,
            nodes,
        });
    }
    let mut top = source.root().children().peekable();
    while let Some(node) = top.next() {
        let end = at + node.len();
        match node.kind() {
            SyntaxKind::Parbreak => {
                let leading = source.text()[at..end]
                    .chars()
                    .take_while(|c| *c != '\n' && *c != '\r')
                    .map(char::len_utf8)
                    .sum::<usize>();
                if leading > 0 && !pending.is_empty() {
                    let gs: Vec<_> = source.text()[at..at + leading]
                        .char_indices()
                        .map(|(i, text)| Glyph {
                            text,
                            source: at + i..at + i + text.len_utf8(),
                            bold: false,
                            italic: false,
                            atom: None,
                        })
                        .collect();
                    pending.push(Inline {
                        range: at..at + leading,
                        len: gs.len(),
                        kind: InlineKind::Text(gs),
                    });
                }
                let empty = if ps.is_empty() && at == 0 {
                    Some(0)
                } else {
                    None
                };
                flush(
                    &mut ps,
                    &mut blocks,
                    &mut pending,
                    BlockKind::Paragraph,
                    empty,
                );
                // Each additional GUI paragraph split adds two newlines.
                // Keep its empty insertion slot instead of moving the caret
                // into the next nonempty paragraph on Return.
                let newlines: Vec<_> = source.text()[at..end]
                    .char_indices()
                    .filter_map(|(i, c)| (c == '\n').then_some(at + i + 1))
                    .collect();
                let breaks = newlines.len().div_ceil(2);
                for extra in 1..breaks {
                    let slot = newlines[extra * 2 - 1];
                    flush(
                        &mut ps,
                        &mut blocks,
                        &mut pending,
                        BlockKind::Paragraph,
                        Some(slot),
                    );
                }
                // A trailing blank paragraph needs a place to put its caret.
                if end == source.text().len() {
                    flush(
                        &mut ps,
                        &mut blocks,
                        &mut pending,
                        BlockKind::Paragraph,
                        Some(end),
                    );
                }
            }
            SyntaxKind::Heading | SyntaxKind::ListItem | SyntaxKind::EnumItem => {
                flush(
                    &mut ps,
                    &mut blocks,
                    &mut pending,
                    BlockKind::Paragraph,
                    None,
                );
                let kind = match node.kind() {
                    SyntaxKind::Heading => BlockKind::Heading(
                        node.children()
                            .find(|n| n.kind() == SyntaxKind::HeadingMarker)
                            .map_or(1, |n| n.len()),
                    ),
                    SyntaxKind::ListItem => BlockKind::Bullet,
                    _ => BlockKind::Numbered,
                };
                let mut offset = at;
                let mut body_start = end;
                for child in node.children() {
                    if child.kind() == SyntaxKind::Markup {
                        body_start = offset;
                        pending = collect_inline(child, offset);
                    }
                    offset += child.len();
                }
                if pending.is_empty() {
                    let line_end = source.text()[body_start..]
                        .find('\n')
                        .map_or(source.text().len(), |i| body_start + i);
                    if source.text()[body_start..line_end]
                        .chars()
                        .all(char::is_whitespace)
                    {
                        body_start = line_end;
                    }
                }
                // Typst's block node omits trailing spaces on its line.
                // They still belong to the GUI insertion range: otherwise
                // typing the next word puts it before the space just entered.
                let tail = pending.last().map_or(body_start, |n| n.range.end);
                let line_end = source.text()[tail..]
                    .find('\n')
                    .map_or(source.text().len(), |i| tail + i);
                if tail < line_end
                    && source.text()[tail..line_end]
                        .chars()
                        .all(|c| c == ' ' || c == '\t')
                {
                    let gs: Vec<_> = source.text()[tail..line_end]
                        .char_indices()
                        .map(|(i, text)| Glyph {
                            text,
                            source: tail + i..tail + i + text.len_utf8(),
                            bold: false,
                            italic: false,
                            atom: None,
                        })
                        .collect();
                    pending.push(Inline {
                        range: tail..line_end,
                        len: gs.len(),
                        kind: InlineKind::Text(gs),
                    });
                }
                flush(&mut ps, &mut blocks, &mut pending, kind, Some(body_start));
            }
            SyntaxKind::Hash
                if top
                    .peek()
                    .is_some_and(|next| static_style(next, at + 1).is_some()) =>
            {
                let next = top.next().unwrap();
                let mut styled = static_style(next, at + node.len()).unwrap();
                styled.range.start = at;
                pending.push(styled);
                at = end + next.len();
                continue;
            }
            SyntaxKind::Hash => {
                flush(
                    &mut ps,
                    &mut blocks,
                    &mut pending,
                    BlockKind::Paragraph,
                    None,
                );
                blocks.push(Block::Source {
                    range: at..end,
                    kind: "Typst".into(),
                });
            }
            SyntaxKind::Text
            | SyntaxKind::Strong
            | SyntaxKind::Emph
            | SyntaxKind::SmartQuote
            | SyntaxKind::Escape
            | SyntaxKind::Shorthand
            | SyntaxKind::Linebreak
            | SyntaxKind::Ref
            | SyntaxKind::Equation
            | SyntaxKind::Raw
            | SyntaxKind::Link
            | SyntaxKind::Label
            | SyntaxKind::BlockComment => {
                pending.push(inline(node, at));
            }
            SyntaxKind::Space => {
                if pending.is_empty() && ps.last().is_some_and(|p| p.range.end > at) {
                    at = end;
                    continue;
                }
                if !pending.is_empty()
                    && node.leaf_text().contains('\n')
                    && top.peek().is_none_or(|n| {
                        matches!(
                            n.kind(),
                            SyntaxKind::Heading | SyntaxKind::ListItem | SyntaxKind::EnumItem
                        )
                    })
                {
                    let leading = node
                        .leaf_text()
                        .chars()
                        .take_while(|c| *c != '\n' && *c != '\r')
                        .map(char::len_utf8)
                        .sum::<usize>();
                    if leading > 0 {
                        let gs: Vec<_> = source.text()[at..at + leading]
                            .char_indices()
                            .map(|(i, text)| Glyph {
                                text,
                                source: at + i..at + i + text.len_utf8(),
                                bold: false,
                                italic: false,
                                atom: None,
                            })
                            .collect();
                        pending.push(Inline {
                            range: at..at + leading,
                            len: gs.len(),
                            kind: InlineKind::Text(gs),
                        });
                    }
                    flush(
                        &mut ps,
                        &mut blocks,
                        &mut pending,
                        BlockKind::Paragraph,
                        None,
                    );
                } else if !pending.is_empty()
                    || !node.leaf_text().contains('\n')
                        && !top.peek().is_some_and(|n| n.kind() == SyntaxKind::Hash)
                {
                    pending.push(inline(node, at));
                }
            }
            _ => {
                flush(
                    &mut ps,
                    &mut blocks,
                    &mut pending,
                    BlockKind::Paragraph,
                    None,
                );
                if let Some(Block::Source { range, .. }) = blocks
                    .last_mut()
                    .filter(|b| matches!(b, Block::Source { range, .. } if range.end == at))
                {
                    range.end = end;
                } else {
                    blocks.push(Block::Source {
                        range: at..end,
                        kind: format!("{:?}", node.kind()),
                    });
                }
            }
        }
        at = end;
    }
    flush(
        &mut ps,
        &mut blocks,
        &mut pending,
        BlockKind::Paragraph,
        None,
    );
    if ps.is_empty() {
        flush(
            &mut ps,
            &mut blocks,
            &mut pending,
            BlockKind::Paragraph,
            Some(source.text().len()),
        );
    }
    let mut grouped = Vec::with_capacity(blocks.len());
    for block in blocks {
        if let Block::Source { range: next, .. } = &block
            && let Some(Block::Source { range, kind }) = grouped.last_mut()
            && source.text()[range.end..next.start]
                .chars()
                .all(char::is_whitespace)
        {
            range.end = next.end;
            *kind = "Typst source".into();
        } else {
            grouped.push(block);
        }
    }
    (ps, grouped)
}

/// Disjoint syntax runs for a source editor, using Typst's own highlight tags.
pub fn highlights(text: &str) -> Vec<(Range<usize>, typst_syntax::Tag)> {
    fn visit(
        node: typst_syntax::LinkedNode<'_>,
        parent: Option<typst_syntax::Tag>,
        out: &mut Vec<(Range<usize>, typst_syntax::Tag)>,
    ) {
        let tag = typst_syntax::highlight(&node).or(parent);
        if node.get().children().next().is_none() {
            if let Some(tag) = tag {
                out.push((node.range(), tag));
            }
        } else {
            for child in node.children() {
                visit(child, tag, out);
            }
        }
    }
    let root = typst_syntax::parse(text);
    let mut out = vec![];
    visit(typst_syntax::LinkedNode::new(&root), None, &mut out);
    out
}
pub use typst_syntax::Tag as HighlightTag;
