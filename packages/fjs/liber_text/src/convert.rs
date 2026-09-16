//! The frozen reader's Chinese conversion: longest-match tables, UTF-16 units,
//! and Legado's `t2s` exclude list.
//!
//! The tables are embedded text (see `assets/hanlp-tc/PROVENANCE.md`), parsed
//! once per process. Everything works on UTF-16 code units because that is what
//! the frozen implementation's `char[]` is and what a Dart string is: a
//! non-BMP character is two units, and whether a table entry goes to the
//! character map or the trie depends on that count.

use std::collections::HashMap;
use std::sync::OnceLock;

/// Which direction to convert.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Traditional to Simplified (`java.t2s`, the reader's 简体 setting).
    TraditionalToSimplified,
    /// Simplified to Traditional (`java.s2t`, the reader's 繁體 setting).
    SimplifiedToTraditional,
}

/// Words Legado keeps verbatim in `t2s`, in its own order
/// (`io.legado.app.utils.ChineseUtils.fixT2sDict`). Each one is the identity
/// mapping the frozen library installs, which is what makes e.g. 魔戒 stay 魔戒
/// although the table would turn it into 指环王.
pub const T2S_EXCLUDE: &[&str] = &[
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

/// The embedded tables, as NUL-free UTF-8 text.
const T2S_TABLE: &str = include_str!("../assets/hanlp-tc/t2s.txt");
const S2T_TABLE: &str = include_str!("../assets/hanlp-tc/s2t.txt");

/// A conversion table in the shape the frozen `DictionaryFactory` builds: a
/// character map for one-unit entries and a trie of longer entries.
/// Longer entries, grouped by their first unit and ordered longest first, so the
/// first match at a position is the longest match.
type TrieIndex = HashMap<u16, Vec<(Vec<u16>, Vec<u16>)>>;

struct Table {
    char_map: HashMap<u16, u16>,
    by_first: TrieIndex,
    /// The longest key in the trie; a match never reaches past it.
    max_len: usize,
}

impl Table {
    /// Reads `key=value` lines the way `DictionaryFactory.loadDictionary` does:
    /// `#` comments and empty lines are dropped, a line without `=` is skipped,
    /// one-unit key and value go to the character map, anything else to the trie.
    fn parse(text: &str) -> Table {
        let mut char_map = HashMap::new();
        let mut by_first: TrieIndex = HashMap::new();
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
            if key.is_empty() || value.is_empty() {
                continue;
            }
            if key.len() == 1 && value.len() == 1 {
                char_map.insert(key[0], value[0]);
            } else {
                max_len = max_len.max(key.len());
                by_first.entry(key[0]).or_default().push((key, value));
            }
        }
        for entries in by_first.values_mut() {
            entries.sort_by_key(|entry| std::cmp::Reverse(entry.0.len()));
        }
        Table {
            char_map,
            by_first,
            max_len,
        }
    }

    /// `BasicDictionary.remove`: a one-unit word leaves the character map; a
    /// longer one enters the trie mapping to itself, so the whole word survives.
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
            let limit = at + self.max_len.min(input.len() - at);
            let mut matched: Option<&(Vec<u16>, Vec<u16>)> = None;
            if let Some(entries) = self.by_first.get(&input[at]) {
                for entry in entries {
                    if entry.0.len() <= limit - at && entry.0[..] == input[at..at + entry.0.len()] {
                        matched = Some(entry);
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

fn t2s() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = Table::parse(T2S_TABLE);
        for word in T2S_EXCLUDE {
            table.exclude(word);
        }
        table
    })
}

fn s2t() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| Table::parse(S2T_TABLE))
}

/// Converts `text` in one direction and returns the result.
///
/// Working per string rather than per file is deliberate: the reader converts a
/// chapter and a TOC title, the host surface converts whatever a rule hands it,
/// and the tables are position-independent, so a chapter converted alone gives
/// the same text as the same chapter converted inside its file.
pub fn convert(text: &str, direction: Direction) -> String {
    let table = match direction {
        Direction::TraditionalToSimplified => t2s(),
        Direction::SimplifiedToTraditional => s2t(),
    };
    let units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16_lossy(&table.convert(&units))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t2s_of(text: &str) -> String {
        convert(text, Direction::TraditionalToSimplified)
    }

    fn s2t_of(text: &str) -> String {
        convert(text, Direction::SimplifiedToTraditional)
    }

    /// The exclude list, word by word: every one of these stays as it is, which
    /// is the whole point of Legado loading it.
    #[test]
    fn excluded_words_are_kept_verbatim() {
        for word in T2S_EXCLUDE {
            assert_eq!(&t2s_of(word), word, "excluded word {word} was converted");
        }
    }

    /// The exclude list does not spread to other words that share a character.
    #[test]
    fn exclusion_is_per_word() {
        // 槃 is excluded on its own, but 盤 is not excluded and still converts.
        assert_eq!(t2s_of("涅槃"), "涅槃");
        assert_eq!(t2s_of("棋盤"), "棋盘");
        // 雪糕 is excluded, 雪 is not.
        assert_eq!(t2s_of("雪糕"), "雪糕");
        assert_eq!(t2s_of("下雪"), "下雪");
        // 魔戒 is excluded; 魔鬼終結者 is excluded too, 魔 alone is not.
        assert_eq!(t2s_of("魔戒"), "魔戒");
        assert_eq!(t2s_of("魔鬼終結者"), "魔鬼終結者");
        assert_eq!(t2s_of("惡魔"), "恶魔");
    }

    /// The measured fixture: every row is one input line, what the frozen
    /// baseline produced for it, and what this product's tables produce. Rows
    /// where the two differ are marked `divergence` by the generator, so a table
    /// or matcher change that moves the output — and a divergence that appeared or
    /// disappeared — fails the test and shows up as a fixture diff instead of
    /// shipping silently.
    const FIXTURE: &str = include_str!("../assets/conversion_fixtures.tsv");

    #[test]
    fn fixture_rows_are_what_the_tables_produce() {
        let (mut agreements, mut divergences) = (0u32, 0u32);
        let mut failures = Vec::new();
        for (number, line) in FIXTURE.lines().enumerate() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = line.split('\t').collect();
            let [direction, input, expected, baseline, note] = fields.as_slice() else {
                failures.push(format!("第 {} 行不是 5 列", number + 1));
                continue;
            };
            let direction = match *direction {
                "t2s" => Direction::TraditionalToSimplified,
                "s2t" => Direction::SimplifiedToTraditional,
                other => {
                    failures.push(format!("第 {} 行的方向 {other} 未知", number + 1));
                    continue;
                }
            };
            let actual = convert(input, direction);
            if actual != *expected {
                failures.push(format!(
                    "第 {} 行 {input}：表产出 {actual:?}，期望 {expected:?}",
                    number + 1
                ));
            }
            // The two output columns have to keep telling the truth about each
            // other: a row that disagrees with the baseline without saying so is
            // how a divergence gets lost.
            let marked = *note == "divergence";
            if marked == (expected == baseline) {
                failures.push(format!(
                    "第 {} 行 {input}：备注 {note:?} 与两列的关系不符",
                    number + 1
                ));
            }
            if marked {
                divergences += 1;
            } else {
                agreements += 1;
            }
        }
        assert!(
            failures.is_empty(),
            "{} 行不符：\n{}",
            failures.len(),
            failures.join("\n")
        );
        assert!(agreements > 0, "fixture 里没有与冻结基线一致的行");
        // Eight rows diverge with the tables measured in ADR 0009; a different
        // number is a different product and the ADR has to say so.
        assert_eq!(
            divergences, 8,
            "与冻结基线的差异行数变了，需要更新 ADR 0009"
        );
    }

    #[test]
    fn non_bmp_and_ascii_units_survive() {
        assert_eq!(t2s_of("abc 123 \u{2b748} 測試"), "abc 123 \u{2b748} 测试");
        assert_eq!(s2t_of("abc 123 \u{2b748} 测试"), "abc 123 㑮 測試");
    }
}
