use base64::Engine;
use biblatex::ChunksExt;
use serde_json::{Value, json};
use std::collections::BTreeMap;

type Metadata = BTreeMap<String, BTreeMap<String, String>>;
const ARCHIVE: &str = "x-blank-original-";
fn is_archive(line: &str) -> bool {
    line.starts_with("% x-blank-original-") || line.starts_with("# x-blank-original-")
}
fn visible_source(text: &str) -> String {
    text.split_inclusive('\n')
        .filter(|line| !is_archive(line))
        .collect()
}
fn fingerprint(text: &str) -> String {
    format!("{:032x}", typst::utils::hash128(&visible_source(text)))
}

fn library(text: &str, format: &str) -> Result<hayagriva::Library, String> {
    if format == "bib" {
        hayagriva::io::from_biblatex_str(text).map_err(|e| format!("{e:?}"))
    } else {
        hayagriva::io::from_yaml_str(text).map_err(|e| e.to_string())
    }
}
fn metadata(text: &str, format: &str) -> Result<Metadata, String> {
    let mut result = Metadata::new();
    if format == "bib" {
        let bib = biblatex::Bibliography::parse(text).map_err(|e| e.to_string())?;
        for entry in bib.iter() {
            result.insert(
                entry.key.clone(),
                entry
                    .fields
                    .iter()
                    .filter(|(name, _)| name.starts_with("x-blank-"))
                    .map(|(name, value)| (name.clone(), value.format_verbatim()))
                    .collect(),
            );
        }
    } else {
        let yaml: Value = serde_yaml::from_str(text).map_err(|e| e.to_string())?;
        for (key, fields) in yaml
            .as_object()
            .ok_or("Expected a YAML bibliography mapping.")?
        {
            result.insert(
                key.clone(),
                fields
                    .as_object()
                    .ok_or("Expected a YAML entry mapping.")?
                    .iter()
                    .filter(|(name, _)| name.starts_with("x-blank-"))
                    .map(|(name, value)| (name.clone(), scalar(value)))
                    .collect(),
            );
        }
    }
    Ok(result)
}
fn scalar(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string())
}
fn escape(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            '\\' => "\\textbackslash{}".into(),
            '{' => "\\{".into(),
            '}' => "\\}".into(),
            '%' | '&' | '_' | '#' | '$' => format!("\\{c}"),
            '~' => "\\textasciitilde{}".into(),
            '^' => "\\textasciicircum{}".into(),
            _ => c.to_string(),
        })
        .collect()
}
fn formatted(value: &Value) -> String {
    if value.is_string() {
        scalar(value)
    } else {
        value
            .get("value")
            .map(scalar)
            .unwrap_or_else(|| scalar(value))
    }
}
fn people(value: &Value) -> String {
    let values = value
        .as_array()
        .cloned()
        .unwrap_or_else(|| vec![value.clone()]);
    values
        .iter()
        .map(|v| {
            if v.is_string() {
                return scalar(v);
            }
            let family = [v.get("prefix"), v.get("name")]
                .into_iter()
                .flatten()
                .map(scalar)
                .collect::<Vec<_>>()
                .join(" ");
            let given = v.get("given-name").map(scalar).unwrap_or_default();
            if let Some(suffix) = v.get("suffix") {
                format!("{family}, {}, {given}", scalar(suffix))
            } else {
                format!("{family}, {given}")
            }
        })
        .collect::<Vec<_>>()
        .join(" and ")
}
// Hayagriva has no BibLaTeX exporter. Construct a candidate, then require the
// official parser to recover exactly the same reference data before accepting it.
fn bib_candidate(library: &hayagriva::Library) -> Result<String, String> {
    let value = serde_json::to_value(library).map_err(|e| e.to_string())?;
    let mut result = String::new();
    for (key, entry) in value.as_object().ok_or("Expected bibliography entries.")? {
        if key.contains([',', '{', '}', '(', ')', '\n', '\r']) {
            return Err("This citation key cannot be represented safely in BibLaTeX.".into());
        }
        let parents = entry
            .get("parent")
            .map(|v| v.as_array().cloned().unwrap_or_else(|| vec![v.clone()]))
            .unwrap_or_default();
        let parent = parents.first();
        let kind = match entry["type"].as_str().unwrap_or("misc") {
            "book" => "book",
            "article" if parent.is_some_and(|p| p["type"] == "periodical") => "article",
            "article" if parent.is_some_and(|p| p["type"] == "proceedings") => "inproceedings",
            "chapter" => "inbook",
            "anthos" => "incollection",
            "anthology" => "collection",
            "reference" => "reference",
            "entry" => "inreference",
            "proceedings" => "proceedings",
            "report" => "report",
            "thesis" => "thesis",
            "manuscript" => "unpublished",
            "periodical" => "periodical",
            "patent" => "patent",
            "web" => "online",
            "repository" => "dataset",
            _ => "misc",
        };
        let mut fields = BTreeMap::<String, String>::new();
        for (name, target) in [
            ("title", "title"),
            ("date", "date"),
            ("edition", "edition"),
            ("volume", "volume"),
            ("issue", "number"),
            ("page-range", "pages"),
            ("page-total", "pagetotal"),
            ("note", "note"),
            ("abstract", "abstract"),
            ("genre", "type"),
            ("language", "langid"),
            ("organization", "organization"),
            ("location", "location"),
        ] {
            if let Some(v) = entry.get(name) {
                fields.insert(target.into(), formatted(v));
            }
        }
        if let Some(short) = entry.get("title").and_then(|v| v.get("short")) {
            fields.insert("shorttitle".into(), formatted(short));
        }
        for name in ["author", "editor"] {
            if let Some(v) = entry.get(name) {
                fields.insert(name.into(), people(v));
            }
        }
        if let Some(v) = entry.get("publisher") {
            fields.insert(
                "publisher".into(),
                v.get("name").map(formatted).unwrap_or_else(|| formatted(v)),
            );
            if let Some(location) = v.get("location") {
                fields.insert("location".into(), formatted(location));
            }
        }
        if let Some(v) = entry.get("url") {
            fields.insert(
                "url".into(),
                v.get("value").map(scalar).unwrap_or_else(|| scalar(v)),
            );
            if let Some(date) = v.get("date") {
                fields.insert("urldate".into(), scalar(date));
            }
        }
        if let Some(v) = entry.get("serial-number").and_then(Value::as_object) {
            for (name, v) in v {
                fields.insert(
                    if name == "serial" {
                        "number".into()
                    } else {
                        name.clone()
                    },
                    scalar(v),
                );
            }
        }
        if let Some(parent) = parent {
            for (name, target) in [
                (
                    "title",
                    if kind == "article" {
                        "journaltitle"
                    } else {
                        "booktitle"
                    },
                ),
                ("volume", "volume"),
                ("issue", "number"),
                ("publisher", "publisher"),
                ("location", "location"),
            ] {
                if let Some(v) = parent.get(name) {
                    fields.insert(
                        target.into(),
                        v.get("name").map(formatted).unwrap_or_else(|| formatted(v)),
                    );
                }
            }
            if let Some(v) = parent.get("author") {
                fields.insert("bookauthor".into(), people(v));
            }
            if let Some(v) = parent.get("editor") {
                fields.insert("editor".into(), people(v));
            }
        }
        result.push_str(&format!("@{kind}{{{key},\n"));
        for (name, value) in fields {
            result.push_str(&format!("  {name} = {{{}}},\n", escape(&value)));
        }
        result.push_str("}\n\n");
    }
    Ok(result)
}
fn linkage(mut meta: Metadata) -> Metadata {
    for fields in meta.values_mut() {
        fields.remove("x-blank-zotero-fields");
    }
    meta
}
fn normalized(library: &hayagriva::Library) -> Value {
    serde_json::to_value(library).unwrap()
}
fn mapped_fields<'a>(from: &str, name: &'a str) -> Vec<&'a str> {
    match (from, name) {
        ("bib", "year" | "month" | "day" | "date") => vec!["date"],
        ("bib", "journal" | "journaltitle" | "booktitle" | "bookauthor") => vec!["parent"],
        ("bib", "pages") => vec!["page-range"],
        ("bib", "pagetotal") => vec!["page-total"],
        ("bib", "number") => vec!["issue", "serial-number"],
        ("bib", "doi" | "isbn" | "issn") => vec!["serial-number"],
        ("yaml", "parent") => vec![
            "journaltitle",
            "booktitle",
            "bookauthor",
            "editor",
            "volume",
            "number",
            "publisher",
            "location",
        ],
        ("yaml", "page-range") => vec!["pages"],
        ("yaml", "page-total") => vec!["pagetotal"],
        ("yaml", "issue") => vec!["number"],
        ("yaml", "serial-number") => vec!["doi", "isbn", "issn", "number"],
        (_, name) => vec![name],
    }
}
pub fn convert(params: Value) -> Result<Value, String> {
    let text = params["text"].as_str().ok_or("Missing bibliography.")?;
    let from = params["from"].as_str().unwrap_or("bib");
    let to = params["to"].as_str().unwrap_or("bib");
    if !["bib", "yaml"].contains(&from) || !["bib", "yaml"].contains(&to) {
        return Err("Unsupported bibliography format.".into());
    }
    if from == to {
        return Ok(json!({"text":text}));
    }
    let original = library(text, from)?;
    let meta = metadata(text, from)?;
    // Restore original spelling only while both reference data and linkage agree.
    let prefix = format!("{} {ARCHIVE}{to}: ", if from == "bib" { "%" } else { "#" });
    for line in text.lines().rev() {
        if let Some(payload) = line.strip_prefix(&prefix)
            && let Some((encoded, expected)) = payload.split_once(' ')
            && expected == fingerprint(text)
            && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded)
            && let Ok(archived) = String::from_utf8(bytes)
            && let Ok(previous) = library(&archived, to)
            && normalized(&previous) == normalized(&original)
            && linkage(metadata(&archived, to)?) == linkage(meta.clone())
        {
            let mut restored = archived;
            let previous: Vec<_> = text
                .lines()
                .filter(|other| is_archive(other) && *other != line)
                .collect();
            if !previous.is_empty() && !restored.ends_with('\n') {
                restored.push('\n');
            }
            for other in previous {
                restored.push_str(&format!(
                    "{} {}\n",
                    if to == "bib" { "%" } else { "#" },
                    &other[2..]
                ));
            }
            return Ok(json!({"text":restored}));
        }
    }
    let mut converted = if to == "yaml" {
        hayagriva::io::to_yaml_str(&original).map_err(|e| e.to_string())?
    } else {
        bib_candidate(&original)?
    };
    if normalized(&library(&converted, to)?) != normalized(&original) {
        return Err("These Hayagriva fields cannot be converted to BibLaTeX without changing reference data. Keep Hayagriva, or edit the fields in Source.".into());
    }
    if to == "yaml" {
        let mut yaml: Value = serde_yaml::from_str(&converted).map_err(|e| e.to_string())?;
        for (key, fields) in &meta {
            let Some(entry) = yaml.get_mut(key).and_then(Value::as_object_mut) else {
                continue;
            };
            let managed = fields.get("x-blank-zotero-fields").map(|value| {
                value
                    .split(',')
                    .flat_map(|name| mapped_fields(from, name))
                    .filter(|name| entry.contains_key(*name))
                    .collect::<std::collections::BTreeSet<_>>()
                    .into_iter()
                    .collect::<Vec<_>>()
                    .join(",")
            });
            for (name, value) in fields {
                entry.insert(
                    name.clone(),
                    json!(if name == "x-blank-zotero-fields" {
                        managed.as_deref().unwrap_or("")
                    } else {
                        value
                    }),
                );
            }
        }
        converted = serde_yaml::to_string(&yaml).map_err(|e| e.to_string())?;
    } else {
        let bib = biblatex::Bibliography::parse(&converted).map_err(|e| e.to_string())?;
        for entry in bib.iter() {
            if let Some(fields) = meta.get(&entry.key) {
                let managed = fields.get("x-blank-zotero-fields").map(|value| {
                    value
                        .split(',')
                        .flat_map(|name| mapped_fields(from, name))
                        .filter(|name| entry.fields.contains_key(*name))
                        .collect::<std::collections::BTreeSet<_>>()
                        .into_iter()
                        .collect::<Vec<_>>()
                        .join(",")
                });
                let start = converted
                    .find(&format!("{{{},\n", entry.key))
                    .ok_or("Cannot locate converted entry.")?;
                let end = start
                    + converted[start..]
                        .find("\n}\n")
                        .ok_or("Cannot locate converted entry end.")?;
                let added = fields
                    .iter()
                    .map(|(name, value)| {
                        format!(
                            "\n  {name} = {{{}}},",
                            escape(if name == "x-blank-zotero-fields" {
                                managed.as_deref().unwrap_or("")
                            } else {
                                value
                            })
                        )
                    })
                    .collect::<String>();
                converted.insert_str(end, &added);
            }
        }
    }
    // Keep earlier snapshots as separate comments, avoiding nested base64
    // snapshots while retaining custom source after edited format conversions.
    let snapshot = visible_source(text);
    if !converted.ends_with('\n') {
        converted.push('\n');
    }
    for line in text.lines().filter(|line| is_archive(line)) {
        converted.push_str(&format!(
            "{} {}\n",
            if to == "bib" { "%" } else { "#" },
            &line[2..]
        ));
    }
    let expected = fingerprint(&converted);
    let archive = base64::engine::general_purpose::STANDARD.encode(snapshot);
    converted.push_str(&format!(
        "{} {ARCHIVE}{from}: {archive} {expected}\n",
        if to == "bib" { "%" } else { "#" }
    ));
    Ok(json!({"text":converted}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn format_roundtrip_keeps_keys_metadata_comments_and_custom_fields() {
        let bib = "% comment 日本\n@book{smith, title={Café}, author={Smith, Jane}, year={2026}, publisher={Press}, custom={Retain me}, x-blank-zotero-key={ABCD1234}, x-blank-zotero-library={groups/123}, x-blank-zotero-fields={author,publisher,title,year}}";
        let yaml = convert(json!({"text":bib,"from":"bib","to":"yaml"})).unwrap()["text"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            metadata(&yaml, "yaml").unwrap()["smith"]["x-blank-zotero-key"],
            "ABCD1234"
        );
        assert_eq!(
            convert(json!({"text":yaml,"from":"yaml","to":"bib"})).unwrap()["text"],
            bib
        );
    }
    #[test]
    fn changed_comments_or_linkage_never_restore_an_old_snapshot() {
        let bib =
            "@book{a,title={A},x-blank-zotero-key={ABCD1234},x-blank-zotero-library={users/0}}";
        let yaml = convert(json!({"text":bib,"from":"bib","to":"yaml"})).unwrap()["text"]
            .as_str()
            .unwrap()
            .to_owned();
        let updated = "# New comment 日本\n".to_owned() + &yaml;
        let output = convert(json!({"text":updated,"from":"yaml","to":"bib"})).unwrap();
        assert_ne!(output["text"], bib);
        let text = output["text"].as_str().unwrap();
        assert!(text.contains("% x-blank-original-yaml:"));
        assert_eq!(
            convert(json!({"text":text,"from":"bib","to":"yaml"})).unwrap()["text"],
            updated
        );
        let updated = yaml.replace("ABCD1234", "WXYZ9876");
        let output = convert(json!({"text":updated,"from":"yaml","to":"bib"})).unwrap()["text"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            metadata(&output, "bib").unwrap()["a"]["x-blank-zotero-key"],
            "WXYZ9876"
        );
    }
    #[test]
    fn yaml_conversion_refuses_loss_and_accepts_simple_books() {
        let yaml =
            "smith:\n  type: Book\n  title: Café 日本\n  author: Smith, Jane\n  date: 2026\n";
        let bib = convert(json!({"text":yaml,"from":"yaml","to":"bib"})).unwrap()["text"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            normalized(&library(&bib, "bib").unwrap()),
            normalized(&library(yaml, "yaml").unwrap())
        );
        assert_eq!(
            convert(json!({"text":bib,"from":"bib","to":"yaml"})).unwrap()["text"],
            yaml
        );
        assert!(convert(json!({"text":"x:\n  type: Book\n  title: Book\n  runtime: 01:00:00\n","from":"yaml","to":"bib"})).is_err());
    }
}
