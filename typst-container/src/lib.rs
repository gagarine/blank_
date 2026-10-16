//! Bounded cached-PDF access for sandboxed Quick Look extensions.
//! No compiler, subprocess, package cache or network access.
use std::ffi::{CStr, c_char};
use std::fs;
use std::io::Read;
use std::path::Path;
use zip::ZipArchive;
pub const MAX_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_FILES: usize = 10_000;
pub const MAX_PREVIEW: u64 = 32 * 1024 * 1024;
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
pub fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && !path.contains(['\\', ':', '\0'])
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

pub fn preview_path<'a>(metadata: &'a toml::Value, entry: &str) -> Option<&'a str> {
    let info = metadata.get("blank_")?;
    if info.get("version")?.as_integer()? != 1 {
        return None;
    }
    info.get("preview")?
        .as_str()
        .filter(|p| valid_path(p) && *p != entry)
}

// Reads only the cached member, never compiling or unpacking the project.
pub fn cached_preview(source: &Path) -> Result<Vec<u8>> {
    let file = fs::File::open(source)?;
    if file.metadata()?.len() > MAX_BYTES {
        return Err("Bundle exceeds size limit".into());
    }
    let mut archive = ZipArchive::new(file)?;
    if archive.len() > MAX_FILES {
        return Err("Too many project members".into());
    }
    let metadata: toml::Value = std::str::from_utf8(archive.comment())?.parse()?;
    let entry = metadata
        .get("entrypoint")
        .and_then(toml::Value::as_str)
        .ok_or("Missing entrypoint")?;
    if !valid_path(entry) || !entry.to_lowercase().ends_with(".typ") {
        return Err("Invalid entrypoint".into());
    }
    archive.by_name(entry)?;
    let path = preview_path(&metadata, entry)
        .ok_or("No saved preview. Open and save this document in blank_ to generate one.")?;
    let mut member = archive.by_name(path)?;
    if member.size() > MAX_PREVIEW {
        return Err("Saved preview exceeds size limit".into());
    }
    let mut data = Vec::new();
    (&mut member).take(MAX_PREVIEW + 1).read_to_end(&mut data)?;
    if data.len() as u64 != member.size() || !data.starts_with(b"%PDF-") {
        return Err("Invalid saved preview".into());
    }
    Ok(data)
}

/// Returns an owned byte buffer, or null. Only blank_container_free may release it.
/// # Safety
/// path is a NUL-terminated UTF-8 filesystem path; length points to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn blank_container_preview(
    path: *const c_char,
    length: *mut usize,
) -> *mut u8 {
    if length.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *length = 0;
    }
    if path.is_null() {
        return std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(|| {
        let path = unsafe { CStr::from_ptr(path) }.to_str().ok()?;
        cached_preview(Path::new(path)).ok()
    });
    match result {
        Ok(Some(data)) => {
            let data = data.into_boxed_slice();
            unsafe {
                *length = data.len();
            }
            Box::into_raw(data) as *mut u8
        }
        _ => std::ptr::null_mut(),
    }
}
/// # Safety
/// data and length must be the exact result of blank_container_preview, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn blank_container_free(data: *mut u8, length: usize) {
    if !data.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                data, length,
            )));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::io::Write;
    #[test]
    fn ffi_owns_and_releases_only_the_cached_bytes() {
        let path =
            std::env::temp_dir().join(format!("blank-container-{}.typz", std::process::id()));
        let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        writer
            .set_comment(
                "entrypoint = 'main.typ'\n[blank_]\nversion = 1\npreview = 'preview.pdf'\n",
            )
            .unwrap();
        writer
            .start_file("main.typ", zip::write::SimpleFileOptions::default())
            .unwrap();
        writer.write_all(b"#invalid(").unwrap();
        writer
            .start_file("preview.pdf", zip::write::SimpleFileOptions::default())
            .unwrap();
        writer.write_all(b"%PDF-1.7\nSaved render").unwrap();
        fs::write(&path, writer.finish().unwrap().into_inner()).unwrap();
        let cpath = CString::new(path.to_str().unwrap()).unwrap();
        let mut length = 0;
        unsafe {
            let bytes = blank_container_preview(cpath.as_ptr(), &mut length);
            assert!(!bytes.is_null());
            assert_eq!(
                std::slice::from_raw_parts(bytes, length),
                b"%PDF-1.7\nSaved render"
            );
            blank_container_free(bytes, length);
        }
        fs::write(&path, b"Damaged archive").unwrap();
        unsafe {
            assert!(blank_container_preview(cpath.as_ptr(), &mut length).is_null());
            assert_eq!(length, 0);
            length = 17;
            assert!(blank_container_preview(std::ptr::null(), &mut length).is_null());
            assert_eq!(length, 0);
            assert!(blank_container_preview(cpath.as_ptr(), std::ptr::null_mut()).is_null());
            blank_container_free(std::ptr::null_mut(), 0);
        }
        fs::remove_file(path).unwrap();
    }
}
