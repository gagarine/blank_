//! App-owned Universe cache. The lock lives outside the disposable packages
//! directory and spans compilation, including lazy reads of package assets.
use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use typst::diag::FileResult;
use typst_kit::downloader::SystemDownloader;
use typst_kit::files::FsRoot;
use typst_kit::packages::{FsPackages, SystemPackages, UniversePackages};
use typst_syntax::package::PackageSpec;

pub(crate) fn cache_path() -> io::Result<PathBuf> {
    if let Some(path) = std::env::var_os("BLANK_PACKAGE_CACHE") {
        return Ok(PathBuf::from(path));
    }
    // Disposable acceptance/UI runs must never clear the user's cache.
    if let Some(path) = std::env::var_os("BLANK_DATA_DIR") {
        return Ok(PathBuf::from(path).join("cache/typst/packages"));
    }
    dirs::cache_dir()
        .map(|path| path.join("blank_/typst/packages"))
        .ok_or_else(|| io::Error::other("The user cache directory is unavailable."))
}

pub(crate) fn lock_file(cache: &Path) -> io::Result<File> {
    let parent = cache
        .parent()
        .ok_or_else(|| io::Error::other("Invalid cache path."))?;
    std::fs::create_dir_all(parent)?;
    OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(parent.join(".packages.lock"))
}

pub struct Packages {
    _lock: File,
    system: SystemPackages,
}

impl Packages {
    pub fn new() -> io::Result<Self> {
        let cache = cache_path()?;
        let lock = lock_file(&cache)?;
        lock.lock_shared()?;
        Ok(Self {
            _lock: lock,
            system: SystemPackages::from_parts(
                None,
                Some(FsPackages::new(cache)),
                UniversePackages::new(SystemDownloader::new("blank_/0.1 (Typst/0.15.1)")),
            ),
        })
    }

    pub fn obtain(&self, project: &Path, spec: &PackageSpec) -> FileResult<FsRoot> {
        // Preserve support for CLI-installed and self-contained project packages.
        for packages in [
            FsPackages::system_data(),
            FsPackages::system_cache(),
            Some(FsPackages::new(project.join("packages"))),
        ] {
            if let Some(root) = packages.and_then(|p| p.obtain(spec)) {
                return Ok(root);
            }
        }
        self.system.obtain(spec).map_err(Into::into)
    }
}

fn clear_at(cache: &Path) -> io::Result<()> {
    let lock = lock_file(cache)?;
    // All helper processes share this lock. Wait until their snapshots have
    // finished reading packages before deleting any downloaded files.
    lock.lock()?;
    match std::fs::remove_dir_all(cache) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

pub fn clear_cache() -> io::Result<()> {
    clear_at(&cache_path()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::any::Any;
    use std::io::{Cursor, Read};
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    use typst_kit::downloader::Downloader;

    struct Fixture {
        downloads: AtomicUsize,
        response: Mutex<io::Result<Vec<u8>>>,
    }
    impl Downloader for Fixture {
        fn stream(&self, _: &dyn Any, url: &str) -> io::Result<(Option<usize>, Box<dyn Read>)> {
            assert_eq!(
                url,
                "https://packages.typst.org/preview/blank-fixture-1.0.0.tar.gz"
            );
            self.downloads.fetch_add(1, Ordering::SeqCst);
            match &*self.response.lock().unwrap() {
                Ok(bytes) => Ok((Some(bytes.len()), Box::new(Cursor::new(bytes.clone())))),
                Err(error) => Err(io::Error::new(error.kind(), error.to_string())),
            }
        }
    }
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "blank-packages-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::SeqCst)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn packages(&self, fixture: Arc<Fixture>) -> Packages {
            let cache = self.0.join("packages");
            let lock = lock_file(&cache).unwrap();
            lock.lock_shared().unwrap();
            Packages {
                _lock: lock,
                system: SystemPackages::from_parts(
                    None,
                    Some(FsPackages::new(cache)),
                    UniversePackages::new(fixture),
                ),
            }
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn archive(text: &str) -> Vec<u8> {
        let gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        let mut tar = tar::Builder::new(gzip);
        for (path, text) in [("lib.typ", text), ("assets/data.txt", "nested asset")] {
            let mut header = tar::Header::new_gnu();
            header.set_size(text.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            tar.append_data(&mut header, path, text.as_bytes()).unwrap();
        }
        tar.into_inner().unwrap().finish().unwrap()
    }
    fn spec() -> PackageSpec {
        "@preview/blank-fixture:1.0.0".parse().unwrap()
    }

    #[test]
    fn download_offline_clear_and_redownload() {
        let temp = Temp::new();
        let fixture = Arc::new(Fixture {
            downloads: AtomicUsize::new(0),
            response: Mutex::new(Ok(archive("first"))),
        });
        let packages = temp.packages(fixture.clone());
        let root = packages.obtain(&temp.0, &spec()).unwrap();
        assert_eq!(
            std::fs::read_to_string(root.path().join("lib.typ")).unwrap(),
            "first"
        );
        assert!(root.path().join("assets/data.txt").exists());
        *fixture.response.lock().unwrap() = Err(io::Error::other("offline"));
        assert!(packages.obtain(&temp.0, &spec()).is_ok());
        assert_eq!(fixture.downloads.load(Ordering::SeqCst), 1);
        drop(packages);
        let unrelated = temp.0.join("keep.typ");
        std::fs::write(&unrelated, "user source").unwrap();
        clear_at(&temp.0.join("packages")).unwrap();
        clear_at(&temp.0.join("packages")).unwrap(); // Empty clear is harmless.
        assert!(unrelated.exists());
        let packages = temp.packages(fixture.clone());
        assert!(
            packages
                .obtain(&temp.0, &spec())
                .unwrap_err()
                .to_string()
                .contains("offline")
        );
        *fixture.response.lock().unwrap() = Ok(archive("second"));
        let root = packages.obtain(&temp.0, &spec()).unwrap();
        assert_eq!(
            std::fs::read_to_string(root.path().join("lib.typ")).unwrap(),
            "second"
        );
        assert_eq!(fixture.downloads.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn failed_archive_can_retry_and_vendored_packages_stay_local() {
        let temp = Temp::new();
        let fixture = Arc::new(Fixture {
            downloads: AtomicUsize::new(0),
            response: Mutex::new(Ok(b"invalid gzip".to_vec())),
        });
        let packages = temp.packages(fixture.clone());
        assert!(packages.obtain(&temp.0, &spec()).is_err());
        assert!(!temp.0.join("packages/preview/blank-fixture/1.0.0").exists());
        *fixture.response.lock().unwrap() = Ok(archive("retry"));
        assert!(packages.obtain(&temp.0, &spec()).is_ok());
        let project = temp.0.join("project");
        let vendored = project.join("packages/local/blank-fixture/1.0.0");
        std::fs::create_dir_all(&vendored).unwrap();
        std::fs::write(vendored.join("lib.typ"), "local").unwrap();
        assert!(
            packages
                .obtain(&project, &"@local/blank-fixture:1.0.0".parse().unwrap())
                .is_ok()
        );
        assert!(
            packages
                .obtain(&project, &"@local/missing:1.0.0".parse().unwrap())
                .is_err()
        );
        assert_eq!(fixture.downloads.load(Ordering::SeqCst), 2);
        drop(packages);
        clear_at(&temp.0.join("packages")).unwrap();
        assert!(vendored.join("lib.typ").exists());
    }

    #[test]
    fn clearing_waits_for_active_readers() {
        let temp = Temp::new();
        let cache = temp.0.join("packages");
        std::fs::create_dir_all(&cache).unwrap();
        let reader = lock_file(&cache).unwrap();
        reader.lock_shared().unwrap();
        let writer = lock_file(&cache).unwrap();
        assert!(writer.try_lock().is_err());
        let (send, receive) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            clear_at(&cache).unwrap();
            send.send(()).unwrap();
        });
        assert!(
            receive
                .recv_timeout(std::time::Duration::from_millis(50))
                .is_err()
        );
        assert!(temp.0.join("packages").exists());
        drop(reader);
        receive
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        thread.join().unwrap();
        assert!(!temp.0.join("packages").exists());
    }
}
