//! THROWAWAY: measure Traditional/Simplified conversion tables against the
//! frozen baseline (ticket #19).
//!
//! Usage:
//!   conversion_probe <baseline.jsonl> <jar-tc-dir> <hanlp-tc-dir> <report.json>
//!
//! `<baseline.jsonl>` is written by the Java oracle (`BaselineOracle.java`,
//! documented in this directory's README) and holds one record per corpus line:
//! `{"i":..,"src":..,"t2s":..,"s2t":..}` — the frozen `quick-transfer-core`
//! 0.2.16 tables plus Legado's exclude list for `t2s`.
//!
//! For every candidate this prints, per direction: how many UTF-16 code units
//! differ from the baseline, how many lines differ, the most frequent diff
//! hunks, and the single-code-unit substitutions. Two of the candidates are
//! *controls*: the baseline's own tables re-run through this probe's
//! longest-match matcher. They must reproduce the baseline exactly; if they do
//! not, the probe's matcher is wrong and no other row means anything.
//!
//! The baseline operates on UTF-16 code units (Java `char`), so everything here
//! does too: a non-BMP character is two units, and `String.length()`-style
//! decisions (a one-unit table entry goes to the character map, longer entries
//! go to the trie, the trie's maximum key length bounds a match) follow.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde_json::{json, Value};

/// A text table exactly as `DictionaryFactory.loadDictionary` reads it: one
/// `key=value` per line, `#` starts a comment, a key and value that are both one
/// UTF-16 unit form the character map, everything else the longest-match trie.
struct Table {
    char_map: HashMap<u16, u16>,
    by_first: HashMap<u16, Vec<(Vec<u16>, Vec<u16>)>>,
    max_len: usize,
}

impl Table {
    fn load(path: &Path) -> Table {
        let text = fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
        let mut char_map = HashMap::new();
        let mut by_first: HashMap<u16, Vec<(Vec<u16>, Vec<u16>)>> = HashMap::new();
        let mut max_len = 2usize;
        for line in text.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else { continue };
            let key: Vec<u16> = key.encode_utf16().collect();
            let value: Vec<u16> = value.encode_utf16().collect();
            if key.len() == 1 && value.len() == 1 {
                char_map.insert(key[0], value[0]);
            } else {
                max_len = max_len.max(key.len());
                by_first.entry(key[0]).or_default().push((key, value));
            }
        }
        for entries in by_first.values_mut() {
            // Longest first, so the first match is the longest match.
            entries.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
        }
        Table { char_map, by_first, max_len }
    }

    /// `BasicDictionary.remove`: a one-unit entry leaves the character map, a
    /// longer one keeps itself unchanged by entering the trie as an identity.
    fn exclude(&mut self, word: &str) {
        let word: Vec<u16> = word.encode_utf16().collect();
        if word.len() == 1 {
            self.char_map.remove(&word[0]);
        } else {
            self.max_len = self.max_len.max(word.len());
            self.by_first
                .entry(word[0])
                .or_default()
                .insert(0, (word.clone(), word));
        }
    }

    /// `BasicDictionary.convert`: longest table match at each position, else one
    /// character through the character map.
    fn convert(&self, input: &[u16]) -> Vec<u16> {
        let mut out = Vec::with_capacity(input.len());
        let mut at = 0usize;
        while at < input.len() {
            let limit = (at + self.max_len).min(input.len());
            let mut matched: Option<(&Vec<u16>, &Vec<u16>)> = None;
            if let Some(entries) = self.by_first.get(&input[at]) {
                for (key, value) in entries {
                    if key.len() <= limit - at && key[..] == input[at..at + key.len()] {
                        matched = Some((key, value));
                        break;
                    }
                }
            }
            match matched {
                Some((key, value)) => {
                    out.extend_from_slice(value);
                    at += key.len();
                }
                None => {
                    out.push(*self.char_map.get(&input[at]).unwrap_or(&input[at]));
                    at += 1;
                }
            }
        }
        out
    }
}

/// Legado's `fixT2sDict` exclude list, in the order the baseline loads it.
const EXCLUDE: &[&str] = &[
    "槃", "划槳", "列根", "雪梨", "雪糕", "零錢", "零钱", "離線", "碟片", "模組", "桌球", "案頭",
    "機車", "電漿", "鳳梨", "魔戒", "載入", "菲林", "整合", "變數", "路易斯", "非同步", "出租车",
    "周杰倫", "马铃薯", "馬鈴薯", "機械人", "電單車", "電扶梯", "音效卡", "飆車族", "點陣圖",
    "個入球", "顆進球", "魔獸紀元", "高空彈跳", "铁达尼号", "魔鬼終結者", "純文字檔案",
];

/// Whole-word protection for the exclude list in front of a converter that has
/// no such list: mask each occurrence with a private-use unit, convert, restore.
/// Longest word first and non-overlapping, which is what the baseline's matcher
/// does with identity entries.
fn mask_excluded(input: &[u16]) -> (Vec<u16>, Vec<(u16, Vec<u16>)>) {
    const BASE: u16 = 0xE000;
    let masked: Vec<Vec<u16>> = EXCLUDE.iter().map(|word| word.encode_utf16().collect()).collect();
    let mut out: Vec<u16> = Vec::with_capacity(input.len());
    let mut restored: Vec<(u16, Vec<u16>)> = Vec::new();
    let mut at = 0usize;
    'outer: while at < input.len() {
        for (index, word) in masked.iter().enumerate() {
            if word.len() <= input.len() - at && word[..] == input[at..at + word.len()] {
                let unit = BASE + index as u16;
                out.push(unit);
                restored.push((unit, word.clone()));
                at += word.len();
                continue 'outer;
            }
        }
        out.push(input[at]);
        at += 1;
    }
    (out, restored)
}

fn unmask_excluded(input: &str, restored: &[(u16, Vec<u16>)]) -> Vec<u16> {
    let mut out: Vec<u16> = Vec::new();
    for unit in input.encode_utf16() {
        match restored.iter().find(|(marker, _)| *marker == unit) {
            Some((_, word)) => out.extend_from_slice(word),
            None => out.push(unit),
        }
    }
    out
}

/// One mismatching run: the run itself (`core_*`) and the same run with up to
/// `CONTEXT` matching units on either side (`ctx_*`), which is what a reader
/// needs to judge it.
struct Run {
    core_base: Vec<u16>,
    core_cand: Vec<u16>,
    ctx_base: Vec<u16>,
    ctx_cand: Vec<u16>,
}

/// Character-level alignment between two converted lines: how many units do not
/// line up (substitutions plus gaps for the longer side) and the mismatching
/// runs.
fn alignment(baseline: &[u16], candidate: &[u16]) -> (u64, Vec<Run>) {
    const CONTEXT: usize = 6;
    let (n, m) = (baseline.len(), candidate.len());
    if n == 0 || m == 0 {
        return (
            n.max(m) as u64,
            vec![Run {
                core_base: baseline.to_vec(),
                core_cand: candidate.to_vec(),
                ctx_base: baseline.to_vec(),
                ctx_cand: candidate.to_vec(),
            }],
        );
    }
    // LCS length table, then one forward walk over it.
    let mut lengths = vec![0u32; (n + 1) * (m + 1)];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lengths[i * (m + 1) + j] = if baseline[i] == candidate[j] {
                lengths[(i + 1) * (m + 1) + j + 1] + 1
            } else {
                lengths[(i + 1) * (m + 1) + j].max(lengths[i * (m + 1) + j + 1])
            };
        }
    }
    let mismatched = n.max(m) as u64 - lengths[0] as u64;
    let mut runs: Vec<(usize, usize, usize, usize)> = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if baseline[i] == candidate[j] {
            i += 1;
            j += 1;
            continue;
        }
        let (start_i, start_j) = (i, j);
        while i < n && j < m && baseline[i] != candidate[j] {
            if lengths[(i + 1) * (m + 1) + j] >= lengths[i * (m + 1) + j + 1] {
                i += 1;
            } else {
                j += 1;
            }
        }
        runs.push((start_i, start_j, i, j));
    }
    if i < n || j < m {
        runs.push((i, j, n, m));
    }
    let hunks = runs
        .into_iter()
        .map(|(start_i, start_j, end_i, end_j)| {
            let from_i = start_i.saturating_sub(CONTEXT);
            let from_j = start_j.saturating_sub(CONTEXT);
            Run {
                core_base: baseline[start_i..end_i].to_vec(),
                core_cand: candidate[start_j..end_j].to_vec(),
                ctx_base: baseline[from_i..(end_i + CONTEXT).min(n)].to_vec(),
                ctx_cand: candidate[from_j..(end_j + CONTEXT).min(m)].to_vec(),
            }
        })
        .collect();
    (mismatched, hunks)
}

fn to_text(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

fn rate(differing: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        (differing as f64) / (total as f64)
    }
}

/// One measured candidate in one direction.
struct Report {
    name: String,
    direction: String,
    differing_units: u64,
    total_units: u64,
    differing_lines: u64,
    total_lines: u64,
    hunk_counts: HashMap<(String, String), u64>,
    substitution_counts: HashMap<(String, String), u64>,
}

impl Report {
    fn new(name: &str, direction: &str) -> Report {
        Report {
            name: name.into(),
            direction: direction.into(),
            differing_units: 0,
            total_units: 0,
            differing_lines: 0,
            total_lines: 0,
            hunk_counts: HashMap::new(),
            substitution_counts: HashMap::new(),
        }
    }

    fn record(&mut self, baseline: &[u16], candidate: &[u16]) {
        self.total_lines += 1;
        self.total_units += baseline.len() as u64;
        if baseline == candidate {
            return;
        }
        self.differing_lines += 1;
        let (mismatched, runs) = alignment(baseline, candidate);
        self.differing_units += mismatched;
        for run in runs {
            let hunk_key = (to_text(&run.ctx_base), to_text(&run.ctx_cand));
            let core_key = (to_text(&run.core_base), to_text(&run.core_cand));
            if run.core_base.len() == 1 && run.core_cand.len() == 1 {
                *self.substitution_counts.entry(core_key).or_default() += 1;
            }
            *self.hunk_counts.entry(hunk_key).or_default() += 1;
        }
    }

    fn to_json(&self) -> Value {
        let mut top_hunks: Vec<(&(String, String), &u64)> = self.hunk_counts.iter().collect();
        top_hunks.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        let mut top_substitutions: Vec<(&(String, String), &u64)> =
            self.substitution_counts.iter().collect();
        top_substitutions.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        json!({
            "name": self.name,
            "direction": self.direction,
            "differing_code_units": self.differing_units,
            "total_code_units": self.total_units,
            "code_unit_rate": rate(self.differing_units, self.total_units),
            "differing_lines": self.differing_lines,
            "total_lines": self.total_lines,
            "line_rate": rate(self.differing_lines, self.total_lines),
            "distinct_hunks": self.hunk_counts.len(),
            "top_hunks": top_hunks.iter().take(60).map(|((base, cand), count)| json!({
                "baseline": base, "candidate": cand, "count": count,
            })).collect::<Vec<Value>>(),
            "top_substitutions": top_substitutions.iter().take(60).map(|((base, cand), count)| json!({
                "baseline": base, "candidate": cand, "count": count,
            })).collect::<Vec<Value>>(),
        })
    }
}

fn opencc(config_name: &str) -> ferrous_opencc::OpenCC {
    use ferrous_opencc::config::BuiltinConfig;
    let config = match config_name {
        "t2s" => BuiltinConfig::T2s,
        "tw2sp" => BuiltinConfig::Tw2sp,
        "s2t" => BuiltinConfig::S2t,
        other => panic!("unknown builtin config {other}"),
    };
    ferrous_opencc::OpenCC::from_config(config)
        .unwrap_or_else(|error| panic!("cannot open builtin config {config_name}: {error}"))
}

fn convert_opencc(converter: &ferrous_opencc::OpenCC, input: &[u16]) -> Vec<u16> {
    converter.convert(&to_text(input)).encode_utf16().collect()
}

fn convert_opencc_excluded(converter: &ferrous_opencc::OpenCC, input: &[u16]) -> Vec<u16> {
    let (masked, restored) = mask_excluded(input);
    unmask_excluded(&converter.convert(&to_text(&masked)), &restored)
}

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
    let dump_path = if args.len() == 7 && args[5] == "--dump" { Some(&args[6]) } else { None };
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
            let baseline = if report.direction == "t2s" { &baseline_t2s } else { &baseline_s2t };
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
    fs::write(report_path, serde_json::to_string_pretty(&report).unwrap() + "\n")
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
