use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};
use std::time::Duration;

struct Helper {
    child: Child,
    stdin: ChildStdin,
    responses: Receiver<Value>,
    reader: Option<JoinHandle<()>>,
}

impl Helper {
    fn start() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_writer-helper"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start compiler helper");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, responses) = mpsc::channel();
        let reader = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let response = serde_json::from_str(&line).expect("valid helper JSON");
                if tx.send(response).is_err() {
                    break;
                }
            }
        });
        Self {
            child,
            stdin,
            responses,
            reader: Some(reader),
        }
    }

    fn request(&mut self, request: Value) -> Value {
        writeln!(self.stdin, "{request}").unwrap();
        self.stdin.flush().unwrap();
        let response = self
            .responses
            .recv_timeout(Duration::from_secs(60))
            .expect("helper response within 60 seconds");
        assert_eq!(response["id"], request["id"]);
        response
    }

    fn compile(
        &mut self,
        root: &std::path::Path,
        text: &str,
        revision: u64,
        native: bool,
    ) -> Value {
        let mut params = json!({
            "root": root,
            "entry": "main.typ",
            "files": {"main.typ": text},
            "revision": revision,
        });
        if native {
            params["native_preview"] = json!(true);
        }
        let response = self.request(json!({
            "jsonrpc": "2.0", "id": revision, "method": "compile",
            "protocolVersion": 1, "params": params,
        }));
        assert!(response.get("error").is_none(), "{response}");
        response["result"].clone()
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = self.reader.take().unwrap().join();
    }
}

#[test]
fn compiler_protocol_exports_pdf_renders_pages_and_reports_invalid_source() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples");
    let text = std::fs::read_to_string(root.join("Tutorial.typ")).unwrap();
    let mut helper = Helper::start();
    // Requests without native_preview remain PDF-only.
    let pdf = helper.compile(&root, &text, 1, false);
    assert!(pdf["diagnostics"].as_array().unwrap().is_empty());
    assert!(pdf.get("pageImages").is_none());
    assert!(
        STANDARD
            .decode(pdf["pdf"].as_str().unwrap())
            .unwrap()
            .starts_with(b"%PDF-")
    );
    assert!(!pdf["sourceMap"].as_array().unwrap().is_empty());

    #[cfg(feature = "native-preview")]
    {
        let rendered = helper.compile(&root, &text, 2, true);
        assert!(rendered["diagnostics"].as_array().unwrap().is_empty());
        let pages = rendered["pageImages"].as_array().unwrap();
        assert!(!pages.is_empty());
        assert_eq!(pages.len() as u64, rendered["pages"].as_u64().unwrap());
        for page in pages {
            assert!(
                STANDARD
                    .decode(page.as_str().unwrap())
                    .unwrap()
                    .starts_with(b"\x89PNG\r\n\x1a\n")
            );
        }
    }

    let broken = helper.compile(&root, "#let x = (", 3, cfg!(feature = "native-preview"));
    assert!(!broken["diagnostics"].as_array().unwrap().is_empty());
    assert!(broken.get("pdf").is_none());
    let unsupported = helper.request(json!({
        "id": 4, "method": "initialize", "protocolVersion": 2,
    }));
    assert!(unsupported.get("error").is_some());
}
