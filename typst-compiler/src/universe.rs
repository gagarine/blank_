//! Universe discovery uses the same official downloader, cache and reader lock
//! as compilation. Starter files are returned as a snapshot, never edited in cache.
use crate::packages::{Packages, cache_path, lock_file};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime};
use typst_kit::downloader::{Downloader, SystemDownloader};
use typst_syntax::package::{PackageManifest, PackageSpec, PackageVersion, VersionBound};

const INDEX_LIMIT: u64 = 16 * 1024 * 1024;
const PROJECT_LIMIT: u64 = 64 * 1024 * 1024;
const FILE_LIMIT: usize = 10_000;
const INDEX_URL: &str = "https://packages.typst.org/preview/index.json";

pub fn request(method: &str, params: Value) -> Result<Value, String> {
    if method == "universeCatalog" {
        catalog(params["refresh"].as_bool().unwrap_or(false))
    } else {
        let name = params["name"].as_str().ok_or("Missing template name")?;
        let version = params["version"]
            .as_str()
            .ok_or("Missing template version")?;
        let spec = checked_spec(name, version)?;
        let packages = Packages::new().map_err(|e| e.to_string())?;
        let root = packages
            .obtain(Path::new("/"), &spec)
            .map_err(|e| e.to_string())?;
        snapshot(root.path(), &spec)
    }
}

fn checked_spec(name: &str, version: &str) -> Result<PackageSpec, String> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        return Err("Invalid Universe package name".into());
    }
    format!("@preview/{name}:{version}")
        .parse()
        .map_err(|e| format!("{e}"))
}

fn catalog(refresh: bool) -> Result<Value, String> {
    let cache = cache_path().map_err(|e| e.to_string())?;
    let lock = lock_file(&cache).map_err(|e| e.to_string())?;
    lock.lock_shared().map_err(|e| e.to_string())?;
    fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
    catalog_at(
        &cache,
        &SystemDownloader::new("blank_/0.1 (Typst/0.15.1)"),
        refresh,
    )
}

fn catalog_at(cache: &Path, downloader: &dyn Downloader, refresh: bool) -> Result<Value, String> {
    let path = cache.join(".universe-index.json");
    let saved = bounded_read(&path, INDEX_LIMIT)
        .ok()
        .and_then(|data| parse_catalog(&data).ok());
    let fresh = fs::metadata(&path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|time| time.elapsed().ok())
        .is_some_and(|age| age < Duration::from_secs(24 * 60 * 60));
    if !refresh
        && fresh
        && let Some(templates) = saved.as_ref()
    {
        return Ok(json!({"templates":templates,"warning":null}));
    }
    let fetched = (|| {
        let (_, stream) = downloader
            .stream(&"universe-index", INDEX_URL)
            .map_err(|e| e.to_string())?;
        let mut data = Vec::new();
        stream
            .take(INDEX_LIMIT + 1)
            .read_to_end(&mut data)
            .map_err(|e| e.to_string())?;
        if data.len() as u64 > INDEX_LIMIT {
            return Err("Universe catalogue is too large".to_owned());
        }
        let templates = parse_catalog(&data)?;
        // Concurrent readers see either complete index. The shared package lock
        // also prevents Clear Package Cache from racing this write.
        let stamp = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let temp = cache.join(format!(".universe-{}-{stamp}", std::process::id()));
        let written = (|| -> std::io::Result<()> {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temp)?;
            file.write_all(&data)?;
            fs::rename(&temp, &path)
        })();
        let _ = fs::remove_file(temp);
        // A read-only cache must not prevent browsing a successful response.
        let warning = written
            .err()
            .map(|e| format!("Catalogue could not be cached: {e}"));
        Ok(json!({"templates":templates,"warning":warning}))
    })();
    match fetched {
        Ok(result) => Ok(result),
        Err(error) => saved.map(|templates| json!({"templates":templates,"warning":format!("Showing the saved catalogue. {error}")})).ok_or(error),
    }
}

fn parse_catalog(data: &[u8]) -> Result<Vec<Value>, String> {
    let records: Vec<Value> =
        serde_json::from_slice(data).map_err(|e| format!("Invalid Universe catalogue: {e}"))?;
    let mut latest = BTreeMap::<String, (PackageVersion, Value)>::new();
    for record in records {
        if !record["template"].is_object() {
            continue;
        }
        let Some(name) = record["name"].as_str() else {
            continue;
        };
        let Some(version) = record["version"].as_str() else {
            continue;
        };
        let Ok(spec) = checked_spec(name, version) else {
            continue;
        };
        if let Some(required) = record["compiler"].as_str() {
            let Ok(bound) = required.parse::<VersionBound>() else {
                continue;
            };
            if !PackageVersion::compiler().matches_ge(&bound) {
                continue;
            }
        }
        if latest
            .get(name)
            .is_some_and(|(version, _)| *version >= spec.version)
        {
            continue;
        }
        let value = json!({
            "name":name,"version":version,"description":record["description"].as_str().unwrap_or(""),
            "authors":record["authors"].as_array().cloned().unwrap_or_default(),
            "categories":record["categories"].as_array().cloned().unwrap_or_default(),
            "keywords":record["keywords"].as_array().cloned().unwrap_or_default(),
        });
        latest.insert(name.to_owned(), (spec.version, value));
    }
    if latest.is_empty() {
        return Err("Universe returned no compatible templates".into());
    }
    Ok(latest.into_values().map(|(_, value)| value).collect())
}

fn bounded_read(path: &Path, limit: u64) -> Result<Vec<u8>, String> {
    let mut data = Vec::new();
    fs::File::open(path)
        .map_err(|e| e.to_string())?
        .take(limit + 1)
        .read_to_end(&mut data)
        .map_err(|e| e.to_string())?;
    if data.len() as u64 > limit {
        return Err("Template files exceed the size limit".into());
    }
    Ok(data)
}

fn relative(path: &str, allow_root: bool) -> Result<PathBuf, String> {
    if path.is_empty() && allow_root {
        return Ok(PathBuf::new());
    }
    if path.is_empty() || path.contains('\\') || path.contains('\0') {
        return Err("Template declares an invalid project path".into());
    }
    let mut normalized = PathBuf::new();
    for part in Path::new(path).components() {
        match part {
            Component::Normal(name) => normalized.push(name),
            Component::CurDir => {}
            _ => return Err("Template declares a path outside its project".into()),
        }
    }
    if normalized.as_os_str().is_empty() && !allow_root {
        return Err("Template entry file is missing".into());
    }
    Ok(normalized)
}

fn checked_child(root: &Path, path: &Path) -> Result<PathBuf, String> {
    let mut target = root.to_owned();
    for part in path.components() {
        target.push(part);
        if fs::symlink_metadata(&target)
            .map_err(|e| e.to_string())?
            .file_type()
            .is_symlink()
        {
            return Err("Template contains a symbolic link".into());
        }
    }
    Ok(target)
}

fn snapshot(root: &Path, spec: &PackageSpec) -> Result<Value, String> {
    let manifest_path = checked_child(root, Path::new("typst.toml"))?;
    let manifest: PackageManifest = toml::from_str(
        std::str::from_utf8(&bounded_read(&manifest_path, 1024 * 1024)?)
            .map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    manifest.validate(spec).map_err(|e| e.to_string())?;
    let template = manifest
        .template
        .ok_or("This package has no starter template")?;
    let folder = checked_child(root, &relative(&template.path, true)?)?;
    let entry = relative(&template.entrypoint, false)?;
    if entry
        .extension()
        .and_then(|e| e.to_str())
        .is_none_or(|e| !e.eq_ignore_ascii_case("typ"))
    {
        return Err("Template entry must be a .typ file".into());
    }
    let mut files = BTreeMap::new();
    let mut total = 0;
    collect(&folder, &folder, &mut files, &mut total, 0)?;
    let entry = entry
        .to_str()
        .ok_or("Template has a non-Unicode entry path")?;
    if !files.contains_key(entry) {
        return Err("Template entry file is missing".into());
    }
    let documentation = ["README.md", "readme.md", "README.typ"]
        .into_iter()
        .find_map(|name| {
            let file = checked_child(root, Path::new(name)).ok()?;
            String::from_utf8(bounded_read(&file, 128 * 1024).ok()?).ok()
        });
    Ok(json!({"entry":entry,"files":files,"documentation":documentation}))
}

fn collect(
    folder: &Path,
    root: &Path,
    files: &mut BTreeMap<String, String>,
    total: &mut u64,
    depth: usize,
) -> Result<(), String> {
    if depth > 64 {
        return Err("Template folders are nested too deeply".into());
    }
    for item in fs::read_dir(folder).map_err(|e| e.to_string())? {
        let item = item.map_err(|e| e.to_string())?;
        let kind = item.file_type().map_err(|e| e.to_string())?;
        if kind.is_symlink() {
            return Err("Template contains a symbolic link".into());
        }
        if kind.is_dir() {
            collect(&item.path(), root, files, total, depth + 1)?;
        } else if kind.is_file() {
            if files.len() >= FILE_LIMIT {
                return Err("Template has too many files".into());
            }
            let path = item.path();
            let name = path
                .strip_prefix(root)
                .map_err(|e| e.to_string())?
                .to_str()
                .ok_or("Template has a non-Unicode filename")?
                .to_owned();
            relative(&name, false)?;
            let data = bounded_read(&path, PROJECT_LIMIT.saturating_sub(*total))?;
            if path.extension().is_some_and(|extension| extension == "typ") {
                std::str::from_utf8(&data).map_err(|_| "Template source is not UTF-8")?;
            }
            *total += data.len() as u64;
            files.insert(name, STANDARD.encode(data));
        } else {
            return Err("Template contains an unsupported file".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::any::Any;
    use std::io::{self, Cursor};
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };

    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "blank-universe-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn file(&self, name: &str, data: &[u8]) {
            let path = self.0.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, data).unwrap();
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    struct Download {
        calls: AtomicUsize,
        response: Mutex<io::Result<Vec<u8>>>,
    }
    impl Downloader for Download {
        fn stream(&self, _: &dyn Any, url: &str) -> io::Result<(Option<usize>, Box<dyn Read>)> {
            assert_eq!(url, INDEX_URL);
            self.calls.fetch_add(1, Ordering::Relaxed);
            let response = self.response.lock().unwrap();
            match &*response {
                Ok(data) => Ok((None, Box::new(Cursor::new(data.clone())))),
                Err(error) => Err(io::Error::new(error.kind(), error.to_string())),
            }
        }
    }
    fn index() -> Vec<u8> {
        serde_json::to_vec(&json!([
            {"name":"fixture","version":"0.9.0","description":"Old","template":{}},
            {"name":"fixture","version":"0.10.0","description":"Unicode Café 日本","template":{}},
            {"name":"fixture","version":"0.11.0","compiler":"99.0.0","template":{}},
            {"name":"library","version":"1.0.0"},
            {"name":"../outside","version":"1.0.0","template":{}},
            {"name":"other","version":"1.0.0","template":{},"categories":["book"]}
        ]))
        .unwrap()
    }
    #[test]
    fn latest_compatible_templates_and_offline_catalogue() {
        let temp = Temp::new();
        let download = Download {
            calls: AtomicUsize::new(0),
            response: Mutex::new(Ok(index())),
        };
        let first = catalog_at(&temp.0, &download, false).unwrap();
        assert_eq!(first["templates"].as_array().unwrap().len(), 2);
        assert_eq!(first["templates"][0]["version"], "0.10.0");
        assert_eq!(first["templates"][0]["description"], "Unicode Café 日本");
        *download.response.lock().unwrap() = Err(io::Error::other("offline"));
        assert_eq!(catalog_at(&temp.0, &download, false).unwrap(), first);
        assert_eq!(download.calls.load(Ordering::Relaxed), 1);
        let offline = catalog_at(&temp.0, &download, true).unwrap();
        assert_eq!(offline["templates"], first["templates"]);
        assert!(offline["warning"].as_str().unwrap().contains("offline"));
        // A malformed refresh does not replace the usable saved index.
        *download.response.lock().unwrap() = Ok(b"invalid".to_vec());
        assert_eq!(
            catalog_at(&temp.0, &download, true).unwrap()["templates"],
            first["templates"]
        );
        assert_eq!(
            fs::read(temp.0.join(".universe-index.json")).unwrap(),
            index()
        );
    }
    fn fixture(path: &str, entry: &str) -> Temp {
        let temp = Temp::new();
        temp.file("typst.toml",format!("[package]\nname = \"fixture\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"\n[template]\npath = {path:?}\nentrypoint = {entry:?}\n").as_bytes());
        temp
    }
    #[test]
    fn exact_declared_entry_all_starter_files_and_assets() {
        let temp = fixture("./starter/", "./chapters/main.typ");
        let source = b"// exact starter\n#import \"@preview/fixture:1.0.0\": *\n#include \"../appendix.typ\"\n";
        temp.file("starter/chapters/main.typ", source);
        temp.file("starter/appendix.typ", "= Café 日本".as_bytes());
        temp.file("starter/assets/unused.bin", &[0, 255, 1]);
        temp.file("README.md", b"Documentation");
        temp.file("lib.typ", b"#let theme = none");
        let spec = checked_spec("fixture", "1.0.0").unwrap();
        let result = snapshot(&temp.0, &spec).unwrap();
        assert_eq!(result["entry"], "chapters/main.typ");
        let files = result["files"].as_object().unwrap();
        assert_eq!(files.len(), 3);
        assert_eq!(
            STANDARD
                .decode(files["chapters/main.typ"].as_str().unwrap())
                .unwrap(),
            source
        );
        assert_eq!(
            STANDARD
                .decode(files["assets/unused.bin"].as_str().unwrap())
                .unwrap(),
            [0, 255, 1]
        );
        assert_eq!(result["documentation"], "Documentation");
        // The snapshot contains bytes, independent of subsequent cache deletion.
        fs::remove_dir_all(&temp.0).unwrap();
        assert_eq!(
            STANDARD
                .decode(files["appendix.typ"].as_str().unwrap())
                .unwrap(),
            "= Café 日本".as_bytes()
        );
    }
    #[test]
    fn root_templates_accept_empty_or_dot_directory() {
        let spec = checked_spec("fixture", "1.0.0").unwrap();
        for path in ["", ".", "./"] {
            let temp = fixture(path, "./main.typ");
            temp.file("main.typ", b"= Root starter");
            let result = snapshot(&temp.0, &spec).unwrap();
            assert_eq!(result["entry"], "main.typ");
            assert_eq!(
                STANDARD
                    .decode(result["files"]["main.typ"].as_str().unwrap())
                    .unwrap(),
                b"= Root starter"
            );
        }
        assert!(relative("", false).is_err());
    }

    #[test]
    fn refuses_missing_entry_traversal_links_bad_source_and_wrong_versions() {
        let spec = checked_spec("fixture", "1.0.0").unwrap();
        for path in ["../outside", "/outside", "bad\\path"] {
            let temp = fixture(path, "main.typ");
            assert!(snapshot(&temp.0, &spec).is_err());
        }
        let temp = fixture("starter", "main.typ");
        temp.file("starter/other.typ", b"= Other");
        assert!(snapshot(&temp.0, &spec).unwrap_err().contains("missing"));
        temp.file("starter/main.typ", &[255]);
        assert!(snapshot(&temp.0, &spec).unwrap_err().contains("UTF-8"));
        temp.file("starter/main.typ", b"= Main");
        assert!(
            snapshot(&temp.0, &checked_spec("fixture", "2.0.0").unwrap())
                .unwrap_err()
                .contains("mismatched version")
        );
        assert!(
            snapshot(&temp.0, &checked_spec("different", "1.0.0").unwrap())
                .unwrap_err()
                .contains("mismatched name")
        );
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(temp.0.join("lib.typ"), temp.0.join("starter/link.typ"))
                .unwrap();
            assert!(
                snapshot(&temp.0, &spec)
                    .unwrap_err()
                    .contains("symbolic link")
            );
            fs::remove_file(temp.0.join("starter/link.typ")).unwrap();
            fs::remove_dir_all(temp.0.join("starter")).unwrap();
            std::os::unix::fs::symlink(&temp.0, temp.0.join("starter")).unwrap();
            assert!(
                snapshot(&temp.0, &spec)
                    .unwrap_err()
                    .contains("symbolic link")
            );
        }
    }
}
