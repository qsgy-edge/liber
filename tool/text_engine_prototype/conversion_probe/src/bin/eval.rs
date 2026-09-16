//! THROWAWAY: run every candidate conversion recipe over the accuracy gold sets
//! and write each candidate's output next to the gold (`score_eval.py` scores
//! them).
//!
//! Usage:
//!   conversion_eval <gold.jsonl> <hanlp-tc-dir> <opencc-dict-dir> <out-dir>
//!
//! The gold sets come from `make_eval_gold.py`. The candidates all convert
//! Traditional to Simplified, because that is the direction this product needs:
//! a book source's or a local file's Traditional text has to read as mainland
//! Simplified, word choice included.
//!
//! * `liber-now` — the shipped reading conversion (`liber_text`): HanLP 1.x
//!   character tables plus the phrase tables in `assets/phrases/` (OpenCC's
//!   regional wording after the corpus audit and the hand decisions) and the
//!   reduced exclude list. This is `convert_to(..., SimplifiedMainland)`.
//! * `hanlp`, `hanlp+exclude` — the same character tables through this crate's
//!   matcher, with and without the *frozen* exclude list. `hanlp+exclude` against
//!   the crate's character-only `convert` is the control: those two must agree,
//!   because the reading conversion deliberately adds the phrase tables.
//! * `hanlp+tw+hk` — HanLP's character tables plus OpenCC's Taiwan and Hong Kong
//!   phrase lists (`TWPhrasesRev.txt`, `HKPhrasesRev.txt`, Apache-2.0) unedited,
//!   and the frozen exclude list on top: what adopting OpenCC's list without the
//!   audit would have shipped.
//!   each phrase's value is mapped through the character table first so it comes
//!   out Simplified.
//! * `opencc-t2s`, `opencc-t2s+exclude`, `opencc-tw2s`, `opencc-tw2sp` —
//!   ferrous-opencc's own configurations.

use std::fs;
use std::path::{Path, PathBuf};

use conversion_probe::{convert_opencc, convert_opencc_excluded, opencc, to_text, Table, EXCLUDE};
use liber_text::{ConvertTarget, Direction, convert, convert_to};
use serde_json::Value;

/// Reads an OpenCC dictionary: `key<TAB>value(s)`, `#` comments, several values
/// separated by spaces. The first value is the one OpenCC uses.
fn load_phrases(table: &mut Table, path: &Path) {
    let text = fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    let mut loaded = 0usize;
    for line in text.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, values)) = line.split_once('\t') else {
            continue;
        };
        let Some(value) = values.split_whitespace().next() else {
            continue;
        };
        table.insert(key, value);
        loaded += 1;
    }
    println!("  {}: {loaded} entries", path.display());
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: conversion_eval <gold.jsonl> <hanlp-tc-dir> <opencc-dict-dir> <out-dir>");
        std::process::exit(2);
    }
    let (gold_path, hanlp_dir, phrases_dir, out_dir) = (
        &args[1],
        Path::new(&args[2]),
        Path::new(&args[3]),
        PathBuf::from(&args[4]),
    );

    let rows: Vec<Value> = fs::read_to_string(gold_path)
        .expect("cannot read the gold jsonl")
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("gold line is not JSON"))
        .collect();
    println!("{} gold rows from {gold_path}", rows.len());

    // The character table, with and without the exclude list.
    let hanlp_plain = Table::load(&hanlp_dir.join("t2s.txt"));
    let mut hanlp = Table::load(&hanlp_dir.join("t2s.txt"));
    for word in EXCLUDE {
        hanlp.exclude(word);
    }
    // The same table plus OpenCC's regional phrase lists. Each phrase's value is
    // mapped through the *plain* character table first (no exclude list, and
    // before any phrase is inserted), so a value that is written in Traditional
    // characters comes out Simplified and later inserts cannot influence it.
    let mut hanlp_regional = Table::load(&hanlp_dir.join("t2s.txt"));
    println!("loading OpenCC phrase lists");
    let mut phrases = Table {
        char_map: Default::default(),
        by_first: Default::default(),
        max_len: 2,
    };
    load_phrases(&mut phrases, &phrases_dir.join("TWPhrasesRev.txt"));
    load_phrases(&mut phrases, &phrases_dir.join("HKPhrasesRev.txt"));
    let mut regional_added = 0usize;
    for entries in phrases.by_first.values() {
        for (key, value) in entries {
            let key = String::from_utf16_lossy(key);
            let value = String::from_utf16_lossy(value);
            let simplified =
                to_text(&hanlp_plain.convert(&value.encode_utf16().collect::<Vec<u16>>()));
            hanlp_regional.insert(&key, &simplified);
            regional_added += 1;
        }
    }
    println!("  {regional_added} phrases folded into the character table");
    for word in EXCLUDE {
        hanlp_regional.exclude(word);
    }

    let opencc_t2s = opencc("t2s");
    let opencc_tw2s = opencc("tw2s");
    let opencc_tw2sp = opencc("tw2sp");

    /// One candidate: a name and the conversion it applies.
    type Candidate<'a> = (&'a str, Box<dyn Fn(&str) -> String + 'a>);

    let candidates: Vec<Candidate> = vec![
        (
            "liber-now",
            Box::new(|text| convert_to(text, ConvertTarget::SimplifiedMainland)),
        ),
        (
            "hanlp",
            Box::new(|text| to_text(&hanlp_plain.convert(&utf16(text)))),
        ),
        (
            "hanlp+exclude",
            Box::new(|text| to_text(&hanlp.convert(&utf16(text)))),
        ),
        (
            "hanlp+tw+hk",
            Box::new(|text| to_text(&hanlp_regional.convert(&utf16(text)))),
        ),
        (
            "opencc-t2s",
            Box::new(|text| to_text(&convert_opencc(&opencc_t2s, &utf16(text)))),
        ),
        (
            "opencc-t2s+exclude",
            Box::new(|text| to_text(&convert_opencc_excluded(&opencc_t2s, &utf16(text)))),
        ),
        (
            "opencc-tw2s",
            Box::new(|text| to_text(&convert_opencc(&opencc_tw2s, &utf16(text)))),
        ),
        (
            "opencc-tw2sp",
            Box::new(|text| to_text(&convert_opencc(&opencc_tw2sp, &utf16(text)))),
        ),
    ];

    fs::create_dir_all(&out_dir).expect("cannot create the output directory");
    for (name, candidate) in &candidates {
        let path = out_dir.join(format!("{name}.jsonl"));
        let mut body = String::new();
        for row in &rows {
            let source = row["source"].as_str().expect("gold row without a source");
            body.push_str(&format!(
                "{}\n",
                serde_json::json!({"id": row["id"], "output": candidate(source)})
            ));
        }
        fs::write(&path, body)
            .unwrap_or_else(|error| panic!("cannot write {}: {error}", path.display()));
        println!("  {}", path.display());
    }

    // The control: the character-only path of the crate against this matcher's
    // copy of the same tables. The reading conversion is deliberately different
    // (it has the phrase tables), so it is not the control.
    let mut differences = 0usize;
    let mut shown = 0usize;
    for row in &rows {
        let source = row["source"].as_str().unwrap();
        let shipped = to_text(&convert(&source, Direction::TraditionalToSimplified).encode_utf16().collect::<Vec<u16>>());
        let matcher = to_text(&hanlp.convert(&utf16(source)));
        if shipped != matcher {
            differences += 1;
            if shown < 5 {
                println!("  control mismatch: {source:?} shipped {shipped:?} matcher {matcher:?}");
                shown += 1;
            }
        }
    }
    println!(
        "control: hanlp+exclude differs from liber-now on {differences} / {} rows",
        rows.len()
    );
}

fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}
