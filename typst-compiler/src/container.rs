//! Interoperable .typz ZIP containers with optional, disposable Quick Look PDFs.
use base64::Engine;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{Cursor, Read, Write};
use std::path::Path;
use unicode_normalization::UnicodeNormalization;
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

use blank_container::{
    MAX_BYTES, MAX_FILES, MAX_PREVIEW, cached_preview, preview_path, valid_path,
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn key(path: &str) -> String {
    path.nfc().collect::<String>().to_lowercase()
}

fn decode(bytes: Vec<u8>) -> Result<(String, BTreeMap<String, Vec<u8>>)> {
    if bytes.len() as u64 > MAX_BYTES {
        return Err("The .typz archive exceeds 256 MiB.".into());
    }
    let mut archive = ZipArchive::new(Cursor::new(bytes))?;
    if archive.len() > MAX_FILES {
        return Err("The .typz archive contains too many files.".into());
    }
    let metadata: toml::Value = std::str::from_utf8(archive.comment())?.parse()?;
    let entry = metadata
        .get("entrypoint")
        .and_then(toml::Value::as_str)
        .filter(|path| valid_path(path) && path.to_lowercase().ends_with(".typ"))
        .ok_or("The .typz ZIP comment must specify a project-relative .typ entrypoint.")?
        .to_owned();
    let mut files = BTreeMap::new();
    let mut names = HashSet::new();
    let mut spellings = HashMap::new();
    let mut total = 0u64;
    for index in 0..archive.len() {
        let mut file = archive.by_index(index)?;
        let directory = file.is_dir();
        let name = file.name().trim_end_matches('/').to_owned();
        if !valid_path(&name) || !names.insert(key(&name)) {
            return Err("The .typz archive contains an unsafe or duplicate path.".into());
        }
        let mut prefix = String::new();
        for part in name.split('/') {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(part);
            if let Some(previous) = spellings.insert(key(&prefix), prefix.clone()) {
                if previous != prefix {
                    return Err("Ambiguous case or Unicode spelling in project paths.".into());
                }
            }
        }
        let mode = file.unix_mode().unwrap_or(0) & 0o170000;
        if mode != 0 && mode != if directory { 0o040000 } else { 0o100000 } {
            return Err("Links and special files are not supported in .typz archives.".into());
        }
        if directory {
            continue;
        }
        total = total
            .checked_add(file.size())
            .ok_or("Archive size overflow")?;
        if total > MAX_BYTES {
            return Err("The expanded .typz project exceeds 256 MiB.".into());
        }
        let mut data = Vec::new();
        (&mut file).take(MAX_BYTES + 1).read_to_end(&mut data)?;
        if data.len() as u64 != file.size() {
            return Err("Invalid ZIP member size.".into());
        }
        files.insert(name, data);
    }
    if !files.contains_key(&entry) {
        return Err("The .typz entrypoint is missing from the archive.".into());
    }
    std::str::from_utf8(&files[&entry])?;
    // Also reject file/directory collisions before writing anything.
    let file_names: HashSet<_> = files.keys().map(|name| key(name)).collect();
    for name in files.keys() {
        let mut parent = Path::new(name).parent();
        while let Some(path) = parent {
            if file_names.contains(&key(&path.to_string_lossy())) {
                return Err("Conflicting file and directory paths in .typz archive.".into());
            }
            parent = path.parent();
        }
    }
    if let Some(path) = preview_path(&metadata, &entry) {
        if files
            .get(path)
            .is_some_and(|data| data.starts_with(b"%PDF-") && data.len() as u64 <= MAX_PREVIEW)
        {
            files.remove(path);
        }
    }
    Ok((entry, files))
}

fn encode(entry: &str, files: &BTreeMap<String, Vec<u8>>) -> Result<Vec<u8>> {
    encode_preview(entry, files, None)
}

fn rendered_preview(root: &Path, entry: &str) -> Option<Vec<u8>> {
    let params = serde_json::json!({"root":root,"entry":entry,"files":{},"revision":0});
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let pdf = super::compile(params).ok().and_then(|value| {
            value["pdf"]
                .as_str()
                .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
        });
        let _ = sender.send(pdf);
    });
    // A broken/slow document must still save. This short-lived CLI exits after
    // encoding, stopping any unfinished render; browsing never calls this path.
    receiver
        .recv_timeout(std::time::Duration::from_secs(2))
        .ok()
        .flatten()
}

fn encode_preview(
    entry: &str,
    files: &BTreeMap<String, Vec<u8>>,
    preview: Option<&[u8]>,
) -> Result<Vec<u8>> {
    if !valid_path(entry) || !entry.to_lowercase().ends_with(".typ") || !files.contains_key(entry) {
        return Err("Invalid .typz entrypoint.".into());
    }
    if files.len() > MAX_FILES || files.values().map(|d| d.len() as u64).sum::<u64>() > MAX_BYTES {
        return Err("The .typz project exceeds 10,000 files or 256 MiB.".into());
    }
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let mut metadata = toml::map::Map::new();
    metadata.insert("entrypoint".into(), toml::Value::String(entry.into()));
    let preview = preview.filter(|data| {
        data.starts_with(b"%PDF-")
            && data.len() as u64 <= MAX_PREVIEW
            && files.len() < MAX_FILES
            && files.values().map(|d| d.len() as u64).sum::<u64>() + data.len() as u64 <= MAX_BYTES
    });
    let preview_name = preview.map(|_| {
        (0..)
            .map(|i| format!("blank-preview-{i}.pdf"))
            .find(|name| {
                !files
                    .keys()
                    .any(|path| key(path) == key(name) || key(path).starts_with(&(key(name) + "/")))
            })
            .unwrap()
    });
    if let Some(name) = &preview_name {
        metadata.insert(
            "blank_".into(),
            toml::Value::Table(toml::map::Map::from_iter([
                ("version".into(), toml::Value::Integer(1)),
                ("preview".into(), toml::Value::String(name.clone())),
            ])),
        );
    }
    writer.set_comment(toml::to_string(&metadata)?)?;
    for (name, data) in files {
        if !valid_path(name) {
            return Err("Unsafe project path.".into());
        }
        writer.start_file(
            name,
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated),
        )?;
        writer.write_all(data)?;
    }
    if let (Some(name), Some(data)) = (preview_name, preview) {
        writer.start_file(
            name,
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated),
        )?;
        writer.write_all(data)?;
    }
    let bytes = writer.finish()?.into_inner();
    decode(bytes.clone())?;
    Ok(bytes)
}

fn collect(
    root: &Path,
    directory: &Path,
    files: &mut BTreeMap<String, Vec<u8>>,
    total: &mut u64,
) -> Result<()> {
    for item in fs::read_dir(directory)? {
        let item = item?;
        let kind = item.file_type()?;
        if kind.is_dir() {
            collect(root, &item.path(), files, total)?;
        } else if kind.is_file() {
            *total += item.metadata()?.len();
            if *total > MAX_BYTES || files.len() >= MAX_FILES {
                return Err("Project exceeds the .typz size limit.".into());
            }
            files.insert(
                item.path()
                    .strip_prefix(root)?
                    .to_str()
                    .ok_or("Non-Unicode project filename")?
                    .to_owned(),
                fs::read(item.path())?,
            );
        } else {
            return Err("Links and special files cannot be saved in .typz archives.".into());
        }
    }
    Ok(())
}

pub fn command() -> Option<Result<String>> {
    let args: Vec<_> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--typz-read") => Some((|| {
            if args.len() != 4 && args.len() != 5 {
                return Err("Usage: --typz-read archive destination [preview-output]".into());
            }
            let source = Path::new(&args[2]);
            if fs::metadata(source)?.len() > MAX_BYTES {
                return Err("The .typz archive exceeds 256 MiB.".into());
            }
            let (entry, files) = decode(fs::read(source)?)?;
            let destination = Path::new(&args[3]);
            fs::create_dir(destination)?; // Caller supplies a fresh app-owned directory.
            for (name, data) in files {
                let target = destination.join(name);
                fs::create_dir_all(target.parent().unwrap())?;
                fs::write(target, data)?;
            }
            if let Some(output) = args.get(4) {
                if let Ok(data) = cached_preview(source) {
                    fs::write(output, data)?;
                }
            }
            Ok(entry)
        })()),
        Some("--typz-preview") => Some((|| {
            if args.len() != 4 {
                return Err("Usage: --typz-preview archive output".into());
            }
            fs::write(&args[3], cached_preview(Path::new(&args[2]))?)?;
            Ok("preview".into())
        })()),
        Some("--typz-write") => Some((|| {
            if args.len() != 5 && args.len() != 6 {
                return Err(
                    "Usage: --typz-write root entry archive [preview-pdf|--render-preview]".into(),
                );
            }
            let mut files = BTreeMap::new();
            let root = Path::new(&args[2]);
            collect(root, root, &mut files, &mut 0)?;
            let preview = match args.get(5).map(String::as_str) {
                Some("--render-preview") => rendered_preview(root, &args[3]),
                Some(file) => Some(fs::read(file)?),
                None => None,
            };
            let data = if preview.is_some() {
                encode_preview(&args[3], &files, preview.as_deref())?
            } else {
                encode(&args[3], &files)?
            };
            fs::write(&args[4], data)?;
            Ok(args[3].clone())
        })()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cached_preview_is_optional_disposable_and_never_compiles() {
        let files = BTreeMap::from([
            ("main.typ".into(), b"#intentionally-invalid(".to_vec()),
            ("blank-preview-0.pdf".into(), b"User project file".to_vec()),
        ]);
        let preview = b"%PDF-1.7\nCached render";
        let bytes = encode_preview("main.typ", &files, Some(preview)).unwrap();
        assert_eq!(decode(bytes.clone()).unwrap().1, files);
        let path = std::env::temp_dir().join(format!(
            "blank-preview-{}-{}.typz",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, bytes).unwrap();
        assert_eq!(cached_preview(&path).unwrap(), preview);
        fs::write(&path, encode("main.typ", &files).unwrap()).unwrap();
        assert!(cached_preview(&path).is_err());
        fs::write(
            &path,
            encode_preview("main.typ", &files, Some(b"not a PDF")).unwrap(),
        )
        .unwrap();
        assert!(cached_preview(&path).is_err());
        fs::remove_file(path).unwrap();
    }
    fn fixture(comment: &str, members: &[(&str, &[u8])]) -> Vec<u8> {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        writer.set_comment(comment).unwrap();
        for (name, data) in members {
            writer
                .start_file(*name, SimpleFileOptions::default())
                .unwrap();
            writer.write_all(data).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }
    #[test]
    fn round_trip_nested_unicode_entry_and_unreferenced_assets() {
        let entry = "chapters/café 日本.typ";
        let files = BTreeMap::from([
            (entry.into(), b"// untouched\nHello".to_vec()),
            ("unused.bin".into(), vec![0, 255, 1]),
        ]);
        let data = encode(entry, &files).unwrap();
        let (actual, restored) = decode(data).unwrap();
        assert_eq!(actual, entry);
        assert_eq!(restored, files);
        let external = fixture(
            "# another editor\nentrypoint = 'nested/main.typ'\n",
            &[("main.typ", b"Wrong"), ("nested/main.typ", b"Right")],
        );
        assert_eq!(decode(external).unwrap().0, "nested/main.typ");
    }
    #[test]
    fn rejects_invalid_entrypoints_paths_duplicates_and_corruption() {
        for comment in [
            "",
            "entrypoint = 3",
            "entrypoint = '../main.typ'",
            "entrypoint = '/main.typ'",
            "entrypoint = 'missing.typ'",
            "entrypoint = 'note.txt'",
        ] {
            assert!(decode(fixture(comment, &[("main.typ", b"Hi")])).is_err());
        }
        for path in [
            "../escape",
            "/absolute",
            "a/../b",
            "a\\b",
            "a:b",
            "./main.typ",
        ] {
            assert!(
                decode(fixture(
                    "entrypoint = 'main.typ'",
                    &[("main.typ", b"Hi"), (path, b"Bad")]
                ))
                .is_err()
            );
        }
        assert!(
            decode(fixture(
                "entrypoint = 'main.typ'",
                &[("main.typ", b"A"), ("MAIN.typ", b"B")]
            ))
            .is_err()
        );
        assert!(
            decode(fixture(
                "entrypoint = 'main.typ'",
                &[
                    ("main.typ", b"A"),
                    ("caf\u{e9}", b"A"),
                    ("cafe\u{301}", b"B")
                ]
            ))
            .is_err()
        );
        assert!(
            decode(fixture(
                "entrypoint = 'main.typ'",
                &[("main.typ", b"A"), ("A/x", b"A"), ("a/y", b"B")]
            ))
            .is_err()
        );
        assert!(
            decode(fixture(
                "entrypoint = 'main.typ'",
                &[("main.typ", b"A"), ("a", b"file"), ("a/b", b"child")]
            ))
            .is_err()
        );
        let mut bad = encode(
            "main.typ",
            &BTreeMap::from([("main.typ".into(), vec![1; 100])]),
        )
        .unwrap();
        bad[40] ^= 255;
        assert!(decode(bad).is_err());
    }
    #[test]
    fn rejects_symlinks_and_oversized_projects() {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        writer.set_comment("entrypoint = 'main.typ'").unwrap();
        writer
            .add_symlink("main.typ", "/etc/passwd", SimpleFileOptions::default())
            .unwrap();
        assert!(decode(writer.finish().unwrap().into_inner()).is_err());
        let files = BTreeMap::from([("main.typ".into(), vec![0; MAX_BYTES as usize + 1])]);
        assert!(encode("main.typ", &files).is_err());
    }
}
