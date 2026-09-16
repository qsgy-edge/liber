//! THROWAWAY: measure Traditional/Simplified conversion tables against the
//! frozen baseline (ticket #19).
//!
//! Usage:
//!   conversion_probe <baseline.jsonl> <jar-tc-dir> <hanlp-tc-dir> <report.json>
//!                    [--dump <per-line.jsonl>]
//!
//! `<baseline.jsonl>` is written by the Java oracle (`BaselineOracle.java`,
//! documented in this directory's README) and holds one record per corpus line:
//! `{"i":..,"src":..,"t2s":..,"s2t":..}` — the frozen `quick-transfer-core`
//! 0.2.16 tables plus Legado's exclude list for `t2s`.
//!
//! For every candidate this prints, per direction: how many UTF-16 code units
//! differ from the baseline, how many lines differ, the most frequent diff
//! hunks, and the single-code-unit substitutions. Two of the candidates are
//! *controls*: the baseline's own tables re-run through the probe's matcher.
//! They must reproduce the baseline exactly; if they do not, the matcher is
//! wrong and no other row means anything.
//!
//! The matcher and the alignment live in this crate's library (`src/lib.rs`),
//! which the accuracy evaluation (`src/bin/eval.rs`) shares.

use std::fs;
use std::path::Path;

use conversion_probe::{
    convert_opencc, convert_opencc_excluded, opencc, rate, to_text, Report, Table, EXCLUDE,
};
use liber_text::{convert_to, ConvertTarget};
use serde_json::{json, Value};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 && args.len() != 7 {
        eprintln!(
            "usage: conversion_probe <baseline.jsonl> <jar-tc-dir> <hanlp-tc-dir> <report.json> \
             [--dump <per-line.jsonl>]"
        );
        std::process::exit(2);
    }
    let (baseline_path, jar_dir, hanlp_dir, report_path) = (&args[1], &args[2], &args[3], &args[4]);
    let dump_path = if args.len() == 7 && args[5] == "--dump" {
        Some(&args[6])
    } else {
        None
    };
    let jar_dir = Path::new(jar_dir);
    let hanlp_dir = Path::new(hanlp_dir);

    let records: Vec<Value> = fs::read_to_string(baseline_path)
        .expect("cannot read the baseline jsonl")
        .lines()
        .map(|line| serde_json::from_str(line).expect("baseline line is not JSON"))
        .collect();

    let mut jar_t2s = Table::load(&jar_dir.join("t2s.txt"));
    let mut hanlp_t2s = Table::load(&hanlp_dir.join("t2s.txt"));
    for word in EXCLUDE {
        jar_t2s.exclude(word);
        hanlp_t2s.exclude(word);
    }
    let jar_s2t = Table::load(&jar_dir.join("s2t.txt"));
    let hanlp_s2t = Table::load(&hanlp_dir.join("s2t.txt"));
    let opencc_t2s = opencc("t2s");
    let opencc_tw2sp = opencc("tw2sp");
    let opencc_s2t = opencc("s2t");

    let mut reports: Vec<Report> = vec![
        Report::new("liber-reading", "t2s"),
        Report::new("jar-fmm+exclude", "t2s"),
        Report::new("hanlp-fmm+exclude", "t2s"),
        Report::new("opencc-t2s+exclude", "t2s"),
        Report::new("opencc-t2s", "t2s"),
        Report::new("opencc-tw2sp+exclude", "t2s"),
        Report::new("opencc-tw2sp", "t2s"),
        Report::new("jar-fmm", "s2t"),
        Report::new("hanlp-fmm", "s2t"),
        Report::new("opencc-s2t", "s2t"),
    ];

    // The exclude list under every candidate, word by word.
    let mut exclude_cases: Vec<Value> = Vec::new();
    for word in EXCLUDE {
        let units: Vec<u16> = word.encode_utf16().collect();
        exclude_cases.push(json!({
            "word": word,
            "baseline_t2s": to_text(&jar_t2s.convert(&units)),
            "hanlp_t2s": to_text(&hanlp_t2s.convert(&units)),
            "opencc_t2s": to_text(&convert_opencc(&opencc_t2s, &units)),
            "opencc_t2s+exclude": to_text(&convert_opencc_excluded(&opencc_t2s, &units)),
            "opencc_tw2sp": to_text(&convert_opencc(&opencc_tw2sp, &units)),
            "opencc_tw2sp+exclude": to_text(&convert_opencc_excluded(&opencc_tw2sp, &units)),
        }));
    }

    let mut dump = dump_path.map(|path| {
        fs::File::create(path).unwrap_or_else(|error| panic!("cannot create {path}: {error}"))
    });
    for record in &records {
        let source: Vec<u16> = record["src"].as_str().unwrap().encode_utf16().collect();
        let baseline_t2s: Vec<u16> = record["t2s"].as_str().unwrap().encode_utf16().collect();
        let baseline_s2t: Vec<u16> = record["s2t"].as_str().unwrap().encode_utf16().collect();
        let conversions: Vec<Vec<u16>> = vec![
            utf16(&convert_to(
                &to_text(&source),
                ConvertTarget::SimplifiedMainland,
            )),
            jar_t2s.convert(&source),
            hanlp_t2s.convert(&source),
            convert_opencc_excluded(&opencc_t2s, &source),
            convert_opencc(&opencc_t2s, &source),
            convert_opencc_excluded(&opencc_tw2sp, &source),
            convert_opencc(&opencc_tw2sp, &source),
            jar_s2t.convert(&source),
            hanlp_s2t.convert(&source),
            convert_opencc(&opencc_s2t, &source),
        ];
        if let Some(file) = dump.as_mut() {
            use std::io::Write;
            let mut line = serde_json::Map::new();
            line.insert("i".into(), record["i"].clone());
            line.insert("src".into(), record["src"].clone());
            line.insert("baseline_t2s".into(), record["t2s"].clone());
            line.insert("baseline_s2t".into(), record["s2t"].clone());
            for (report, converted) in reports.iter().zip(&conversions) {
                line.insert(
                    format!("{}:{}", report.name, report.direction),
                    json!(to_text(converted)),
                );
            }
            writeln!(file, "{}", Value::Object(line)).expect("cannot write the dump");
        }
        for (report, converted) in reports.iter_mut().zip(&conversions) {
            let baseline = if report.direction == "t2s" {
                &baseline_t2s
            } else {
                &baseline_s2t
            };
            report.record(baseline, converted);
        }
    }

    let report = json!({
        "note": "Conversion-table measurement for ticket #19; see README.md for re-running it.",
        "baseline": {
            "conversion": "quick-transfer-core 0.2.16 (the version the frozen Legado snapshot pins) with Legado's fixT2sDict exclude list for t2s",
            "oracle": "tool/text_engine_prototype/README.md, BaselineOracle.java",
            "records": records.len(),
            "code_units": records.iter().map(|r| r["src"].as_str().unwrap().encode_utf16().count() as u64).sum::<u64>(),
        },
        "candidates": reports.iter().map(|report| report.to_json()).collect::<Vec<Value>>(),
        "exclude_cases": exclude_cases,
    });
    fs::write(
        report_path,
        serde_json::to_string_pretty(&report).unwrap() + "\n",
    )
    .expect("cannot write the report");
    for report in &reports {
        println!(
            "{:<22} {:<4} units {:>12} / {:<12} = {:.6}   lines {:>6} = {:.6}   distinct hunks {}",
            report.name,
            report.direction,
            report.differing_units,
            report.total_units,
            rate(report.differing_units, report.total_units),
            report.differing_lines,
            rate(report.differing_lines, report.total_lines),
            report.hunk_counts.len(),
        );
    }
}

fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}
