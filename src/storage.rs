//! Preferences and atomic recovery journals, independent of the document history.
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub font: String,
    pub size: f32,
    pub background: [u8; 3],
    pub ink: [u8; 3],
    pub paragraph_focus: bool,
    pub typewriter: bool,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            font: "Iowan Old Style".into(),
            size: 18.0,
            background: [255; 3],
            ink: [52, 58, 55],
            paragraph_focus: false,
            typewriter: false,
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Draft {
    pub path: Option<PathBuf>,
    pub text: String,
    pub disk_text: String,
    pub bookmark: usize,
    #[serde(default)]
    pub files: Vec<DraftFile>,
    #[serde(default)]
    pub assets: Vec<Asset>,
    #[serde(default)]
    pub entry: Option<PathBuf>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct DraftFile {
    pub path: PathBuf,
    pub text: String,
    pub disk_text: String,
    pub bookmark: usize,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Asset {
    pub path: PathBuf,
    pub bytes: Vec<u8>,
}
pub struct Storage {
    root: Option<PathBuf>,
    journal: Option<PathBuf>,
    _lock: Option<File>,
}
fn data_directory() -> Option<PathBuf> {
    if cfg!(test) {
        return None;
    }
    #[cfg(target_os = "macos")]
    let path =
        PathBuf::from(std::env::var_os("HOME")?).join("Library/Application Support/blank_/rust");
    #[cfg(target_os = "windows")]
    let path = PathBuf::from(std::env::var_os("APPDATA")?).join("blank_");
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    let path = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".local/share")))?
        .join("blank_");
    Some(path)
}
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Missing destination folder")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut file = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    file.write_all(bytes)
        .and_then(|()| file.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    file.persist(path).map_err(|e| e.to_string())?;
    Ok(())
}
impl Storage {
    pub fn new() -> Self {
        Self::at(data_directory())
    }
    fn at(root: Option<PathBuf>) -> Self {
        let mut storage = Self {
            root,
            journal: None,
            _lock: None,
        };
        if let Some(root) = &storage.root {
            let folder = root.join("recovery");
            if fs::create_dir_all(&folder).is_ok()
                && let Ok(file) = tempfile::NamedTempFile::new_in(folder)
                && let Ok((lock, path)) = file.keep()
                && lock.try_lock().is_ok()
            {
                storage.journal = Some(path.with_extension("json"));
                storage._lock = Some(lock);
            }
        }
        storage
    }
    pub fn preferences(&self) -> Preferences {
        let mut prefs: Preferences = self
            .root
            .as_ref()
            .and_then(|root| fs::read(root.join("settings.json")).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        if !prefs.size.is_finite() {
            prefs.size = 18.0;
        }
        prefs.size = prefs.size.clamp(12.0, 32.0);
        prefs
    }
    pub fn save_preferences(&self, prefs: &Preferences) -> Result<(), String> {
        if let Some(root) = &self.root {
            atomic_write(
                &root.join("settings.json"),
                &serde_json::to_vec(prefs).map_err(|e| e.to_string())?,
            )?;
        }
        Ok(())
    }
    pub fn checkpoint(&self, draft: &Draft) -> Result<(), String> {
        if let Some(path) = &self.journal {
            atomic_write(path, &serde_json::to_vec(draft).map_err(|e| e.to_string())?)?;
        }
        Ok(())
    }
    pub fn clear(&self) {
        if let Some(path) = &self.journal {
            let _ = fs::remove_file(path);
        }
    }
    pub fn recoverable(&self) -> Vec<(PathBuf, Draft)> {
        let Some(root) = &self.root else {
            return vec![];
        };
        let Ok(entries) = fs::read_dir(root.join("recovery")) else {
            return vec![];
        };
        entries
            .filter_map(Result::ok)
            .filter_map(|entry| {
                let path = entry.path();
                if path.extension()?.to_str()? != "json" || self.journal.as_ref() == Some(&path) {
                    return None;
                }
                let lock_path = path.with_extension("");
                // An open window holds this lock. Its draft is never offered for recovery.
                let lock = File::options()
                    .read(true)
                    .write(true)
                    .open(lock_path)
                    .ok()?;
                lock.try_lock().ok()?;
                let draft = serde_json::from_slice(&fs::read(&path).ok()?).ok()?;
                Some((path, draft))
            })
            .collect()
    }
    pub fn discard_recovery(path: &Path) {
        let _ = fs::remove_file(path);
        let _ = fs::remove_file(path.with_extension(""));
    }
}
impl Drop for Storage {
    fn drop(&mut self) {
        if let Some(journal) = &self.journal
            && !journal.exists()
        {
            let _ = fs::remove_file(journal.with_extension(""));
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_excludes_live_windows_and_survives_an_abrupt_session_end() {
        let folder = tempfile::tempdir().unwrap();
        let first = Storage::at(Some(folder.path().to_owned()));
        let second = Storage::at(Some(folder.path().to_owned()));
        first
            .checkpoint(&Draft {
                path: None,
                text: "Unsaved é".into(),
                disk_text: String::new(),
                bookmark: 10,
                files: vec![],
                assets: vec![],
                entry: None,
            })
            .unwrap();
        assert!(second.recoverable().is_empty());
        drop(first);
        let recovered = second.recoverable();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].1.text, "Unsaved é");
        Storage::discard_recovery(&recovered[0].0);
        assert!(second.recoverable().is_empty());
    }
}
