//! Measure cold/warm compilation and chapter parsing through the real helper.
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::error::Error;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Instant;

struct Helper(Child);
impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn collect(
    root: &Path,
    directory: &Path,
    files: &mut BTreeMap<String, String>,
) -> std::io::Result<()> {
    for entry in std::fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        let kind = entry.file_type()?;
        if kind.is_dir() {
            collect(root, &path, files)?;
        } else if kind.is_file()
            && matches!(
                path.extension().and_then(|s| s.to_str()),
                Some("typ" | "bib")
            )
        {
            let relative = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            files.insert(relative, std::fs::read_to_string(path)?);
        }
    }
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let workspace = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut args = std::env::args_os().skip(1);
    let root = args
        .next()
        .map(PathBuf::from)
        .unwrap_or_else(|| workspace.join("target/fixtures/thesis"))
        .canonicalize()?;
    let executable = args.next().map(PathBuf::from).unwrap_or_else(|| {
        workspace
            .join("target/release")
            .join(format!("writer-helper{}", std::env::consts::EXE_SUFFIX))
    });
    let mut files = BTreeMap::new();
    collect(&root, &root, &mut files)?;
    let mut helper = Helper(
        Command::new(executable)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?,
    );
    let mut stdin = helper.0.stdin.take().unwrap();
    let mut stdout = BufReader::new(helper.0.stdout.take().unwrap());
    let mut request = |id: u64,
                       method: &str,
                       params: Value|
     -> Result<(f64, Value), Box<dyn Error>> {
        let start = Instant::now();
        writeln!(
            stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": id, "method": method, "protocolVersion": 1, "params": params})
        )?;
        stdin.flush()?;
        let mut line = String::new();
        if stdout.read_line(&mut line)? == 0 {
            return Err("compiler helper exited without a response".into());
        }
        let response: Value = serde_json::from_str(&line)?;
        if response.get("error").is_some() || response["id"] != id {
            return Err(format!("unexpected helper response: {response}").into());
        }
        Ok((start.elapsed().as_secs_f64(), response["result"].clone()))
    };
    let mut times = Vec::new();
    let mut pages = 0;
    for revision in 1..=3 {
        if revision > 1 {
            let text = files
                .get_mut("chapters/01.typ")
                .ok_or("missing chapters/01.typ")?;
            *text = if revision == 2 {
                text.replacen("Careful", "Thoughtful", 1)
            } else {
                text.replacen("Thoughtful", "Considered", 1)
            };
        }
        let (duration, result) = request(
            revision,
            "compile",
            json!({
                "root": root, "entry": "main.typ", "files": files, "revision": revision,
            }),
        )?;
        if result.get("pdf").is_none() {
            return Err(format!("compilation failed: {result}").into());
        }
        times.push(duration);
        pages = result["pages"].as_u64().unwrap_or_default();
    }
    let chapter = files
        .get("chapters/01.typ")
        .ok_or("missing chapters/01.typ")?;
    let (parse, _) = request(
        4,
        "parse",
        json!({"path": "chapter", "text": chapter, "revision": 3}),
    )?;
    println!(
        "{}",
        serde_json::to_string_pretty(
            &json!({"compileSeconds": times, "pages": pages, "chapterParseMs": parse * 1000.0})
        )?
    );
    Ok(())
}
