//! Literal includes retain independent source documents and histories.
use blank_document::Document;
use egui_richedit::Selection;
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};
pub struct File {
    pub path: PathBuf,
    pub document: Option<Document>,
    pub disk_text: String,
    pub bookmark: usize,
    pub selection: Option<Selection<usize>>,
}
pub struct Project {
    pub root: PathBuf,
    pub entry: PathBuf,
    pub files: Vec<File>,
    pub active: usize,
}
impl Project {
    pub fn open(entry: &Path, text: &str) -> Result<Self, String> {
        let entry = entry.canonicalize().map_err(|e| e.to_string())?;
        let root = entry.parent().ok_or("Missing project folder")?.to_owned();
        let mut files = vec![File {
            path: entry.clone(),
            document: None,
            disk_text: text.into(),
            bookmark: 0,
            selection: None,
        }];
        let mut seen = HashSet::from([entry.clone()]);
        fn visit(
            root: &Path,
            parent: &Path,
            text: &str,
            files: &mut Vec<File>,
            seen: &mut HashSet<PathBuf>,
        ) -> Result<(), String> {
            for (_, literal) in blank_document::objects::includes(text) {
                let path = parent
                    .join(literal)
                    .canonicalize()
                    .map_err(|e| e.to_string())?;
                if !path.starts_with(root) {
                    return Err("An included file resolves outside the project folder.".into());
                }
                if !seen.insert(path.clone()) {
                    continue;
                }
                let text = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
                files.push(File {
                    path: path.clone(),
                    document: Some(Document::new(text.clone())),
                    disk_text: text.clone(),
                    bookmark: 0,
                    selection: None,
                });
                visit(root, path.parent().unwrap(), &text, files, seen)?;
            }
            Ok(())
        }
        visit(&root, &root, text, &mut files, &mut seen)?;
        Ok(Self {
            root,
            entry,
            files,
            active: 0,
        })
    }
    pub fn texts(&self, current: &Document) -> std::collections::HashMap<String, String> {
        self.files
            .iter()
            .enumerate()
            .map(|(index, file)| {
                (
                    file.path
                        .strip_prefix(&self.root)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                    if index == self.active {
                        current.text().to_owned()
                    } else {
                        file.document.as_ref().unwrap().text().to_owned()
                    },
                )
            })
            .collect()
    }
}
impl crate::App {
    pub(crate) fn recovery_draft(&self) -> Result<crate::storage::Draft, String> {
        let mut files = vec![];
        if let Some(project) = &self.project {
            for (index, file) in project.files.iter().enumerate() {
                if index != project.active {
                    files.push(crate::storage::DraftFile {
                        path: file.path.clone(),
                        text: file.document.as_ref().unwrap().text().into(),
                        disk_text: file.disk_text.clone(),
                        bookmark: file.bookmark,
                    });
                }
            }
        }
        fn assets(
            root: &Path,
            at: &Path,
            out: &mut Vec<crate::storage::Asset>,
        ) -> Result<(), String> {
            for entry in std::fs::read_dir(at).map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                let kind = entry.file_type().map_err(|e| e.to_string())?;
                if kind.is_dir() {
                    assets(root, &entry.path(), out)?;
                } else if kind.is_file() {
                    out.push(crate::storage::Asset {
                        path: entry.path().strip_prefix(root).unwrap().to_owned(),
                        bytes: std::fs::read(entry.path()).map_err(|e| e.to_string())?,
                    });
                }
            }
            Ok(())
        }
        let mut imported = vec![];
        assets(self.assets.path(), self.assets.path(), &mut imported)?;
        Ok(crate::storage::Draft {
            path: self.path.clone(),
            text: self.model.document.text().into(),
            disk_text: self.disk_text.clone(),
            bookmark: self.bookmark,
            files,
            assets: imported,
            entry: self.project.as_ref().map(|p| p.entry.clone()),
        })
    }
    pub(crate) fn restore_draft(
        &mut self,
        draft: &crate::storage::Draft,
        ctx: &eframe::egui::Context,
    ) {
        if let Some(entry) = &draft.entry
            && let Some(root) = entry.parent()
        {
            let mut files = vec![File {
                path: draft.path.clone().unwrap_or_else(|| entry.clone()),
                document: None,
                disk_text: draft.disk_text.clone(),
                bookmark: draft.bookmark,
                selection: None,
            }];
            for file in &draft.files {
                if !file.path.starts_with(root) {
                    self.error = Some("Recovery contains a file outside its project.".into());
                    continue;
                }
                files.push(File {
                    path: file.path.clone(),
                    document: Some(Document::new(file.text.clone())),
                    disk_text: file.disk_text.clone(),
                    bookmark: file.bookmark,
                    selection: None,
                });
            }
            self.project = Some(Project {
                root: root.to_owned(),
                entry: entry.clone(),
                files,
                active: 0,
            });
        }
        for asset in &draft.assets {
            if asset
                .path
                .components()
                .any(|part| !matches!(part, std::path::Component::Normal(_)))
            {
                self.error = Some("Recovery contains an invalid asset path.".into());
                continue;
            }
            if let Err(error) =
                crate::storage::atomic_write(&self.assets.path().join(&asset.path), &asset.bytes)
            {
                self.error = Some(error);
            }
        }
        self.editor
            .select(Selection::caret(crate::editor::editor_position(
                self.model.document.position_at(self.bookmark),
            )));
        self.journal_revision = None;
        self.restore_editor_focus(ctx);
    }
    pub(crate) fn switch_file(&mut self, index: usize, ctx: &eframe::egui::Context) {
        let Some(project) = &mut self.project else {
            return;
        };
        if index >= project.files.len() || index == project.active {
            return;
        }
        let previous = project.active;
        let replacement = project.files[index].document.take().unwrap();
        project.files[previous].document =
            Some(std::mem::replace(&mut self.model.document, replacement));
        project.files[previous].disk_text = self.disk_text.clone();
        project.files[previous].bookmark = self.bookmark;
        project.files[previous].selection = self.editor.selection().cloned();
        project.active = index;
        let file = &project.files[index];
        self.path = Some(file.path.clone());
        self.disk_text = file.disk_text.clone();
        self.bookmark = file.bookmark;
        self.source_buffer = self.model.document.text().to_owned();
        self.seen_revision = self.model.document.revision;
        self.journal_revision = None;
        self.conflict = false;
        self.layouts.clear();
        self.access_positions.clear();
        self.source_map.clear();
        self.find.cache = None;
        self.find.matches.clear();
        self.editor.document_replaced();
        self.editor
            .select(file.selection.clone().unwrap_or_else(|| {
                Selection::caret(crate::editor::editor_position(
                    self.model.document.position_at(self.bookmark),
                ))
            }));
        self.source_focus = true;
        self.source_new_step = true;
        self.source_last_selection = None;
        self.source_layout = None;
        self.pages.clear();
        self.page_ratios.clear();
        self.pending_pages.clear();
        self.pdf.clear();
        self.objects.clear();
        self.pending_objects.clear();
        self.failed_objects.clear();
        self.request_id += 1;
        self.requested_revision = None;
        self.preview_revision = None;
        self.page_revision = None;
        self.compiling = false;
        self.last_edit = std::time::Instant::now() - std::time::Duration::from_secs(1);
        self.restore_editor_focus(ctx);
    }
    pub(crate) fn save_other_files(&mut self) -> Result<(), String> {
        let Some(project) = &mut self.project else {
            return Ok(());
        };
        for (index, file) in project.files.iter_mut().enumerate() {
            if index == project.active {
                continue;
            }
            let text = file.document.as_ref().unwrap().text();
            if text == file.disk_text {
                continue;
            }
            if std::fs::read_to_string(&file.path).ok().as_deref() != Some(&file.disk_text) {
                return Err(format!(
                    "{} changed on disk. Its edits remain in memory.",
                    file.path.display()
                ));
            }
            crate::storage::atomic_write(&file.path, text.as_bytes())?;
            file.disk_text = text.to_owned();
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn literal_includes_are_loaded_once_and_symlinks_cannot_escape() {
        let folder = tempfile::tempdir().unwrap();
        std::fs::create_dir(folder.path().join("chapters")).unwrap();
        std::fs::write(
            folder.path().join("main.typ"),
            "= Book\n#include \"chapters/a.typ\"\n#include \"chapters/a.typ\"",
        )
        .unwrap();
        std::fs::write(folder.path().join("chapters/a.typ"), "== Chapter\n\nCafé").unwrap();
        let project = Project::open(
            &folder.path().join("main.typ"),
            &std::fs::read_to_string(folder.path().join("main.typ")).unwrap(),
        )
        .unwrap();
        assert_eq!(project.files.len(), 2);
        assert_eq!(
            project.files[1].document.as_ref().unwrap().paragraphs[1].text(),
            "Café"
        );
        #[cfg(unix)]
        {
            let external = tempfile::NamedTempFile::new().unwrap();
            std::os::unix::fs::symlink(external.path(), folder.path().join("outside.typ")).unwrap();
            assert!(
                Project::open(&folder.path().join("main.typ"), "#include \"outside.typ\"").is_err()
            );
        }
    }
}
