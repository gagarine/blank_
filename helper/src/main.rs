use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World, WorldExt};
use typst_syntax::{FileId, Source, SyntaxKind, SyntaxNode, VirtualPath, RootedPath, VirtualRoot};

#[derive(Clone, Serialize)]
struct Node { kind: String, start: usize, end: usize, children: Vec<Node> }

fn project(node: &SyntaxNode, start: usize) -> Node {
    let mut children: Vec<Node> = Vec::new();
    let mut at = start;
    for child in node.children() {
        let next = project(child, at);
        if matches!(child.kind(), SyntaxKind::Text | SyntaxKind::Space) {
            if let Some(prev) = children.last_mut() {
                if prev.kind == "Text" && prev.end == at { prev.end = next.end; at += child.len(); continue; }
            }
            children.push(Node { kind: "Text".into(), children: vec![], ..next });
        } else { children.push(next); }
        at += child.len();
    }
    Node { kind: format!("{:?}", node.kind()), start, end: start + node.len(), children }
}

struct Environment {
    root: PathBuf,
    main: FileId,
    library: LazyHash<Library>,
    fonts: &'static typst_kit::fonts::FontStore,
    files: HashMap<String, String>,
    sources: Mutex<HashMap<FileId, Source>>,
    binary: Mutex<HashMap<FileId, Bytes>>,
    time: typst_kit::datetime::Time,
}

impl Environment {
    fn path(&self, id: FileId) -> FileResult<PathBuf> {
        if let VirtualRoot::Package(spec) = id.root() {
            for packages in [typst_kit::packages::FsPackages::system_data(),typst_kit::packages::FsPackages::system_cache(),Some(typst_kit::packages::FsPackages::new(self.root.join("packages")))] {
                if let Some(root)=packages.and_then(|p|p.obtain(spec)) {
                    let path=root.resolve(id.vpath())?;
                    let real=path.canonicalize().map_err(|e|FileError::from_io(e,&path))?;
                    let base=root.path().canonicalize().map_err(|e|FileError::from_io(e,root.path()))?;
                    if !real.starts_with(base) {return Err(FileError::AccessDenied)};
                    return Ok(real);
                }
            }
            return Err(FileError::Other(Some(format!("Package {spec} is not cached. Compile once with the Typst CLI to download it, or vendor it in the project's packages directory.").into())));
        }
        let path = id.vpath().realize(&self.root).map_err(|_|FileError::AccessDenied)?;
        // Existing paths must resolve inside the selected project.
        if let Ok(real) = path.canonicalize() { if !real.starts_with(&self.root) { return Err(FileError::AccessDenied); } }
        Ok(path)
    }
    fn bytes(&self, id: FileId) -> FileResult<Bytes> {
        if let Some(bytes)=self.binary.lock().unwrap().get(&id) {return Ok(bytes.clone())}
        let path = self.path(id)?;
        if matches!(id.root(),VirtualRoot::Project) {
            let relative = path.strip_prefix(&self.root).map_err(|_| FileError::AccessDenied)?.to_string_lossy();
            if let Some(text) = self.files.get(relative.as_ref()) { return Ok(Bytes::new(text.as_bytes().to_vec())); }
        }
        let bytes=std::fs::read(&path).map(Bytes::new).map_err(|e| FileError::from_io(e, &path))?;
        self.binary.lock().unwrap().insert(id,bytes.clone());Ok(bytes)
    }
}

impl World for Environment {
    fn library(&self) -> &LazyHash<Library> { &self.library }
    fn book(&self) -> &LazyHash<FontBook> { self.fonts.book() }
    fn main(&self) -> FileId { self.main }
    fn source(&self, id: FileId) -> FileResult<Source> {
        if let Some(source) = self.sources.lock().unwrap().get(&id) { return Ok(source.clone()); }
        let bytes = self.bytes(id)?;
        let text = std::str::from_utf8(&bytes).map_err(|_| FileError::InvalidUtf8)?;
        static SOURCE_CACHE: OnceLock<Mutex<HashMap<(PathBuf,FileId),Source>>> = OnceLock::new();
        let mut cache=SOURCE_CACHE.get_or_init(||Mutex::new(HashMap::new())).lock().unwrap();
        let source=cache.entry((self.root.clone(),id)).or_insert_with(||Source::new(id,text.to_owned()));
        if source.text()!=text {source.replace(text);}
        let source=source.clone();drop(cache);
        self.sources.lock().unwrap().insert(id, source.clone());
        Ok(source)
    }
    fn file(&self, id: FileId) -> FileResult<Bytes> { self.bytes(id) }
    fn font(&self, index: usize) -> Option<Font> { self.fonts.font(index) }
    fn today(&self, offset: Option<typst::foundations::Duration>) -> Option<Datetime> { self.time.today(offset) }
}

#[derive(Deserialize)]
struct CompileRequest { root: String, entry: String, files: HashMap<String, String>, revision: u64 }

// One anchor per source run, rather than per glyph, keeps the map small for theses.
fn reading_map(world: &Environment, frame: &typst::layout::Frame, transform: typst::layout::Transform, page: usize, height: f64, out: &mut Vec<Value>) {
    use typst::layout::{FrameItem, Transform};
    let mut ranges = HashMap::new();
    for (pos, item) in frame.items() {
        let transform = transform.pre_concat(Transform::translate(pos.x, pos.y));
        match item {
            FrameItem::Group(group) => reading_map(world, &group.frame, transform.pre_concat(group.transform), page, height, out),
            FrameItem::Text(text) => {
                let mut runs: Vec<(FileId, usize, usize)> = vec![];
                for glyph in &text.glyphs {
                    let (span, offset) = glyph.span;
                    let Some(id) = span.id() else { continue };
                    if !matches!(id.root(), VirtualRoot::Project) || !world.files.contains_key(id.vpath().get_without_slash()) { continue; }
                    let Some(range) = ranges.entry(span).or_insert_with(|| world.range(span)).as_ref() else { continue };
                    let start = (range.start + usize::from(offset)).min(range.end);
                    let end = (start + glyph.range().len()).min(range.end);
                    if let Some(last) = runs.last_mut().filter(|r| r.0 == id) {
                        last.1 = last.1.min(start); last.2 = last.2.max(end);
                    } else { runs.push((id, start, end)); }
                }
                for (id, start, end) in runs {
                    out.push(json!({"path":id.vpath().get_without_slash(),"start":start,"end":end,"page":page,"y":(transform.ty.to_pt()/height).clamp(0.0,1.0)}));
                }
            },
            _ => {}
        }
    }
}

fn compile(params: Value) -> Result<Value,String> {
    let p: CompileRequest = serde_json::from_value(params).map_err(|e| e.to_string())?;
    let root = Path::new(&p.root).canonicalize().map_err(|e|e.to_string())?;
    static FONTS: OnceLock<typst_kit::fonts::FontStore> = OnceLock::new();
    let fonts = FONTS.get_or_init(||{let mut store=typst_kit::fonts::FontStore::new();store.extend(typst_kit::fonts::system());store});
    let path=VirtualPath::new(&p.entry).map_err(|e|e.to_string())?;
    let world = Environment { root, main: FileId::new(RootedPath::new(VirtualRoot::Project,path)), library: LazyHash::new(Library::default()), fonts, files:p.files, sources:Mutex::new(HashMap::new()),binary:Mutex::new(HashMap::new()),time:typst_kit::datetime::Time::system() };
    let compiled = typst::compile::<typst_layout::PagedDocument>(&world);
    let result = match compiled.output {
        Ok(document) => {
            let pdf = typst_pdf::pdf(&document, &typst_pdf::PdfOptions::default()).map_err(|e|format!("{e:?}"))?;
            let mut source_map = vec![];
            let mut page_ratios = vec![];
            for (index, page) in document.pages().iter().enumerate() {
                let size = page.frame.size();
                page_ratios.push(size.y.to_pt()/size.x.to_pt());
                reading_map(&world, &page.frame, typst::layout::Transform::identity(), index + 1, size.y.to_pt(), &mut source_map);
            }
            Ok(json!({"revision":p.revision,"pdf":base64::engine::general_purpose::STANDARD.encode(pdf),"pages":document.pages().len(),"sourceMap":source_map,"pageRatios":page_ratios,"diagnostics":[]}))
        },
        Err(errors) => {
            let diagnostics: Vec<Value> = errors.iter().map(|e| {
                let id=e.span.id();
                let range=world.range(e.span);
                json!({"message":e.message.to_string(),"path":id.map(|i|i.vpath().get_without_slash().to_string()),"start":range.as_ref().map(|r|r.start),"end":range.map(|r|r.end),"hints":e.hints.iter().map(|h|h.v.to_string()).collect::<Vec<_>>()})
            }).collect();
            Ok(json!({"revision":p.revision,"diagnostics":diagnostics}))
        }
    };
    comemo::evict(10);
    result
}

fn respond(output: &Arc<Mutex<io::Stdout>>, id: Value, result: Result<Value,String>) {
    let value=match result {Ok(v)=>json!({"jsonrpc":"2.0","id":id,"result":v}),Err(e)=>json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":e}})};
    let mut out=output.lock().unwrap(); let _=writeln!(out,"{value}"); let _=out.flush();
}

fn main() {
    let output=Arc::new(Mutex::new(io::stdout()));
    let sources=Arc::new(Mutex::new(HashMap::<String,Source>::new()));
    for line in io::stdin().lock().lines() {
        let Ok(line)=line else {break};
        let Ok(request)=serde_json::from_str::<Value>(&line) else {continue};
        let id=request["id"].clone(); let params=request["params"].clone();
        if request.get("protocolVersion").is_some_and(|v|v.as_u64()!=Some(1)){respond(&output,id,Err("unsupported helper protocol version".into()));continue}
        match request["method"].as_str().unwrap_or("") {
            "initialize"=>respond(&output,id,Ok(json!({"protocolVersion":1,"typstVersion":"0.15.1"}))),
            "parse"=>{
                let path=params["path"].as_str().unwrap_or("main.typ").to_string();
                let text=params["text"].as_str().unwrap_or("");
                let mut cache=sources.lock().unwrap();
                let source=cache.entry(path).or_insert_with(||Source::detached(text));
                if source.text()!=text {source.replace(text);}
                respond(&output,id,Ok(json!({"revision":params["revision"],"tree":project(source.root(),0)})));
            },
            "compile"=>{let output=output.clone();std::thread::spawn(move||respond(&output,id,compile(params)));},
            _=>respond(&output,id,Err("unknown method".into()))
        }
    }
}
