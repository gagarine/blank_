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
    pub files: std::collections::HashMap<String, String>,
    pub page: Option<usize>,
    pub object: Option<(u64, String)>,
    pub revision: u64,
    pub root: PathBuf,
    pub entry: String,
    pub render: bool,
}
pub struct Page {
    pub size: [usize; 2],
    pub rgba: Vec<u8>,
}
pub struct Result {
    pub object: Option<u64>,
    pub page: Option<usize>,
    pub ratios: Vec<f32>,
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
    stopped: Arc<std::sync::atomic::AtomicBool>,
}

impl Compiler {
    pub fn new(ctx: egui::Context) -> Self {
        let (tx, requests) = mpsc::channel::<Request>();
        let (results, rx) = mpsc::channel();
        let child = Arc::new(Mutex::new(None));
        let process = child.clone();
        let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_stopped = stopped.clone();
        thread::spawn(move || {
            let spawned = (|| {
                let helper = match std::env::var_os("BLANK_HELPER") {
                    Some(path) => PathBuf::from(path),
                    None => {
                        let mut path = std::env::current_exe()?;
                        path.set_file_name(format!(
                            "writer-helper{}",
                            std::env::consts::EXE_SUFFIX
                        ));
                        path
                    }
                };
                Command::new(helper)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::inherit())
                    .spawn()
            })();
            let mut helper = match spawned {
                Ok(child) => child,
                Err(e) => {
                    let _ = results.send(Err(format!(
                        "Cannot start compiler: {e}. Run cargo xtask dev."
                    )));
                    ctx.request_repaint();
                    return;
                }
            };
            let mut stdin = helper.stdin.take().expect("piped stdin");
            let mut stdout = BufReader::new(helper.stdout.take().expect("piped stdout"));
            let mut process_lock = process.lock().unwrap();
            if worker_stopped.load(std::sync::atomic::Ordering::Acquire) {
                let _ = helper.kill();
                let _ = helper.wait();
                return;
            }
            *process_lock = Some(helper);
            drop(process_lock);
            while let Ok(request) = requests.recv() {
                let mut batch = vec![request];
                while let Ok(newer) = requests.try_recv() {
                    if newer.page.is_none() && newer.object.is_none() {
                        batch.retain(|request: &Request| request.object.is_some());
                        batch.insert(0, newer);
                    } else {
                        batch.push(newer);
                    }
                }
                for request in batch {
                    let revision = request.revision;
                    let request = if let Some((key, text)) = request.object {
                        json!({"jsonrpc":"2.0","id":revision,"method":"render-object","protocolVersion":1,"params":{"root":request.root,"revision":revision,"objectKey":key,"text":text}})
                    } else if request.page == Some(usize::MAX) {
                        json!({"id":revision,"method":"release-preview","protocolVersion":1})
                    } else if let Some(page) = request.page {
                        json!({"jsonrpc":"2.0","id":revision,"method":"render-page","protocolVersion":1,"params":{"revision":revision,"page":page}})
                    } else {
                        json!({"jsonrpc":"2.0", "id":revision, "method":"compile", "protocolVersion":1,
                    "params":{"root":request.root, "entry":request.entry, "files":request.files, "revision":revision, "retain_preview":request.render}})
                    };
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
            }
        });
        Self {
            tx,
            rx,
            child,
            stopped,
        }
    }
    pub fn render(&self, revision: u64, page: usize) {
        let _ = self.tx.send(Request {
            revision,
            page: Some(page),
            object: None,
            root: PathBuf::new(),
            entry: String::new(),
            render: true,
            files: Default::default(),
        });
    }
    pub fn stop(&mut self) {
        self.stopped
            .store(true, std::sync::atomic::Ordering::Release);
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    pub fn release_preview(&self) {
        self.render(0, usize::MAX);
    }
}

impl Drop for Compiler {
    fn drop(&mut self) {
        self.stop();
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
        object: result["objectKey"].as_u64(),
        page: result["pageNumber"].as_u64().map(|p| p as usize),
        ratios: result["pageRatios"]
            .as_array()
            .map(|ratios| {
                ratios
                    .iter()
                    .map(|ratio| ratio.as_f64().unwrap_or(1.414) as f32)
                    .collect()
            })
            .unwrap_or_default(),
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
