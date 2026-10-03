//! Generate a reproducible large Typst document for compiler benchmarks.
use serde_json::json;
use std::error::Error;
use std::fmt::Write;
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn Error>> {
    let root = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/fixtures/thesis")
        });
    std::fs::create_dir_all(root.join("chapters"))?;
    let words: Vec<_> = "Careful research connects observation evidence interpretation and theory through a clear argument that remains open to revision and invites further questions"
        .split_whitespace().collect();
    let paragraph = (0..100)
        .map(|i| words[i % words.len()])
        .collect::<Vec<_>>()
        .join(" ")
        + ".";
    for chapter in 0..20 {
        let mut text = format!("= Chapter {}\n\n", chapter + 1);
        for page in 0..25 {
            if page > 0 {
                text.push_str("\n#pagebreak()\n\n");
            }
            let citation = 2 * (chapter * 25 + page);
            writeln!(
                text,
                "{paragraph}\n\n{paragraph}\n\n{paragraph} @ref{citation:04} @ref{:04}\n",
                citation + 1
            )?;
        }
        text.push_str("\n#pagebreak()\n");
        std::fs::write(
            root.join("chapters")
                .join(format!("{:02}.typ", chapter + 1)),
            text,
        )?;
    }
    let mut references = String::new();
    for i in 0..1000 {
        writeln!(
            references,
            "@article{{ref{i:04}, author={{Researcher, A.}}, title={{Study {i}}}, year={{2026}}, journal={{Evidence}}}}"
        )?;
    }
    std::fs::write(root.join("references.bib"), references)?;
    let mut main = "#set page(paper: \"a4\", margin: 2.3cm)\n#set text(size: 10pt)\n#set heading(numbering: \"1\")\n\n".to_owned();
    for chapter in 1..=20 {
        writeln!(main, "#include \"chapters/{chapter:02}.typ\"")?;
    }
    main.push_str("#bibliography(\"references.bib\", style: \"ieee\")\n");
    std::fs::write(root.join("main.typ"), main)?;
    println!(
        "{}",
        json!({"root": root.canonicalize()?, "bodyWords": 150000,
        "chapters": 20, "citations": 1000, "explicitBodyPages": 500})
    );
    Ok(())
}
