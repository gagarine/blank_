use blank_document::{Document, Position};
use std::time::Instant;

fn main() {
    let count = std::env::args()
        .nth(1)
        .and_then(|n| n.parse::<usize>().ok())
        .unwrap_or(1000)
        .max(1);
    let text = (0..count).map(|i| format!("Paragraph {i}. A short academic paragraph with *emphasis*, Unicode café, and ordinary text.\n\n")).collect::<String>();
    let started = Instant::now();
    let mut doc = Document::new(text);
    let load = started.elapsed();
    let index = doc.paragraphs.len() - 2;
    let mut samples = vec![];
    for i in 0..100 {
        let at = Position::new(index, doc.paragraphs[index].glyphs.len());
        let started = Instant::now();
        doc.replace(at, at, "x", i == 0).unwrap();
        samples.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(f64::total_cmp);
    println!(
        "paragraphs={count} load_ms={:.2} edit_p50_ms={:.2} edit_p95_ms={:.2} source_bytes={}",
        load.as_secs_f64() * 1000.0,
        samples[50],
        samples[95],
        doc.text().len()
    );
    println!(
        "Core-only measurement: includes source patch, incremental parsing, full projection; excludes GUI layout and compilation."
    );
}
