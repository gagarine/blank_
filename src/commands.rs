//! One action registry for native menus and both keyboard command pickers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    New,
    Open,
    Save,
    SaveAs,
    Export,
    Close,
    Quit,
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    SelectAll,
    Bold,
    Italic,
    Paragraph,
    Heading1,
    Heading2,
    Heading3,
    Bullet,
    Numbered,
    Write,
    Source,
    Preview,
    Contents,
    Refresh,
    ZoomIn,
    ZoomOut,
    ActualSize,
    Palette,
    Tutorial,
}
impl Command {
    pub const ALL: &'static [Self] = &[
        Self::New,
        Self::Open,
        Self::Save,
        Self::SaveAs,
        Self::Export,
        Self::Close,
        Self::Undo,
        Self::Redo,
        Self::Cut,
        Self::Copy,
        Self::Paste,
        Self::SelectAll,
        Self::Bold,
        Self::Italic,
        Self::Paragraph,
        Self::Heading1,
        Self::Heading2,
        Self::Heading3,
        Self::Bullet,
        Self::Numbered,
        Self::Write,
        Self::Source,
        Self::Preview,
        Self::Contents,
        Self::Refresh,
        Self::ZoomIn,
        Self::ZoomOut,
        Self::ActualSize,
        Self::Palette,
        Self::Tutorial,
        Self::Quit,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::New => "New document",
            Self::Open => "Open…",
            Self::Save => "Save",
            Self::SaveAs => "Save As…",
            Self::Export => "Export PDF…",
            Self::Close => "Close window",
            Self::Quit => "Quit blank_",
            Self::Undo => "Undo",
            Self::Redo => "Redo",
            Self::Cut => "Cut",
            Self::Copy => "Copy",
            Self::Paste => "Paste",
            Self::SelectAll => "Select All",
            Self::Bold => "Bold",
            Self::Italic => "Italic",
            Self::Paragraph => "Paragraph",
            Self::Heading1 => "Heading 1",
            Self::Heading2 => "Heading 2",
            Self::Heading3 => "Heading 3",
            Self::Bullet => "Bulleted list",
            Self::Numbered => "Numbered list",
            Self::Write => "Write",
            Self::Source => "Source",
            Self::Preview => "Preview",
            Self::Contents => "Show / hide sidebar",
            Self::Refresh => "Refresh preview",
            Self::ZoomIn => "Zoom In",
            Self::ZoomOut => "Zoom Out",
            Self::ActualSize => "Actual Size",
            Self::Palette => "Commands…",
            Self::Tutorial => "Open tutorial",
        }
    }
    pub fn block(self) -> Option<blank_document::BlockKind> {
        use blank_document::BlockKind;
        Some(match self {
            Self::Paragraph => BlockKind::Paragraph,
            Self::Heading1 => BlockKind::Heading(1),
            Self::Heading2 => BlockKind::Heading(2),
            Self::Heading3 => BlockKind::Heading(3),
            Self::Bullet => BlockKind::Bullet,
            Self::Numbered => BlockKind::Numbered,
            _ => return None,
        })
    }
    pub fn formatting(self) -> bool {
        self.block().is_some() || matches!(self, Self::Bold | Self::Italic)
    }
}
#[derive(Default)]
pub struct Picker {
    pub open: bool,
    pub slash: bool,
    pub query: String,
    pub index: usize,
    pub focus: bool,
}
impl Picker {
    pub fn show(&mut self, slash: bool) {
        self.open = true;
        self.slash = slash;
        self.query.clear();
        self.index = 0;
        self.focus = true;
    }
}
