//! Shared pieces of the ticket-#19 conversion harnesses: the frozen library's
//! table matcher (`Table`, `EXCLUDE`), the diff alignment used to describe a
//! candidate's divergences, and the OpenCC wrappers.
//!
//! Everything is in UTF-16 code units (Java `char`), because the frozen library
//! is: a non-BMP character is two units, a one-unit table entry goes to the
//! character map, longer entries go to the longest-match trie, and a trie
//! match's maximum key length bounds the search.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde_json::{json, Value};

/// One trie entry: the key to match and the value to write.
type Entry = (Vec<u16>, Vec<u16>);

/// A text table exactly as `DictionaryFactory.loadDictionary` reads it: one
/// `key=value` per line, `#` starts a comment, a key and value that are both one
/// UTF-16 unit form the character map, everything else the longest-match trie.
pub struct Table {
    pub char_map: HashMap<u16, u16>,
    pub by_first: HashMap<u16, Vec<Entry>>,
    pub max_len: usize,
}

impl Table {
    pub fn load(path: &Path) -> Table {
        let text = fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
        let mut char_map = HashMap::new();
        let mut by_first: HashMap<u16, Vec<Entry>> = HashMap::new();
        let mut max_len = 2usize;
        for line in text.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
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
            entries.sort_by_key(|entry| std::cmp::Reverse(entry.0.len()));
        }
        Table {
            char_map,
            by_first,
            max_len,
        }
    }

    /// Adds one `key` → `value` mapping, as a table file's line would.
    pub fn insert(&mut self, key: &str, value: &str) {
        let key: Vec<u16> = key.encode_utf16().collect();
        let value: Vec<u16> = value.encode_utf16().collect();
        if key.is_empty() {
            return;
        }
        if key.len() == 1 && value.len() == 1 {
            self.char_map.insert(key[0], value[0]);
        } else {
            self.max_len = self.max_len.max(key.len());
            let entries = self.by_first.entry(key[0]).or_default();
            entries.push((key, value));
            // Longest first, so the first match in `convert` is the longest one;
            // equal-length entries keep the order they were added in.
            entries.sort_by_key(|entry| std::cmp::Reverse(entry.0.len()));
        }
    }

    /// `BasicDictionary.remove`: a one-unit entry leaves the character map, a
    /// longer one keeps itself unchanged by entering the trie as an identity.
    pub fn exclude(&mut self, word: &str) {
        let word: Vec<u16> = word.encode_utf16().collect();
        if word.len() == 1 {
            self.char_map.remove(&word[0]);
        } else {
            self.max_len = self.max_len.max(word.len());
            // In front: an excluded word must win over a table phrase of the same
            // length, which is what makes e.g. 雪梨 stay 雪梨 rather than become
            // 悉尼 through the Taiwan-phrase table.
            self.by_first
                .entry(word[0])
                .or_default()
                .insert(0, (word.clone(), word));
        }
    }

    /// `BasicDictionary.convert`: longest table match at each position, else one
    /// character through the character map.
    pub fn convert(&self, input: &[u16]) -> Vec<u16> {
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
pub const EXCLUDE: &[&str] = &[
    "槃",
    "划槳",
    "列根",
    "雪梨",
    "雪糕",
    "零錢",
    "零钱",
    "離線",
    "碟片",
    "模組",
    "桌球",
    "案頭",
    "機車",
    "電漿",
    "鳳梨",
    "魔戒",
    "載入",
    "菲林",
    "整合",
    "變數",
    "路易斯",
    "非同步",
    "出租车",
    "周杰倫",
    "马铃薯",
    "馬鈴薯",
    "機械人",
    "電單車",
    "電扶梯",
    "音效卡",
    "飆車族",
    "點陣圖",
    "個入球",
    "顆進球",
    "魔獸紀元",
    "高空彈跳",
    "铁达尼号",
    "魔鬼終結者",
    "純文字檔案",
];

/// Whole-word protection for the exclude list in front of a converter that has
/// no such list: mask each occurrence with a private-use unit, convert, restore.
/// Longest word first and non-overlapping, which is what the baseline's matcher
/// does with identity entries.
pub fn mask_excluded(input: &[u16]) -> (Vec<u16>, Vec<(u16, Vec<u16>)>) {
    const BASE: u16 = 0xE000;
    let masked: Vec<Vec<u16>> = EXCLUDE
        .iter()
        .map(|word| word.encode_utf16().collect())
        .collect();
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

pub fn unmask_excluded(input: &str, restored: &[(u16, Vec<u16>)]) -> Vec<u16> {
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
pub struct Run {
    pub core_base: Vec<u16>,
    pub core_cand: Vec<u16>,
    pub ctx_base: Vec<u16>,
    pub ctx_cand: Vec<u16>,
}

/// Character-level alignment between two converted lines: how many units do not
/// line up (substitutions plus gaps for the longer side) and the mismatching
/// runs.
pub fn alignment(baseline: &[u16], candidate: &[u16]) -> (u64, Vec<Run>) {
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

pub fn to_text(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

pub fn rate(differing: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        (differing as f64) / (total as f64)
    }
}

/// One measured candidate in one direction.
pub struct Report {
    pub name: String,
    pub direction: String,
    pub differing_units: u64,
    pub total_units: u64,
    pub differing_lines: u64,
    pub total_lines: u64,
    pub hunk_counts: HashMap<(String, String), u64>,
    pub substitution_counts: HashMap<(String, String), u64>,
}

impl Report {
    pub fn new(name: &str, direction: &str) -> Report {
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

    pub fn record(&mut self, baseline: &[u16], candidate: &[u16]) {
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

    pub fn to_json(&self) -> Value {
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

pub fn opencc(config_name: &str) -> ferrous_opencc::OpenCC {
    use ferrous_opencc::config::BuiltinConfig;
    let config = match config_name {
        "t2s" => BuiltinConfig::T2s,
        "tw2s" => BuiltinConfig::Tw2s,
        "hk2s" => BuiltinConfig::Hk2s,
        "tw2sp" => BuiltinConfig::Tw2sp,
        "s2t" => BuiltinConfig::S2t,
        other => panic!("unknown builtin config {other}"),
    };
    ferrous_opencc::OpenCC::from_config(config)
        .unwrap_or_else(|error| panic!("cannot open builtin config {config_name}: {error}"))
}

pub fn convert_opencc(converter: &ferrous_opencc::OpenCC, input: &[u16]) -> Vec<u16> {
    converter.convert(&to_text(input)).encode_utf16().collect()
}

pub fn convert_opencc_excluded(converter: &ferrous_opencc::OpenCC, input: &[u16]) -> Vec<u16> {
    let (masked, restored) = mask_excluded(input);
    unmask_excluded(&converter.convert(&to_text(&masked)), &restored)
}
