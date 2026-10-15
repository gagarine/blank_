//! Interoperable .typz ZIP containers. No app metadata is stored in the project.
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{Cursor, Read, Write};
use std::path::Path;
use unicode_normalization::UnicodeNormalization;
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

const MAX_BYTES: u64 = 256 * 1024 * 1024;
const MAX_FILES: usize = 10_000;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && !path.contains(['\\', ':', '\0'])
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

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
    Ok((entry, files))
}

fn encode(entry: &str, files: &BTreeMap<String, Vec<u8>>) -> Result<Vec<u8>> {
    if !valid_path(entry) || !entry.to_lowercase().ends_with(".typ") || !files.contains_key(entry) {
        return Err("Invalid .typz entrypoint.".into());
    }
    if files.len() > MAX_FILES || files.values().map(|d| d.len() as u64).sum::<u64>() > MAX_BYTES {
        return Err("The .typz project exceeds 10,000 files or 256 MiB.".into());
    }
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let mut metadata = toml::map::Map::new();
    metadata.insert("entrypoint".into(), toml::Value::String(entry.into()));
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
            if args.len() != 4 {
                return Err("Usage: --typz-read archive destination".into());
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
            Ok(entry)
        })()),
        Some("--typz-write") => Some((|| {
            if args.len() != 5 {
                return Err("Usage: --typz-write root entry archive".into());
            }
            let mut files = BTreeMap::new();
            let root = Path::new(&args[2]);
            collect(root, root, &mut files, &mut 0)?;
            let data = encode(&args[3], &files)?;
            fs::write(&args[4], data)?;
            Ok(args[3].clone())
        })()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
