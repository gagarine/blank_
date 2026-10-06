//! The official Typst parser only; document state and editing live in Swift.
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char};
use typst_syntax::{LinkedNode, SyntaxNode};

fn node(n: &SyntaxNode, start: usize) -> Value {
    let mut at = start;
    let children: Vec<_> = n
        .children()
        .map(|c| {
            let result = node(c, at);
            at += c.len();
            result
        })
        .collect();
    let mut value = json!({"kind":format!("{:?}", n.kind()),"start":start,"end":start+n.len(),"children":children});
    if let Some(string) = n.cast::<typst_syntax::ast::Str>() {
        value["stringValue"] = json!(string.get());
    }
    if let Some(raw) = n.cast::<typst_syntax::ast::Raw>() {
        value["rawText"] = json!(
            raw.lines()
                .map(|line| line.get().as_str())
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
    value
}
fn styles(n: LinkedNode<'_>, out: &mut Vec<Value>) {
    if let Some(tag) = typst_syntax::highlight(&n) {
        out.push(json!({"start":n.range().start,"end":n.range().end,"tag":format!("{tag:?}")}));
    }
    for c in n.children() {
        styles(c, out);
    }
}
/// # Safety
/// `source` must be a readable, NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn blank_parse(source: *const c_char) -> *mut c_char {
    if source.is_null() {
        return std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(|| {
        let text = unsafe { CStr::from_ptr(source) }.to_str().unwrap_or("");
        let root = typst_syntax::parse(text);
        let mut runs = vec![];
        styles(LinkedNode::new(&root), &mut runs);
        CString::new(json!({"tree":node(&root,0),"styles":runs,"erroneous":!root.errors_and_warnings().0.is_empty()}).to_string())
            .unwrap()
            .into_raw()
    });
    result.unwrap_or(std::ptr::null_mut())
}
/// # Safety
/// The pointer must be returned by `blank_parse`, and freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn blank_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}
