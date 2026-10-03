//! Sequential compiler worker. A burst of queued revisions compiles only its latest.
use base64::Engine;
use eframe::egui;
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, mpsc},
    thread,
};

pub struct Request {
    pub revision: u64,
    pub root: PathBuf,
    pub entry: String,
    pub text: String,
    pub render: bool,
}
pub struct Page {
    pub size: [usize; 2],
    pub rgba: Vec<u8>,
}
pub struct Result {
    pub revision: u64,
    pub pages: Vec<Page>,
    pub pdf: Vec<u8>,
    pub diagnostics: Vec<String>,
    pub source_map: Vec<Value>,
}

pub struct Compiler {
    pub tx: mpsc::Sender<Request>,
    pub rx: mpsc::Receiver<std::result::Result<Result, String>>,
    child: Arc<Mutex<Option<Child>>>,
}

impl Compiler {
    pub fn new(ctx: egui::Context) -> Self {
        let (tx, requests) = mpsc::channel::<Request>();
        let (results, rx) = mpsc::channel();
        let child = Arc::new(Mutex::new(None));
        let process = child.clone();
        thread::spawn(move || {
            let helper = std::env::var_os("BLANK_HELPER")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    let bundled = std::env::current_exe()
                        .ok()
                        .and_then(|path| path.parent().map(|dir| dir.join("writer-helper")));
                    bundled.filter(|path| path.is_file()).unwrap_or_else(|| {
                        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                            .join("target/release/writer-helper")
                    })
                });
            let spawned = Command::new(&helper)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn();
            let mut helper = match spawned {
                Ok(child) => child,
                Err(e) => {
                    let _ = results.send(Err(format!(
                        "Cannot start compiler at {}: {e}. Run scripts/dev.sh.",
                        helper.display()
                    )));
                    ctx.request_repaint();
                    return;
                }
            };
            let mut stdin = helper.stdin.take().expect("piped stdin");
            let mut stdout = BufReader::new(helper.stdout.take().expect("piped stdout"));
            *process.lock().unwrap() = Some(helper);
            while let Ok(mut request) = requests.recv() {
                while let Ok(newer) = requests.try_recv() {
                    request = newer;
                }
                let revision = request.revision;
                let request = json!({"jsonrpc":"2.0", "id":revision, "method":"compile", "protocolVersion":1,
                    "params":{"root":request.root, "entry":request.entry, "files":{request.entry:request.text}, "revision":revision, "native_preview":request.render}});
                let result = (|| {
                    writeln!(stdin, "{request}").map_err(|e| e.to_string())?;
                    stdin.flush().map_err(|e| e.to_string())?;
                    let mut line = String::new();
                    if stdout.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                        return Err("Compiler exited unexpectedly.".into());
                    }
                    decode(revision, &line)
                })();
                if results.send(result).is_err() {
                    break;
                }
                ctx.request_repaint();
            }
        });
        Self { tx, rx, child }
    }
}

impl Drop for Compiler {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn decode(revision: u64, line: &str) -> std::result::Result<Result, String> {
    let response: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
    if let Some(e) = response.get("error") {
        return Err(e["message"].as_str().unwrap_or("Compiler error").into());
    }
    let result = &response["result"];
    let diagnostics = result["diagnostics"]
        .as_array()
        .map(|d| {
            d.iter()
                .map(|d| {
                    d["message"]
                        .as_str()
                        .unwrap_or("Typesetting error")
                        .to_string()
                })
                .collect()
        })
        .unwrap_or_default();
    let pdf = decode_base64(result["pdf"].as_str().unwrap_or(""))?;
    let mut pages = vec![];
    if let Some(images) = result["pageImages"].as_array() {
        for encoded in images {
            let bytes = decode_base64(encoded.as_str().ok_or("Invalid page image")?)?;
            let image = image::load_from_memory_with_format(&bytes, image::ImageFormat::Png)
                .map_err(|e| e.to_string())?
                .into_rgba8();
            pages.push(Page {
                size: [image.width() as usize, image.height() as usize],
                rgba: image.into_raw(),
            });
        }
    }
    Ok(Result {
        revision,
        pages,
        pdf,
        diagnostics,
        source_map: result["sourceMap"].as_array().cloned().unwrap_or_default(),
    })
}
fn decode_base64(text: &str) -> std::result::Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(text)
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_compile_preserves_diagnostics_without_requiring_pdf() {
        let result = decode(
            7,
            r#"{"result":{"revision":7,"diagnostics":[{"message":"unknown variable"}]}}"#,
        )
        .unwrap();
        assert_eq!(result.revision, 7);
        assert_eq!(result.diagnostics, ["unknown variable"]);
        assert!(result.pdf.is_empty());
    }
}
