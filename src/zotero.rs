//! Zotero's local HTTP API. Citation keys include library identity; BibLaTeX stays local.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    time::Duration,
};

pub const GUIDANCE: &str = "Open Zotero → Settings → Advanced and enable ‘Allow other applications on this computer to communicate with Zotero’. Keep Zotero open and try again.";
#[derive(Clone, Serialize, Deserialize)]
pub struct Item {
    pub key: String,
    pub library: String,
    pub cite_key: String,
    pub title: String,
    pub author: String,
    pub year: String,
}
fn get(path: &str) -> Result<String, String> {
    let mut stream = TcpStream::connect_timeout(
        &SocketAddr::from(([127, 0, 0, 1], 23119)),
        Duration::from_secs(3),
    )
    .map_err(|e| format!("{GUIDANCE}\n{e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(8)))
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(8)))
        .map_err(|e| e.to_string())?;
    write!(stream,"GET /api/{path} HTTP/1.1\r\nHost: localhost:23119\r\nZotero-API-Version: 3\r\nConnection: close\r\n\r\n").map_err(|e|e.to_string())?;
    let mut data = vec![];
    stream
        .take(16 * 1024 * 1024 + 1)
        .read_to_end(&mut data)
        .map_err(|e| format!("{GUIDANCE}\n{e}"))?;
    if data.len() > 16 * 1024 * 1024 {
        return Err("Zotero response is too large".into());
    }
    decode_http(&data)
}
fn decode_http(data: &[u8]) -> Result<String, String> {
    let boundary = data
        .windows(4)
        .position(|bytes| bytes == b"\r\n\r\n")
        .ok_or("Invalid Zotero HTTP response")?;
    let headers = String::from_utf8_lossy(&data[..boundary]);
    if headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        != Some("200")
    {
        return Err(format!(
            "{GUIDANCE}\n{}",
            headers.lines().next().unwrap_or("Zotero request failed")
        ));
    }
    let mut body = &data[boundary + 4..];
    if headers
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        let mut decoded = vec![];
        loop {
            let end = body
                .windows(2)
                .position(|bytes| bytes == b"\r\n")
                .ok_or("Invalid HTTP chunk")?;
            let size = usize::from_str_radix(
                std::str::from_utf8(&body[..end])
                    .map_err(|e| e.to_string())?
                    .split(';')
                    .next()
                    .unwrap(),
                16,
            )
            .map_err(|e| e.to_string())?;
            body = &body[end + 2..];
            if size == 0 {
                break;
            }
            let chunk = body.get(..size).ok_or("Incomplete HTTP chunk")?;
            decoded.extend_from_slice(chunk);
            body = body.get(size + 2..).ok_or("Incomplete HTTP chunk")?;
        }
        String::from_utf8(decoded).map_err(|e| e.to_string())
    } else {
        String::from_utf8(body.to_vec()).map_err(|e| e.to_string())
    }
}
fn encode(query: &str) -> String {
    query
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-_.~".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}
fn valid_library(library: &str) -> bool {
    library == "users/0"
        || library
            .strip_prefix("groups/")
            .is_some_and(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()))
}
pub fn search(library: &str, query: &str) -> Result<Vec<Item>, String> {
    if !valid_library(library) {
        return Err("Choose the personal library or groups/<group ID>.".into());
    }
    let data = get(&format!(
        "{library}/items/top?limit=40&includeTrashed=0&q={}&qmode=titleCreatorYear",
        encode(query)
    ))?;
    let entries: Vec<Value> = serde_json::from_str(&data).map_err(|e| e.to_string())?;
    Ok(entries
        .iter()
        .filter_map(|entry| {
            let data = &entry["data"];
            if matches!(data["itemType"].as_str(), Some("attachment" | "note")) {
                return None;
            }
            let key = entry["key"].as_str()?.to_owned();
            let author = data["creators"]
                .as_array()
                .map(|creators| {
                    creators
                        .iter()
                        .filter_map(|creator| {
                            creator["lastName"].as_str().or(creator["name"].as_str())
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            let date = data["date"].as_str().unwrap_or("");
            let year = date
                .as_bytes()
                .windows(4)
                .find(|bytes| bytes.iter().all(u8::is_ascii_digit))
                .map(|bytes| String::from_utf8_lossy(bytes).to_string())
                .unwrap_or_default();
            Some(Item {
                cite_key: format!("zotero-{}-{key}", library.replace('/', "-")),
                key,
                library: library.to_owned(),
                title: data["title"]
                    .as_str()
                    .unwrap_or("Untitled reference")
                    .into(),
                author,
                year,
            })
        })
        .collect())
}
pub fn bibliography(item: &Item) -> Result<String, String> {
    if !valid_library(&item.library)
        || item.key.len() != 8
        || !item
            .key
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    {
        return Err("Invalid Zotero item identity".into());
    }
    let data = get(&format!(
        "{}/items/{}?format=biblatex",
        item.library, item.key
    ))?;
    let open = data.find('{').ok_or("Zotero did not return BibLaTeX")?;
    let comma = data
        .find(',')
        .filter(|&comma| comma > open)
        .ok_or("Zotero did not return BibLaTeX")?;
    Ok(format!(
        "{}{}{}\n",
        &data[..open + 1],
        item.cite_key,
        data[comma..].trim_end()
    ))
}
pub fn upsert(text: &str, key: &str, entry: &str) -> Result<String, String> {
    let pattern = regex::Regex::new(&format!(
        r"(?m)@[A-Za-z]+\s*\{{\s*{}\s*,",
        regex::escape(key)
    ))
    .map_err(|e| e.to_string())?;
    let Some(found) = pattern.find(text) else {
        return Ok(format!("{text}\n{entry}"));
    };
    let start = text[found.start()..].find('{').unwrap() + found.start();
    let mut depth = 0;
    let mut escaped = false;
    for (offset, byte) in text.as_bytes()[start..].iter().copied().enumerate() {
        if escaped {
            escaped = false;
            continue;
        }
        if byte == b'\\' {
            escaped = true;
            continue;
        }
        if byte == b'{' {
            depth += 1;
        }
        if byte == b'}' {
            depth -= 1;
            if depth == 0 {
                return Ok(format!(
                    "{}{}{}",
                    &text[..found.start()],
                    entry.trim_end(),
                    &text[start + offset + 1..]
                ));
            }
        }
    }
    Err("An existing bibliography entry is malformed. Repair it before refreshing.".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunked_http_and_bibliography_upsert_preserve_other_entries() {
        assert_eq!(decode_http(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n").unwrap(),"abcde");
        let text = "// note\n@book{first, title={A {nested} title}}\n@book{other,title={Keep}}";
        assert_eq!(
            upsert(text, "first", "@book{first,title={Changed}}\n").unwrap(),
            "// note\n@book{first,title={Changed}}\n@book{other,title={Keep}}"
        );
        assert!(upsert("@book{first,title={Broken}", "first", "x").is_err());
    }
}
